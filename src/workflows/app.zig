const std = @import("std");
const builtin = @import("builtin");
const app_runtime = @import("../core/runtime.zig");
const io_util = @import("../core/io_util.zig");
const http_child = @import("../api/http_child.zig");
const registry = @import("../registry/root.zig");
const types = @import("../cli/types.zig");

const codex_cli_path_env = "CODEX_CLI_PATH";
const codex_home_env = "CODEX_HOME";
const app_path_env = "CODEX_AUTH_APP_PATH";
const codex_app_package_name = "OpenAI.Codex";
const codex_app_bundle_id = "com.openai.codex";
const wsl_agent_mode_key = "runCodexInWindowsSubsystemForLinux";
const codext_repo_latest_url = "https://api.github.com/repos/Loongphy/codext/releases/latest";
const codext_cache_dir_name = "codext-cli";
const guarded_script_name = "codex-auth-app-shim";
const guarded_windows_shim_name = "codex-auth-app-shim.exe";
const mac_persistent_env_label = "com.codex-auth.app-env";

const ValueSource = enum { explicit, env, detected, cached, downloaded, not_set };

const ResolvedValue = struct {
    value: ?[]const u8,
    source: ValueSource,
    owned: bool = false,

    fn deinit(self: ResolvedValue, allocator: std.mem.Allocator) void {
        if (self.owned) if (self.value) |value| allocator.free(@constCast(value));
    }
};

const ResolvedPlatform = struct {
    value: ?types.AppPlatform,
    source: ValueSource,
};

pub fn handleApp(allocator: std.mem.Allocator, resolved_codex_home: []const u8, opts: types.AppOptions) !void {
    const effective_home = opts.codex_home orelse resolved_codex_home;
    const effective_platform = try resolvePlatform(allocator, effective_home, opts.platform);
    if (opts.action == .launch or opts.action == .patch) try validateAppPlatform(effective_platform.value);
    const effective_app_path = try resolveAppPath(allocator, opts);
    defer effective_app_path.deinit(allocator);
    const allow_download = opts.action == .launch or opts.action == .patch;
    const quiet_download = opts.action == .launch;
    const effective_cli_path = try resolveCliPath(allocator, effective_home, effective_platform.value, opts, allow_download, quiet_download);
    defer effective_cli_path.deinit(allocator);
    const persistent_cli_path = if (opts.action == .status) try readPersistentCliPath(allocator) else null;
    defer if (persistent_cli_path) |path| allocator.free(path);

    switch (opts.action) {
        .status => try printStatus(effective_app_path, effective_cli_path, persistent_cli_path, effective_home, effective_platform),
        .launch => try launchApp(allocator, effective_app_path, effective_cli_path, effective_home, effective_platform, opts.inherit_stdio),
        .patch => try patchApp(allocator, effective_app_path, effective_cli_path, effective_home, effective_platform),
        .unpatch => try unpatchApp(allocator),
    }
}

fn getOptionalEnv(allocator: std.mem.Allocator, name: []const u8) ?[]const u8 {
    const value = registry.getEnvVarOwned(allocator, name) catch return null;
    if (value.len == 0) {
        allocator.free(value);
        return null;
    }
    return value;
}

fn resolveAppPath(allocator: std.mem.Allocator, opts: types.AppOptions) !ResolvedValue {
    if (opts.app_path) |path| return .{ .value = path, .source = .explicit };
    if (getOptionalEnv(allocator, app_path_env)) |path| return .{ .value = path, .source = .env, .owned = true };
    if (try detectInstalledAppPath(allocator)) |path| return .{ .value = path, .source = .detected, .owned = true };
    return .{ .value = null, .source = .not_set };
}

fn resolveCliPath(
    allocator: std.mem.Allocator,
    home: []const u8,
    platform: ?types.AppPlatform,
    opts: types.AppOptions,
    allow_download: bool,
    quiet_download: bool,
) !ResolvedValue {
    if (opts.codex_cli_path) |path| return .{ .value = path, .source = .explicit };

    const target_platform = platform orelse nativeDefaultPlatform();
    if (allow_download) {
        const path = try downloadDefaultCodextCli(allocator, home, target_platform, quiet_download);
        return .{ .value = path, .source = .downloaded, .owned = true };
    }
    if (try cachedCodextCliPath(allocator, home, target_platform)) |path| return .{ .value = path, .source = .cached, .owned = true };
    return .{ .value = null, .source = .not_set };
}

fn resolvePlatform(allocator: std.mem.Allocator, home: []const u8, explicit: ?types.AppPlatform) !ResolvedPlatform {
    if (explicit) |platform| return .{ .value = platform, .source = .explicit };
    if (builtin.os.tag == .windows) {
        const use_wsl = try readWindowsWslBackendSetting(allocator, home);
        return .{ .value = if (use_wsl) .wsl else .win, .source = .detected };
    }
    if (builtin.os.tag == .macos) return .{ .value = .mac, .source = .detected };
    return .{ .value = null, .source = .not_set };
}

fn nativeDefaultPlatform() types.AppPlatform {
    return switch (builtin.os.tag) {
        .windows => .win,
        .macos => .mac,
        else => .wsl,
    };
}

fn readWindowsWslBackendSetting(allocator: std.mem.Allocator, home: []const u8) !bool {
    const state_path = try std.fs.path.join(allocator, &.{ home, ".codex-global-state.json" });
    defer allocator.free(state_path);

    var file = std.Io.Dir.cwd().openFile(app_runtime.io(), state_path, .{}) catch |err| switch (err) {
        error.FileNotFound => return false,
        else => return err,
    };
    defer file.close(app_runtime.io());
    const data = try registry.readFileAlloc(file, allocator, 1024 * 1024);
    defer allocator.free(data);

    const parsed = std.json.parseFromSlice(std.json.Value, allocator, data, .{}) catch return false;
    defer parsed.deinit();
    const object = switch (parsed.value) {
        .object => |object| object,
        else => return false,
    };
    const value = object.get(wsl_agent_mode_key) orelse return false;
    return switch (value) {
        .bool => |enabled| enabled,
        else => false,
    };
}

fn printStatus(
    app_path: ResolvedValue,
    cli_path: ResolvedValue,
    persistent_cli_path: ?[]const u8,
    home: []const u8,
    platform: ResolvedPlatform,
) !void {
    var stdout: io_util.Stdout = undefined;
    stdout.init();
    const out = stdout.out();
    try out.writeAll("Codex App launch environment\n");
    try out.print("  app path: {s} ({s})\n", .{ app_path.value orelse "(not set)", valueSourceName(app_path.source) });
    try out.print("  CODEX_HOME: {s}\n", .{home});
    try out.print("  CODEX_CLI_PATH: {s} ({s})\n", .{ cli_path.value orelse "(not cached)", valueSourceName(cli_path.source) });
    try out.print("  persistent CODEX_CLI_PATH: {s}\n", .{persistent_cli_path orelse "(not set)"});
    try out.print("  platform: {s} ({s})\n", .{ appPlatformName(platform.value), valueSourceName(platform.source) });
    try out.flush();
}

fn launchApp(
    allocator: std.mem.Allocator,
    app_path: ResolvedValue,
    cli_path: ResolvedValue,
    home: []const u8,
    platform: ResolvedPlatform,
    inherit_stdio: bool,
) !void {
    const target = app_path.value orelse {
        try writeAppError("app launch could not find the installed Codex app. Pass `--app-path <path>` or set CODEX_AUTH_APP_PATH.\n");
        return error.AppPathRequired;
    };
    try validateAppPlatform(platform.value);
    try applyAppPlatform(allocator, home, platform.value);

    if (inherit_stdio) {
        return launchExecutableWithStdio(allocator, target, cli_path.value, home);
    }

    if (builtin.os.tag == .windows) {
        return launchWindowsViaPowerShell(allocator, target, app_path.source, cli_path.value, home);
    }
    if (looksLikeWindowsPath(target) or looksLikeWslWindowsMountPath(target)) {
        try writeAppError("windows app launch must run from the Windows codex-auth executable.\n");
        return error.WindowsAppLaunchRequiresWindows;
    }
    if (builtin.os.tag == .macos) {
        return launchMac(allocator, target, app_path.source, cli_path.value, home);
    }
    try writeAppError("app launch is supported only from the Windows or macOS codex-auth executable.\n");
    return error.UnsupportedPlatform;
}

fn patchApp(
    allocator: std.mem.Allocator,
    app_path: ResolvedValue,
    cli_path: ResolvedValue,
    home: []const u8,
    platform: ResolvedPlatform,
) !void {
    try validateAppPlatform(platform.value);
    try applyAppPlatform(allocator, home, platform.value);
    const target_cli = cli_path.value orelse {
        try writeAppError("app patch could not resolve CODEX_CLI_PATH. Pass `--codex-cli-path <path>` or allow the default Loongphy codext download.\n");
        return error.CliPathRequired;
    };
    const target_app = app_path.value orelse {
        try writeAppError("app patch could not find the installed Codex app. Pass `--app-path <path>` or set CODEX_AUTH_APP_PATH.\n");
        return error.AppPathRequired;
    };
    const launch_path = try resolveLaunchPath(allocator, target_app);
    defer allocator.free(launch_path);
    const target_platform = platform.value orelse return error.UnsupportedPlatform;
    const shim_path = try installGuardedCliShim(allocator, home, launch_path, target_cli, target_platform);
    defer allocator.free(shim_path);
    try persistCliPath(allocator, shim_path);
    try writeAppOutput("persistent CODEX_CLI_PATH={s}\n", .{shim_path});
    try writeAppOutput("guarded target CLI={s}\n", .{target_cli});
}

fn unpatchApp(allocator: std.mem.Allocator) !void {
    try clearPersistentCliPath(allocator);
    try writeAppOutput("persistent CODEX_CLI_PATH cleared\n", .{});
}

fn appPlatformName(value: ?types.AppPlatform) []const u8 {
    return switch (value orelse return "(not set)") {
        .win => "win",
        .wsl => "wsl",
        .mac => "mac",
    };
}

fn valueSourceName(value: ValueSource) []const u8 {
    return switch (value) {
        .explicit => "explicit",
        .env => "env",
        .detected => "detected",
        .cached => "cached",
        .downloaded => "downloaded",
        .not_set => "not set",
    };
}

fn validateAppPlatform(value: ?types.AppPlatform) !void {
    const platform = value orelse return;
    switch (platform) {
        .win, .wsl => if (builtin.os.tag != .windows) {
            try writeAppError("app with `--platform win` or `--platform wsl` must run from the Windows codex-auth executable.\n");
            return error.WindowsAppPlatformRequiresWindows;
        },
        .mac => if (builtin.os.tag != .macos) {
            try writeAppError("app with `--platform mac` must run from the macOS codex-auth executable.\n");
            return error.MacAppPlatformRequiresMacOS;
        },
    }
}

fn applyAppPlatform(allocator: std.mem.Allocator, home: []const u8, value: ?types.AppPlatform) !void {
    const platform = value orelse return;
    const use_wsl = switch (platform) {
        .win => false,
        .wsl => true,
        .mac => return,
    };
    const state_path = try std.fs.path.join(allocator, &.{ home, ".codex-global-state.json" });
    defer allocator.free(state_path);

    if (std.fs.path.dirname(state_path)) |dir| {
        try std.Io.Dir.cwd().createDirPath(app_runtime.io(), dir);
    }

    var parsed: ?std.json.Parsed(std.json.Value) = null;
    defer if (parsed) |*p| p.deinit();

    var root: std.json.Value = blk: {
        var file = std.Io.Dir.cwd().openFile(app_runtime.io(), state_path, .{}) catch |err| switch (err) {
            error.FileNotFound => break :blk .{ .object = .{} },
            else => return err,
        };
        defer file.close(app_runtime.io());
        const data = try registry.readFileAlloc(file, allocator, 1024 * 1024);
        defer allocator.free(data);
        parsed = std.json.parseFromSlice(std.json.Value, allocator, data, .{}) catch {
            break :blk .{ .object = .{} };
        };
        break :blk switch (parsed.?.value) {
            .object => try cloneJsonValue(allocator, parsed.?.value),
            else => .{ .object = .{} },
        };
    };
    defer deinitClonedJsonValue(allocator, &root);

    switch (root) {
        .object => |*obj| try obj.put(allocator, wsl_agent_mode_key, .{ .bool = use_wsl }),
        else => unreachable,
    }

    var aw: std.Io.Writer.Allocating = .init(allocator);
    defer aw.deinit();
    try std.json.Stringify.value(root, .{ .whitespace = .indent_2 }, &aw.writer);

    var file = try std.Io.Dir.cwd().createFile(app_runtime.io(), state_path, .{ .truncate = true });
    defer file.close(app_runtime.io());
    try file.writeStreamingAll(app_runtime.io(), aw.written());
}

fn cloneJsonValue(allocator: std.mem.Allocator, value: std.json.Value) !std.json.Value {
    return switch (value) {
        .null, .bool, .integer, .float, .number_string, .string => value,
        .array => |array| blk: {
            var cloned = std.json.Array.init(allocator);
            for (array.items) |item| {
                try cloned.append(try cloneJsonValue(allocator, item));
            }
            break :blk .{ .array = cloned };
        },
        .object => |object| blk: {
            var cloned: std.json.ObjectMap = .{};
            for (object.keys(), object.values()) |key, item| {
                try cloned.put(allocator, key, try cloneJsonValue(allocator, item));
            }
            break :blk .{ .object = cloned };
        },
    };
}

fn deinitClonedJsonValue(allocator: std.mem.Allocator, value: *std.json.Value) void {
    switch (value.*) {
        .array => |*array| {
            for (array.items) |*item| deinitClonedJsonValue(allocator, item);
            array.deinit();
        },
        .object => |*object| {
            for (object.values()) |*item| deinitClonedJsonValue(allocator, item);
            object.deinit(allocator);
        },
        else => {},
    }
}

fn looksLikeWindowsPath(path: []const u8) bool {
    return (path.len >= 3 and std.ascii.isAlphabetic(path[0]) and path[1] == ':' and (path[2] == '\\' or path[2] == '/')) or
        std.mem.startsWith(u8, path, "\\\\");
}

fn looksLikeWslWindowsMountPath(path: []const u8) bool {
    return std.mem.startsWith(u8, path, "/mnt/") and path.len >= "/mnt/c/".len and path[6] == '/';
}

fn launchExecutableWithStdio(
    allocator: std.mem.Allocator,
    app_path: []const u8,
    cli_path: ?[]const u8,
    home: []const u8,
) !void {
    const launch_path = try resolveLaunchPath(allocator, app_path);
    defer allocator.free(launch_path);

    var env_map = try registry.getEnvMap(allocator);
    defer env_map.deinit();
    try env_map.put(codex_home_env, home);
    if (cli_path) |path| try env_map.put(codex_cli_path_env, path);

    var child = try std.process.spawn(app_runtime.io(), .{
        .argv = &[_][]const u8{launch_path},
        .environ_map = &env_map,
        .stdin = .ignore,
        .stdout = .inherit,
        .stderr = .inherit,
    });
    _ = try child.wait(app_runtime.io());
}

fn launchMac(
    allocator: std.mem.Allocator,
    app_path: []const u8,
    app_source: ValueSource,
    cli_path: ?[]const u8,
    home: []const u8,
) !void {
    if (!isDirectory(app_path) and std.mem.indexOf(u8, app_path, ".app") == null) {
        try writeAppError("macOS app launch requires an app bundle path such as `/Applications/Codex.app`.\n");
        return error.AppPathRequired;
    }

    const home_env = try std.fmt.allocPrint(allocator, "{s}={s}", .{ codex_home_env, home });
    defer allocator.free(home_env);
    const cli_env = if (cli_path) |path| try std.fmt.allocPrint(allocator, "{s}={s}", .{ codex_cli_path_env, path }) else null;
    defer if (cli_env) |value| allocator.free(value);

    var argv = std.ArrayList([]const u8).empty;
    defer argv.deinit(allocator);
    try argv.append(allocator, "/usr/bin/open");
    try argv.appendSlice(allocator, &[_][]const u8{ "--env", home_env });
    if (cli_env) |value| try argv.appendSlice(allocator, &[_][]const u8{ "--env", value });
    try argv.appendSlice(allocator, &[_][]const u8{
        "--stdout",
        "/dev/null",
        "--stderr",
        "/dev/null",
    });
    if (app_source == .detected) {
        try argv.appendSlice(allocator, &[_][]const u8{ "-b", codex_app_bundle_id });
    } else {
        try argv.append(allocator, app_path);
    }
    var child = try std.process.spawn(app_runtime.io(), .{
        .argv = argv.items,
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .ignore,
    });
    _ = try child.wait(app_runtime.io());
}

fn resolveLaunchPath(allocator: std.mem.Allocator, app_path: []const u8) ![]u8 {
    if (!isDirectory(app_path)) return try allocator.dupe(u8, app_path);

    const candidates = [_][]const u8{
        "Codex.exe",
        "codex.exe",
        "app/Codex.exe",
        "app/codex.exe",
        "Codex",
        "codex",
        "Contents/MacOS/Codex",
        "Contents/MacOS/codex",
    };
    for (candidates) |candidate| {
        const joined = try std.fs.path.join(allocator, &.{ app_path, candidate });
        if (fileExists(joined)) return joined;
        allocator.free(joined);
    }
    return error.AppExecutableNotFound;
}

fn isDirectory(path: []const u8) bool {
    const stat = std.Io.Dir.cwd().statFile(app_runtime.io(), path, .{}) catch return false;
    return stat.kind == .directory;
}

fn fileExists(path: []const u8) bool {
    std.Io.Dir.cwd().access(app_runtime.io(), path, .{}) catch return false;
    return true;
}

pub fn isGuardedShimExecutablePath(path: []const u8) bool {
    const base = std.fs.path.basename(path);
    return std.mem.eql(u8, base, guarded_windows_shim_name) or
        std.mem.eql(u8, base, guarded_script_name) or
        (std.mem.startsWith(u8, base, "codex-patch-") and (std.mem.endsWith(u8, base, ".exe") or std.mem.indexOfScalar(u8, base, '.') == null));
}

const GuardedShimConfig = struct {
    expected_root: []u8,
    target_cli: []u8,

    fn deinit(self: GuardedShimConfig, allocator: std.mem.Allocator) void {
        allocator.free(self.expected_root);
        allocator.free(self.target_cli);
    }
};

pub fn runGuardedAppShim(allocator: std.mem.Allocator, init: std.process.Init.Minimal) !void {
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const args = try init.args.toSlice(arena_state.allocator());

    const self_exe = try std.process.executablePathAlloc(app_runtime.io(), allocator);
    defer allocator.free(self_exe);
    const config = try readGuardedShimConfig(allocator, self_exe);
    defer config.deinit(allocator);

    const cwd_z = try std.process.currentPathAlloc(app_runtime.io(), allocator);
    defer allocator.free(cwd_z);
    const cwd = std.mem.sliceTo(cwd_z, 0);

    const target = if (pathHasRoot(cwd, config.expected_root, builtin.os.tag == .windows))
        try allocator.dupe(u8, config.target_cli)
    else
        try fallbackCliForCurrentApp(allocator, cwd);
    defer allocator.free(target);

    var argv = std.ArrayList([]const u8).empty;
    defer argv.deinit(allocator);
    try argv.append(allocator, target);
    for (args[1..]) |arg| try argv.append(allocator, std.mem.sliceTo(arg, 0));

    var env_map = try registry.getEnvMap(allocator);
    defer env_map.deinit();
    var child = try std.process.spawn(app_runtime.io(), .{
        .argv = argv.items,
        .environ_map = &env_map,
        .stdin = .inherit,
        .stdout = .inherit,
        .stderr = .inherit,
    });
    const term = try child.wait(app_runtime.io());
    switch (term) {
        .exited => |code| std.process.exit(@intCast(@min(code, 255))),
        else => std.process.exit(1),
    }
}

fn readGuardedShimConfig(allocator: std.mem.Allocator, self_exe: []const u8) !GuardedShimConfig {
    const config_path = try std.fmt.allocPrint(allocator, "{s}.json", .{self_exe});
    defer allocator.free(config_path);
    var file = try std.Io.Dir.cwd().openFile(app_runtime.io(), config_path, .{});
    defer file.close(app_runtime.io());
    const data = try registry.readFileAlloc(file, allocator, 1024 * 1024);
    defer allocator.free(data);
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, data, .{});
    defer parsed.deinit();
    const object = switch (parsed.value) {
        .object => |object| object,
        else => return error.InvalidGuardedShimConfig,
    };
    const expected_root = switch (object.get("expected_root") orelse return error.InvalidGuardedShimConfig) {
        .string => |value| try allocator.dupe(u8, value),
        else => return error.InvalidGuardedShimConfig,
    };
    errdefer allocator.free(expected_root);
    const target_cli = switch (object.get("target_cli") orelse return error.InvalidGuardedShimConfig) {
        .string => |value| try allocator.dupe(u8, value),
        else => return error.InvalidGuardedShimConfig,
    };
    return .{ .expected_root = expected_root, .target_cli = target_cli };
}

fn fallbackCliForCurrentApp(allocator: std.mem.Allocator, cwd: []const u8) ![]u8 {
    const candidates = [_][]const u8{ "codex.exe", "codex" };
    for (candidates) |name| {
        const candidate = try std.fs.path.join(allocator, &.{ cwd, name });
        if (fileExists(candidate)) return candidate;
        allocator.free(candidate);
    }
    try writeAppError("codex-auth app shim skipped the guarded override because the app package changed, but no bundled fallback CLI was found in the current app resources.\n");
    return error.GuardedShimFallbackNotFound;
}

fn pathHasRoot(path: []const u8, root: []const u8, case_insensitive: bool) bool {
    if (path.len < root.len) return false;
    const path_prefix = path[0..root.len];
    const prefix_matches = if (case_insensitive)
        std.ascii.eqlIgnoreCase(path_prefix, root)
    else
        std.mem.eql(u8, path_prefix, root);
    if (!prefix_matches) return false;
    if (path.len == root.len) return true;
    return path[root.len] == '/' or path[root.len] == '\\';
}

fn installGuardedCliShim(
    allocator: std.mem.Allocator,
    home: []const u8,
    app_launch_path: []const u8,
    target_cli: []const u8,
    platform: types.AppPlatform,
) ![]u8 {
    const expected_root = try appGuardRootAlloc(allocator, app_launch_path, platform);
    defer allocator.free(expected_root);
    const shim_dir = try std.fs.path.join(allocator, &.{ home, "accounts", codext_cache_dir_name });
    defer allocator.free(shim_dir);
    try std.Io.Dir.cwd().createDirPath(app_runtime.io(), shim_dir);

    return switch (platform) {
        .win => try installWindowsGuardedCliShim(allocator, shim_dir, expected_root, target_cli),
        .wsl => try installWslGuardedCliShim(allocator, shim_dir, home, expected_root, target_cli),
        .mac => try installMacGuardedCliShim(allocator, shim_dir, expected_root, target_cli),
    };
}

fn installWindowsGuardedCliShim(
    allocator: std.mem.Allocator,
    shim_dir: []const u8,
    expected_root: []const u8,
    target_cli: []const u8,
) ![]u8 {
    const self_exe = try std.process.executablePathAlloc(app_runtime.io(), allocator);
    defer allocator.free(self_exe);
    const shim_name = try guardedShimFileName(allocator, .win);
    defer allocator.free(shim_name);
    const shim_path = try std.fs.path.join(allocator, &.{ shim_dir, shim_name });
    errdefer allocator.free(shim_path);
    try std.Io.Dir.copyFileAbsolute(self_exe, shim_path, app_runtime.io(), .{ .replace = true, .make_path = true });
    const config_path = try std.fmt.allocPrint(allocator, "{s}.json", .{shim_path});
    defer allocator.free(config_path);
    const config = try guardedShimConfigText(allocator, expected_root, target_cli);
    defer allocator.free(config);
    try std.Io.Dir.cwd().writeFile(app_runtime.io(), .{ .sub_path = config_path, .data = config });
    return shim_path;
}

fn installWslGuardedCliShim(
    allocator: std.mem.Allocator,
    shim_dir: []const u8,
    home: []const u8,
    expected_root: []const u8,
    target_cli: []const u8,
) ![]u8 {
    const expected_wsl = try windowsPathToWslPathAlloc(allocator, expected_root);
    defer allocator.free(expected_wsl);
    const target_wsl = try windowsPathToWslPathAlloc(allocator, target_cli);
    defer allocator.free(target_wsl);
    const home_wsl = try windowsPathToWslPathAlloc(allocator, home);
    defer allocator.free(home_wsl);
    const script = try wslGuardedShimScript(allocator, expected_wsl, target_wsl, home_wsl);
    defer allocator.free(script);
    const shim_name = try guardedShimFileName(allocator, .wsl);
    defer allocator.free(shim_name);
    const shim_path = try std.fs.path.join(allocator, &.{ shim_dir, shim_name });
    errdefer allocator.free(shim_path);
    try writeExecutableTextFile(shim_path, script);
    return shim_path;
}

fn installMacGuardedCliShim(
    allocator: std.mem.Allocator,
    shim_dir: []const u8,
    expected_root: []const u8,
    target_cli: []const u8,
) ![]u8 {
    const expected_version = try readMacBundleVersion(allocator, expected_root);
    defer allocator.free(expected_version);
    const script = try macGuardedShimScript(allocator, expected_root, expected_version, target_cli);
    defer allocator.free(script);
    const shim_name = try guardedShimFileName(allocator, .mac);
    defer allocator.free(shim_name);
    const shim_path = try std.fs.path.join(allocator, &.{ shim_dir, shim_name });
    errdefer allocator.free(shim_path);
    try writeExecutableTextFile(shim_path, script);
    return shim_path;
}

fn writeExecutableTextFile(path: []const u8, data: []const u8) !void {
    try std.Io.Dir.cwd().writeFile(app_runtime.io(), .{ .sub_path = path, .data = data });
    if (builtin.os.tag != .windows) {
        try std.Io.Dir.cwd().setFilePermissions(app_runtime.io(), path, std.Io.File.Permissions.fromMode(0o755), .{});
    }
}

fn guardedShimFileName(allocator: std.mem.Allocator, platform: types.AppPlatform) ![]u8 {
    return if (platform == .win)
        try std.fmt.allocPrint(allocator, "codex-patch-{s}.exe", .{codextPlatformCacheName(platform)})
    else
        try std.fmt.allocPrint(allocator, "codex-patch-{s}", .{codextPlatformCacheName(platform)});
}

fn guardedShimConfigText(allocator: std.mem.Allocator, expected_root: []const u8, target_cli: []const u8) ![]u8 {
    const escaped_root = try jsonEscapeAlloc(allocator, expected_root);
    defer allocator.free(escaped_root);
    const escaped_target = try jsonEscapeAlloc(allocator, target_cli);
    defer allocator.free(escaped_target);
    return try std.fmt.allocPrint(
        allocator,
        "{{\"expected_root\":\"{s}\",\"target_cli\":\"{s}\"}}\n",
        .{ escaped_root, escaped_target },
    );
}

fn wslGuardedShimScript(allocator: std.mem.Allocator, expected_root: []const u8, target_cli: []const u8, fallback_home: []const u8) ![]u8 {
    const expected_quoted = try shellSingleQuoteAlloc(allocator, expected_root);
    defer allocator.free(expected_quoted);
    const target_quoted = try shellSingleQuoteAlloc(allocator, target_cli);
    defer allocator.free(target_quoted);
    const fallback_home_quoted = try shellSingleQuoteAlloc(allocator, fallback_home);
    defer allocator.free(fallback_home_quoted);
    return try std.fmt.allocPrint(
        allocator,
        \\#!/usr/bin/env bash
        \\set -e
        \\expected={s}
        \\target={s}
        \\fallback_home={s}
        \\case "$PWD" in
        \\  "$expected"|"$expected"/*) exec "$target" "$@" ;;
        \\esac
        \\for fallback in "${{CODEX_HOME:-}}/bin/wsl/codex" "$fallback_home/bin/wsl/codex"; do
        \\  if [ -x "$fallback" ]; then exec "$fallback" "$@"; fi
        \\done
        \\printf '%s\n' 'codex-auth app shim skipped the guarded override because the app package changed, but no bundled fallback CLI was found.' >&2
        \\exit 126
        \\
    ,
        .{ expected_quoted, target_quoted, fallback_home_quoted },
    );
}

fn macGuardedShimScript(allocator: std.mem.Allocator, expected_root: []const u8, expected_version: []const u8, target_cli: []const u8) ![]u8 {
    const root_quoted = try shellSingleQuoteAlloc(allocator, expected_root);
    defer allocator.free(root_quoted);
    const version_quoted = try shellSingleQuoteAlloc(allocator, expected_version);
    defer allocator.free(version_quoted);
    const target_quoted = try shellSingleQuoteAlloc(allocator, target_cli);
    defer allocator.free(target_quoted);
    return try std.fmt.allocPrint(
        allocator,
        \\#!/usr/bin/env bash
        \\set -e
        \\expected_root={s}
        \\expected_version={s}
        \\target={s}
        \\current_version=$(/usr/bin/defaults read "$expected_root/Contents/Info" CFBundleVersion 2>/dev/null || true)
        \\if [ "$current_version" = "$expected_version" ]; then
        \\  exec "$target" "$@"
        \\fi
        \\for fallback in "$PWD/codex" "$expected_root/Contents/Resources/codex"; do
        \\  if [ -x "$fallback" ]; then exec "$fallback" "$@"; fi
        \\done
        \\printf '%s\n' 'codex-auth app shim skipped the guarded override because the app bundle version changed, but no bundled fallback CLI was found.' >&2
        \\exit 126
        \\
    ,
        .{ root_quoted, version_quoted, target_quoted },
    );
}

fn appGuardRootAlloc(allocator: std.mem.Allocator, app_launch_path: []const u8, platform: types.AppPlatform) ![]u8 {
    if (platform == .mac) {
        if (std.mem.indexOf(u8, app_launch_path, ".app")) |idx| {
            return try allocator.dupe(u8, app_launch_path[0 .. idx + ".app".len]);
        }
    }

    if (indexOfIgnoreCase(app_launch_path, "\\app\\codex.exe")) |idx| return try allocator.dupe(u8, app_launch_path[0..idx]);
    if (indexOfIgnoreCase(app_launch_path, "/app/codex.exe")) |idx| return try allocator.dupe(u8, app_launch_path[0..idx]);
    if (std.fs.path.dirname(app_launch_path)) |dir| {
        if (std.fs.path.dirname(dir)) |parent| return try allocator.dupe(u8, parent);
        return try allocator.dupe(u8, dir);
    }
    return try allocator.dupe(u8, app_launch_path);
}

fn readMacBundleVersion(allocator: std.mem.Allocator, app_root: []const u8) ![]u8 {
    const info_path = try std.fs.path.join(allocator, &.{ app_root, "Contents", "Info.plist" });
    defer allocator.free(info_path);
    var result = try http_child.runChildCapture(
        allocator,
        &[_][]const u8{ "/usr/bin/plutil", "-extract", "CFBundleVersion", "raw", "-o", "-", info_path },
        7000,
        null,
    );
    defer result.deinit(allocator);
    const trimmed = std.mem.trim(u8, result.stdout, " \t\r\n");
    if (trimmed.len == 0) return error.MacBundleVersionNotFound;
    return try allocator.dupe(u8, trimmed);
}

fn windowsPathToWslPathAlloc(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    if (std.mem.startsWith(u8, path, "/")) return try allocator.dupe(u8, path);
    if (path.len >= 3 and std.ascii.isAlphabetic(path[0]) and path[1] == ':' and (path[2] == '\\' or path[2] == '/')) {
        var out = std.ArrayList(u8).empty;
        errdefer out.deinit(allocator);
        try out.appendSlice(allocator, "/mnt/");
        try out.append(allocator, std.ascii.toLower(path[0]));
        for (path[2..]) |ch| {
            try out.append(allocator, if (ch == '\\') '/' else ch);
        }
        return try out.toOwnedSlice(allocator);
    }
    return try allocator.dupe(u8, path);
}

fn indexOfIgnoreCase(haystack: []const u8, needle: []const u8) ?usize {
    if (needle.len == 0) return 0;
    if (haystack.len < needle.len) return null;
    var i: usize = 0;
    while (i + needle.len <= haystack.len) : (i += 1) {
        if (std.ascii.eqlIgnoreCase(haystack[i .. i + needle.len], needle)) return i;
    }
    return null;
}

fn readPersistentCliPath(allocator: std.mem.Allocator) !?[]u8 {
    return switch (builtin.os.tag) {
        .windows => readWindowsPersistentCliPath(allocator),
        .macos => readMacPersistentCliPath(allocator),
        else => null,
    };
}

fn readWindowsPersistentCliPath(allocator: std.mem.Allocator) !?[]u8 {
    var result = http_child.runChildCapture(
        allocator,
        &[_][]const u8{ "pwsh.exe", "-NoProfile", "-Command", "[Console]::Out.Write([Environment]::GetEnvironmentVariable('CODEX_CLI_PATH','User'))" },
        7000,
        null,
    ) catch return null;
    defer result.deinit(allocator);
    return switch (result.term) {
        .exited => |code| if (code == 0) try dupTrimmedOrNull(allocator, result.stdout) else null,
        else => null,
    };
}

fn readMacPersistentCliPath(allocator: std.mem.Allocator) !?[]u8 {
    var result = http_child.runChildCapture(
        allocator,
        &[_][]const u8{ "launchctl", "getenv", codex_cli_path_env },
        7000,
        null,
    ) catch return null;
    defer result.deinit(allocator);
    return switch (result.term) {
        .exited => |code| if (code == 0) try dupTrimmedOrNull(allocator, result.stdout) else null,
        else => null,
    };
}

fn dupTrimmedOrNull(allocator: std.mem.Allocator, value: []const u8) !?[]u8 {
    const trimmed = std.mem.trim(u8, value, " \t\r\n");
    if (trimmed.len == 0) return null;
    return try allocator.dupe(u8, trimmed);
}

fn persistCliPath(allocator: std.mem.Allocator, cli_path: []const u8) !void {
    switch (builtin.os.tag) {
        .windows => try persistWindowsCliPath(allocator, cli_path),
        .macos => try persistMacCliPath(allocator, cli_path),
        else => {
            try writeAppError("app patch is supported only from the Windows or macOS codex-auth executable.\n");
            return error.UnsupportedPlatform;
        },
    }
}

fn clearPersistentCliPath(allocator: std.mem.Allocator) !void {
    switch (builtin.os.tag) {
        .windows => try clearWindowsPersistentCliPath(allocator),
        .macos => try clearMacPersistentCliPath(allocator),
        else => {
            try writeAppError("app unpatch is supported only from the Windows or macOS codex-auth executable.\n");
            return error.UnsupportedPlatform;
        },
    }
}

fn persistWindowsCliPath(allocator: std.mem.Allocator, cli_path: []const u8) !void {
    const cli_quoted = try psSingleQuoteAlloc(allocator, cli_path);
    defer allocator.free(cli_quoted);
    const script = try std.fmt.allocPrint(
        allocator,
        "$ErrorActionPreference='Stop'; [Environment]::SetEnvironmentVariable('CODEX_CLI_PATH',{s},'User'); try {{ $sig='[DllImport(\"user32.dll\", SetLastError=true, CharSet=CharSet.Auto)] public static extern IntPtr SendMessageTimeout(IntPtr hWnd, int Msg, UIntPtr wParam, string lParam, int fuFlags, int uTimeout, out UIntPtr lpdwResult);'; Add-Type -MemberDefinition $sig -Name NativeMethods -Namespace CodexAuthEnv -ErrorAction SilentlyContinue; $r=[UIntPtr]::Zero; [CodexAuthEnv.NativeMethods]::SendMessageTimeout([IntPtr]0xffff,0x1A,[UIntPtr]::Zero,'Environment',0x2,5000,[ref]$r) | Out-Null }} catch {{ }}",
        .{cli_quoted},
    );
    defer allocator.free(script);
    try runChecked(allocator, &[_][]const u8{ "pwsh.exe", "-NoProfile", "-Command", script }, 7000);
}

fn clearWindowsPersistentCliPath(allocator: std.mem.Allocator) !void {
    const script =
        "$ErrorActionPreference='Stop'; [Environment]::SetEnvironmentVariable('CODEX_CLI_PATH',$null,'User'); try { $sig='[DllImport(\"user32.dll\", SetLastError=true, CharSet=CharSet.Auto)] public static extern IntPtr SendMessageTimeout(IntPtr hWnd, int Msg, UIntPtr wParam, string lParam, int fuFlags, int uTimeout, out UIntPtr lpdwResult);'; Add-Type -MemberDefinition $sig -Name NativeMethods -Namespace CodexAuthEnv -ErrorAction SilentlyContinue; $r=[UIntPtr]::Zero; [CodexAuthEnv.NativeMethods]::SendMessageTimeout([IntPtr]0xffff,0x1A,[UIntPtr]::Zero,'Environment',0x2,5000,[ref]$r) | Out-Null } catch { }";
    try runChecked(allocator, &[_][]const u8{ "pwsh.exe", "-NoProfile", "-Command", script }, 7000);
}

fn persistMacCliPath(allocator: std.mem.Allocator, cli_path: []const u8) !void {
    const plist_path = try macPersistentEnvPlistPath(allocator);
    defer allocator.free(plist_path);
    const plist = try macPersistentEnvPlistText(allocator, cli_path);
    defer allocator.free(plist);

    if (std.fs.path.dirname(plist_path)) |dir| {
        try std.Io.Dir.cwd().createDirPath(app_runtime.io(), dir);
    }
    try std.Io.Dir.cwd().writeFile(app_runtime.io(), .{ .sub_path = plist_path, .data = plist });
    _ = runChecked(allocator, &[_][]const u8{ "launchctl", "unload", plist_path }, 7000) catch {};
    try runChecked(allocator, &[_][]const u8{ "launchctl", "load", plist_path }, 7000);
    try runChecked(allocator, &[_][]const u8{ "launchctl", "setenv", codex_cli_path_env, cli_path }, 7000);
}

fn clearMacPersistentCliPath(allocator: std.mem.Allocator) !void {
    const plist_path = try macPersistentEnvPlistPath(allocator);
    defer allocator.free(plist_path);
    _ = runChecked(allocator, &[_][]const u8{ "launchctl", "unsetenv", codex_cli_path_env }, 7000) catch {};
    _ = runChecked(allocator, &[_][]const u8{ "launchctl", "unload", plist_path }, 7000) catch {};
    std.Io.Dir.deleteFileAbsolute(app_runtime.io(), plist_path) catch |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    };
}

fn macPersistentEnvPlistPath(allocator: std.mem.Allocator) ![]u8 {
    const home = getOptionalEnv(allocator, "HOME") orelse return error.EnvironmentVariableNotFound;
    defer allocator.free(@constCast(home));
    return try std.fs.path.join(allocator, &.{ home, "Library", "LaunchAgents", "com.codex-auth.app-env.plist" });
}

fn macPersistentEnvPlistText(allocator: std.mem.Allocator, cli_path: []const u8) ![]u8 {
    const escaped_path = try xmlEscapeAlloc(allocator, cli_path);
    defer allocator.free(escaped_path);
    return try std.fmt.allocPrint(
        allocator,
        \\<?xml version="1.0" encoding="UTF-8"?>
        \\<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        \\<plist version="1.0">
        \\<dict>
        \\  <key>Label</key>
        \\  <string>{s}</string>
        \\  <key>ProgramArguments</key>
        \\  <array>
        \\    <string>/bin/launchctl</string>
        \\    <string>setenv</string>
        \\    <string>CODEX_CLI_PATH</string>
        \\    <string>{s}</string>
        \\  </array>
        \\  <key>RunAtLoad</key>
        \\  <true/>
        \\</dict>
        \\</plist>
        \\
    ,
        .{ mac_persistent_env_label, escaped_path },
    );
}

fn xmlEscapeAlloc(allocator: std.mem.Allocator, value: []const u8) ![]u8 {
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(allocator);
    for (value) |ch| {
        switch (ch) {
            '&' => try out.appendSlice(allocator, "&amp;"),
            '<' => try out.appendSlice(allocator, "&lt;"),
            '>' => try out.appendSlice(allocator, "&gt;"),
            '"' => try out.appendSlice(allocator, "&quot;"),
            '\'' => try out.appendSlice(allocator, "&apos;"),
            else => try out.append(allocator, ch),
        }
    }
    return try out.toOwnedSlice(allocator);
}

fn jsonEscapeAlloc(allocator: std.mem.Allocator, value: []const u8) ![]u8 {
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(allocator);
    for (value) |ch| {
        switch (ch) {
            '\\' => try out.appendSlice(allocator, "\\\\"),
            '"' => try out.appendSlice(allocator, "\\\""),
            '\n' => try out.appendSlice(allocator, "\\n"),
            '\r' => try out.appendSlice(allocator, "\\r"),
            '\t' => try out.appendSlice(allocator, "\\t"),
            else => try out.append(allocator, ch),
        }
    }
    return try out.toOwnedSlice(allocator);
}

fn shellSingleQuoteAlloc(allocator: std.mem.Allocator, value: []const u8) ![]u8 {
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(allocator);
    try out.append(allocator, '\'');
    for (value) |ch| {
        if (ch == '\'') {
            try out.appendSlice(allocator, "'\\''");
        } else {
            try out.append(allocator, ch);
        }
    }
    try out.append(allocator, '\'');
    return try out.toOwnedSlice(allocator);
}

fn detectInstalledAppPath(allocator: std.mem.Allocator) !?[]u8 {
    return switch (builtin.os.tag) {
        .windows => try detectWindowsInstalledAppPath(allocator),
        .macos => try detectMacInstalledAppPath(allocator),
        else => null,
    };
}

fn detectWindowsInstalledAppPath(allocator: std.mem.Allocator) !?[]u8 {
    const package_quoted = try psSingleQuoteAlloc(allocator, codex_app_package_name);
    defer allocator.free(package_quoted);
    const script = try std.fmt.allocPrint(
        allocator,
        "$ErrorActionPreference='SilentlyContinue'; $pkg=Get-AppxPackage -Name {s} | Sort-Object Version -Descending | Select-Object -First 1; if ($pkg) {{ [Console]::Out.Write($pkg.InstallLocation) }}",
        .{package_quoted},
    );
    defer allocator.free(script);
    var result = try http_child.runChildCapture(allocator, &[_][]const u8{ "pwsh.exe", "-NoProfile", "-Command", script }, 7000, null);
    defer result.deinit(allocator);
    const trimmed = std.mem.trim(u8, result.stdout, " \t\r\n");
    if (trimmed.len == 0) return null;
    return try allocator.dupe(u8, trimmed);
}

fn detectMacInstalledAppPath(allocator: std.mem.Allocator) !?[]u8 {
    const candidates = [_][]const u8{
        "/Applications/Codex.app",
        "~/Applications/Codex.app",
    };
    for (candidates[0..]) |candidate| {
        const expanded = try expandTildePath(allocator, candidate);
        if (isDirectory(expanded) or fileExists(expanded)) return expanded;
        allocator.free(expanded);
    }
    return null;
}

fn expandTildePath(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    if (!std.mem.startsWith(u8, path, "~/")) return try allocator.dupe(u8, path);
    const home = getOptionalEnv(allocator, "HOME") orelse return try allocator.dupe(u8, path);
    defer allocator.free(@constCast(home));
    return try std.fs.path.join(allocator, &.{ home, path[2..] });
}

fn cachedCodextCliPath(allocator: std.mem.Allocator, home: []const u8, platform: types.AppPlatform) !?[]u8 {
    const candidate = try managedCodextExecutablePath(allocator, home, platform);
    if (fileExists(candidate)) return candidate;
    allocator.free(candidate);
    return null;
}

fn downloadDefaultCodextCli(allocator: std.mem.Allocator, home: []const u8, platform: types.AppPlatform, quiet: bool) ![]u8 {
    const release = try fetchLatestCodextRelease(allocator);
    defer release.deinit(allocator);

    const cache_root = try std.fs.path.join(allocator, &.{ home, "accounts", codext_cache_dir_name });
    defer allocator.free(cache_root);
    try std.Io.Dir.cwd().createDirPath(app_runtime.io(), cache_root);

    if (builtin.os.tag == .windows) {
        const win_asset = release.assetFor(.win) orelse return error.CodextReleaseAssetNotFound;
        const wsl_asset = release.assetFor(.wsl) orelse return error.CodextReleaseAssetNotFound;
        try ensureCodextAssetInstalled(allocator, cache_root, release.tag, .win, win_asset, quiet);
        try ensureCodextAssetInstalled(allocator, cache_root, release.tag, .wsl, wsl_asset, quiet);
    } else {
        const asset = release.assetFor(platform) orelse return error.CodextReleaseAssetNotFound;
        try ensureCodextAssetInstalled(allocator, cache_root, release.tag, platform, asset, quiet);
    }

    const installed = try managedCodextExecutablePath(allocator, home, platform);
    if (!fileExists(installed)) {
        allocator.free(installed);
        return error.CodextReleaseInstallFailed;
    }
    return installed;
}

fn managedCodextExecutablePath(allocator: std.mem.Allocator, home: []const u8, platform: types.AppPlatform) ![]u8 {
    const name = try managedCodextExecutableName(allocator, platform);
    defer allocator.free(name);
    return try std.fs.path.join(allocator, &.{ home, "accounts", codext_cache_dir_name, name });
}

fn ensureCodextAssetInstalled(
    allocator: std.mem.Allocator,
    cache_root: []const u8,
    tag: []const u8,
    platform: types.AppPlatform,
    asset: CodextAsset,
    quiet: bool,
) !void {
    if (try managedCodextAssetIsCurrent(allocator, cache_root, tag, platform, asset)) return;
    if (!quiet) try writeAppInfo("downloading from {s}\n", .{asset.url});
    try downloadAndInstallCodextAsset(allocator, cache_root, tag, platform, asset);
}

fn managedCodextAssetIsCurrent(
    allocator: std.mem.Allocator,
    cache_root: []const u8,
    tag: []const u8,
    platform: types.AppPlatform,
    asset: CodextAsset,
) !bool {
    const executable_name = try managedCodextExecutableName(allocator, platform);
    defer allocator.free(executable_name);
    const executable_path = try std.fs.path.join(allocator, &.{ cache_root, executable_name });
    defer allocator.free(executable_path);
    if (!fileExists(executable_path)) return false;

    const version_path = try managedCodextVersionPath(allocator, cache_root, platform);
    defer allocator.free(version_path);
    var file = std.Io.Dir.cwd().openFile(app_runtime.io(), version_path, .{}) catch |err| switch (err) {
        error.FileNotFound => return false,
        else => return err,
    };
    defer file.close(app_runtime.io());
    const data = try registry.readFileAlloc(file, allocator, 16 * 1024);
    defer allocator.free(data);

    const expected = try managedCodextVersionText(allocator, tag, asset);
    defer allocator.free(expected);
    return std.mem.eql(u8, data, expected);
}

fn managedCodextVersionPath(allocator: std.mem.Allocator, cache_root: []const u8, platform: types.AppPlatform) ![]u8 {
    const executable_name = try managedCodextExecutableName(allocator, platform);
    defer allocator.free(executable_name);
    const version_name = try std.fmt.allocPrint(allocator, "{s}.version", .{executable_name});
    defer allocator.free(version_name);
    return try std.fs.path.join(allocator, &.{ cache_root, version_name });
}

fn managedCodextVersionText(allocator: std.mem.Allocator, tag: []const u8, asset: CodextAsset) ![]u8 {
    return try std.fmt.allocPrint(allocator, "tag={s}\nasset={s}\n", .{ tag, asset.name });
}

const CodextAsset = struct {
    name: []u8,
    url: []u8,

    fn deinit(self: CodextAsset, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        allocator.free(self.url);
    }
};

const CodextRelease = struct {
    tag: []u8,
    win_asset: ?CodextAsset = null,
    linux_asset: ?CodextAsset = null,
    mac_asset: ?CodextAsset = null,

    fn deinit(self: CodextRelease, allocator: std.mem.Allocator) void {
        allocator.free(self.tag);
        if (self.win_asset) |value| value.deinit(allocator);
        if (self.linux_asset) |value| value.deinit(allocator);
        if (self.mac_asset) |value| value.deinit(allocator);
    }

    fn assetFor(self: CodextRelease, platform: types.AppPlatform) ?CodextAsset {
        return switch (platform) {
            .win => self.win_asset,
            .wsl => self.linux_asset,
            .mac => self.mac_asset,
        };
    }
};

fn fetchLatestCodextRelease(allocator: std.mem.Allocator) !CodextRelease {
    var result = try http_child.runChildCapture(allocator, &[_][]const u8{ curlExecutable(), "-L", "--fail", "--silent", codext_repo_latest_url }, 15000, null);
    defer result.deinit(allocator);
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, result.stdout, .{});
    defer parsed.deinit();
    const object = switch (parsed.value) {
        .object => |object| object,
        else => return error.InvalidCodextReleaseResponse,
    };
    const tag_value = object.get("tag_name") orelse return error.InvalidCodextReleaseResponse;
    const tag = switch (tag_value) {
        .string => |value| try allocator.dupe(u8, value),
        else => return error.InvalidCodextReleaseResponse,
    };
    var release = CodextRelease{ .tag = tag };
    errdefer release.deinit(allocator);

    const assets_value = object.get("assets") orelse return error.InvalidCodextReleaseResponse;
    const assets = switch (assets_value) {
        .array => |array| array.items,
        else => return error.InvalidCodextReleaseResponse,
    };
    const want_win = releaseAssetNeedle(.win);
    const want_linux = releaseAssetNeedle(.wsl);
    const want_mac = releaseAssetNeedle(.mac);
    for (assets) |asset| {
        const asset_object = switch (asset) {
            .object => |asset_object| asset_object,
            else => continue,
        };
        const name = switch (asset_object.get("name") orelse continue) {
            .string => |value| value,
            else => continue,
        };
        const url = switch (asset_object.get("browser_download_url") orelse continue) {
            .string => |value| value,
            else => continue,
        };
        if (std.mem.indexOf(u8, name, want_win) != null) {
            if (release.win_asset == null) release.win_asset = try dupeCodextAsset(allocator, name, url);
        } else if (std.mem.indexOf(u8, name, want_linux) != null) {
            if (release.linux_asset == null) release.linux_asset = try dupeCodextAsset(allocator, name, url);
        } else if (std.mem.indexOf(u8, name, want_mac) != null) {
            if (release.mac_asset == null) release.mac_asset = try dupeCodextAsset(allocator, name, url);
        }
    }
    return release;
}

fn dupeCodextAsset(allocator: std.mem.Allocator, name: []const u8, url: []const u8) !CodextAsset {
    return .{
        .name = try allocator.dupe(u8, name),
        .url = try allocator.dupe(u8, url),
    };
}

fn downloadAndInstallCodextAsset(
    allocator: std.mem.Allocator,
    cache_root: []const u8,
    tag: []const u8,
    platform: types.AppPlatform,
    asset: CodextAsset,
) !void {
    const extract_dir_name = try std.fmt.allocPrint(allocator, ".extract-{s}", .{codextPlatformCacheName(platform)});
    defer allocator.free(extract_dir_name);
    const extract_dir = try std.fs.path.join(allocator, &.{ cache_root, extract_dir_name });
    defer allocator.free(extract_dir);
    if (isDirectory(extract_dir)) try std.Io.Dir.cwd().deleteTree(app_runtime.io(), extract_dir);
    defer std.Io.Dir.cwd().deleteTree(app_runtime.io(), extract_dir) catch {};
    try std.Io.Dir.cwd().createDirPath(app_runtime.io(), extract_dir);

    const archive_name = if (platform == .win) "codext.zip" else "codext.tar.gz";
    const archive_path = try std.fs.path.join(allocator, &.{ extract_dir, archive_name });
    defer allocator.free(archive_path);
    try runChecked(allocator, &[_][]const u8{ curlExecutable(), "-L", "--fail", "--silent", "--show-error", "-o", archive_path, asset.url }, 120000);
    if (platform == .win) {
        const archive_quoted = try psSingleQuoteAlloc(allocator, archive_path);
        defer allocator.free(archive_quoted);
        const dest_quoted = try psSingleQuoteAlloc(allocator, extract_dir);
        defer allocator.free(dest_quoted);
        const script = try std.fmt.allocPrint(allocator, "Expand-Archive -LiteralPath {s} -DestinationPath {s} -Force", .{ archive_quoted, dest_quoted });
        defer allocator.free(script);
        try runChecked(allocator, &[_][]const u8{ "pwsh.exe", "-NoProfile", "-Command", script }, 120000);
    } else {
        try runChecked(allocator, &[_][]const u8{ tarExecutable(), "-xzf", archive_path, "-C", extract_dir }, 120000);
    }
    try installManagedCodextExecutable(allocator, cache_root, extract_dir, platform);
    try writeManagedCodextVersion(allocator, cache_root, tag, platform, asset);
}

fn writeManagedCodextVersion(
    allocator: std.mem.Allocator,
    cache_root: []const u8,
    tag: []const u8,
    platform: types.AppPlatform,
    asset: CodextAsset,
) !void {
    const version_path = try managedCodextVersionPath(allocator, cache_root, platform);
    defer allocator.free(version_path);
    const data = try managedCodextVersionText(allocator, tag, asset);
    defer allocator.free(data);
    try std.Io.Dir.cwd().writeFile(app_runtime.io(), .{ .sub_path = version_path, .data = data });
}

fn runChecked(allocator: std.mem.Allocator, argv: []const []const u8, timeout_ms: u64) !void {
    var result = try http_child.runChildCapture(allocator, argv, timeout_ms, null);
    defer result.deinit(allocator);
    if (result.timed_out) return error.ChildProcessTimedOut;
    switch (result.term) {
        .exited => |code| if (code == 0) return,
        else => {},
    }
    return error.ChildProcessFailed;
}

fn codextPlatformCacheName(platform: types.AppPlatform) []const u8 {
    return switch (platform) {
        .win => if (builtin.cpu.arch == .aarch64) "win32-arm64" else "win32-x64",
        .wsl => if (builtin.cpu.arch == .aarch64) "linux-arm64" else "linux-x64",
        .mac => if (builtin.cpu.arch == .aarch64) "darwin-arm64" else "darwin-x64",
    };
}

fn releaseAssetNeedle(platform: types.AppPlatform) []const u8 {
    return codextPlatformCacheName(platform);
}

fn curlExecutable() []const u8 {
    return if (builtin.os.tag == .windows) "C:\\Windows\\System32\\curl.exe" else "curl";
}

fn tarExecutable() []const u8 {
    return if (builtin.os.tag == .windows) "C:\\Windows\\System32\\tar.exe" else "tar";
}

fn codextExecutableName(platform: types.AppPlatform) []const u8 {
    return switch (platform) {
        .win => "codex.exe",
        .wsl, .mac => "codex",
    };
}

fn codextReleaseExecutableName(platform: types.AppPlatform) []const u8 {
    return switch (platform) {
        .win => "codext.exe",
        .wsl, .mac => "codext",
    };
}

fn managedCodextExecutableName(allocator: std.mem.Allocator, platform: types.AppPlatform) ![]u8 {
    return if (platform == .win)
        try std.fmt.allocPrint(allocator, "codex-{s}.exe", .{codextPlatformCacheName(platform)})
    else
        try std.fmt.allocPrint(allocator, "codex-{s}", .{codextPlatformCacheName(platform)});
}

fn installManagedCodextExecutable(allocator: std.mem.Allocator, cache_root: []const u8, extract_dir: []const u8, platform: types.AppPlatform) !void {
    const source = try extractedCodextExecutablePath(allocator, extract_dir, platform);
    defer allocator.free(source);
    const target_name = try managedCodextExecutableName(allocator, platform);
    defer allocator.free(target_name);
    const target = try std.fs.path.join(allocator, &.{ cache_root, target_name });
    defer allocator.free(target);
    if (fileExists(target)) try std.Io.Dir.deleteFileAbsolute(app_runtime.io(), target);
    try std.Io.Dir.renameAbsolute(source, target, app_runtime.io());
}

fn extractedCodextExecutablePath(allocator: std.mem.Allocator, extract_dir: []const u8, platform: types.AppPlatform) ![]u8 {
    const primary = try std.fs.path.join(allocator, &.{ extract_dir, codextExecutableName(platform) });
    if (fileExists(primary)) return primary;
    allocator.free(primary);

    const release = try std.fs.path.join(allocator, &.{ extract_dir, codextReleaseExecutableName(platform) });
    if (fileExists(release)) return release;
    allocator.free(release);

    return error.CodextReleaseInstallFailed;
}

fn writeAppError(message: []const u8) !void {
    var buffer: [512]u8 = undefined;
    var writer = std.Io.File.stderr().writer(app_runtime.io(), &buffer);
    const out = &writer.interface;
    try out.writeAll(message);
    try out.flush();
}

fn writeAppInfo(comptime format: []const u8, args: anytype) !void {
    var buffer: [1024]u8 = undefined;
    var writer = std.Io.File.stderr().writer(app_runtime.io(), &buffer);
    const out = &writer.interface;
    try out.print(format, args);
    try out.flush();
}

fn writeAppOutput(comptime format: []const u8, args: anytype) !void {
    var buffer: [1024]u8 = undefined;
    var writer = std.Io.File.stdout().writer(app_runtime.io(), &buffer);
    const out = &writer.interface;
    try out.print(format, args);
    try out.flush();
}

fn launchWindowsViaPowerShell(
    allocator: std.mem.Allocator,
    app_path: []const u8,
    app_source: ValueSource,
    cli_path: ?[]const u8,
    home: []const u8,
) !void {
    if (app_source == .detected) {
        return launchWindowsDetectedPackageViaPowerShell(allocator, cli_path, home);
    }

    const app_quoted = try psSingleQuoteAlloc(allocator, app_path);
    defer allocator.free(app_quoted);
    const home_quoted = try psSingleQuoteAlloc(allocator, home);
    defer allocator.free(home_quoted);
    const cli_quoted = if (cli_path) |path| try psSingleQuoteAlloc(allocator, path) else null;
    defer if (cli_quoted) |path| allocator.free(path);

    const cli_part = if (cli_quoted) |path|
        try std.fmt.allocPrint(allocator, "; CODEX_CLI_PATH={s}", .{path})
    else
        try allocator.dupe(u8, "");
    defer allocator.free(cli_part);

    const script = try std.fmt.allocPrint(
        allocator,
        "$ErrorActionPreference='Stop'; $p={s}; if (Test-Path -LiteralPath $p -PathType Container) {{ $c=@('Codex.exe','codex.exe','app\\Codex.exe','app\\codex.exe'); foreach ($n in $c) {{ $x=Join-Path $p $n; if (Test-Path -LiteralPath $x -PathType Leaf) {{ $p=$x; break }} }} }}; Start-Process -FilePath $p -Environment @{{ CODEX_HOME={s}{s} }}",
        .{ app_quoted, home_quoted, cli_part },
    );
    defer allocator.free(script);

    var child = try std.process.spawn(app_runtime.io(), .{
        .argv = &[_][]const u8{ "pwsh.exe", "-NoProfile", "-Command", script },
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .ignore,
        .create_no_window = true,
    });
    _ = try child.wait(app_runtime.io());
}

fn launchWindowsDetectedPackageViaPowerShell(
    allocator: std.mem.Allocator,
    cli_path: ?[]const u8,
    home: []const u8,
) !void {
    const package_quoted = try psSingleQuoteAlloc(allocator, codex_app_package_name);
    defer allocator.free(package_quoted);
    const home_quoted = try psSingleQuoteAlloc(allocator, home);
    defer allocator.free(home_quoted);
    const cli_quoted = if (cli_path) |path| try psSingleQuoteAlloc(allocator, path) else null;
    defer if (cli_quoted) |path| allocator.free(path);

    const cli_part = if (cli_quoted) |path|
        try std.fmt.allocPrint(allocator, "; $env:CODEX_CLI_PATH={s}", .{path})
    else
        try allocator.dupe(u8, "");
    defer allocator.free(cli_part);

    const script = try std.fmt.allocPrint(
        allocator,
        "$ErrorActionPreference='Stop'; $pkg=Get-AppxPackage -Name {s} | Sort-Object Version -Descending | Select-Object -First 1; if (-not $pkg) {{ throw 'OpenAI.Codex package not found' }}; $appId=(Get-AppxPackageManifest $pkg).Package.Applications.Application | Select-Object -First 1 -ExpandProperty Id; $aumid=\"$($pkg.PackageFamilyName)!$appId\"; $env:CODEX_HOME={s}{s}; Start-Process -FilePath \"shell:AppsFolder\\$aumid\"",
        .{ package_quoted, home_quoted, cli_part },
    );
    defer allocator.free(script);

    var child = try std.process.spawn(app_runtime.io(), .{
        .argv = &[_][]const u8{ "pwsh.exe", "-NoProfile", "-Command", script },
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .ignore,
        .create_no_window = true,
    });
    _ = try child.wait(app_runtime.io());
}

fn psSingleQuoteAlloc(allocator: std.mem.Allocator, value: []const u8) ![]u8 {
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(allocator);
    try out.append(allocator, '\'');
    for (value) |ch| {
        try out.append(allocator, ch);
        if (ch == '\'') try out.append(allocator, '\'');
    }
    try out.append(allocator, '\'');
    return try out.toOwnedSlice(allocator);
}

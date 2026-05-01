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
const wsl_agent_mode_key = "runCodexInWindowsSubsystemForLinux";
const codext_repo_latest_url = "https://api.github.com/repos/Loongphy/codext/releases/latest";
const codext_cache_dir_name = "codext-cli";
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
    const effective_home = opts.home orelse resolved_codex_home;
    const effective_platform = try resolvePlatform(allocator, effective_home, opts.platform);
    if ((opts.action == .launch or opts.action == .patch) and !opts.dry_run) try validateAppPlatform(effective_platform.value);
    const effective_app_path = try resolveAppPath(allocator, opts);
    defer effective_app_path.deinit(allocator);
    const allow_download = (opts.action == .launch or opts.action == .patch) and !opts.dry_run;
    const effective_cli_path = try resolveCliPath(allocator, effective_home, effective_platform.value, opts, allow_download);
    defer effective_cli_path.deinit(allocator);
    const persistent_cli_path = if (opts.action == .status or opts.dry_run) try readPersistentCliPath(allocator) else null;
    defer if (persistent_cli_path) |path| allocator.free(path);

    switch (opts.action) {
        .status => try printStatus(effective_app_path, effective_cli_path, persistent_cli_path, effective_home, effective_platform, opts),
        .launch => try launchApp(allocator, effective_app_path, effective_cli_path, persistent_cli_path, effective_home, effective_platform, opts),
        .patch => try patchApp(allocator, effective_app_path, effective_cli_path, persistent_cli_path, effective_home, effective_platform, opts),
        .unpatch => try unpatchApp(allocator, effective_app_path, effective_cli_path, persistent_cli_path, effective_home, effective_platform, opts),
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
) !ResolvedValue {
    if (opts.cli_path) |path| return .{ .value = path, .source = .explicit };
    if (opts.action != .patch) {
        if (getOptionalEnv(allocator, codex_cli_path_env)) |path| return .{ .value = path, .source = .env, .owned = true };
    }

    const target_platform = platform orelse nativeDefaultPlatform();
    if (try cachedCodextCliPath(allocator, home, target_platform)) |path| return .{ .value = path, .source = .cached, .owned = true };
    if (!allow_download) return .{ .value = null, .source = .not_set };

    const path = try downloadDefaultCodextCli(allocator, home, target_platform);
    return .{ .value = path, .source = .downloaded, .owned = true };
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
    opts: types.AppOptions,
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
    try out.print("  dry run: {s}\n", .{if (opts.dry_run) "yes" else "no"});
    try out.print("  wait: {s}\n", .{if (opts.wait) "yes" else "no"});
    try out.flush();
}

fn launchApp(
    allocator: std.mem.Allocator,
    app_path: ResolvedValue,
    cli_path: ResolvedValue,
    persistent_cli_path: ?[]const u8,
    home: []const u8,
    platform: ResolvedPlatform,
    opts: types.AppOptions,
) !void {
    const target = app_path.value orelse {
        try writeAppError("app launch could not find the installed Codex app. Pass `--app-path <path>` or set CODEX_AUTH_APP_PATH.\n");
        return error.AppPathRequired;
    };
    if (opts.dry_run) {
        try printStatus(app_path, cli_path, persistent_cli_path, home, platform, opts);
        return;
    }
    try validateAppPlatform(platform.value);
    try applyAppPlatform(allocator, home, platform.value);

    if (builtin.os.tag == .windows) {
        return launchWindowsViaPowerShell(allocator, target, cli_path.value, home, opts);
    }
    if (looksLikeWindowsPath(target) or looksLikeWslWindowsMountPath(target)) {
        try writeAppError("windows app launch must run from the Windows codex-auth executable.\n");
        return error.WindowsAppLaunchRequiresWindows;
    }
    return launchNative(allocator, target, cli_path.value, home, opts);
}

fn patchApp(
    allocator: std.mem.Allocator,
    app_path: ResolvedValue,
    cli_path: ResolvedValue,
    persistent_cli_path: ?[]const u8,
    home: []const u8,
    platform: ResolvedPlatform,
    opts: types.AppOptions,
) !void {
    if (opts.dry_run) {
        try printStatus(app_path, cli_path, persistent_cli_path, home, platform, opts);
        return;
    }
    try validateAppPlatform(platform.value);
    try applyAppPlatform(allocator, home, platform.value);
    const target_cli = cli_path.value orelse {
        try writeAppError("app patch could not resolve CODEX_CLI_PATH. Pass `--cli-path <path>` or allow the default Loongphy codext download.\n");
        return error.CliPathRequired;
    };
    try persistCliPath(allocator, target_cli);
    try writeAppOutput("persistent CODEX_CLI_PATH={s}\n", .{target_cli});
}

fn unpatchApp(
    allocator: std.mem.Allocator,
    app_path: ResolvedValue,
    cli_path: ResolvedValue,
    persistent_cli_path: ?[]const u8,
    home: []const u8,
    platform: ResolvedPlatform,
    opts: types.AppOptions,
) !void {
    if (opts.dry_run) {
        try printStatus(app_path, cli_path, persistent_cli_path, home, platform, opts);
        return;
    }
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

fn launchNative(
    allocator: std.mem.Allocator,
    app_path: []const u8,
    cli_path: ?[]const u8,
    home: []const u8,
    opts: types.AppOptions,
) !void {
    const launch_path = try resolveLaunchPath(allocator, app_path);
    defer allocator.free(launch_path);

    var env_map = try registry.getEnvMap(allocator);
    defer env_map.deinit();
    try env_map.put(codex_home_env, home);
    if (cli_path) |path| {
        try env_map.put(codex_cli_path_env, path);
    }

    var argv = std.ArrayList([]const u8).empty;
    defer argv.deinit(allocator);
    try argv.append(allocator, launch_path);
    try argv.appendSlice(allocator, opts.extra_args);

    var child = try std.process.spawn(app_runtime.io(), .{
        .argv = argv.items,
        .environ_map = &env_map,
        .stdin = .ignore,
        .stdout = .inherit,
        .stderr = .inherit,
    });
    if (opts.wait) {
        _ = try child.wait(app_runtime.io());
    }
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

fn detectInstalledAppPath(allocator: std.mem.Allocator) !?[]u8 {
    return switch (builtin.os.tag) {
        .windows => try detectWindowsInstalledAppPath(allocator),
        .macos => try detectMacInstalledAppPath(allocator),
        else => null,
    };
}

fn detectWindowsInstalledAppPath(allocator: std.mem.Allocator) !?[]u8 {
    const script = try std.fmt.allocPrint(
        allocator,
        "$ErrorActionPreference='SilentlyContinue'; $pkg=Get-AppxPackage -Name 'OpenAI.Codex' | Sort-Object Version -Descending | Select-Object -First 1; if ($pkg) {{ foreach ($rel in @('app\\Codex.exe','Codex.exe')) {{ $p=Join-Path $pkg.InstallLocation $rel; if (Test-Path -LiteralPath $p -PathType Leaf) {{ [Console]::Out.Write($p); exit 0 }} }} }}",
        .{},
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
    const platform_name = codextPlatformCacheName(platform);
    const root_path = try std.fs.path.join(allocator, &.{ home, "accounts", codext_cache_dir_name });
    defer allocator.free(root_path);

    var root = std.Io.Dir.cwd().openDir(app_runtime.io(), root_path, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return err,
    };
    defer root.close(app_runtime.io());

    var best: ?[]u8 = null;
    var best_tag: ?[]u8 = null;
    var it = root.iterate();
    while (try it.next(app_runtime.io())) |entry| {
        if (entry.kind != .directory) continue;
        const candidate = try findCachedCodextExecutable(allocator, root_path, entry.name, platform_name, platform) orelse continue;
        if (fileExists(candidate)) {
            if (best_tag == null or std.mem.order(u8, entry.name, best_tag.?) == .gt) {
                if (best) |old| allocator.free(old);
                if (best_tag) |old| allocator.free(old);
                best = candidate;
                best_tag = try allocator.dupe(u8, entry.name);
            } else {
                allocator.free(candidate);
            }
        } else {
            allocator.free(candidate);
        }
    }
    if (best_tag) |tag| allocator.free(tag);
    return best;
}

fn downloadDefaultCodextCli(allocator: std.mem.Allocator, home: []const u8, platform: types.AppPlatform) ![]u8 {
    const release = try fetchLatestCodextRelease(allocator);
    defer release.deinit(allocator);

    const cache_root = try std.fs.path.join(allocator, &.{ home, "accounts", codext_cache_dir_name, release.tag });
    defer allocator.free(cache_root);
    try std.Io.Dir.cwd().createDirPath(app_runtime.io(), cache_root);

    if (builtin.os.tag == .windows) {
        const win_asset = release.assetFor(.win) orelse return error.CodextReleaseAssetNotFound;
        const wsl_asset = release.assetFor(.wsl) orelse return error.CodextReleaseAssetNotFound;
        try writeAppInfo("downloading from {s}\ndownloading from {s}\n", .{ win_asset.url, wsl_asset.url });
        try downloadAndInstallCodextAsset(allocator, cache_root, .win, win_asset);
        try downloadAndInstallCodextAsset(allocator, cache_root, .wsl, wsl_asset);
    } else {
        const asset = release.assetFor(platform) orelse return error.CodextReleaseAssetNotFound;
        try writeAppInfo("downloading from {s}\n", .{asset.url});
        try downloadAndInstallCodextAsset(allocator, cache_root, platform, asset);
    }

    const installed = try std.fs.path.join(allocator, &.{ cache_root, codextPlatformCacheName(platform), codextExecutableName(platform) });
    if (!fileExists(installed)) {
        allocator.free(installed);
        return error.CodextReleaseInstallFailed;
    }
    return installed;
}

fn findCachedCodextExecutable(
    allocator: std.mem.Allocator,
    root_path: []const u8,
    tag: []const u8,
    platform_name: []const u8,
    platform: types.AppPlatform,
) !?[]u8 {
    const primary = try std.fs.path.join(allocator, &.{ root_path, tag, platform_name, codextExecutableName(platform) });
    if (fileExists(primary)) return primary;
    allocator.free(primary);
    const legacy = try std.fs.path.join(allocator, &.{ root_path, tag, platform_name, codextReleaseExecutableName(platform) });
    if (fileExists(legacy)) return legacy;
    allocator.free(legacy);
    return null;
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
    platform: types.AppPlatform,
    asset: CodextAsset,
) !void {
    const platform_dir = try std.fs.path.join(allocator, &.{ cache_root, codextPlatformCacheName(platform) });
    defer allocator.free(platform_dir);
    if (isDirectory(platform_dir)) try std.Io.Dir.cwd().deleteTree(app_runtime.io(), platform_dir);
    try std.Io.Dir.cwd().createDirPath(app_runtime.io(), platform_dir);

    const archive_name = if (platform == .win) "codext.zip" else "codext.tar.gz";
    const archive_path = try std.fs.path.join(allocator, &.{ platform_dir, archive_name });
    defer allocator.free(archive_path);
    try runChecked(allocator, &[_][]const u8{ curlExecutable(), "-L", "--fail", "--silent", "--show-error", "-o", archive_path, asset.url }, 120000);
    if (platform == .win) {
        const archive_quoted = try psSingleQuoteAlloc(allocator, archive_path);
        defer allocator.free(archive_quoted);
        const dest_quoted = try psSingleQuoteAlloc(allocator, platform_dir);
        defer allocator.free(dest_quoted);
        const script = try std.fmt.allocPrint(allocator, "Expand-Archive -LiteralPath {s} -DestinationPath {s} -Force", .{ archive_quoted, dest_quoted });
        defer allocator.free(script);
        try runChecked(allocator, &[_][]const u8{ "pwsh.exe", "-NoProfile", "-Command", script }, 120000);
    } else {
        try runChecked(allocator, &[_][]const u8{ tarExecutable(), "-xzf", archive_path, "-C", platform_dir }, 120000);
    }
    try normalizeCodextExecutableName(allocator, platform_dir, platform);
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

fn normalizeCodextExecutableName(allocator: std.mem.Allocator, platform_dir: []const u8, platform: types.AppPlatform) !void {
    const target = try std.fs.path.join(allocator, &.{ platform_dir, codextExecutableName(platform) });
    defer allocator.free(target);
    if (fileExists(target)) return;
    const source = try std.fs.path.join(allocator, &.{ platform_dir, codextReleaseExecutableName(platform) });
    defer allocator.free(source);
    if (!fileExists(source)) return;
    try std.Io.Dir.renameAbsolute(source, target, app_runtime.io());
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
    cli_path: ?[]const u8,
    home: []const u8,
    opts: types.AppOptions,
) !void {
    if (opts.extra_args.len != 0) return error.WindowsPassthroughArgsUnsupported;

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
        "$ErrorActionPreference='Stop'; $p={s}; if (Test-Path -LiteralPath $p -PathType Container) {{ $c=@('Codex.exe','codex.exe','app\\Codex.exe','app\\codex.exe'); foreach ($n in $c) {{ $x=Join-Path $p $n; if (Test-Path -LiteralPath $x -PathType Leaf) {{ $p=$x; break }} }} }}; Start-Process -FilePath $p -Environment @{{ CODEX_HOME={s}{s} }}{s}",
        .{ app_quoted, home_quoted, cli_part, if (opts.wait) " -Wait" else "" },
    );
    defer allocator.free(script);

    var child = try std.process.spawn(app_runtime.io(), .{
        .argv = &[_][]const u8{ "pwsh.exe", "-NoProfile", "-Command", script },
        .stdin = .ignore,
        .stdout = .inherit,
        .stderr = .inherit,
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

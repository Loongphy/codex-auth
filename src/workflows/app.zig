const std = @import("std");
const builtin = @import("builtin");
const app_runtime = @import("../core/runtime.zig");
const http_child = @import("../api/http_child.zig");
const registry = @import("../registry/root.zig");
const types = @import("../cli/types.zig");
const io_util = @import("../core/io_util.zig");
const cli_style = @import("../cli/style.zig");

const codex_cli_path_env = "CODEX_CLI_PATH";
const codex_home_env = "CODEX_HOME";
const app_id_env = "CODEX_AUTH_APP_ID";
const codex_app_package_name = "OpenAI.Codex";
const codex_app_bundle_id = "com.openai.codex";
const wsl_agent_mode_key = "runCodexInWindowsSubsystemForLinux";
const codext_repo_latest_url = "https://api.github.com/repos/Loongphy/codext/releases/latest";
const codext_repo_url = "https://github.com/Loongphy/codext";
const codext_cache_dir_name = "codext-cli";
const windows_app_id_resolver_script =
    "function Resolve-CodexAppPackage { param([string]$AppId) " ++
    "if ([string]::IsNullOrWhiteSpace($AppId)) { throw 'Codex App ID is empty' }; " ++
    "$id=$AppId; " ++
    "if ($id.Contains('!')) { " ++
    "$family=$id.Split('!')[0]; " ++
    "$pkg=Get-AppxPackage | Where-Object { $_.PackageFamilyName -ieq $family -or $_.PackageFullName -ieq $family -or $_.Name -ieq $family } | Sort-Object Version -Descending | Select-Object -First 1; " ++
    "if (-not $pkg) { throw \"App package not found: $id\" }; return $pkg } " ++
    "$pkg=Get-AppxPackage -Name $id | Sort-Object Version -Descending | Select-Object -First 1; " ++
    "if (-not $pkg) { $pkg=Get-AppxPackage | Where-Object { $_.PackageFamilyName -ieq $id -or $_.PackageFullName -ieq $id } | Sort-Object Version -Descending | Select-Object -First 1 }; " ++
    "if (-not $pkg) { throw \"App package not found: $id\" }; return $pkg } " ++
    "function Resolve-CodexAppAumid { param([string]$AppId) " ++
    "if ($AppId.Contains('!')) { return $AppId }; " ++
    "$pkg=Resolve-CodexAppPackage $AppId; " ++
    "$appId=(Get-AppxPackageManifest $pkg).Package.Applications.Application | Select-Object -First 1 -ExpandProperty Id; " ++
    "if (-not $appId) { throw \"App manifest has no application id: $AppId\" }; " ++
    "return \"$($pkg.PackageFamilyName)!$appId\" } " ++
    "function Resolve-CodexAppExecutable { param([string]$AppId) " ++
    "$pkg=Resolve-CodexAppPackage $AppId; " ++
    "$app=(Get-AppxPackageManifest $pkg).Package.Applications.Application | Select-Object -First 1; " ++
    "if (-not $app -or -not $app.Executable) { throw \"App executable not found: $AppId\" }; " ++
    "$exe=Join-Path $pkg.InstallLocation ([string]$app.Executable); " ++
    "if (-not (Test-Path -LiteralPath $exe -PathType Leaf)) { throw \"App executable not found: $exe\" }; " ++
    "return [System.IO.Path]::GetFullPath($exe) }";

const ValueSource = enum { explicit, env, detected, built_in, cached, downloaded, not_set };
const WindowsLaunchMode = enum { gui, stdio };

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

const CodextInstallResult = struct {
    path: []u8,
    source: ValueSource,
};

const PathValidationIssue = struct {
    option: []const u8,
    message: []const u8,
    path: []const u8,
};

pub fn handleApp(allocator: std.mem.Allocator, resolved_codex_home: []const u8, opts: types.AppOptions) !void {
    const effective_home = opts.codex_home orelse resolved_codex_home;
    const effective_platform = try resolvePlatform(allocator, effective_home, opts.platform);
    try validateAppPlatform(effective_platform.value);
    const effective_app_id = try resolveAppId(allocator, effective_platform.value, opts);
    defer effective_app_id.deinit(allocator);
    try requireAppId(effective_app_id);
    try validateConfiguredPaths(allocator, opts);
    if (try isCodexAppRunning(allocator, effective_platform.value, effective_app_id)) {
        try writeAppAlreadyRunning();
        return;
    }
    try requireResolvableAppId(allocator, effective_platform.value, effective_app_id);
    const effective_cli_path = try resolveCliPath(allocator, effective_home, effective_platform.value, opts, true, false);
    defer effective_cli_path.deinit(allocator);
    try writeAppLaunchPlan(allocator, opts.codex_home != null, effective_home, effective_platform, effective_app_id, effective_cli_path);

    switch (opts.action) {
        .launch => try launchApp(allocator, effective_app_id, effective_cli_path, effective_home, effective_platform, opts.inherit_stdio),
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

fn resolveAppId(allocator: std.mem.Allocator, platform: ?types.AppPlatform, opts: types.AppOptions) !ResolvedValue {
    if (opts.app_id) |app_id| return .{ .value = app_id, .source = .explicit };
    if (getOptionalEnv(allocator, app_id_env)) |app_id| return .{ .value = app_id, .source = .env, .owned = true };
    if (defaultAppId(platform)) |app_id| return .{ .value = app_id, .source = .built_in };
    return .{ .value = null, .source = .not_set };
}

fn defaultAppId(platform: ?types.AppPlatform) ?[]const u8 {
    const value = platform orelse return null;
    return switch (value) {
        .win, .wsl => codex_app_package_name,
        .mac => codex_app_bundle_id,
    };
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
        const result = try downloadDefaultCodextCli(allocator, home, target_platform, quiet_download);
        return .{ .value = result.path, .source = result.source, .owned = true };
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

fn validateConfiguredPaths(allocator: std.mem.Allocator, opts: types.AppOptions) !void {
    var issues = std.ArrayList(PathValidationIssue).empty;
    defer issues.deinit(allocator);

    if (opts.codex_cli_path) |path| try appendConfiguredCliPathIssue(allocator, &issues, path);

    if (issues.items.len == 0) return;
    try writePathValidationIssues(issues.items);
    return error.AppLaunchConfigValidationFailed;
}

fn requireAppId(app_id: ResolvedValue) !void {
    if (app_id.value != null) return;
    try writeAppError("app launch needs an app ID. Pass `--app-id <id>` or set CODEX_AUTH_APP_ID.\n");
    return error.AppIdRequired;
}

fn requireResolvableAppId(allocator: std.mem.Allocator, platform: ?types.AppPlatform, app_id: ResolvedValue) !void {
    const value = app_id.value orelse return error.AppIdRequired;
    if (try appIdCanResolve(allocator, platform, value)) return;
    try writeAppError("app launch could not find the installed app for the configured app ID.\n");
    return error.AppIdNotFound;
}

fn appIdCanResolve(allocator: std.mem.Allocator, platform: ?types.AppPlatform, app_id: []const u8) !bool {
    const value = platform orelse return true;
    return switch (value) {
        .win, .wsl => try windowsCanResolveAppId(allocator, app_id),
        .mac => try macCanResolveAppId(allocator, app_id),
    };
}

fn appendConfiguredCliPathIssue(
    allocator: std.mem.Allocator,
    issues: *std.ArrayList(PathValidationIssue),
    path: []const u8,
) !void {
    const kind = pathKind(path) catch |err| switch (err) {
        error.AccessDenied, error.PermissionDenied => {
            try issues.append(allocator, .{ .option = "--codex-cli-path", .message = "Path is not accessible", .path = path });
            return;
        },
        else => return err,
    } orelse {
        try issues.append(allocator, .{ .option = "--codex-cli-path", .message = "Path does not exist", .path = path });
        return;
    };
    if (kind == .file or kind == .sym_link) return;

    try issues.append(allocator, .{ .option = "--codex-cli-path", .message = "Path is not a file", .path = path });
}

fn writePathValidationIssues(issues: []const PathValidationIssue) !void {
    var stderr: io_util.Stderr = undefined;
    stderr.init();
    var writer = cli_style.StyledWriter.init(stderr.out(), stderr.color_enabled);

    for (issues) |issue| {
        try writer.writeStyle(cli_style.role.error_text);
        try writer.print("ERROR: {s}: {s}\n", .{ issue.option, issue.message });
        try writer.reset();
        try writer.writeStyle(cli_style.role.secondary);
        try writer.print("        \"{s}\"\n", .{issue.path});
        try writer.reset();
    }
    try writer.flush();
}

fn writeAppLaunchPlan(
    allocator: std.mem.Allocator,
    show_home: bool,
    home: []const u8,
    platform: ResolvedPlatform,
    app_id: ResolvedValue,
    cli_path: ResolvedValue,
) !void {
    var stderr: io_util.Stderr = undefined;
    stderr.init();
    var writer = cli_style.StyledWriter.init(stderr.out(), stderr.color_enabled);
    const out = &writer;
    const columns = terminalColumns();

    try out.writeStyle(cli_style.role.secondary);
    try out.writeAll("\n- Environment Configuration ------------------------------------------------\n");

    if (platform.value) |value| {
        try writePanelField(allocator, out, columns, "Platform:", platformLabel(value), platformSourceLabel(platform.source));
    } else {
        try writePanelField(allocator, out, columns, "Platform:", "<not set>", null);
    }
    if (show_home) try writePanelField(allocator, out, columns, "Codex Home:", home, valueSourceLabel(.explicit));
    if (app_id.value) |value| {
        try writePanelField(allocator, out, columns, "App ID:", value, valueSourceLabel(app_id.source));
    } else {
        try writePanelField(allocator, out, columns, "App ID:", "<not set>", null);
    }
    if (cli_path.value) |value| {
        try writePanelField(allocator, out, columns, "CLI Path:", value, valueSourceLabel(cli_path.source));
    } else {
        try writePanelField(allocator, out, columns, "CLI Path:", "<not set>", null);
    }

    try out.writeAll("----------------------------------------------------------------------------\n");
    try out.reset();
    try out.flush();
}

fn valueSourceLabel(source: ValueSource) []const u8 {
    return switch (source) {
        .explicit => "explicit",
        .env => "environment",
        .detected => "auto-detected",
        .built_in => "default",
        .cached => "",
        .downloaded => "downloaded",
        .not_set => "not set",
    };
}

fn platformSourceLabel(source: ValueSource) []const u8 {
    return switch (source) {
        .detected => "auto-detected",
        else => valueSourceLabel(source),
    };
}

fn writePanelField(
    allocator: std.mem.Allocator,
    out: *cli_style.StyledWriter,
    columns: usize,
    label: []const u8,
    value: []const u8,
    source: ?[]const u8,
) !void {
    try writePanelFieldStyled(allocator, out, columns, label, value, source, "");
}

fn writePanelFieldStyled(
    allocator: std.mem.Allocator,
    out: *cli_style.StyledWriter,
    columns: usize,
    label: []const u8,
    value: []const u8,
    source: ?[]const u8,
    value_style: []const u8,
) !void {
    const display_value = try panelDisplayValue(allocator, value, source);
    defer allocator.free(display_value);

    try out.writeAll("  ");
    try out.print("{s}", .{label});
    try out.writeAll(" ");
    try out.writeStyle(value_style);
    try writeWrappedPanelValue(out, columns, 2 + label.len + 1, display_value);
    try out.writeAll("\n");
}

fn panelDisplayValue(allocator: std.mem.Allocator, value: []const u8, source: ?[]const u8) ![]u8 {
    if (source) |source_label| {
        if (source_label.len != 0) return try std.fmt.allocPrint(allocator, "{s} ({s})", .{ value, source_label });
    }
    return try allocator.dupe(u8, value);
}

fn writeWrappedPanelValue(out: *cli_style.StyledWriter, columns: usize, first_line_prefix: usize, value: []const u8) !void {
    var remaining = value;
    var used = first_line_prefix;
    while (remaining.len > 0) {
        const available = if (columns > used) columns - used else 1;
        if (remaining.len <= available) {
            try out.writeAll(remaining);
            return;
        }
        try out.writeAll(remaining[0..available]);
        remaining = remaining[available..];
        try out.writeAll("\n  ");
        used = 2;
    }
}

fn terminalColumns() usize {
    const file = std.Io.File.stderr();
    if (!(file.isTty(app_runtime.io()) catch false)) return 80;
    if (comptime builtin.os.tag == .windows) {
        var get_console_info = std.os.windows.CONSOLE.USER_IO.GET_SCREEN_BUFFER_INFO;
        switch (get_console_info.operate(app_runtime.io(), file) catch return 80) {
            .SUCCESS => {},
            else => return 80,
        }
        const cols = @as(i32, get_console_info.Data.dwWindowSize.X);
        if (cols <= 0) return 80;
        return @intCast(cols);
    } else {
        var wsz: std.posix.winsize = .{
            .row = 0,
            .col = 0,
            .xpixel = 0,
            .ypixel = 0,
        };
        const rc = std.posix.system.ioctl(file.handle, std.posix.T.IOCGWINSZ, @intFromPtr(&wsz));
        if (std.posix.errno(rc) != .SUCCESS or wsz.col == 0) return 80;
        return @intCast(wsz.col);
    }
}

fn platformLabel(platform: types.AppPlatform) []const u8 {
    return switch (platform) {
        .win => "Windows",
        .wsl => "WSL",
        .mac => "macOS",
    };
}

fn isCodexAppRunning(allocator: std.mem.Allocator, platform: ?types.AppPlatform, app_id: ResolvedValue) !bool {
    const value = app_id.value orelse return false;
    return switch (builtin.os.tag) {
        .windows => try isCodexAppRunningOnWindows(allocator, value),
        .macos => try isCodexAppRunningOnMac(allocator, value),
        else => switch (platform orelse return false) {
            .win, .wsl, .mac => false,
        },
    };
}

fn isCodexAppRunningOnWindows(allocator: std.mem.Allocator, app_id: []const u8) !bool {
    const script = try windowsAppIdRunningScriptAlloc(allocator, app_id);
    defer allocator.free(script);

    var result = http_child.runChildCapture(
        allocator,
        &[_][]const u8{ "pwsh.exe", "-NoProfile", "-Command", script },
        3000,
        null,
    ) catch return false;
    defer result.deinit(allocator);
    if (result.timed_out) return false;
    return std.mem.trim(u8, result.stdout, " \t\r\n").len != 0;
}

fn isCodexAppRunningOnMac(allocator: std.mem.Allocator, app_id: []const u8) !bool {
    var result = http_child.runChildCapture(
        allocator,
        &[_][]const u8{
            "/usr/bin/osascript",
            "-e",
            "on run argv",
            "-e",
            "application id (item 1 of argv) is running",
            "-e",
            "end run",
            app_id,
        },
        3000,
        null,
    ) catch return false;
    defer result.deinit(allocator);
    if (result.timed_out or !childExitedSuccessfully(result.term)) return false;
    return std.mem.eql(u8, std.mem.trim(u8, result.stdout, " \t\r\n"), "true");
}

fn windowsAppIdRunningScriptAlloc(allocator: std.mem.Allocator, app_id: []const u8) ![]u8 {
    const app_quoted = try psSingleQuoteAlloc(allocator, app_id);
    defer allocator.free(app_quoted);
    return try std.fmt.allocPrint(
        allocator,
        "$ErrorActionPreference='SilentlyContinue'; {s}; " ++
            "$target=Resolve-CodexAppExecutable {s}; " ++
            "$p=Get-CimInstance Win32_Process | Where-Object {{ $_.ExecutablePath -and ([System.IO.Path]::GetFullPath($_.ExecutablePath) -ieq $target) }} | Select-Object -First 1; " ++
            "if ($p) {{ [Console]::Out.Write('running') }}",
        .{ windows_app_id_resolver_script, app_quoted },
    );
}

fn childExitedSuccessfully(term: std.process.Child.Term) bool {
    return switch (term) {
        .exited => |code| code == 0,
        else => false,
    };
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

fn launchApp(
    allocator: std.mem.Allocator,
    app_id: ResolvedValue,
    cli_path: ResolvedValue,
    home: []const u8,
    platform: ResolvedPlatform,
    inherit_stdio: bool,
) !void {
    const target = app_id.value orelse {
        try writeAppError("app launch needs an app ID. Pass `--app-id <id>` or set CODEX_AUTH_APP_ID.\n");
        return error.AppIdRequired;
    };
    try validateAppPlatform(platform.value);
    try applyAppPlatform(allocator, home, platform.value);

    if (builtin.os.tag == .windows) {
        try writeAppLaunching();
        return launchWindowsViaPowerShell(allocator, target, cli_path.value, home, if (inherit_stdio) .stdio else .gui);
    }

    if (builtin.os.tag == .macos) {
        if (inherit_stdio) {
            try writeAppLaunching();
            return launchMacExecutableWithStdio(allocator, target, cli_path.value, home);
        }
        return launchMac(allocator, target, cli_path.value, home);
    }
    try writeAppError("app launch is supported only from the Windows or macOS codex-auth executable.\n");
    return error.UnsupportedPlatform;
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

fn launchMacExecutableWithStdio(
    allocator: std.mem.Allocator,
    app_id: []const u8,
    cli_path: ?[]const u8,
    home: []const u8,
) !void {
    const bundle_path = try resolveMacBundlePath(allocator, app_id);
    defer allocator.free(bundle_path);
    const launch_path = try resolveMacBundleExecutablePath(allocator, bundle_path);
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
    app_id: []const u8,
    cli_path: ?[]const u8,
    home: []const u8,
) !void {
    try writeAppLaunching();

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
        "-b",
        app_id,
    });
    var child = try std.process.spawn(app_runtime.io(), .{
        .argv = argv.items,
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .ignore,
    });
    switch (try child.wait(app_runtime.io())) {
        .exited => |code| if (code == 0) return,
        else => {},
    }
    try writeAppError("app launcher failed.\n");
    return error.AppLaunchFailed;
}

fn resolveMacBundlePath(allocator: std.mem.Allocator, app_id: []const u8) ![]u8 {
    var result = http_child.runChildCapture(
        allocator,
        &[_][]const u8{
            "/usr/bin/osascript",
            "-e",
            "on run argv",
            "-e",
            "POSIX path of (path to application id (item 1 of argv))",
            "-e",
            "end run",
            app_id,
        },
        7000,
        null,
    ) catch return error.AppIdNotFound;
    defer result.deinit(allocator);
    if (result.timed_out or !childExitedSuccessfully(result.term)) return error.AppIdNotFound;
    const trimmed = std.mem.trim(u8, result.stdout, " \t\r\n");
    if (trimmed.len == 0) return error.AppIdNotFound;
    return try allocator.dupe(u8, trimmed);
}

fn macCanResolveAppId(allocator: std.mem.Allocator, app_id: []const u8) !bool {
    const bundle_path = resolveMacBundlePath(allocator, app_id) catch return false;
    allocator.free(bundle_path);
    return true;
}

fn resolveMacBundleExecutablePath(allocator: std.mem.Allocator, bundle_path: []const u8) ![]u8 {
    const candidates = [_][]const u8{
        "Contents/MacOS/Codex",
        "Contents/MacOS/codex",
        "Contents/MacOS/Codext",
        "Contents/MacOS/codext",
    };
    for (candidates) |candidate| {
        const joined = try std.fs.path.join(allocator, &.{ bundle_path, candidate });
        if (fileExists(joined)) return joined;
        allocator.free(joined);
    }
    return error.AppExecutableNotFound;
}

fn windowsCanResolveAppId(allocator: std.mem.Allocator, app_id: []const u8) !bool {
    const app_quoted = try psSingleQuoteAlloc(allocator, app_id);
    defer allocator.free(app_quoted);
    const script = try std.fmt.allocPrint(
        allocator,
        "$ErrorActionPreference='Stop'; {s}; try {{ $null=Resolve-CodexAppAumid {s}; [Console]::Out.Write('ok') }} catch {{ }}",
        .{ windows_app_id_resolver_script, app_quoted },
    );
    defer allocator.free(script);
    var result = http_child.runChildCapture(allocator, &[_][]const u8{ "pwsh.exe", "-NoProfile", "-Command", script }, 5000, null) catch return false;
    defer result.deinit(allocator);
    if (result.timed_out) return false;
    return std.mem.eql(u8, std.mem.trim(u8, result.stdout, " \t\r\n"), "ok");
}

fn isDirectory(path: []const u8) bool {
    const stat = std.Io.Dir.cwd().statFile(app_runtime.io(), path, .{}) catch return false;
    return stat.kind == .directory;
}

fn pathKind(path: []const u8) !?std.Io.File.Kind {
    const stat = std.Io.Dir.cwd().statFile(app_runtime.io(), path, .{}) catch |err| switch (err) {
        error.FileNotFound, error.NotDir => return null,
        else => return err,
    };
    return stat.kind;
}

fn fileExists(path: []const u8) bool {
    std.Io.Dir.cwd().access(app_runtime.io(), path, .{}) catch return false;
    return true;
}

fn cachedCodextCliPath(allocator: std.mem.Allocator, home: []const u8, platform: types.AppPlatform) !?[]u8 {
    const candidate = try managedCodextExecutablePath(allocator, home, platform);
    if (fileExists(candidate)) return candidate;
    allocator.free(candidate);
    return null;
}

fn downloadDefaultCodextCli(allocator: std.mem.Allocator, home: []const u8, platform: types.AppPlatform, quiet: bool) !CodextInstallResult {
    if (!quiet) try writeAppStep("Checking latest " ++ codext_repo_url ++ " release...");
    const release = try fetchLatestCodextRelease(allocator);
    defer release.deinit(allocator);

    const cache_root = try std.fs.path.join(allocator, &.{ home, "accounts", codext_cache_dir_name });
    defer allocator.free(cache_root);
    try std.Io.Dir.cwd().createDirPath(app_runtime.io(), cache_root);

    const asset = release.assetFor(platform) orelse return error.CodextReleaseAssetNotFound;
    const target_downloaded = try ensureCodextAssetInstalled(allocator, cache_root, release.tag, platform, asset, quiet);

    const installed = try managedCodextExecutablePath(allocator, home, platform);
    if (!fileExists(installed)) {
        allocator.free(installed);
        return error.CodextReleaseInstallFailed;
    }
    return .{
        .path = installed,
        .source = if (target_downloaded) .downloaded else .cached,
    };
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
) !bool {
    if (try managedCodextAssetIsCurrent(allocator, cache_root, tag, platform, asset)) {
        if (!quiet) try writeAppUpToDate(platform, tag);
        return false;
    }
    if (!quiet) try writeAppDownload(platform, tag, asset.url);
    try downloadAndInstallCodextAsset(allocator, cache_root, tag, platform, asset);
    if (!quiet) try writeAppInstalled(platform, tag);
    return true;
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

fn writeAppAlreadyRunning() !void {
    var stderr: io_util.Stderr = undefined;
    stderr.init();
    var writer = cli_style.StyledWriter.init(stderr.out(), stderr.color_enabled);
    try writer.writeAll("Codex App is already running, launch skipped.\n");
    try writer.flush();
}

fn writeAppStep(message: []const u8) !void {
    var stderr: io_util.Stderr = undefined;
    stderr.init();
    var writer = cli_style.StyledWriter.init(stderr.out(), stderr.color_enabled);
    try writer.writeStyle(cli_style.role.status);
    try writer.writeAll(stepMarker());
    try writer.writeAll(message);
    try writer.reset();
    try writer.writeAll("\n");
    try writer.flush();
}

fn stepMarker() []const u8 {
    return "- ";
}

fn writeAppDownload(platform: types.AppPlatform, tag: []const u8, url: []const u8) !void {
    var stderr: io_util.Stderr = undefined;
    stderr.init();
    var writer = cli_style.StyledWriter.init(stderr.out(), stderr.color_enabled);
    try writer.writeStyle(cli_style.role.secondary);
    try writer.print("  {s}Downloading Codext CLI for {s} ({s})\n", .{ downloadMarker(), platformLabel(platform), tag });
    try writer.print("  {s}\n", .{url});
    try writer.reset();
    try writer.flush();
}

fn downloadMarker() []const u8 {
    return "";
}

fn writeAppInstalled(platform: types.AppPlatform, tag: []const u8) !void {
    var stderr: io_util.Stderr = undefined;
    stderr.init();
    var writer = cli_style.StyledWriter.init(stderr.out(), stderr.color_enabled);
    try writer.writeStyle(cli_style.role.success);
    try writer.writeAll(successMarker());
    try writer.reset();
    try writer.print(" Downloaded Codext CLI for {s} ({s})\n", .{ platformLabel(platform), tag });
    try writer.flush();
}

fn writeAppUpToDate(platform: types.AppPlatform, tag: []const u8) !void {
    var stderr: io_util.Stderr = undefined;
    stderr.init();
    var writer = cli_style.StyledWriter.init(stderr.out(), stderr.color_enabled);
    try writer.writeStyle(cli_style.role.success);
    try writer.writeAll(successMarker());
    try writer.reset();
    _ = platform;
    try writer.print(" Codext CLI is up-to-date ({s})\n", .{tag});
    try writer.flush();
}

fn successMarker() []const u8 {
    return "OK";
}

fn writeAppLaunching() !void {
    var stderr: io_util.Stderr = undefined;
    stderr.init();
    var writer = cli_style.StyledWriter.init(stderr.out(), stderr.color_enabled);
    try writer.writeStyle(cli_style.role.status);
    try writer.writeAll(launchMarker());
    try writer.writeAll("Launching");
    try writer.reset();
    try writer.writeAll(" Codex App...\n");
    try writer.flush();
}

fn launchMarker() []const u8 {
    return "";
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
    app_id: []const u8,
    cli_path: ?[]const u8,
    home: []const u8,
    mode: WindowsLaunchMode,
) !void {
    const app_quoted = try psSingleQuoteAlloc(allocator, app_id);
    defer allocator.free(app_quoted);
    const home_quoted = try psSingleQuoteAlloc(allocator, home);
    defer allocator.free(home_quoted);
    const cli_quoted = if (cli_path) |path| try psSingleQuoteAlloc(allocator, path) else null;
    defer if (cli_quoted) |path| allocator.free(path);

    const cli_part = if (cli_quoted) |path|
        try std.fmt.allocPrint(allocator, "; $env:CODEX_CLI_PATH={s}", .{path})
    else
        try allocator.dupe(u8, "");
    defer allocator.free(cli_part);

    const launch_part = switch (mode) {
        .gui => "$aumid=Resolve-CodexAppAumid $id; Start-Process -FilePath \"shell:AppsFolder\\$aumid\"",
        .stdio => "$app=Resolve-CodexAppExecutable $id; $wd=Split-Path -Parent $app; Push-Location $wd; try { & $app; $code=$LASTEXITCODE } finally { Pop-Location }; if ($null -ne $code) { exit $code }",
    };

    const script = try std.fmt.allocPrint(
        allocator,
        "$ErrorActionPreference='Stop'; {s}; $id={s}; $env:CODEX_HOME={s}{s}; {s}",
        .{ windows_app_id_resolver_script, app_quoted, home_quoted, cli_part, launch_part },
    );
    defer allocator.free(script);

    var child = try std.process.spawn(app_runtime.io(), .{
        .argv = &[_][]const u8{ "pwsh.exe", "-NoProfile", "-Command", script },
        .stdin = .ignore,
        .stdout = if (mode == .stdio) .inherit else .ignore,
        .stderr = if (mode == .stdio) .inherit else .ignore,
        .create_no_window = mode == .gui,
    });
    switch (try child.wait(app_runtime.io())) {
        .exited => |code| if (code == 0) return,
        else => {},
    }
    try writeAppError("app launcher failed.\n");
    return error.AppLaunchFailed;
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

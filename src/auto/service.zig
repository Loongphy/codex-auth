const std = @import("std");
const app_runtime = @import("../core/runtime.zig");
const builtin = @import("builtin");
const registry = @import("../registry/root.zig");
const service_defs = @import("service_defs.zig");
const service_windows = @import("service_windows.zig");
const windows_task_scheduler = @import("../platform/windows.zig");

const linux_service_name = service_defs.linux_service_name;
const linux_timer_name = service_defs.linux_timer_name;
const mac_label = service_defs.mac_label;
const windows_task_name = service_defs.windows_task_name;
const windows_helper_name = service_defs.windows_helper_name;
const windows_task_trigger_kind = service_defs.windows_task_trigger_kind;
const windows_task_restart_count = service_defs.windows_task_restart_count;
const windows_task_restart_count_value = service_defs.windows_task_restart_count_value;
const windows_task_restart_interval_xml = service_defs.windows_task_restart_interval_xml;
const windows_task_execution_time_limit_xml = service_defs.windows_task_execution_time_limit_xml;

pub const RuntimeState = service_defs.RuntimeState;
pub const linuxUnitText = service_defs.linuxUnitText;
pub const macPlistText = service_defs.macPlistText;
pub const windowsTaskAction = service_defs.windowsTaskAction;
pub const windowsRegisterTaskScript = service_defs.windowsRegisterTaskScript;
pub const windowsTaskMatchScript = service_defs.windowsTaskMatchScript;
pub const windowsEndTaskScript = service_defs.windowsEndTaskScript;
pub const windowsDeleteTaskScript = service_defs.windowsDeleteTaskScript;
pub const windowsTaskStateScript = service_defs.windowsTaskStateScript;
pub const parseWindowsTaskStateOutput = service_defs.parseWindowsTaskStateOutput;

const windowsTaskArguments = service_defs.windowsTaskArguments;

pub fn queryRuntimeState(allocator: std.mem.Allocator) RuntimeState {
    return switch (builtin.os.tag) {
        .linux => queryLinuxRuntimeState(allocator),
        .macos => queryMacRuntimeState(allocator),
        .windows => queryWindowsRuntimeState(allocator),
        else => .unknown,
    };
}

pub fn installService(allocator: std.mem.Allocator, codex_home: []const u8, self_exe: []const u8) !void {
    switch (builtin.os.tag) {
        .linux => try installLinuxService(allocator, codex_home, self_exe),
        .macos => try installMacService(allocator, codex_home, self_exe),
        .windows => try installWindowsService(allocator, codex_home, self_exe),
        else => return error.UnsupportedPlatform,
    }
}

pub fn uninstallService(allocator: std.mem.Allocator, codex_home: []const u8) !void {
    switch (builtin.os.tag) {
        .linux => try uninstallLinuxService(allocator, codex_home),
        .macos => try uninstallMacService(allocator, codex_home),
        .windows => try uninstallWindowsService(allocator),
        else => return error.UnsupportedPlatform,
    }
}

fn installLinuxService(allocator: std.mem.Allocator, codex_home: []const u8, self_exe: []const u8) !void {
    const unit_path = try linuxUnitPath(allocator, linux_service_name);
    defer allocator.free(unit_path);
    const unit_text = try linuxUnitText(allocator, self_exe, codex_home);
    defer allocator.free(unit_text);

    const unit_dir = std.fs.path.dirname(unit_path).?;
    try std.Io.Dir.cwd().createDirPath(app_runtime.io(), unit_dir);
    try std.Io.Dir.cwd().writeFile(app_runtime.io(), .{ .sub_path = unit_path, .data = unit_text });
    try removeLinuxUnit(allocator, linux_timer_name);
    try runChecked(allocator, &[_][]const u8{ "systemctl", "--user", "daemon-reload" });
    try runChecked(allocator, &[_][]const u8{ "systemctl", "--user", "enable", linux_service_name });
    switch (queryLinuxRuntimeState(allocator)) {
        .running => try runChecked(allocator, &[_][]const u8{ "systemctl", "--user", "restart", linux_service_name }),
        else => try runChecked(allocator, &[_][]const u8{ "systemctl", "--user", "start", linux_service_name }),
    }
}

fn uninstallLinuxService(allocator: std.mem.Allocator, codex_home: []const u8) !void {
    _ = codex_home;
    try removeLinuxUnit(allocator, linux_timer_name);
    try removeLinuxUnit(allocator, linux_service_name);
}

fn removeLinuxUnit(allocator: std.mem.Allocator, service_name: []const u8) !void {
    const unit_path = try linuxUnitPath(allocator, service_name);
    defer allocator.free(unit_path);
    runIgnoringFailure(allocator, &[_][]const u8{ "systemctl", "--user", "stop", service_name });
    runIgnoringFailure(allocator, &[_][]const u8{ "systemctl", "--user", "disable", service_name });
    runIgnoringFailure(allocator, &[_][]const u8{ "systemctl", "--user", "reset-failed", service_name });
    deleteAbsoluteFileIfExists(unit_path);
    runIgnoringFailure(allocator, &[_][]const u8{ "systemctl", "--user", "daemon-reload" });
}

pub fn linuxUserSystemdAvailable(allocator: std.mem.Allocator) bool {
    const result = runCapture(allocator, &[_][]const u8{ "systemctl", "--user", "show-environment" }) catch return false;
    defer {
        allocator.free(result.stdout);
        allocator.free(result.stderr);
    }
    return switch (result.term) {
        .exited => |code| code == 0,
        else => false,
    };
}

fn installMacService(allocator: std.mem.Allocator, codex_home: []const u8, self_exe: []const u8) !void {
    const plist_path = try macPlistPath(allocator);
    defer allocator.free(plist_path);
    const plist = try macPlistText(allocator, self_exe, codex_home);
    defer allocator.free(plist);

    const dir = std.fs.path.dirname(plist_path).?;
    try std.Io.Dir.cwd().createDirPath(app_runtime.io(), dir);
    try std.Io.Dir.cwd().writeFile(app_runtime.io(), .{ .sub_path = plist_path, .data = plist });
    _ = runChecked(allocator, &[_][]const u8{ "launchctl", "unload", plist_path }) catch {};
    try runChecked(allocator, &[_][]const u8{ "launchctl", "load", plist_path });
}

fn uninstallMacService(allocator: std.mem.Allocator, codex_home: []const u8) !void {
    _ = codex_home;
    const plist_path = try macPlistPath(allocator);
    defer allocator.free(plist_path);
    _ = runChecked(allocator, &[_][]const u8{ "launchctl", "unload", plist_path }) catch {};
    deleteAbsoluteFileIfExists(plist_path);
}

pub fn deleteAbsoluteFileIfExists(path: []const u8) void {
    std.Io.Dir.deleteFileAbsolute(app_runtime.io(), path) catch |err| switch (err) {
        error.FileNotFound => {},
        else => {},
    };
}

fn installWindowsService(allocator: std.mem.Allocator, codex_home: []const u8, self_exe: []const u8) !void {
    const helper_path = try windowsHelperPath(allocator, self_exe);
    defer allocator.free(helper_path);
    try std.Io.Dir.cwd().access(app_runtime.io(), helper_path, .{});

    const arguments = try windowsTaskArguments(allocator, codex_home);
    defer allocator.free(arguments);

    try windows_task_scheduler.installTask(allocator, .{
        .task_name = windows_task_name,
        .executable_path = helper_path,
        .arguments = arguments,
        .restart_count = windows_task_restart_count_value,
        .restart_interval = windows_task_restart_interval_xml,
        .execution_time_limit = windows_task_execution_time_limit_xml,
    });
}

fn uninstallWindowsService(allocator: std.mem.Allocator) !void {
    try windows_task_scheduler.uninstallTask(allocator, windows_task_name);
}

fn queryLinuxRuntimeState(allocator: std.mem.Allocator) RuntimeState {
    const result = runCapture(allocator, &[_][]const u8{ "systemctl", "--user", "is-active", linux_service_name }) catch return .unknown;
    defer {
        allocator.free(result.stdout);
        allocator.free(result.stderr);
    }
    return switch (result.term) {
        .exited => |code| if (code == 0 and std.mem.startsWith(u8, std.mem.trim(u8, result.stdout, " \n\r\t"), "active")) .running else .stopped,
        else => .unknown,
    };
}

fn queryMacRuntimeState(allocator: std.mem.Allocator) RuntimeState {
    const plist_path = macPlistPath(allocator) catch return .unknown;
    defer allocator.free(plist_path);
    const result = runCapture(allocator, &[_][]const u8{ "launchctl", "list", mac_label }) catch return .unknown;
    defer {
        allocator.free(result.stdout);
        allocator.free(result.stderr);
    }
    return switch (result.term) {
        .exited => |code| if (code == 0) .running else .stopped,
        else => .unknown,
    };
}

fn queryWindowsRuntimeState(allocator: std.mem.Allocator) RuntimeState {
    return switch (windows_task_scheduler.queryTaskRuntimeState(allocator, windows_task_name)) {
        .running => .running,
        .stopped => .stopped,
        .unknown => .unknown,
    };
}

fn linuxUnitPath(allocator: std.mem.Allocator, service_name: []const u8) ![]u8 {
    const home = try registry.resolveUserHome(allocator);
    defer allocator.free(home);
    return try std.fs.path.join(allocator, &[_][]const u8{ home, ".config", "systemd", "user", service_name });
}

pub fn managedServiceSelfExePath(allocator: std.mem.Allocator, self_exe: []const u8) ![]u8 {
    return managedServiceSelfExePathFromDir(allocator, std.Io.Dir.cwd(), self_exe);
}

pub fn managedServiceSelfExePathFromDir(allocator: std.mem.Allocator, cwd: std.Io.Dir, self_exe: []const u8) ![]u8 {
    if (std.mem.indexOf(u8, self_exe, "/.zig-cache/") != null or std.mem.indexOf(u8, self_exe, "\\.zig-cache\\") != null) {
        const candidate_rel = try std.fs.path.join(allocator, &[_][]const u8{ "zig-out", "bin", std.fs.path.basename(self_exe) });
        defer allocator.free(candidate_rel);
        cwd.access(app_runtime.io(), candidate_rel, .{}) catch return try allocator.dupe(u8, self_exe);
        return try app_runtime.realPathFileAlloc(allocator, cwd, candidate_rel);
    }
    return try allocator.dupe(u8, self_exe);
}

pub fn currentServiceDefinitionMatches(allocator: std.mem.Allocator, codex_home: []const u8, self_exe: []const u8) !bool {
    return switch (builtin.os.tag) {
        .linux => try linuxUnitMatches(allocator, codex_home, self_exe),
        .macos => try macPlistMatches(allocator, codex_home, self_exe),
        .windows => try windowsTaskMatches(allocator, codex_home, self_exe),
        else => true,
    };
}

fn linuxUnitMatches(allocator: std.mem.Allocator, codex_home: []const u8, self_exe: []const u8) !bool {
    const unit_path = try linuxUnitPath(allocator, linux_service_name);
    defer allocator.free(unit_path);
    const expected = try linuxUnitText(allocator, self_exe, codex_home);
    defer allocator.free(expected);
    if (!(try fileEqualsBytes(allocator, unit_path, expected))) return false;
    return !(try linuxUnitHasLegacyResidue(allocator, linux_timer_name));
}

fn linuxUnitHasLegacyResidue(allocator: std.mem.Allocator, service_name: []const u8) !bool {
    const unit_path = try linuxUnitPath(allocator, service_name);
    defer allocator.free(unit_path);
    const legacy_unit = try readFileIfExists(allocator, unit_path);
    defer if (legacy_unit) |bytes| allocator.free(bytes);
    if (legacy_unit != null) return true;

    const result = runCapture(allocator, &[_][]const u8{
        "systemctl",
        "--user",
        "show",
        service_name,
        "--property=LoadState,ActiveState,UnitFileState",
    }) catch return false;
    defer {
        allocator.free(result.stdout);
        allocator.free(result.stderr);
    }
    return switch (result.term) {
        .exited => |code| code == 0 and linuxShowUnitHasResidue(result.stdout),
        else => false,
    };
}

fn linuxShowUnitHasResidue(output: []const u8) bool {
    const load_state = linuxShowProperty(output, "LoadState") orelse return false;
    const active_state = linuxShowProperty(output, "ActiveState") orelse return false;
    const unit_file_state = linuxShowProperty(output, "UnitFileState") orelse return false;

    if (!std.mem.eql(u8, load_state, "not-found")) return true;
    if (!std.mem.eql(u8, active_state, "inactive")) return true;
    if (unit_file_state.len != 0 and !std.mem.eql(u8, unit_file_state, "not-found") and !std.mem.eql(u8, unit_file_state, "disabled")) {
        return true;
    }
    return false;
}

fn linuxShowProperty(output: []const u8, key: []const u8) ?[]const u8 {
    var lines = std.mem.splitScalar(u8, output, '\n');
    while (lines.next()) |raw_line| {
        const line = std.mem.trim(u8, raw_line, " \r\t");
        if (line.len == 0) continue;
        if (!std.mem.startsWith(u8, line, key)) continue;
        if (line.len <= key.len or line[key.len] != '=') continue;
        return std.mem.trim(u8, line[key.len + 1 ..], " \r\t");
    }
    return null;
}

fn macPlistMatches(allocator: std.mem.Allocator, codex_home: []const u8, self_exe: []const u8) !bool {
    const plist_path = try macPlistPath(allocator);
    defer allocator.free(plist_path);
    const expected = try macPlistText(allocator, self_exe, codex_home);
    defer allocator.free(expected);
    return try fileEqualsBytes(allocator, plist_path, expected);
}

fn windowsTaskMatches(allocator: std.mem.Allocator, codex_home: []const u8, self_exe: []const u8) !bool {
    const helper_path = try windowsHelperPath(allocator, self_exe);
    defer allocator.free(helper_path);
    return try service_windows.taskMatches(allocator, codex_home, helper_path);
}

fn windowsHelperPath(allocator: std.mem.Allocator, self_exe: []const u8) ![]u8 {
    const dir = std.fs.path.dirname(self_exe) orelse return error.FileNotFound;
    return try std.fs.path.join(allocator, &[_][]const u8{ dir, windows_helper_name });
}

fn macPlistPath(allocator: std.mem.Allocator) ![]u8 {
    const home = try registry.resolveUserHome(allocator);
    defer allocator.free(home);
    return try std.fs.path.join(allocator, &[_][]const u8{ home, "Library", "LaunchAgents", mac_label ++ ".plist" });
}

fn runChecked(allocator: std.mem.Allocator, argv: []const []const u8) !void {
    const result = try runCapture(allocator, argv);
    defer {
        allocator.free(result.stdout);
        allocator.free(result.stderr);
    }
    switch (result.term) {
        .exited => |code| {
            if (code == 0) return;
        },
        else => {},
    }
    if (result.stderr.len > 0) {
        std.log.err("{s}", .{std.mem.trim(u8, result.stderr, " \n\r\t")});
    }
    return error.CommandFailed;
}

fn readFileIfExists(allocator: std.mem.Allocator, path: []const u8) !?[]u8 {
    var file = std.Io.Dir.cwd().openFile(app_runtime.io(), path, .{}) catch |err| {
        if (err == error.FileNotFound) return null;
        return err;
    };
    defer file.close(app_runtime.io());
    var read_buffer: [4096]u8 = undefined;
    var file_reader = file.reader(app_runtime.io(), &read_buffer);
    return try file_reader.interface.allocRemaining(allocator, .limited(1024 * 1024));
}

fn fileEqualsBytes(allocator: std.mem.Allocator, path: []const u8, bytes: []const u8) !bool {
    const data = try readFileIfExists(allocator, path);
    defer if (data) |buf| allocator.free(buf);
    if (data == null) return false;
    return std.mem.eql(u8, data.?, bytes);
}

fn runCapture(allocator: std.mem.Allocator, argv: []const []const u8) !std.process.RunResult {
    return try std.process.run(allocator, app_runtime.io(), .{
        .argv = argv,
        .stdout_limit = .limited(1024 * 1024),
        .stderr_limit = .limited(1024 * 1024),
    });
}

fn runIgnoringFailure(allocator: std.mem.Allocator, argv: []const []const u8) void {
    const result = runCapture(allocator, argv) catch return;
    allocator.free(result.stdout);
    allocator.free(result.stderr);
}

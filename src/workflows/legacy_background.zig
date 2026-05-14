const std = @import("std");
const builtin = @import("builtin");
const app_runtime = @import("../core/runtime.zig");
const registry = @import("../registry/root.zig");

const linux_service_name = "codex-auth-autoswitch.service";
const linux_timer_name = "codex-auth-autoswitch.timer";
const mac_label = "com.loongphy.codex-auth.auto";
const windows_task_name = "CodexAuthAutoSwitch";

pub const CleanSummary = struct {
    platform: []const u8,
    files_removed: usize = 0,
};

pub fn clean(allocator: std.mem.Allocator) !CleanSummary {
    return switch (builtin.os.tag) {
        .linux => cleanLinux(allocator),
        .macos => cleanMac(allocator),
        .windows => cleanWindows(allocator),
        else => .{ .platform = @tagName(builtin.os.tag) },
    };
}

fn cleanLinux(allocator: std.mem.Allocator) !CleanSummary {
    var summary = CleanSummary{ .platform = "linux" };
    cleanupLinuxUnit(allocator, linux_timer_name, &summary);
    cleanupLinuxUnit(allocator, linux_service_name, &summary);
    runIgnoringFailure(allocator, &[_][]const u8{ "systemctl", "--user", "daemon-reload" });
    return summary;
}

fn cleanupLinuxUnit(allocator: std.mem.Allocator, unit_name: []const u8, summary: *CleanSummary) void {
    runIgnoringFailure(allocator, &[_][]const u8{ "systemctl", "--user", "stop", unit_name });
    runIgnoringFailure(allocator, &[_][]const u8{ "systemctl", "--user", "disable", unit_name });
    runIgnoringFailure(allocator, &[_][]const u8{ "systemctl", "--user", "reset-failed", unit_name });

    const path = linuxUnitPath(allocator, unit_name) catch return;
    defer allocator.free(path);
    if (deleteAbsoluteFileIfExists(path)) summary.files_removed += 1;
}

fn linuxUnitPath(allocator: std.mem.Allocator, unit_name: []const u8) ![]u8 {
    const home = try registry.resolveUserHome(allocator);
    defer allocator.free(home);
    return try std.fs.path.join(allocator, &[_][]const u8{ home, ".config", "systemd", "user", unit_name });
}

fn cleanMac(allocator: std.mem.Allocator) !CleanSummary {
    var summary = CleanSummary{ .platform = "macos" };
    const plist_path = try macPlistPath(allocator);
    defer allocator.free(plist_path);
    runIgnoringFailure(allocator, &[_][]const u8{ "launchctl", "unload", plist_path });
    if (deleteAbsoluteFileIfExists(plist_path)) summary.files_removed += 1;
    return summary;
}

fn macPlistPath(allocator: std.mem.Allocator) ![]u8 {
    const home = try registry.resolveUserHome(allocator);
    defer allocator.free(home);
    return try std.fs.path.join(allocator, &[_][]const u8{ home, "Library", "LaunchAgents", mac_label ++ ".plist" });
}

fn cleanWindows(allocator: std.mem.Allocator) !CleanSummary {
    runIgnoringFailure(allocator, &[_][]const u8{ "schtasks.exe", "/End", "/TN", windows_task_name });
    runIgnoringFailure(allocator, &[_][]const u8{ "schtasks.exe", "/Delete", "/TN", windows_task_name, "/F" });
    return .{ .platform = "windows" };
}

fn deleteAbsoluteFileIfExists(path: []const u8) bool {
    std.Io.Dir.deleteFileAbsolute(app_runtime.io(), path) catch |err| switch (err) {
        error.FileNotFound => return false,
        else => return false,
    };
    return true;
}

fn runIgnoringFailure(allocator: std.mem.Allocator, argv: []const []const u8) void {
    const result = std.process.run(allocator, app_runtime.io(), .{
        .argv = argv,
        .stdout_limit = .limited(1024 * 1024),
        .stderr_limit = .limited(1024 * 1024),
    }) catch return;
    allocator.free(result.stdout);
    allocator.free(result.stderr);
}

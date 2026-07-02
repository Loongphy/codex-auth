const std = @import("std");
const builtin = @import("builtin");
const app_runtime = @import("../core/runtime.zig");
const io_util = @import("../core/io_util.zig");
const output = @import("../cli/output.zig");

// macOS GUI bundle id (mirrors `codex_app_bundle_id` in workflows/app.zig).
const mac_bundle_id = "com.openai.codex";

/// Terminate every running Codex process (CLI and GUI) before an account switch.
///
/// Strategy: graceful request first (quit / SIGTERM / windowed close), a short
/// wait, then a hard kill for anything that survived. If a Codex process is
/// still alive afterwards the switch must not proceed, so `error.CodexStillRunning`
/// is returned (after printing a user-facing message).
///
/// Exact process-name matching is used everywhere (`pkill -x codex`,
/// `taskkill /IM codex.exe`) so `codex-auth` itself is never targeted.
pub fn ensureCodexStoppedForSwitch(allocator: std.mem.Allocator) !void {
    if (!isAnyCodexRunning(allocator)) return;

    gracefulKill(allocator);
    sleepMs(700);
    if (isAnyCodexRunning(allocator)) {
        forceKill(allocator);
        sleepMs(400);
    }
    if (isAnyCodexRunning(allocator)) {
        try output.printCodexStillRunningError();
        return error.CodexStillRunning;
    }
    printStoppedNotice();
}

fn gracefulKill(allocator: std.mem.Allocator) void {
    switch (builtin.os.tag) {
        .windows => {
            // `/T` also stops child processes of the launcher shims; no `/F` yet.
            runIgnoringFailure(allocator, &[_][]const u8{ "taskkill", "/IM", "codex.exe", "/T" });
        },
        .macos => {
            runIgnoringFailure(allocator, &[_][]const u8{ "osascript", "-e", "tell application id \"" ++ mac_bundle_id ++ "\" to quit" });
            runIgnoringFailure(allocator, &[_][]const u8{ "pkill", "-TERM", "-x", "codex" });
            runIgnoringFailure(allocator, &[_][]const u8{ "pkill", "-TERM", "-x", "Codex" });
        },
        .linux => {
            runIgnoringFailure(allocator, &[_][]const u8{ "pkill", "-TERM", "-x", "codex" });
            runIgnoringFailure(allocator, &[_][]const u8{ "pkill", "-TERM", "-x", "Codex" });
        },
        else => {},
    }
}

fn forceKill(allocator: std.mem.Allocator) void {
    switch (builtin.os.tag) {
        .windows => {
            runIgnoringFailure(allocator, &[_][]const u8{ "taskkill", "/IM", "codex.exe", "/T", "/F" });
        },
        .macos, .linux => {
            runIgnoringFailure(allocator, &[_][]const u8{ "pkill", "-KILL", "-x", "codex" });
            runIgnoringFailure(allocator, &[_][]const u8{ "pkill", "-KILL", "-x", "Codex" });
        },
        else => {},
    }
}

fn isAnyCodexRunning(allocator: std.mem.Allocator) bool {
    return switch (builtin.os.tag) {
        .windows => windowsCodexRunning(allocator),
        .macos, .linux => pgrepMatches(allocator, "codex") or pgrepMatches(allocator, "Codex"),
        else => false,
    };
}

fn pgrepMatches(allocator: std.mem.Allocator, name: []const u8) bool {
    const result = std.process.run(allocator, app_runtime.io(), .{
        .argv = &[_][]const u8{ "pgrep", "-x", name },
        .stdout_limit = .limited(64 * 1024),
        .stderr_limit = .limited(64 * 1024),
    }) catch return false;
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);
    return switch (result.term) {
        .exited => |code| code == 0,
        else => false,
    };
}

fn windowsCodexRunning(allocator: std.mem.Allocator) bool {
    // Exact image-name filter => never matches `codex-auth.exe`.
    const result = std.process.run(allocator, app_runtime.io(), .{
        .argv = &[_][]const u8{ "tasklist", "/FI", "IMAGENAME eq codex.exe", "/NH" },
        .stdout_limit = .limited(64 * 1024),
        .stderr_limit = .limited(64 * 1024),
    }) catch return false;
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);
    const trimmed = std.mem.trim(u8, result.stdout, " \t\r\n");
    if (trimmed.len == 0) return false;
    // When no process matches, tasklist prints "INFO: No tasks are running ...".
    if (std.mem.startsWith(u8, trimmed, "INFO:")) return false;
    return std.ascii.indexOfIgnoreCase(trimmed, "codex.exe") != null;
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

fn sleepMs(ms: i64) void {
    app_runtime.io().sleep(std.Io.Duration.fromMilliseconds(ms), .awake) catch {};
}

fn printStoppedNotice() void {
    var stderr: io_util.Stderr = undefined;
    stderr.init();
    const out = stderr.out();
    out.writeAll("Stopped running codex processes before switching.\n") catch return;
    out.flush() catch {};
}

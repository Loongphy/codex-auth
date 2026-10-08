const std = @import("std");
const builtin = @import("builtin");
const app_runtime = @import("../core/runtime.zig");

// Codex CLI sessions attach to a shared app-server daemon that loads auth.json
// once at startup. Restarting it is the only way to apply a switch; attached
// sessions reconnect on their own.
pub const RestartOutcome = enum {
    not_running,
    disabled,
    restarted,
    failed,
};

pub fn restartIfRunning(allocator: std.mem.Allocator, codex_home: []const u8, enabled: bool) RestartOutcome {
    if (!isRunning(allocator, codex_home)) return .not_running;
    if (!enabled) return .disabled;
    restart(allocator, codex_home) catch return .failed;
    return .restarted;
}

fn isRunning(allocator: std.mem.Allocator, codex_home: []const u8) bool {
    const socket_path = std.fs.path.join(allocator, &[_][]const u8{ codex_home, "app-server-control", "app-server-control.sock" }) catch return false;
    defer allocator.free(socket_path);
    std.Io.Dir.cwd().access(app_runtime.io(), socket_path, .{}) catch return false;
    return true;
}

fn restart(allocator: std.mem.Allocator, codex_home: []const u8) !void {
    // Use the daemon's own managed binary so PATH shims and versions cannot drift.
    const exe_name = if (builtin.os.tag == .windows) "codex.exe" else "codex";
    const codex_path = try std.fs.path.join(allocator, &[_][]const u8{ codex_home, "packages", "app-server-daemon", "current", "bin", exe_name });
    defer allocator.free(codex_path);

    var env_map = try app_runtime.currentEnviron().createMap(allocator);
    defer env_map.deinit();
    try env_map.put("CODEX_HOME", codex_home);

    var child = try std.process.spawn(app_runtime.io(), .{
        .argv = &[_][]const u8{ codex_path, "app-server", "daemon", "restart" },
        .environ_map = &env_map,
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .ignore,
    });
    switch (try child.wait(app_runtime.io())) {
        .exited => |code| if (code == 0) return,
        else => {},
    }
    return error.CodexDaemonRestartFailed;
}

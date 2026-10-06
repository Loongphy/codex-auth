const std = @import("std");
const app_runtime = @import("../core/runtime.zig");
const executable = @import("../api/http_executable.zig");
const child = @import("../api/http_child.zig");

const socket_dir_name = "app-server-control";
const socket_file_name = "app-server-control.sock";
const nudge_timeout_ms: u64 = 20_000;

/// After `CODEX_HOME/auth.json` is replaced, ask a running Codext app-server
/// daemon to reload it. The daemon is a long-lived process that caches auth;
/// without this nudge it keeps the previous account until a request-boundary
/// reload, and a stock upstream daemon ignores the swap entirely.
///
/// Best effort: this never fails the caller and only logs to stderr, so
/// `--json` output stays clean.
pub fn nudgeDaemonAuthReload(allocator: std.mem.Allocator, codex_home: []const u8) void {
    inner(allocator, codex_home) catch |err| {
        std.log.warn("daemon auth reload nudge skipped: {s}", .{@errorName(err)});
    };
}

fn inner(allocator: std.mem.Allocator, codex_home: []const u8) !void {
    const socket_path = try std.fs.path.join(allocator, &.{ codex_home, socket_dir_name, socket_file_name });
    defer allocator.free(socket_path);

    std.Io.Dir.cwd().access(app_runtime.io(), socket_path, .{}) catch return;

    const codext = executable.ensureExecutableAvailableAlloc(allocator, "codext") catch |err| switch (err) {
        error.ExecutableRequired => {
            std.log.warn(
                "an app-server daemon is running but `codext` is not on PATH; running Codext sessions may keep the previous account",
                .{},
            );
            return;
        },
        else => return err,
    };
    defer allocator.free(codext);

    const result = try child.runChildCapture(allocator, &.{ codext, "app-server", "daemon", "reload-auth" }, nudge_timeout_ms, null);
    defer result.deinit(allocator);

    if (result.timed_out) {
        std.log.warn("timed out asking the app-server daemon to reload auth; the switch may not take effect in running sessions", .{});
        return;
    }
    const ok = switch (result.term) {
        .exited => |code| code == 0,
        else => false,
    };
    if (ok) return;

    const detail = std.mem.trim(u8, result.stderr, " \t\r\n");
    if (detail.len != 0) {
        std.log.warn(
            "the app-server daemon refused the auth reload: {s} — if the daemon is not a codext build, stop it or run `codext --no-daemon` so the account switch takes effect",
            .{detail},
        );
    } else {
        std.log.warn(
            "the app-server daemon refused the auth reload; if the daemon is not a codext build, stop it or run `codext --no-daemon` so the account switch takes effect",
            .{},
        );
    }
}

const std = @import("std");
const fs = @import("codex_auth").core.compat_fs;

/// A strict lifecycle fake: only version and restart are accepted. Restart
/// records the selected home and verifies persistence before its side effect.
pub fn install(dir: fs.Dir, body: []const u8) !void {
    try dir.makePath("app-server-control");
    try dir.writeFile(.{ .sub_path = "app-server-control/app-server-control.sock", .data = "fake endpoint" });
    try dir.makePath("packages/app-server-daemon/current/bin");
    const script = try std.mem.concat(std.testing.allocator, u8, &.{
        "#!/bin/sh\nset -eu\n" ++
            "[ \"$#\" = 3 ] && [ \"$1\" = app-server ] && [ \"$2\" = daemon ] || exit 90\n" ++
            "printf '%s\\n' \"$3\" >> \"$CODEX_HOME/lifecycle-calls\"\n",
        body,
    });
    defer std.testing.allocator.free(script);
    try dir.writeFile(.{ .sub_path = "packages/app-server-daemon/current/bin/codex", .data = script });
    var file = try dir.openFile("packages/app-server-daemon/current/bin/codex", .{ .mode = .read_write });
    defer file.close();
    try file.chmod(0o700);
}

pub const running = "if [ \"$3\" = version ]; then printf '%s\\n' '{\"status\":\"running\",\"appServerVersion\":\"0.160.0\",\"backend\":\"pid\"}'; exit 0; fi\n";
/// Mirrors the real codext CLI: unsupported reload prints the marker to
/// stderr and exits non-zero; the caller reads stderr to decide whether a
/// restart fallback is justified.
pub const reload_unsupported = "if [ \"$3\" = reload-auth ]; then printf '%s\\n' 'the running app-server does not implement account/reload; it is not a codext daemon' >&2; exit 1; fi\n";
pub const succeed = running ++ reload_unsupported ++ "[ \"$3\" = restart ] || exit 91\nprintf '%s\\n' \"$CODEX_HOME\" > \"$CODEX_HOME/restarted-home\"\n";
pub const reload_changed = running ++ "[ \"$3\" = reload-auth ] || exit 91\nprintf '%s\\n' 'Daemon reloaded auth; the account changed.'\n";
pub const reload_busy = running ++ "[ \"$3\" = reload-auth ] || exit 91\nprintf '%s\\n' 'Daemon skipped the auth reload because a turn is running.'\n";
pub const reload_unsupported_succeed = running ++ reload_unsupported ++ "[ \"$3\" = restart ] || exit 91\nprintf '%s\\n' \"$CODEX_HOME\" > \"$CODEX_HOME/restarted-home\"\n";
pub const reload_failed_succeed = running ++ "if [ \"$3\" = reload-auth ]; then printf '%s\\n' 'account/reload failed: failed to reload auth from storage' >&2; exit 1; fi\n" ++ "[ \"$3\" = restart ] || exit 91\nprintf '%s\\n' \"$CODEX_HOME\" > \"$CODEX_HOME/restarted-home\"\n";
/// reload-auth stalls forever so callers can observe the reload deadline
/// without needing the daemon to be unsupported. `exec` makes the stalled
/// process the one runLifecycle kills, not a grandchild it leaves behind.
pub const reload_slow = running ++ "if [ \"$3\" = reload-auth ]; then exec sleep 60; fi\n" ++ "[ \"$3\" = restart ] || exit 91\nprintf '%s\\n' \"$CODEX_HOME\" > \"$CODEX_HOME/restarted-home\"\n";
/// Every lifecycle call sleeps far past the caller's cancel poll window, so
/// teardown exercises cancellation instead of the command deadline.
pub const sleep_forever = "exec sleep 60\n";
/// Same stall but with both pipes closed first: the reader sees EOF while the
/// helper is still alive, exercising cancellation inside waitForExit.
pub const sleep_no_output = "exec 1>&- 2>&-; exec sleep 60\n";
/// version sleeps briefly so a second apply lands while the worker is busy.
pub const slow_reload_changed = "if [ \"$3\" = version ]; then sleep 1; printf '%s\\n' '{\"status\":\"running\",\"appServerVersion\":\"0.160.0\",\"backend\":\"pid\"}'; exit 0; fi\n" ++ "[ \"$3\" = reload-auth ] || exit 91\nprintf '%s\\n' 'Daemon reloaded auth; the account changed.'\n";

pub fn read(dir: fs.Dir, path: []const u8) ![]u8 {
    var file = try dir.openFile(path, .{});
    defer file.close();
    return try file.readToEndAlloc(std.testing.allocator, 16 * 1024);
}

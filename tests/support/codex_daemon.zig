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
pub const succeed = running ++ "[ \"$3\" = restart ] || exit 91\nprintf '%s\\n' \"$CODEX_HOME\" > \"$CODEX_HOME/restarted-home\"\n";

pub fn read(dir: fs.Dir, path: []const u8) ![]u8 {
    var file = try dir.openFile(path, .{});
    defer file.close();
    return try file.readToEndAlloc(std.testing.allocator, 16 * 1024);
}

const std = @import("std");
const codex_auth = @import("codex_auth");

/// std.log goes through the style.md palette instead of Zig's default
/// yellow-on-bold warning: warnings are cyan, errors red, info cyan,
/// debug dim — the same roles the CLI applies to its own messages.
pub const std_options: std.Options = .{
    .logFn = appLogFn,
};

fn appLogFn(
    comptime level: std.log.Level,
    comptime scope: @EnumLiteral(),
    comptime format: []const u8,
    args: anytype,
) void {
    const io = std.Options.debug_io;
    const prev = io.swapCancelProtection(.blocked);
    defer _ = io.swapCancelProtection(prev);
    var buffer: [64]u8 = undefined;
    const stderr = std.debug.lockStderr(&buffer).terminal();
    defer std.debug.unlockStderr();
    stderr.setColor(switch (level) {
        .err => .red,
        .warn, .info => .cyan,
        .debug => .dim,
    }) catch {};
    stderr.writer.writeAll(level.asText()) catch {};
    if (scope != .default) stderr.writer.print("({t})", .{scope}) catch {};
    stderr.setColor(.reset) catch {};
    stderr.writer.writeAll(": ") catch {};
    stderr.writer.print(format ++ "\n", args) catch {};
}

pub fn main(init: std.process.Init) !u8 {
    return codex_auth.workflows.main(init);
}

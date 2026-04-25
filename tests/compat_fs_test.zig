const std = @import("std");
const fs = @import("codex_auth").core.compat_fs;

const io = fs.io;

test "compat fs io supports process spawning" {
    const result = try std.process.run(std.testing.allocator, io(), .{
        .argv = &.{ "zig", "version" },
        .stdout_limit = .limited(1024),
        .stderr_limit = .limited(1024),
    });
    defer std.testing.allocator.free(result.stdout);
    defer std.testing.allocator.free(result.stderr);

    try std.testing.expectEqual(.exited, std.meta.activeTag(result.term));
    try std.testing.expect(result.stdout.len != 0);
    try std.testing.expect(result.stderr.len == 0);
}

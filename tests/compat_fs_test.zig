const builtin = @import("builtin");
const std = @import("std");
const test_options = @import("test_options");
const fs = @import("codex_auth").core.compat_fs;

const io = fs.io;

test "compat fs io supports process spawning" {
    const result = try std.process.run(std.testing.allocator, io(), .{
        .argv = &.{ test_options.zig_exe, "version" },
        .stdout_limit = .limited(1024),
        .stderr_limit = .limited(1024),
    });
    defer std.testing.allocator.free(result.stdout);
    defer std.testing.allocator.free(result.stderr);

    try std.testing.expectEqual(.exited, std.meta.activeTag(result.term));
    try std.testing.expectEqualStrings(builtin.zig_version_string, std.mem.trim(u8, result.stdout, " \r\n"));
    try std.testing.expect(result.stderr.len == 0);
}

test "terminal color stays disabled for regular files" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const file = try tmp.dir.createFile(std.testing.io, "plain.txt", .{});
    defer file.close(std.testing.io);
    try std.testing.expect(!@import("codex_auth").terminal.color.fileColorEnabled(file));
}

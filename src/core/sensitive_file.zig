const std = @import("std");
const builtin = @import("builtin");
const app_runtime = @import("runtime.zig");

pub const permissions: std.Io.File.Permissions = switch (builtin.os.tag) {
    .windows => .default_file,
    else => .fromMode(0o600),
};

pub fn writeAtomic(path: []const u8, data: []const u8) !void {
    if (builtin.os.tag == .windows) return writeReplace(path, data);

    var buffer: [4096]u8 = undefined;
    var atomic = try std.Io.Dir.cwd().createFileAtomic(app_runtime.io(), path, .{
        .replace = true,
        .permissions = permissions,
    });
    defer atomic.deinit(app_runtime.io());
    var writer = atomic.file.writer(app_runtime.io(), &buffer);
    try writer.interface.writeAll(data);
    try writer.interface.flush();
    try atomic.file.sync(app_runtime.io());
    try atomic.replace(app_runtime.io());
    try harden(path);
}

fn writeReplace(path: []const u8, data: []const u8) !void {
    const allocator = std.heap.page_allocator;
    const nonce = std.Io.Timestamp.now(app_runtime.io(), .real).toNanoseconds();
    const temp = try std.fmt.allocPrint(allocator, "{s}.tmp.{d}", .{ path, nonce });
    defer allocator.free(temp);
    const backup = try std.fmt.allocPrint(allocator, "{s}.bak.{d}", .{ path, nonce });
    defer allocator.free(backup);

    {
        var file = try std.Io.Dir.cwd().createFile(app_runtime.io(), temp, .{ .truncate = true, .permissions = permissions });
        defer file.close(app_runtime.io());
        try file.writeStreamingAll(app_runtime.io(), data);
        try file.sync(app_runtime.io());
    }
    const had_original = blk: {
        std.Io.Dir.cwd().rename(path, std.Io.Dir.cwd(), backup, app_runtime.io()) catch |err| switch (err) {
            error.FileNotFound => break :blk false,
            else => return err,
        };
        break :blk true;
    };
    errdefer {
        std.Io.Dir.cwd().deleteFile(app_runtime.io(), temp) catch {};
        if (had_original) std.Io.Dir.cwd().rename(backup, std.Io.Dir.cwd(), path, app_runtime.io()) catch {};
    }
    try std.Io.Dir.cwd().rename(temp, std.Io.Dir.cwd(), path, app_runtime.io());
    if (had_original) try std.Io.Dir.cwd().deleteFile(app_runtime.io(), backup);
    try harden(path);
}

fn harden(path: []const u8) !void {
    if (builtin.os.tag == .windows) return;
    const file = try std.Io.Dir.cwd().openFile(app_runtime.io(), path, .{ .mode = .read_write });
    defer file.close(app_runtime.io());
    try file.setPermissions(app_runtime.io(), permissions);
}

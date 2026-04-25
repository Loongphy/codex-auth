const std = @import("std");
const app_runtime = @import("../core/runtime.zig");

pub fn fileMtimeNsIfExists(path: []const u8) !?i128 {
    const stat = std.Io.Dir.cwd().statFile(app_runtime.io(), path, .{}) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return err,
    };
    return stat.mtime.nanoseconds;
}

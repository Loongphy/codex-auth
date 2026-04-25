const std = @import("std");
const app_runtime = @import("../core/runtime.zig");

pub fn readFileOnce(file: std.Io.File, buffer: []u8) !usize {
    var buffers = [_][]u8{buffer};
    return file.readStreaming(app_runtime.io(), &buffers) catch |err| switch (err) {
        error.EndOfStream => 0,
        else => |e| return e,
    };
}

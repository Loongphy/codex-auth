const std = @import("std");
const types = @import("../types.zig");
const common = @import("common.zig");

pub fn parse(allocator: std.mem.Allocator, args: []const [:0]const u8) !types.ParseResult {
    return common.parseSimpleCommandArgs(allocator, "clean", .clean, .{ .clean = .{} }, args);
}

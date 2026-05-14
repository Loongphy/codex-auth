const std = @import("std");
const types = @import("../types.zig");
const common = @import("common.zig");

pub fn parse(allocator: std.mem.Allocator, args: []const [:0]const u8) !types.ParseResult {
    if (args.len == 0) return .{ .command = .{ .clean = .{} } };
    const first = std.mem.sliceTo(args[0], 0);
    if (args.len == 1 and common.isHelpFlag(first)) return .{ .command = .{ .help = .clean } };
    if (args.len == 1 and std.mem.eql(u8, first, "background")) {
        return .{ .command = .{ .clean = .{ .target = .background } } };
    }
    if (args.len > 1) {
        return common.usageErrorResult(allocator, .clean, "unexpected argument after `clean`: `{s}`.", .{
            std.mem.sliceTo(args[1], 0),
        });
    }
    return common.usageErrorResult(allocator, .clean, "unknown clean target `{s}`.", .{first});
}

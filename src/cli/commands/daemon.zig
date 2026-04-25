const std = @import("std");
const types = @import("../types.zig");
const common = @import("common.zig");

pub fn parse(allocator: std.mem.Allocator, args: []const [:0]const u8) !types.ParseResult {
    if (args.len == 1 and common.isHelpFlag(std.mem.sliceTo(args[0], 0))) {
        return .{ .command = .{ .help = .daemon } };
    }
    if (args.len == 1) {
        const mode = std.mem.sliceTo(args[0], 0);
        if (std.mem.eql(u8, mode, "--watch")) return .{ .command = .{ .daemon = .{ .mode = .watch } } };
        if (std.mem.eql(u8, mode, "--once")) return .{ .command = .{ .daemon = .{ .mode = .once } } };
    }
    return common.usageErrorResult(allocator, .daemon, "`daemon` requires `--watch` or `--once`.", .{});
}

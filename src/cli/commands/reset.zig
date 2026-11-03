const std = @import("std");
const types = @import("../types.zig");
const common = @import("common.zig");

pub fn parse(allocator: std.mem.Allocator, args: []const [:0]const u8) !types.ParseResult {
    if (args.len == 1 and common.isHelpFlag(std.mem.sliceTo(args[0], 0))) {
        return .{ .command = .{ .help = .reset_credits } };
    }

    var selector: ?[]u8 = null;
    for (args) |raw_arg| {
        const arg = std.mem.sliceTo(raw_arg, 0);
        if (std.mem.startsWith(u8, arg, "-")) {
            if (selector) |value| allocator.free(value);
            return common.usageErrorResult(allocator, .reset_credits, "unknown flag `{s}` for `reset`.", .{arg});
        }
        if (selector != null) {
            allocator.free(selector.?);
            return common.usageErrorResult(allocator, .reset_credits, "unexpected extra argument `{s}` for `reset`.", .{arg});
        }
        selector = try allocator.dupe(u8, arg);
    }
    if (selector == null) {
        return common.usageErrorResult(allocator, .reset_credits, "`reset` requires an account selector (alias, email, display number, or partial query).", .{});
    }
    return .{ .command = .{ .reset_credits = .{ .selector = selector.? } } };
}

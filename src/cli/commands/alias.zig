const std = @import("std");
const types = @import("../types.zig");
const common = @import("common.zig");

pub fn parse(allocator: std.mem.Allocator, args: []const [:0]const u8) !types.ParseResult {
    if (args.len == 1 and common.isHelpFlag(std.mem.sliceTo(args[0], 0))) {
        return .{ .command = .{ .help = .alias } };
    }
    if (args.len == 0) {
        return common.usageErrorResult(allocator, .alias, "`alias` requires `set` or `clear`.", .{});
    }

    const subcommand = std.mem.sliceTo(args[0], 0);
    if (std.mem.eql(u8, subcommand, "set")) {
        if (args.len < 3) return common.usageErrorResult(allocator, .alias, "`alias set` requires a selector and alias.", .{});
        if (args.len > 3) return common.usageErrorResult(allocator, .alias, "unexpected extra argument `{s}` for `alias set`.", .{std.mem.sliceTo(args[3], 0)});

        const selector = try allocator.dupe(u8, std.mem.sliceTo(args[1], 0));
        errdefer allocator.free(selector);
        const alias_value = try allocator.dupe(u8, std.mem.sliceTo(args[2], 0));
        return .{ .command = .{ .alias = .{ .set = .{
            .selector = selector,
            .alias = alias_value,
        } } } };
    }
    if (std.mem.eql(u8, subcommand, "clear")) {
        if (args.len < 2) return common.usageErrorResult(allocator, .alias, "`alias clear` requires a selector.", .{});
        if (args.len > 2) return common.usageErrorResult(allocator, .alias, "unexpected extra argument `{s}` for `alias clear`.", .{std.mem.sliceTo(args[2], 0)});
        return .{ .command = .{ .alias = .{ .clear = .{
            .selector = try allocator.dupe(u8, std.mem.sliceTo(args[1], 0)),
        } } } };
    }
    if (common.isHelpFlag(subcommand)) {
        return common.usageErrorResult(allocator, .alias, "`--help` must be used by itself for `alias`.", .{});
    }
    if (std.mem.startsWith(u8, subcommand, "-")) {
        return common.usageErrorResult(allocator, .alias, "unknown flag `{s}` for `alias`.", .{subcommand});
    }
    return common.usageErrorResult(allocator, .alias, "unknown alias subcommand `{s}`.", .{subcommand});
}

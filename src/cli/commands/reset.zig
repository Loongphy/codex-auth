const std = @import("std");
const types = @import("../types.zig");
const common = @import("common.zig");

pub fn parse(allocator: std.mem.Allocator, args: []const [:0]const u8) !types.ParseResult {
    if (args.len == 1 and common.isHelpFlag(std.mem.sliceTo(args[0], 0))) {
        return .{ .command = .{ .help = .reset } };
    }

    var selector: ?[]u8 = null;
    errdefer if (selector) |value| allocator.free(value);
    var opts: types.ResetOptions = .{
        .selector = &.{},
        .yes = false,
    };

    for (args) |raw_arg| {
        const arg = std.mem.sliceTo(raw_arg, 0);
        if (std.mem.eql(u8, arg, "--yes")) {
            if (opts.yes) return common.usageErrorResult(allocator, .reset, "duplicate `--yes` for `reset`.", .{});
            opts.yes = true;
            continue;
        }
        if (std.mem.startsWith(u8, arg, "-")) return common.usageErrorResult(allocator, .reset, "unknown flag `{s}` for `reset`.", .{arg});
        if (selector != null) return common.usageErrorResult(allocator, .reset, "unexpected extra argument `{s}` for `reset`.", .{arg});
        selector = try allocator.dupe(u8, arg);
    }

    opts.selector = selector orelse return common.usageErrorResult(allocator, .reset, "`reset` requires an account selector.", .{});
    selector = null;
    return .{ .command = .{ .reset = opts } };
}

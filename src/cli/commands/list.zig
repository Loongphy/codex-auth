const std = @import("std");
const types = @import("../types.zig");
const common = @import("common.zig");

pub fn parse(allocator: std.mem.Allocator, args: []const [:0]const u8) !types.ParseResult {
    if (args.len == 1 and common.isHelpFlag(std.mem.sliceTo(args[0], 0))) {
        return .{ .command = .{ .help = .list } };
    }

    var opts: types.ListOptions = .{};
    for (args) |raw_arg| {
        const arg = std.mem.sliceTo(raw_arg, 0);
        if (std.mem.eql(u8, arg, "--live")) {
            if (opts.live) return common.usageErrorResult(allocator, .list, "duplicate `--live` for `list`.", .{});
            opts.live = true;
            continue;
        }
        if (std.mem.eql(u8, arg, "--api")) {
            switch (opts.api_mode) {
                .default => opts.api_mode = .force_api,
                .force_api => return common.usageErrorResult(allocator, .list, "duplicate `--api` for `list`.", .{}),
                .skip_api => return common.usageErrorResult(allocator, .list, "`--api` cannot be combined with `--skip-api` for `list`.", .{}),
            }
            continue;
        }
        if (std.mem.eql(u8, arg, "--skip-api")) {
            switch (opts.api_mode) {
                .default => opts.api_mode = .skip_api,
                .skip_api => return common.usageErrorResult(allocator, .list, "duplicate `--skip-api` for `list`.", .{}),
                .force_api => return common.usageErrorResult(allocator, .list, "`--skip-api` cannot be combined with `--api` for `list`.", .{}),
            }
            continue;
        }
        if (common.isHelpFlag(arg)) return common.usageErrorResult(allocator, .list, "`--help` must be used by itself for `list`.", .{});
        if (std.mem.startsWith(u8, arg, "-")) return common.usageErrorResult(allocator, .list, "unknown flag `{s}` for `list`.", .{arg});
        return common.usageErrorResult(allocator, .list, "unexpected argument `{s}` for `list`.", .{arg});
    }
    return .{ .command = .{ .list = opts } };
}

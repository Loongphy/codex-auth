const std = @import("std");
const types = @import("../types.zig");
const common = @import("common.zig");

pub fn parse(allocator: std.mem.Allocator, args: []const [:0]const u8) !types.ParseResult {
    if (args.len == 1 and common.isHelpFlag(std.mem.sliceTo(args[0], 0))) {
        return .{ .command = .{ .help = .remove_account } };
    }

    var selectors = std.ArrayList([]const u8).empty;
    errdefer common.freeOwnedStringList(allocator, selectors.items);
    defer selectors.deinit(allocator);
    var opts: types.RemoveOptions = .{
        .selectors = &.{},
        .all = false,
    };
    for (args) |raw_arg| {
        const arg = std.mem.sliceTo(raw_arg, 0);
        if (std.mem.eql(u8, arg, "--live")) {
            if (opts.live) return common.usageErrorResult(allocator, .remove_account, "duplicate `--live` for `remove`.", .{});
            opts.live = true;
            continue;
        }
        if (std.mem.eql(u8, arg, "--api")) {
            switch (opts.api_mode) {
                .default => opts.api_mode = .force_api,
                .force_api => return common.usageErrorResult(allocator, .remove_account, "duplicate `--api` for `remove`.", .{}),
                .skip_api => return common.usageErrorResult(allocator, .remove_account, "`--api` cannot be combined with `--skip-api` for `remove`.", .{}),
            }
            continue;
        }
        if (std.mem.eql(u8, arg, "--skip-api")) {
            switch (opts.api_mode) {
                .default => opts.api_mode = .skip_api,
                .skip_api => return common.usageErrorResult(allocator, .remove_account, "duplicate `--skip-api` for `remove`.", .{}),
                .force_api => return common.usageErrorResult(allocator, .remove_account, "`--skip-api` cannot be combined with `--api` for `remove`.", .{}),
            }
            continue;
        }
        if (std.mem.eql(u8, arg, "--all")) {
            if (opts.all or selectors.items.len != 0) {
                return common.usageErrorResult(allocator, .remove_account, "`remove` cannot combine `--all` with another selector.", .{});
            }
            opts.all = true;
            continue;
        }
        if (std.mem.startsWith(u8, arg, "-")) return common.usageErrorResult(allocator, .remove_account, "unknown flag `{s}` for `remove`.", .{arg});
        if (opts.all) return common.usageErrorResult(allocator, .remove_account, "`remove` cannot combine `--all` with another selector.", .{});
        try selectors.append(allocator, try allocator.dupe(u8, arg));
    }
    if ((opts.live or opts.api_mode != .default) and (opts.all or selectors.items.len != 0)) {
        common.freeOwnedStringList(allocator, selectors.items);
        return common.usageErrorResult(
            allocator,
            .remove_account,
            "`remove <alias|email|display-number|query>...` and `remove --all` do not support `--live`, `--api`, or `--skip-api`.",
            .{},
        );
    }
    opts.selectors = try selectors.toOwnedSlice(allocator);
    return .{ .command = .{ .remove_account = opts } };
}

const std = @import("std");
const types = @import("../types.zig");
const common = @import("common.zig");

pub fn parse(allocator: std.mem.Allocator, args: []const [:0]const u8) !types.ParseResult {
    const json_requested = common.argsContainFlag(args, "--json");
    if (args.len == 1 and common.isHelpFlag(std.mem.sliceTo(args[0], 0))) {
        return .{ .command = .{ .help = .remove_account } };
    }

    var selectors = std.ArrayList([]const u8).empty;
    defer selectors.deinit(allocator);
    var selectors_transferred = false;
    defer if (!selectors_transferred) common.freeOwnedStringList(allocator, selectors.items);
    var opts: types.RemoveOptions = .{
        .selectors = &.{},
        .all = false,
    };
    for (args) |raw_arg| {
        const arg = std.mem.sliceTo(raw_arg, 0);
        if (std.mem.eql(u8, arg, "--live")) {
            if (opts.live) return common.usageErrorResultWithJson(allocator, .remove_account, json_requested, "duplicate `--live` for `remove`.", .{});
            opts.live = true;
            continue;
        }
        if (std.mem.eql(u8, arg, "--json")) {
            if (opts.json) return common.usageErrorResultWithJson(allocator, .remove_account, true, "duplicate `--json` for `remove`.", .{});
            opts.json = true;
            continue;
        }
        if (std.mem.eql(u8, arg, "--api")) {
            switch (opts.api_mode) {
                .default => opts.api_mode = .force_api,
                .force_api => return common.usageErrorResultWithJson(allocator, .remove_account, json_requested, "duplicate `--api` for `remove`.", .{}),
                .skip_api => return common.usageErrorResultWithJson(allocator, .remove_account, json_requested, "`--api` cannot be combined with `--skip-api` for `remove`.", .{}),
            }
            continue;
        }
        if (std.mem.eql(u8, arg, "--skip-api")) {
            switch (opts.api_mode) {
                .default => opts.api_mode = .skip_api,
                .skip_api => return common.usageErrorResultWithJson(allocator, .remove_account, json_requested, "duplicate `--skip-api` for `remove`.", .{}),
                .force_api => return common.usageErrorResultWithJson(allocator, .remove_account, json_requested, "`--skip-api` cannot be combined with `--api` for `remove`.", .{}),
            }
            continue;
        }
        if (std.mem.eql(u8, arg, "--all")) {
            if (opts.all or selectors.items.len != 0) {
                return common.usageErrorResultWithJson(allocator, .remove_account, json_requested, "`remove` cannot combine `--all` with another selector.", .{});
            }
            opts.all = true;
            continue;
        }
        if (std.mem.startsWith(u8, arg, "-")) return common.usageErrorResultWithJson(allocator, .remove_account, json_requested, "unknown flag `{s}` for `remove`.", .{arg});
        if (opts.all) return common.usageErrorResultWithJson(allocator, .remove_account, json_requested, "`remove` cannot combine `--all` with another selector.", .{});
        try selectors.append(allocator, try allocator.dupe(u8, arg));
    }
    if (opts.live and opts.json) {
        return common.usageErrorResultWithJson(allocator, .remove_account, true, "`--live` cannot be combined with `--json`.", .{});
    }
    if (opts.json and !opts.all and selectors.items.len == 0) {
        return common.usageErrorResultWithJson(allocator, .remove_account, true, "`remove --json` requires selectors or `--all`.", .{});
    }
    if ((opts.live or opts.api_mode != .default) and (opts.all or selectors.items.len != 0)) {
        return common.usageErrorResultWithJson(
            allocator,
            .remove_account,
            json_requested,
            "`remove <alias|email|display-number|query>...` and `remove --all` do not support `--live`, `--api`, or `--skip-api`.",
            .{},
        );
    }
    opts.selectors = try selectors.toOwnedSlice(allocator);
    selectors_transferred = true;
    return .{ .command = .{ .remove_account = opts } };
}

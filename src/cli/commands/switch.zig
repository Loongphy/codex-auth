const std = @import("std");
const types = @import("../types.zig");
const common = @import("common.zig");

pub fn parse(allocator: std.mem.Allocator, args: []const [:0]const u8) !types.ParseResult {
    const json_requested = common.argsContainFlag(args, "--json");
    if (args.len == 1 and common.isHelpFlag(std.mem.sliceTo(args[0], 0))) {
        return .{ .command = .{ .help = .switch_account } };
    }

    var opts: types.SwitchOptions = .{};
    for (args) |raw_arg| {
        const arg = std.mem.sliceTo(raw_arg, 0);
        if (std.mem.eql(u8, arg, "--live")) {
            if (opts.live) {
                freeTarget(allocator, opts.target);
                return common.usageErrorResultWithJson(allocator, .switch_account, json_requested, "duplicate `--live` for `switch`.", .{});
            }
            opts.live = true;
            continue;
        }
        if (std.mem.eql(u8, arg, "--json")) {
            if (opts.json) {
                freeTarget(allocator, opts.target);
                return common.usageErrorResultWithJson(allocator, .switch_account, true, "duplicate `--json` for `switch`.", .{});
            }
            opts.json = true;
            continue;
        }
        if (std.mem.eql(u8, arg, "--api")) {
            switch (opts.api_mode) {
                .default => opts.api_mode = .force_api,
                .force_api => {
                    freeTarget(allocator, opts.target);
                    return common.usageErrorResultWithJson(allocator, .switch_account, json_requested, "duplicate `--api` for `switch`.", .{});
                },
                .skip_api => {
                    freeTarget(allocator, opts.target);
                    return common.usageErrorResultWithJson(allocator, .switch_account, json_requested, "`--api` cannot be combined with `--skip-api` for `switch`.", .{});
                },
            }
            continue;
        }
        if (std.mem.eql(u8, arg, "--skip-api")) {
            switch (opts.api_mode) {
                .default => opts.api_mode = .skip_api,
                .skip_api => {
                    freeTarget(allocator, opts.target);
                    return common.usageErrorResultWithJson(allocator, .switch_account, json_requested, "duplicate `--skip-api` for `switch`.", .{});
                },
                .force_api => {
                    freeTarget(allocator, opts.target);
                    return common.usageErrorResultWithJson(allocator, .switch_account, json_requested, "`--skip-api` cannot be combined with `--api` for `switch`.", .{});
                },
            }
            continue;
        }
        if (std.mem.startsWith(u8, arg, "-") and !std.mem.eql(u8, arg, "-")) {
            freeTarget(allocator, opts.target);
            return common.usageErrorResultWithJson(allocator, .switch_account, json_requested, "unknown flag `{s}` for `switch`.", .{arg});
        }
        if (opts.target != .picker) {
            freeTarget(allocator, opts.target);
            return common.usageErrorResultWithJson(allocator, .switch_account, json_requested, "unexpected extra query `{s}` for `switch`.", .{arg});
        }
        opts.target = if (std.mem.eql(u8, arg, "-"))
            .previous
        else
            .{ .query = try allocator.dupe(u8, arg) };
    }
    if (opts.live and opts.json) {
        freeTarget(allocator, opts.target);
        return common.usageErrorResultWithJson(allocator, .switch_account, true, "`--live` cannot be combined with `--json`.", .{});
    }
    if (opts.json and opts.target == .picker) {
        return common.usageErrorResultWithJson(allocator, .switch_account, true, "`switch --json` requires an explicit account query.", .{});
    }
    if (opts.json and opts.target == .previous) {
        return common.usageErrorResultWithJson(allocator, .switch_account, true, "previous-account switching is CLI-only and cannot be combined with `--json`.", .{});
    }
    if (opts.target != .picker and (opts.api_mode != .default or opts.live)) {
        freeTarget(allocator, opts.target);
        return common.usageErrorResultWithJson(
            allocator,
            .switch_account,
            json_requested,
            "`switch -|<alias|email|display-number|query>` does not support `--live`, `--api`, or `--skip-api`.",
            .{},
        );
    }
    return .{ .command = .{ .switch_account = opts } };
}

fn freeTarget(allocator: std.mem.Allocator, target: types.SwitchTarget) void {
    switch (target) {
        .query => |query| allocator.free(query),
        else => {},
    }
}

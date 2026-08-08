const std = @import("std");
const types = @import("../types.zig");
const common = @import("common.zig");

pub fn parse(allocator: std.mem.Allocator, args: []const [:0]const u8) !types.ParseResult {
    const json_requested = common.argsContainFlag(args, "--json");
    if (args.len == 1 and common.isHelpFlag(std.mem.sliceTo(args[0], 0))) {
        return .{ .command = .{ .help = .list } };
    }

    var opts: types.ListOptions = .{};
    for (args) |raw_arg| {
        const arg = std.mem.sliceTo(raw_arg, 0);
        if (std.mem.eql(u8, arg, "--live")) {
            if (opts.live) return common.usageErrorResultWithJson(allocator, .list, json_requested, "duplicate `--live` for `list`.", .{});
            opts.live = true;
            continue;
        }
        if (std.mem.eql(u8, arg, "--json")) {
            if (opts.json) return common.usageErrorResultWithJson(allocator, .list, true, "duplicate `--json` for `list`.", .{});
            opts.json = true;
            continue;
        }
        if (std.mem.eql(u8, arg, "--active")) {
            if (opts.active_only) return common.usageErrorResultWithJson(allocator, .list, json_requested, "duplicate `--active` for `list`.", .{});
            opts.active_only = true;
            continue;
        }
        if (std.mem.eql(u8, arg, "--api")) {
            switch (opts.api_mode) {
                .default => opts.api_mode = .force_api,
                .force_api => return common.usageErrorResultWithJson(allocator, .list, json_requested, "duplicate `--api` for `list`.", .{}),
                .skip_api => return common.usageErrorResultWithJson(allocator, .list, json_requested, "`--api` cannot be combined with `--skip-api` for `list`.", .{}),
            }
            continue;
        }
        if (std.mem.eql(u8, arg, "--skip-api")) {
            switch (opts.api_mode) {
                .default => opts.api_mode = .skip_api,
                .skip_api => return common.usageErrorResultWithJson(allocator, .list, json_requested, "duplicate `--skip-api` for `list`.", .{}),
                .force_api => return common.usageErrorResultWithJson(allocator, .list, json_requested, "`--skip-api` cannot be combined with `--api` for `list`.", .{}),
            }
            continue;
        }
        if (common.isHelpFlag(arg)) return common.usageErrorResultWithJson(allocator, .list, json_requested, "`--help` must be used by itself for `list`.", .{});
        if (std.mem.startsWith(u8, arg, "-")) return common.usageErrorResultWithJson(allocator, .list, json_requested, "unknown flag `{s}` for `list`.", .{arg});
        return common.usageErrorResultWithJson(allocator, .list, json_requested, "unexpected argument `{s}` for `list`.", .{arg});
    }
    if (opts.live and opts.json) {
        return common.usageErrorResultWithJson(allocator, .list, true, "`--live` cannot be combined with `--json`.", .{});
    }
    return .{ .command = .{ .list = opts } };
}

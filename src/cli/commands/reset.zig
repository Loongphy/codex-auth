const std = @import("std");
const types = @import("../types.zig");
const common = @import("common.zig");

pub fn parse(allocator: std.mem.Allocator, args: []const [:0]const u8) !types.ParseResult {
    const json_requested = common.argsContainFlag(args, "--json");
    if (args.len == 1 and common.isHelpFlag(std.mem.sliceTo(args[0], 0))) {
        return .{ .command = .{ .help = .reset_credits } };
    }

    var selector: ?[]u8 = null;
    defer if (selector) |value| allocator.free(value);
    var credit: ?[]u8 = null;
    defer if (credit) |value| allocator.free(value);
    var json = false;
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = std.mem.sliceTo(args[i], 0);
        if (std.mem.eql(u8, arg, "--json")) {
            if (json) {
                return common.usageErrorResultWithJson(allocator, .reset_credits, true, "duplicate `--json` for `reset`.", .{});
            }
            json = true;
            continue;
        }
        if (std.mem.eql(u8, arg, "--credit") or common.inlineFlagValue(arg, "--credit") != null) {
            const inline_value = common.inlineFlagValue(arg, "--credit");
            if (inline_value == null and i + 1 >= args.len) {
                return common.usageErrorResultWithJson(allocator, .reset_credits, json_requested, "missing value for `--credit`.", .{});
            }
            if (credit != null) {
                return common.usageErrorResultWithJson(allocator, .reset_credits, json_requested, "duplicate `--credit` for `reset`.", .{});
            }
            const value = inline_value orelse blk: {
                // A flag-like next word is not a card id: it is the value the
                // user forgot, e.g. `--credit --json`.
                const next = std.mem.sliceTo(args[i + 1], 0);
                if (next.len > 1 and next[0] == '-') {
                    return common.usageErrorResultWithJson(allocator, .reset_credits, json_requested, "missing value for `--credit`.", .{});
                }
                i += 1;
                break :blk std.mem.sliceTo(args[i], 0);
            };
            credit = try allocator.dupe(u8, value);
            continue;
        }
        if (arg.len > 1 and std.mem.startsWith(u8, arg, "-")) {
            return common.usageErrorResultWithJson(allocator, .reset_credits, json_requested, "unknown flag `{s}` for `reset`.", .{arg});
        }
        if (selector != null) {
            return common.usageErrorResultWithJson(allocator, .reset_credits, json_requested, "unexpected extra argument `{s}` for `reset`.", .{arg});
        }
        selector = try allocator.dupe(u8, arg);
    }
    if (selector == null) {
        return common.usageErrorResultWithJson(allocator, .reset_credits, json_requested, "`reset` requires an account selector (alias, email, display number, or partial query).", .{});
    }
    const opts: types.ResetOptions = .{
        .selector = selector.?,
        .credit = credit,
        .json = json,
    };
    // Ownership moved into `opts`; the defers above must not release it.
    selector = null;
    credit = null;
    return .{ .command = .{ .reset_credits = opts } };
}

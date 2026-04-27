const std = @import("std");
const types = @import("../types.zig");
const common = @import("common.zig");

pub fn parse(allocator: std.mem.Allocator, args: []const [:0]const u8) !types.ParseResult {
    if (args.len == 1 and common.isHelpFlag(std.mem.sliceTo(args[0], 0))) {
        return .{ .command = .{ .help = .config } };
    }
    if (args.len < 1) return common.usageErrorResult(allocator, .config, "`config` requires a section.", .{});
    const scope = std.mem.sliceTo(args[0], 0);

    if (std.mem.eql(u8, scope, "auto")) {
        return parseAuto(allocator, args[1..]);
    }
    if (std.mem.eql(u8, scope, "api")) {
        return parseApi(allocator, args[1..]);
    }
    if (std.mem.eql(u8, scope, "live")) {
        return parseLive(allocator, args[1..]);
    }
    return common.usageErrorResult(allocator, .config, "unknown config section `{s}`.", .{scope});
}

fn parseAuto(allocator: std.mem.Allocator, args: []const [:0]const u8) !types.ParseResult {
    if (args.len == 1 and common.isHelpFlag(std.mem.sliceTo(args[0], 0))) {
        return .{ .command = .{ .help = .config } };
    }
    if (args.len == 1) {
        const action = std.mem.sliceTo(args[0], 0);
        if (std.mem.eql(u8, action, "enable")) return .{ .command = .{ .config = .{ .auto_switch = .{ .action = .enable } } } };
        if (std.mem.eql(u8, action, "disable")) return .{ .command = .{ .config = .{ .auto_switch = .{ .action = .disable } } } };
    }

    var threshold_5h_percent: ?u8 = null;
    var threshold_weekly_percent: ?u8 = null;
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = std.mem.sliceTo(args[i], 0);
        if (std.mem.eql(u8, arg, "--5h")) {
            if (i + 1 >= args.len) return common.usageErrorResult(allocator, .config, "missing value for `--5h`.", .{});
            if (threshold_5h_percent != null) return common.usageErrorResult(allocator, .config, "duplicate `--5h` for `config auto`.", .{});
            threshold_5h_percent = common.parsePercentArg(std.mem.sliceTo(args[i + 1], 0)) orelse
                return common.usageErrorResult(allocator, .config, "`--5h` must be an integer from 1 to 100.", .{});
            i += 1;
            continue;
        }
        if (std.mem.eql(u8, arg, "--weekly")) {
            if (i + 1 >= args.len) return common.usageErrorResult(allocator, .config, "missing value for `--weekly`.", .{});
            if (threshold_weekly_percent != null) return common.usageErrorResult(allocator, .config, "duplicate `--weekly` for `config auto`.", .{});
            threshold_weekly_percent = common.parsePercentArg(std.mem.sliceTo(args[i + 1], 0)) orelse
                return common.usageErrorResult(allocator, .config, "`--weekly` must be an integer from 1 to 100.", .{});
            i += 1;
            continue;
        }
        if (std.mem.eql(u8, arg, "enable") or std.mem.eql(u8, arg, "disable")) {
            return common.usageErrorResult(allocator, .config, "`config auto` cannot mix actions with threshold flags.", .{});
        }
        return common.usageErrorResult(allocator, .config, "unknown argument `{s}` for `config auto`.", .{arg});
    }
    if (threshold_5h_percent == null and threshold_weekly_percent == null) {
        return common.usageErrorResult(allocator, .config, "`config auto` requires an action or threshold flags.", .{});
    }
    return .{ .command = .{ .config = .{ .auto_switch = .{ .configure = .{
        .threshold_5h_percent = threshold_5h_percent,
        .threshold_weekly_percent = threshold_weekly_percent,
    } } } } };
}

fn parseApi(allocator: std.mem.Allocator, args: []const [:0]const u8) !types.ParseResult {
    if (args.len == 1 and common.isHelpFlag(std.mem.sliceTo(args[0], 0))) {
        return .{ .command = .{ .help = .config } };
    }
    if (args.len != 1) return common.usageErrorResult(allocator, .config, "`config api` requires `enable` or `disable`.", .{});
    const action = std.mem.sliceTo(args[0], 0);
    if (std.mem.eql(u8, action, "enable")) return .{ .command = .{ .config = .{ .api = .enable } } };
    if (std.mem.eql(u8, action, "disable")) return .{ .command = .{ .config = .{ .api = .disable } } };
    return common.usageErrorResult(allocator, .config, "unknown action `{s}` for `config api`.", .{action});
}

fn parseLive(allocator: std.mem.Allocator, args: []const [:0]const u8) !types.ParseResult {
    if (args.len == 1 and common.isHelpFlag(std.mem.sliceTo(args[0], 0))) {
        return .{ .command = .{ .help = .config } };
    }
    if (args.len != 2) return common.usageErrorResult(allocator, .config, "`config live` requires `--interval <seconds>`.", .{});
    const flag = std.mem.sliceTo(args[0], 0);
    if (!std.mem.eql(u8, flag, "--interval")) {
        if (std.mem.startsWith(u8, flag, "-")) {
            return common.usageErrorResult(allocator, .config, "unknown flag `{s}` for `config live`.", .{flag});
        }
        return common.usageErrorResult(allocator, .config, "unknown argument `{s}` for `config live`.", .{flag});
    }
    const raw = std.mem.sliceTo(args[1], 0);
    const interval = std.fmt.parseInt(u16, raw, 10) catch
        return common.usageErrorResult(allocator, .config, "`--interval` must be an integer from 5 to 3600 seconds.", .{});
    if (interval < 5 or interval > 3600) {
        return common.usageErrorResult(allocator, .config, "`--interval` must be an integer from 5 to 3600 seconds.", .{});
    }
    return .{ .command = .{ .config = .{ .live = .{ .interval_seconds = interval } } } };
}

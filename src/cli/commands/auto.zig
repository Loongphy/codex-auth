const std = @import("std");
const types = @import("../types.zig");
const common = @import("common.zig");

pub fn parse(allocator: std.mem.Allocator, args: []const [:0]const u8) !types.ParseResult {
    const json = common.argsContainFlag(args, "--json");
    if (args.len == 1 and common.isHelpFlag(args[0])) return .{ .command = .{ .help = .auto } };
    var opts: types.AutoOptions = .{};
    const Flag = enum { once, dry_run, json, threshold, interval, cooldown };
    var seen: std.EnumSet(Flag) = .initEmpty();
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = std.mem.sliceTo(args[i], 0);
        const flag: Flag = if (std.mem.eql(u8, arg, "--once")) .once else if (std.mem.eql(u8, arg, "--dry-run")) .dry_run else if (std.mem.eql(u8, arg, "--json")) .json else if (std.mem.eql(u8, arg, "--threshold")) .threshold else if (std.mem.eql(u8, arg, "--interval")) .interval else if (std.mem.eql(u8, arg, "--cooldown")) .cooldown else return common.usageErrorResultWithJson(allocator, .auto, json, "unknown argument `{s}` for `auto`.", .{arg});
        if (seen.contains(flag)) return common.usageErrorResultWithJson(allocator, .auto, json, "duplicate `{s}` for `auto`.", .{arg});
        seen.insert(flag);
        switch (flag) {
            .once => opts.once = true,
            .dry_run => opts.dry_run = true,
            .json => opts.json = true,
            else => {
                i += 1;
                if (i >= args.len) return common.usageErrorResultWithJson(allocator, .auto, json, "missing value for `{s}`.", .{arg});
                const value = std.mem.sliceTo(args[i], 0);
                if (flag == .threshold) {
                    const n = std.fmt.parseFloat(f64, value) catch 0;
                    if (!std.math.isFinite(n) or n < 50 or n > 99.9) return common.usageErrorResultWithJson(allocator, .auto, json, "`--threshold` must be between 50 and 99.9.", .{});
                    opts.threshold = n;
                } else {
                    const n = std.fmt.parseInt(u32, value, 10) catch std.math.maxInt(u32);
                    if (flag == .interval) {
                        if (n < 15 or n > 3600) return common.usageErrorResultWithJson(allocator, .auto, json, "`--interval` must be between 15 and 3600 seconds.", .{});
                        opts.interval_seconds = @intCast(n);
                    } else {
                        if (n > 86400) return common.usageErrorResultWithJson(allocator, .auto, json, "`--cooldown` must be between 0 and 86400 seconds.", .{});
                        opts.cooldown_seconds = n;
                    }
                }
            },
        }
    }
    return .{ .command = .{ .auto = opts } };
}

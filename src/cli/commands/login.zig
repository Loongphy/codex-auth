const std = @import("std");
const types = @import("../types.zig");
const common = @import("common.zig");

pub fn parse(allocator: std.mem.Allocator, args: []const [:0]const u8) !types.ParseResult {
    if (args.len == 1 and common.isHelpFlag(std.mem.sliceTo(args[0], 0))) {
        return .{ .command = .{ .help = .login } };
    }

    var opts: types.LoginOptions = .{};
    for (args) |raw_arg| {
        const arg = std.mem.sliceTo(raw_arg, 0);
        if (std.mem.eql(u8, arg, "--device-auth")) {
            if (opts.device_auth) return common.usageErrorResult(allocator, .login, "duplicate `--device-auth` for `login`.", .{});
            opts.device_auth = true;
            continue;
        }
        if (common.isHelpFlag(arg)) return common.usageErrorResult(allocator, .login, "`--help` must be used by itself for `login`.", .{});
        if (std.mem.startsWith(u8, arg, "-")) return common.usageErrorResult(allocator, .login, "unknown flag `{s}` for `login`.", .{arg});
        return common.usageErrorResult(allocator, .login, "unexpected argument `{s}` for `login`.", .{arg});
    }
    return .{ .command = .{ .login = opts } };
}

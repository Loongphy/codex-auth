const std = @import("std");
const types = @import("../types.zig");
const common = @import("common.zig");

pub fn parse(allocator: std.mem.Allocator, args: []const [:0]const u8) !types.ParseResult {
    if (args.len == 0) return parseOptions(allocator, .launch, args);
    const first = std.mem.sliceTo(args[0], 0);
    if (common.isHelpFlag(first)) return .{ .command = .{ .help = .app } };

    if (std.mem.eql(u8, first, "status")) return parseOptions(allocator, .status, args[1..]);
    return parseOptions(allocator, .launch, args);
}

fn parseOptions(
    allocator: std.mem.Allocator,
    action: types.AppAction,
    args: []const [:0]const u8,
) !types.ParseResult {
    var opts = types.AppOptions{ .action = action };
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = std.mem.sliceTo(args[i], 0);
        if (std.mem.eql(u8, arg, "--")) {
            opts.extra_args = @ptrCast(args[i + 1 ..]);
            break;
        }
        if (common.isHelpFlag(arg)) return .{ .command = .{ .help = .app } };
        if (std.mem.eql(u8, arg, "--app-path")) {
            if (i + 1 >= args.len) return common.usageErrorResult(allocator, .app, "missing value for `--app-path`.", .{});
            if (opts.app_path != null) return common.usageErrorResult(allocator, .app, "duplicate `--app-path` for `app`.", .{});
            i += 1;
            opts.app_path = std.mem.sliceTo(args[i], 0);
            continue;
        }
        if (std.mem.eql(u8, arg, "--cli-path")) {
            if (i + 1 >= args.len) return common.usageErrorResult(allocator, .app, "missing value for `--cli-path`.", .{});
            if (opts.cli_path != null) return common.usageErrorResult(allocator, .app, "duplicate `--cli-path` for `app`.", .{});
            i += 1;
            opts.cli_path = std.mem.sliceTo(args[i], 0);
            continue;
        }
        if (std.mem.eql(u8, arg, "--home")) {
            if (i + 1 >= args.len) return common.usageErrorResult(allocator, .app, "missing value for `--home`.", .{});
            if (opts.home != null) return common.usageErrorResult(allocator, .app, "duplicate `--home` for `app`.", .{});
            i += 1;
            opts.home = std.mem.sliceTo(args[i], 0);
            continue;
        }
        if (std.mem.eql(u8, arg, "--platform")) {
            if (i + 1 >= args.len) return common.usageErrorResult(allocator, .app, "missing value for `--platform`.", .{});
            if (opts.platform != null) return common.usageErrorResult(allocator, .app, "duplicate `--platform` for `app`.", .{});
            i += 1;
            const value = std.mem.sliceTo(args[i], 0);
            if (std.mem.eql(u8, value, "win")) {
                opts.platform = .win;
            } else if (std.mem.eql(u8, value, "wsl")) {
                opts.platform = .wsl;
            } else if (std.mem.eql(u8, value, "mac")) {
                opts.platform = .mac;
            } else {
                return common.usageErrorResult(allocator, .app, "`--platform` must be `win`, `wsl`, or `mac`.", .{});
            }
            continue;
        }
        if (std.mem.eql(u8, arg, "--dry-run")) {
            if (opts.dry_run) return common.usageErrorResult(allocator, .app, "duplicate `--dry-run` for `app`.", .{});
            opts.dry_run = true;
            continue;
        }
        if (std.mem.eql(u8, arg, "--wait")) {
            if (opts.wait) return common.usageErrorResult(allocator, .app, "duplicate `--wait` for `app`.", .{});
            opts.wait = true;
            continue;
        }
        if (std.mem.startsWith(u8, arg, "-")) {
            return common.usageErrorResult(allocator, .app, "unknown flag `{s}` for `app`.", .{arg});
        }
        return common.usageErrorResult(allocator, .app, "unexpected argument `{s}` for `app`.", .{arg});
    }

    if (opts.extra_args.len != 0 and action != .launch) {
        return common.usageErrorResult(allocator, .app, "`app status` does not accept passthrough arguments.", .{});
    }
    return .{ .command = .{ .app = opts } };
}

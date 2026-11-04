const std = @import("std");
const types = @import("../types.zig");
const common = @import("common.zig");

pub fn parse(allocator: std.mem.Allocator, args: []const [:0]const u8) !types.ParseResult {
    if (args.len == 0) return parseOptions(allocator, .launch, args);
    const first = std.mem.sliceTo(args[0], 0);
    if (common.isHelpFlag(first)) return .{ .command = .{ .help = .app } };

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
        if (std.mem.eql(u8, arg, "--")) return common.usageErrorResult(allocator, .app, "`app` does not accept passthrough arguments.", .{});
        if (common.isHelpFlag(arg)) return .{ .command = .{ .help = .app } };
        if (std.mem.eql(u8, arg, "--id") or common.inlineFlagValue(arg, "--id") != null) {
            const inline_value = common.inlineFlagValue(arg, "--id");
            if (inline_value == null and i + 1 >= args.len) return common.usageErrorResult(allocator, .app, "missing value for `--id`.", .{});
            if (opts.app_id != null) return common.usageErrorResult(allocator, .app, "duplicate `--id` for `app`.", .{});
            if (inline_value == null) i += 1;
            opts.app_id = inline_value orelse std.mem.sliceTo(args[i], 0);
            continue;
        }
        if (std.mem.eql(u8, arg, "--codex-cli-path") or common.inlineFlagValue(arg, "--codex-cli-path") != null) {
            const inline_value = common.inlineFlagValue(arg, "--codex-cli-path");
            if (inline_value == null and i + 1 >= args.len) return common.usageErrorResult(allocator, .app, "missing value for `--codex-cli-path`.", .{});
            if (opts.codex_cli_path != null) return common.usageErrorResult(allocator, .app, "duplicate `--codex-cli-path` for `app`.", .{});
            if (inline_value == null) i += 1;
            opts.codex_cli_path = inline_value orelse std.mem.sliceTo(args[i], 0);
            continue;
        }
        if (std.mem.eql(u8, arg, "--codex-home") or common.inlineFlagValue(arg, "--codex-home") != null) {
            const inline_value = common.inlineFlagValue(arg, "--codex-home");
            if (inline_value == null and i + 1 >= args.len) return common.usageErrorResult(allocator, .app, "missing value for `--codex-home`.", .{});
            if (opts.codex_home != null) return common.usageErrorResult(allocator, .app, "duplicate `--codex-home` for `app`.", .{});
            if (inline_value == null) i += 1;
            opts.codex_home = inline_value orelse std.mem.sliceTo(args[i], 0);
            continue;
        }
        if (std.mem.eql(u8, arg, "--platform") or common.inlineFlagValue(arg, "--platform") != null) {
            const inline_value = common.inlineFlagValue(arg, "--platform");
            if (inline_value == null and i + 1 >= args.len) return common.usageErrorResult(allocator, .app, "missing value for `--platform`.", .{});
            if (opts.platform != null) return common.usageErrorResult(allocator, .app, "duplicate `--platform` for `app`.", .{});
            if (inline_value == null) i += 1;
            const value = inline_value orelse std.mem.sliceTo(args[i], 0);
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
        if (std.mem.eql(u8, arg, "--std")) {
            if (opts.inherit_stdio) return common.usageErrorResult(allocator, .app, "duplicate `--std` for `app`.", .{});
            opts.inherit_stdio = true;
            continue;
        }
        if (arg.len > 1 and std.mem.startsWith(u8, arg, "-")) {
            return common.usageErrorResult(allocator, .app, "unknown flag `{s}` for `app`.", .{arg});
        }
        return common.usageErrorResult(allocator, .app, "unexpected argument `{s}` for `app`.", .{arg});
    }

    return .{ .command = .{ .app = opts } };
}

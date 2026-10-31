const std = @import("std");
const types = @import("../types.zig");
const common = @import("common.zig");

pub fn parse(allocator: std.mem.Allocator, args: []const [:0]const u8) !types.ParseResult {
    if (args.len == 1 and common.isHelpFlag(std.mem.sliceTo(args[0], 0))) {
        return .{ .command = .{ .help = .completion } };
    }
    if (args.len == 0) {
        return common.usageErrorResult(allocator, .completion, "`completion` requires a shell name.", .{});
    }

    const shell_name = std.mem.sliceTo(args[0], 0);
    if (args.len == 1) {
        if (std.mem.eql(u8, shell_name, "bash")) {
            return .{ .command = .{ .completion = .bash } };
        }
        if (std.mem.eql(u8, shell_name, "zsh")) {
            return .{ .command = .{ .completion = .zsh } };
        }
        if (std.mem.eql(u8, shell_name, "fish")) {
            return .{ .command = .{ .completion = .fish } };
        }
        if (std.mem.eql(u8, shell_name, "pwsh") or std.mem.eql(u8, shell_name, "powershell")) {
            return .{ .command = .{ .completion = .pwsh } };
        }
    }
    if (args.len > 1) {
        return common.usageErrorResult(allocator, .completion, "unexpected argument after `completion`: `{s}`.", .{
            std.mem.sliceTo(args[1], 0),
        });
    }
    return common.usageErrorResult(allocator, .completion, "unknown completion shell `{s}`.", .{shell_name});
}

const std = @import("std");
const types = @import("../types.zig");

pub fn isHelpFlag(arg: []const u8) bool {
    return std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h");
}

pub fn usageErrorResult(
    allocator: std.mem.Allocator,
    topic: types.HelpTopic,
    comptime fmt: []const u8,
    args: anytype,
) !types.ParseResult {
    return .{ .usage_error = .{
        .topic = topic,
        .message = try std.fmt.allocPrint(allocator, fmt, args),
    } };
}

pub fn parseSimpleCommandArgs(
    allocator: std.mem.Allocator,
    command_name: []const u8,
    topic: types.HelpTopic,
    command: types.Command,
    rest: []const [:0]const u8,
) !types.ParseResult {
    if (rest.len == 0) return .{ .command = command };
    if (rest.len == 1 and isHelpFlag(std.mem.sliceTo(rest[0], 0))) {
        return .{ .command = .{ .help = topic } };
    }
    const arg = std.mem.sliceTo(rest[0], 0);
    if (std.mem.startsWith(u8, arg, "-")) {
        return usageErrorResult(allocator, topic, "unknown flag `{s}` for `{s}`.", .{ arg, command_name });
    }
    return usageErrorResult(allocator, topic, "unexpected argument `{s}` for `{s}`.", .{ arg, command_name });
}

pub fn parsePercentArg(raw: []const u8) ?u8 {
    const value = std.fmt.parseInt(u8, raw, 10) catch return null;
    if (value == 0 or value > 100) return null;
    return value;
}

pub fn freeImportOptions(allocator: std.mem.Allocator, auth_path: ?[]u8, alias: ?[]u8) void {
    if (auth_path) |value| allocator.free(value);
    if (alias) |value| allocator.free(value);
}

pub fn freeOwnedStringList(allocator: std.mem.Allocator, items: []const []const u8) void {
    for (items) |item| allocator.free(@constCast(item));
}

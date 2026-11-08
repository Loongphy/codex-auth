const std = @import("std");
const types = @import("../types.zig");

pub fn isHelpFlag(arg: []const u8) bool {
    return std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h");
}

/// Returns the inline value of a `--name=value` argument, or null when `arg`
/// is not the joined form of `name` (bare flag names need a following arg).
pub fn inlineFlagValue(arg: []const u8, name: []const u8) ?[]const u8 {
    if (!std.mem.startsWith(u8, arg, name)) return null;
    const rest = arg[name.len..];
    if (rest.len == 0 or rest[0] != '=') return null;
    return rest[1..];
}

pub fn usageErrorResult(
    allocator: std.mem.Allocator,
    topic: types.HelpTopic,
    comptime fmt: []const u8,
    args: anytype,
) !types.ParseResult {
    return usageErrorResultWithJson(allocator, topic, false, fmt, args);
}

pub fn usageErrorResultWithJson(
    allocator: std.mem.Allocator,
    topic: types.HelpTopic,
    json: bool,
    comptime fmt: []const u8,
    args: anytype,
) !types.ParseResult {
    return .{ .usage_error = .{
        .topic = topic,
        .message = try allocator.print(fmt, args),
        .json = json,
    } };
}

pub fn argsContainFlag(args: []const [:0]const u8, flag: []const u8) bool {
    for (args) |raw_arg| {
        if (std.mem.eql(u8, std.mem.sliceTo(raw_arg, 0), flag)) return true;
    }
    return false;
}

pub fn freeImportOptions(allocator: std.mem.Allocator, auth_path: ?[]u8, alias: ?[]u8) void {
    if (auth_path) |value| allocator.free(value);
    if (alias) |value| allocator.free(value);
}

pub fn freeOwnedStringList(allocator: std.mem.Allocator, items: []const []const u8) void {
    for (items) |item| allocator.free(@constCast(item));
}

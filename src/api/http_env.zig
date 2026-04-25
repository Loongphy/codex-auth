const std = @import("std");
const app_runtime = @import("../core/runtime.zig");

pub fn getEnvMap(allocator: std.mem.Allocator) !std.process.Environ.Map {
    return try app_runtime.currentEnviron().createMap(allocator);
}

pub fn getEnvVarOwned(allocator: std.mem.Allocator, name: []const u8) ![]u8 {
    var env_map = try getEnvMap(allocator);
    defer env_map.deinit();

    const value = env_map.get(name) orelse return error.EnvironmentVariableNotFound;
    return try allocator.dupe(u8, value);
}

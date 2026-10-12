const std = @import("std");
const app_runtime = @import("../core/runtime.zig");

pub fn getEnvMap(allocator: std.mem.Allocator) !std.process.Environ.Map {
    return app_runtime.getEnvMap(allocator);
}

pub fn getEnvVarOwned(allocator: std.mem.Allocator, name: []const u8) ![]u8 {
    return app_runtime.getEnvVarOwned(allocator, name);
}

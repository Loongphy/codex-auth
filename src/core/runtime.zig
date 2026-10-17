const builtin = @import("builtin");
const std = @import("std");

var runtime_init: ?std.process.Init = null;

pub fn initRuntime(init: std.process.Init) void {
    std.debug.assert(runtime_init == null);
    runtime_init = init;
}

pub fn deinitRuntime() void {
    runtime_init = null;
}

pub fn currentEnviron() std.process.Environ {
    if (runtime_init) |init| return init.minimal.environ;
    if (builtin.is_test) return std.testing.environ;
    @panic("app_runtime.initRuntime must be called during startup");
}

pub fn getEnvMap(allocator: std.mem.Allocator) !std.process.Environ.Map {
    if (runtime_init) |init| return init.environ_map.clone(allocator);
    return currentEnviron().createMap(allocator);
}

pub fn getEnvVarOwned(allocator: std.mem.Allocator, name: []const u8) ![]u8 {
    if (runtime_init) |init| {
        const value = init.environ_map.get(name) orelse return error.EnvironmentVariableNotFound;
        return allocator.dupe(u8, value);
    }
    return currentEnviron().getAlloc(allocator, name) catch |err| switch (err) {
        error.EnvironmentVariableMissing => error.EnvironmentVariableNotFound,
        else => err,
    };
}

pub fn envHasValue(comptime name: []const u8) bool {
    if (runtime_init) |init| {
        const value = init.environ_map.get(name) orelse return false;
        return value.len != 0;
    }
    return currentEnviron().containsUnemptyConstant(name);
}

pub fn io() std.Io {
    if (runtime_init) |init| return init.io;
    if (builtin.is_test) return std.testing.io;
    @panic("app_runtime.initRuntime must be called during startup");
}

pub fn dupeOwnedNoSentinel(allocator: std.mem.Allocator, z_bytes: [:0]u8) ![]u8 {
    defer allocator.free(z_bytes);
    return try allocator.dupe(u8, z_bytes);
}

pub fn realPathFileAlloc(allocator: std.mem.Allocator, dir: std.Io.Dir, sub_path: []const u8) ![]u8 {
    return try dupeOwnedNoSentinel(allocator, try dir.realPathFileAlloc(io(), sub_path, allocator));
}

pub fn realPathFileAbsoluteAlloc(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    return try dupeOwnedNoSentinel(allocator, try std.Io.Dir.realPathFileAbsoluteAlloc(io(), path, allocator));
}

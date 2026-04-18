const builtin = @import("builtin");
const std = @import("std");

fn currentEnviron() std.process.Environ {
    const env_block: std.process.Environ.Block = switch (builtin.os.tag) {
        .windows => .global,
        else => blk: {
            const c_environ = std.c.environ;
            var env_count: usize = 0;
            while (c_environ[env_count] != null) : (env_count += 1) {}
            break :blk .{ .slice = c_environ[0..env_count :null] };
        },
    };
    return .{ .block = env_block };
}

pub fn getEnvMap(allocator: std.mem.Allocator) !std.process.Environ.Map {
    return try currentEnviron().createMap(allocator);
}

pub fn getEnvVarOwned(allocator: std.mem.Allocator, name: []const u8) ![]u8 {
    var env_map = try getEnvMap(allocator);
    defer env_map.deinit();

    const value = env_map.get(name) orelse return error.EnvironmentVariableNotFound;
    return try allocator.dupe(u8, value);
}

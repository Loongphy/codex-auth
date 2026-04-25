const builtin = @import("builtin");
const std = @import("std");
const app_runtime = @import("../core/runtime.zig");
const types = @import("http_types.zig");
const env = @import("http_env.zig");

const node_executable_env = types.node_executable_env;
const node_requirement_hint = types.node_requirement_hint;
const getEnvVarOwned = env.getEnvVarOwned;

pub fn resolveNodeExecutable(allocator: std.mem.Allocator) ![]u8 {
    return getEnvVarOwned(allocator, node_executable_env) catch |err| switch (err) {
        error.EnvironmentVariableNotFound => try allocator.dupe(u8, "node"),
        else => return err,
    };
}

pub fn resolveNodeExecutableForLaunchAlloc(allocator: std.mem.Allocator) ![]u8 {
    const node_executable = try resolveNodeExecutable(allocator);
    defer allocator.free(node_executable);
    return ensureExecutableAvailableAlloc(allocator, node_executable);
}

pub fn ensureExecutableAvailableAlloc(allocator: std.mem.Allocator, executable: []const u8) ![]u8 {
    if (try resolveExecutableForLaunchAlloc(allocator, executable)) |resolved| return resolved;
    logNodeRequirement();
    return error.NodeJsRequired;
}

fn resolveExecutableForLaunchAlloc(allocator: std.mem.Allocator, executable: []const u8) !?[]u8 {
    if (std.fs.path.isAbsolute(executable) or std.mem.indexOfAny(u8, executable, "/\\") != null) {
        if (!accessPath(executable)) return null;
        return try allocator.dupe(u8, executable);
    }

    const path_value = getEnvVarOwned(allocator, "PATH") catch |err| switch (err) {
        error.EnvironmentVariableNotFound => return null,
        else => return err,
    };
    defer allocator.free(path_value);

    var path_it = std.mem.splitScalar(u8, path_value, std.fs.path.delimiter);
    while (path_it.next()) |entry| {
        if (entry.len == 0) continue;
        if (try resolveExecutablePathEntryForLaunchAlloc(allocator, entry, executable)) |resolved| return resolved;
    }

    return null;
}

pub fn resolveExecutablePathEntryForLaunchAlloc(
    allocator: std.mem.Allocator,
    entry: []const u8,
    executable: []const u8,
) !?[]u8 {
    const candidate = try std.fs.path.join(allocator, &[_][]const u8{ entry, executable });
    defer allocator.free(candidate);

    if (accessPath(candidate)) {
        return try allocator.dupe(u8, candidate);
    }

    if (builtin.os.tag == .windows and std.fs.path.extension(executable).len == 0) {
        const path_ext = getEnvVarOwned(allocator, "PATHEXT") catch |err| switch (err) {
            error.EnvironmentVariableNotFound => try allocator.dupe(u8, ".COM;.EXE;.BAT;.CMD"),
            else => return err,
        };
        defer allocator.free(path_ext);

        var ext_it = std.mem.splitScalar(u8, path_ext, ';');
        while (ext_it.next()) |raw_ext| {
            if (raw_ext.len == 0) continue;
            const ext = std.mem.trim(u8, raw_ext, " \t");
            if (ext.len == 0) continue;

            const ext_candidate = try std.fmt.allocPrint(allocator, "{s}{s}", .{ candidate, ext });
            defer allocator.free(ext_candidate);

            if (accessPath(ext_candidate)) {
                return try allocator.dupe(u8, ext_candidate);
            }
        }
    }

    return null;
}
fn accessPath(path: []const u8) bool {
    if (std.fs.path.isAbsolute(path)) {
        std.Io.Dir.accessAbsolute(app_runtime.io(), path, .{}) catch return false;
        return true;
    }

    std.Io.Dir.cwd().access(app_runtime.io(), path, .{}) catch return false;
    return true;
}

pub fn logNodeRequirement() void {
    std.log.warn("{s}", .{node_requirement_hint});
}

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

/// Borrowed env lookup for short ASCII values (terminal brand hints) that
/// must not allocate at startup. The startup `environ_map` serves them
/// directly; test code falls back to the test runner's environment, which
/// stores WTF-16 on Windows — callers there should gate on the OS first.
pub fn envValue(comptime name: []const u8) ?[]const u8 {
    if (runtime_init) |init| return init.environ_map.get(name);
    if (builtin.is_test) {
        if (builtin.target.os.tag == .windows) return null;
        return std.testing.environ.getPosix(name);
    }
    @panic("app_runtime.initRuntime must be called during startup");
}

pub fn io() std.Io {
    if (runtime_init) |init| return init.io;
    if (builtin.is_test) return std.testing.io;
    @panic("app_runtime.initRuntime must be called during startup");
}

/// The checked startup allocator. Debug and ReleaseSafe binaries back
/// `init.gpa` with `std.heap.SafeAllocator`, which reports every leaked
/// allocation at process exit (with a stack trace in Debug); unit tests get
/// `std.testing.allocator`, which fails the test on leaks. Tests that install
/// their own `Init` via `initRuntime` get that `Init`'s `gpa` instead.
/// Allocations that should be covered by those checks must not bypass this
/// or the tier helpers below.
pub fn gpa() std.mem.Allocator {
    if (runtime_init) |init| return init.gpa;
    if (builtin.is_test) return std.testing.allocator;
    @panic("app_runtime.initRuntime must be called during startup");
}

/// Allocator for hot or long-lived runtime paths (live TUI, background
/// refresh arenas). Debug and test builds route through `gpa()` so every
/// allocation is covered by leak checks; release builds keep the
/// zero-tracking `smp_allocator` singleton — deliberately, even though
/// ReleaseSafe also has a checked `init.gpa`, for performance.
pub fn fastAllocator() std.mem.Allocator {
    return if (builtin.optimize == .debug or builtin.is_test) gpa() else std.heap.smp_allocator;
}

/// Allocator for one-shot scratch work: subprocess output capture, launch
/// plans, temporary file names. Debug and test builds route through `gpa()`;
/// release builds keep `page_allocator` — same trade-off as `fastAllocator`.
pub fn scratchAllocator() std.mem.Allocator {
    return if (builtin.optimize == .debug or builtin.is_test) gpa() else std.heap.page_allocator;
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

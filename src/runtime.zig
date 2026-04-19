const builtin = @import("builtin");
const std = @import("std");

var io_init_mutex: std.Io.Mutex = .init;
var io_instance: std.Io.Threaded = undefined;
var io_initialized = false;

pub fn currentEnviron() std.process.Environ {
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

fn bootstrapIo() std.Io {
    return std.Io.Threaded.global_single_threaded.io();
}

fn ensureIoInitialized() void {
    if (@atomicLoad(bool, &io_initialized, .acquire)) return;

    const bootstrap_io = bootstrapIo();
    io_init_mutex.lockUncancelable(bootstrap_io);
    defer io_init_mutex.unlock(bootstrap_io);

    if (@atomicLoad(bool, &io_initialized, .acquire)) return;

    io_instance = std.Io.Threaded.init(std.heap.page_allocator, .{
        .environ = currentEnviron(),
    });
    @atomicStore(bool, &io_initialized, true, .release);
}

pub fn io() std.Io {
    ensureIoInitialized();
    return io_instance.io();
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

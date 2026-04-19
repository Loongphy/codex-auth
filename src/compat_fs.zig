const builtin = @import("builtin");
const std = @import("std");

pub const path = std.fs.path;
pub const max_path_bytes = std.Io.Dir.max_path_bytes;
pub const max_name_bytes = std.Io.Dir.max_name_bytes;

// Zig 0.16's global_single_threaded Io uses Allocator.failing. That works
// for simple file and mutex operations, but process spawning allocates argv/env
// through the Io implementation and will otherwise fail with error.OutOfMemory.
var io_init_mutex: std.Io.Mutex = .init;
var io_instance: std.Io.Threaded = undefined;
var io_initialized = false;

fn bootstrapIo() std.Io {
    return std.Io.Threaded.global_single_threaded.io();
}

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

pub fn cwd() Dir {
    return wrapDir(std.Io.Dir.cwd());
}

pub fn wrapDir(dir: std.Io.Dir) Dir {
    return .{ .inner = dir };
}

pub fn wrapFile(file: std.Io.File) File {
    return .{
        .handle = file.handle,
        .flags = file.flags,
    };
}

pub fn accessAbsolute(absolute_path: []const u8, options: Dir.AccessOptions) !void {
    try std.Io.Dir.accessAbsolute(io(), absolute_path, options);
}

pub fn openFileAbsolute(absolute_path: []const u8, options: Dir.OpenFileOptions) !File {
    return wrapFile(try std.Io.Dir.openFileAbsolute(io(), absolute_path, options));
}

pub fn deleteFileAbsolute(absolute_path: []const u8) !void {
    try std.Io.Dir.deleteFileAbsolute(io(), absolute_path);
}

fn dupeOwnedNoSentinel(allocator: std.mem.Allocator, z_path: [:0]u8) ![]u8 {
    defer allocator.free(z_path);
    return try allocator.dupe(u8, z_path);
}

pub fn realpathAlloc(allocator: std.mem.Allocator, file_path: []const u8) ![]u8 {
    if (path.isAbsolute(file_path)) {
        return try dupeOwnedNoSentinel(
            allocator,
            try std.Io.Dir.realPathFileAbsoluteAlloc(io(), file_path, allocator),
        );
    }
    return try cwd().realpathAlloc(allocator, file_path);
}

pub fn selfExePathAlloc(allocator: std.mem.Allocator) ![]u8 {
    return try std.process.executablePathAlloc(io(), allocator);
}

pub const TmpDir = struct {
    inner: std.testing.TmpDir,
    dir: Dir,

    pub fn cleanup(self: *TmpDir) void {
        self.inner.cleanup();
        self.* = undefined;
    }
};

pub fn tmpDir(opts: std.Io.Dir.OpenOptions) TmpDir {
    const inner = std.testing.tmpDir(opts);
    return .{
        .inner = inner,
        .dir = wrapDir(inner.dir),
    };
}

pub const File = struct {
    handle: std.Io.File.Handle,
    flags: std.Io.File.Flags,

    pub const Writer = std.Io.File.Writer;
    pub const Reader = std.Io.File.Reader;
    pub const MemoryMap = std.Io.File.MemoryMap;
    pub const Lock = std.Io.File.Lock;
    pub const Permissions = std.Io.File.Permissions;
    pub const Stat = std.Io.File.Stat;

    pub fn toIoFile(self: File) std.Io.File {
        return .{
            .handle = self.handle,
            .flags = self.flags,
        };
    }

    pub fn stdout() File {
        return wrapFile(std.Io.File.stdout());
    }

    pub fn stderr() File {
        return wrapFile(std.Io.File.stderr());
    }

    pub fn stdin() File {
        return wrapFile(std.Io.File.stdin());
    }

    pub fn writer(self: File, buffer: []u8) Writer {
        return self.toIoFile().writer(io(), buffer);
    }

    pub fn reader(self: File, buffer: []u8) Reader {
        return self.toIoFile().reader(io(), buffer);
    }

    pub fn isTty(self: File) bool {
        return self.toIoFile().isTty(io()) catch false;
    }

    pub fn read(self: File, buffer: []u8) !usize {
        var buffers = [_][]u8{buffer};
        return self.toIoFile().readStreaming(io(), &buffers) catch |err| switch (err) {
            error.EndOfStream => 0,
            else => |e| return e,
        };
    }

    pub fn readToEndAlloc(self: File, allocator: std.mem.Allocator, max_bytes: usize) ![]u8 {
        var read_buffer: [4096]u8 = undefined;
        var file_reader = self.reader(&read_buffer);
        return try file_reader.interface.allocRemaining(allocator, .limited(max_bytes));
    }

    pub fn writeAll(self: File, bytes: []const u8) !void {
        try self.toIoFile().writeStreamingAll(io(), bytes);
    }

    pub fn sync(self: File) !void {
        try self.toIoFile().sync(io());
    }

    pub fn chmod(self: File, mode: std.posix.mode_t) !void {
        try self.toIoFile().setPermissions(io(), .fromMode(mode));
    }

    pub fn updateTimes(self: File, atime_ns: i128, mtime_ns: i128) !void {
        try self.toIoFile().setTimestamps(io(), .{
            .access_timestamp = .{ .new = .{ .nanoseconds = @intCast(atime_ns) } },
            .modify_timestamp = .{ .new = .{ .nanoseconds = @intCast(mtime_ns) } },
        });
    }

    pub fn stat(self: File) !Stat {
        return try self.toIoFile().stat(io());
    }

    pub fn createMemoryMap(self: File, options: MemoryMap.CreateOptions) !MemoryMap {
        return try self.toIoFile().createMemoryMap(io(), options);
    }

    pub fn tryLock(self: File, lock: Lock) !bool {
        return try self.toIoFile().tryLock(io(), lock);
    }

    pub fn unlock(self: File) void {
        self.toIoFile().unlock(io());
    }

    pub fn close(self: File) void {
        self.toIoFile().close(io());
    }
};

pub const Dir = struct {
    inner: std.Io.Dir,

    pub const OpenDirOptions = std.Io.Dir.OpenOptions;
    pub const OpenFileOptions = std.Io.Dir.OpenFileOptions;
    pub const CreateFileOptions = std.Io.Dir.CreateFileOptions;
    pub const WriteFileOptions = std.Io.Dir.WriteFileOptions;
    pub const AccessOptions = std.Io.Dir.AccessOptions;
    pub const CopyFileOptions = std.Io.Dir.CopyFileOptions;
    pub const SymLinkFlags = std.Io.Dir.SymLinkFlags;
    pub const Iterator = struct {
        inner: std.Io.Dir.Iterator,

        pub fn next(self: *Iterator) !?std.Io.Dir.Entry {
            return try self.inner.next(io());
        }
    };
    pub const Walker = struct {
        inner: std.Io.Dir.Walker,
        pub const Entry = std.Io.Dir.Walker.Entry;

        pub fn next(self: *Walker) !?Entry {
            return try self.inner.next(io());
        }

        pub fn deinit(self: *Walker) void {
            self.inner.deinit();
        }

        pub fn leave(self: *Walker) void {
            self.inner.leave(io());
        }
    };
    pub const AtomicFileOptions = struct {
        write_buffer: []u8 = &.{},
        permissions: File.Permissions = .default_file,
    };
    pub const AtomicFile = struct {
        inner: std.Io.File.Atomic,
        file_writer: std.Io.File.Writer,

        pub fn deinit(self: *AtomicFile) void {
            self.inner.deinit(io());
        }

        pub fn finish(self: *AtomicFile) !void {
            try self.file_writer.interface.flush();
            try self.inner.replace(io());
        }
    };

    pub fn openFile(self: Dir, sub_path: []const u8, options: OpenFileOptions) !File {
        return wrapFile(try self.inner.openFile(io(), sub_path, options));
    }

    pub fn createFile(self: Dir, sub_path: []const u8, flags: CreateFileOptions) !File {
        return wrapFile(try self.inner.createFile(io(), sub_path, flags));
    }

    pub fn writeFile(self: Dir, options: WriteFileOptions) !void {
        try self.inner.writeFile(io(), options);
    }

    pub fn access(self: Dir, sub_path: []const u8, options: AccessOptions) !void {
        try self.inner.access(io(), sub_path, options);
    }

    pub fn makePath(self: Dir, sub_path: []const u8) !void {
        try self.inner.createDirPath(io(), sub_path);
    }

    pub fn openDir(self: Dir, sub_path: []const u8, options: OpenDirOptions) !Dir {
        return wrapDir(try self.inner.openDir(io(), sub_path, options));
    }

    pub fn realpathAlloc(self: Dir, allocator: std.mem.Allocator, sub_path: []const u8) ![]u8 {
        return try dupeOwnedNoSentinel(
            allocator,
            try self.inner.realPathFileAlloc(io(), sub_path, allocator),
        );
    }

    pub fn statFile(self: Dir, sub_path: []const u8) !std.Io.Dir.Stat {
        return try self.inner.statFile(io(), sub_path, .{});
    }

    pub fn copyFile(self: Dir, source_path: []const u8, dest_dir: Dir, dest_path: []const u8, options: CopyFileOptions) !void {
        try self.inner.copyFile(source_path, dest_dir.inner, dest_path, io(), options);
    }

    pub fn rename(self: Dir, old_path: []const u8, new_path: []const u8) !void {
        try self.inner.rename(old_path, self.inner, new_path, io());
    }

    pub fn deleteFile(self: Dir, sub_path: []const u8) !void {
        try self.inner.deleteFile(io(), sub_path);
    }

    pub fn deleteDir(self: Dir, sub_path: []const u8) !void {
        try self.inner.deleteDir(io(), sub_path);
    }

    pub fn deleteTree(self: Dir, sub_path: []const u8) !void {
        try self.inner.deleteTree(io(), sub_path);
    }

    pub fn symLink(self: Dir, target_path: []const u8, sym_link_path: []const u8, flags: SymLinkFlags) !void {
        try self.inner.symLink(io(), target_path, sym_link_path, flags);
    }

    pub fn iterate(self: Dir) Iterator {
        return .{ .inner = self.inner.iterate() };
    }

    pub fn walk(self: Dir, allocator: std.mem.Allocator) !Walker {
        return .{ .inner = try self.inner.walk(allocator) };
    }

    pub fn atomicFile(self: Dir, sub_path: []const u8, options: AtomicFileOptions) !AtomicFile {
        var atomic = try self.inner.createFileAtomic(io(), sub_path, .{
            .permissions = options.permissions,
            .replace = true,
        });
        return .{
            .file_writer = atomic.file.writer(io(), options.write_buffer),
            .inner = atomic,
        };
    }

    pub fn close(self: Dir) void {
        self.inner.close(io());
    }
};

test "compat fs io supports process spawning" {
    const result = try std.process.run(std.testing.allocator, io(), .{
        .argv = &.{ "zig", "version" },
        .stdout_limit = .limited(1024),
        .stderr_limit = .limited(1024),
    });
    defer std.testing.allocator.free(result.stdout);
    defer std.testing.allocator.free(result.stderr);

    try std.testing.expectEqual(.exited, std.meta.activeTag(result.term));
    try std.testing.expect(result.stdout.len != 0);
    try std.testing.expect(result.stderr.len == 0);
}

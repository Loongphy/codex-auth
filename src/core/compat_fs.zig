const std = @import("std");
const app_runtime = @import("runtime.zig");

pub const path = std.Io.Dir.path;

// The Io implementation comes from the runtime: `init.io` in the app,
// `std.testing.io` in tests. A statically initialized default such as
// `Io.Threaded.global_single_threaded` is configured without a process
// environ and with `Allocator.failing`, so it must not be used here.
pub fn io() std.Io {
    return app_runtime.io();
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

    pub const Reader = std.Io.File.Reader;
    pub const Permissions = std.Io.File.Permissions;

    pub fn toIoFile(self: File) std.Io.File {
        return .{
            .handle = self.handle,
            .flags = self.flags,
        };
    }

    pub fn reader(self: File, buffer: []u8) Reader {
        return self.toIoFile().reader(io(), buffer);
    }

    pub fn readToEndAlloc(self: File, allocator: std.mem.Allocator, max_bytes: usize) ![]u8 {
        var read_buffer: [4096]u8 = undefined;
        var file_reader = self.reader(&read_buffer);
        return try file_reader.interface.allocRemaining(allocator, .limited(max_bytes));
    }

    pub fn writeAll(self: File, bytes: []const u8) !void {
        try self.toIoFile().writeStreamingAll(io(), bytes);
    }

    pub fn chmod(self: File, mode: std.posix.mode_t) !void {
        try self.toIoFile().setPermissions(io(), .fromMode(mode));
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

    pub fn symLink(self: Dir, target_path: []const u8, sym_link_path: []const u8, flags: SymLinkFlags) !void {
        try self.inner.symLink(io(), target_path, sym_link_path, flags);
    }

    pub fn iterate(self: Dir) Iterator {
        return .{ .inner = self.inner.iterate() };
    }

    pub fn close(self: Dir) void {
        self.inner.close(io());
    }
};

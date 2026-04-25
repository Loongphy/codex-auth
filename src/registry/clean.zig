const std = @import("std");
const app_runtime = @import("../core/runtime.zig");
const builtin = @import("builtin");
const common = @import("common.zig");
const c_time = @cImport({
    @cInclude("time.h");
});

const Registry = common.Registry;
const account_name_refresh_lock_file_name = common.account_name_refresh_lock_file_name;
const accountSnapshotFileName = common.accountSnapshotFileName;
const accountAuthPath = common.accountAuthPath;
const readFileAlloc = common.readFileAlloc;
const registryPath = common.registryPath;
const ensureAccountsDir = common.ensureAccountsDir;
const copyManagedFile = common.copyManagedFile;
const max_backups = common.max_backups;

pub const CleanSummary = struct {
    auth_backups_removed: usize = 0,
    registry_backups_removed: usize = 0,
    stale_snapshot_files_removed: usize = 0,
};

pub fn fileExists(path: []const u8) !bool {
    std.Io.Dir.cwd().access(app_runtime.io(), path, .{}) catch |err| switch (err) {
        error.FileNotFound => return false,
        else => return err,
    };
    return true;
}

pub fn readFileIfExists(allocator: std.mem.Allocator, path: []const u8) !?[]u8 {
    const cwd = std.Io.Dir.cwd();
    var file = cwd.openFile(app_runtime.io(), path, .{}) catch |err| {
        if (err == error.FileNotFound) return null;
        return err;
    };
    defer file.close(app_runtime.io());
    return try readFileAlloc(file, allocator, 10 * 1024 * 1024);
}

pub fn filesEqual(allocator: std.mem.Allocator, a_path: []const u8, b_path: []const u8) !bool {
    const a = try readFileIfExists(allocator, a_path);
    defer if (a) |buf| allocator.free(buf);
    const b = try readFileIfExists(allocator, b_path);
    defer if (b) |buf| allocator.free(buf);
    if (a == null or b == null) return false;
    return std.mem.eql(u8, a.?, b.?);
}

pub fn fileEqualsBytes(allocator: std.mem.Allocator, path: []const u8, bytes: []const u8) !bool {
    const data = try readFileIfExists(allocator, path);
    defer if (data) |buf| allocator.free(buf);
    if (data == null) return false;
    return std.mem.eql(u8, data.?, bytes);
}

pub fn backupDir(allocator: std.mem.Allocator, codex_home: []const u8) ![]u8 {
    return try std.fs.path.join(allocator, &[_][]const u8{ codex_home, "accounts" });
}

pub fn localtimeCompat(ts: i64, out_tm: *c_time.struct_tm) bool {
    if (comptime builtin.os.tag == .windows) {
        if (comptime @hasDecl(c_time, "_localtime64_s") and @hasDecl(c_time, "__time64_t")) {
            var t64 = std.math.cast(c_time.__time64_t, ts) orelse return false;
            return c_time._localtime64_s(out_tm, &t64) == 0;
        }
        return false;
    }

    var t = std.math.cast(c_time.time_t, ts) orelse return false;
    if (comptime @hasDecl(c_time, "localtime_r")) {
        return c_time.localtime_r(&t, out_tm) != null;
    }

    if (comptime @hasDecl(c_time, "localtime")) {
        const tm_ptr = c_time.localtime(&t);
        if (tm_ptr == null) return false;
        out_tm.* = tm_ptr.*;
        return true;
    }

    return false;
}

pub fn formatBackupTimestamp(allocator: std.mem.Allocator, ts: i64) ![]u8 {
    var tm: c_time.struct_tm = undefined;
    if (!localtimeCompat(ts, &tm)) {
        return std.fmt.allocPrint(allocator, "{d}", .{ts});
    }

    const year: u32 = @intCast(tm.tm_year + 1900);
    const month: u32 = @intCast(tm.tm_mon + 1);
    const day: u32 = @intCast(tm.tm_mday);
    const hour: u32 = @intCast(tm.tm_hour);
    const minute: u32 = @intCast(tm.tm_min);
    const second: u32 = @intCast(tm.tm_sec);
    return std.fmt.allocPrint(allocator, "{d:0>4}{d:0>2}{d:0>2}-{d:0>2}{d:0>2}{d:0>2}", .{
        year,
        month,
        day,
        hour,
        minute,
        second,
    });
}

pub fn makeBackupPath(allocator: std.mem.Allocator, dir: []const u8, base_name: []const u8) ![]u8 {
    const timestamp = try formatBackupTimestamp(allocator, std.Io.Timestamp.now(app_runtime.io(), .real).toSeconds());
    defer allocator.free(timestamp);
    const base = try std.fmt.allocPrint(allocator, "{s}.bak.{s}", .{ base_name, timestamp });
    defer allocator.free(base);

    var attempt: usize = 0;
    while (true) : (attempt += 1) {
        const name = if (attempt == 0)
            try allocator.dupe(u8, base)
        else
            try std.fmt.allocPrint(allocator, "{s}.{d}", .{ base, attempt });

        const path = try std.fs.path.join(allocator, &[_][]const u8{ dir, name });
        allocator.free(name);

        if (std.Io.Dir.cwd().openFile(app_runtime.io(), path, .{})) |file| {
            file.close(app_runtime.io());
            allocator.free(path);
            continue;
        } else |_| {
            return path;
        }
    }
}

pub const BackupEntry = struct {
    name: []u8,
    mtime: i128,
};

pub fn backupEntryLessThan(_: void, a: BackupEntry, b: BackupEntry) bool {
    return a.mtime > b.mtime;
}

pub fn pruneBackups(allocator: std.mem.Allocator, dir: []const u8, base_name: []const u8, max: usize) !void {
    var list = std.ArrayList(BackupEntry).empty;
    defer {
        for (list.items) |item| allocator.free(item.name);
        list.deinit(allocator);
    }

    var dir_handle = try std.Io.Dir.cwd().openDir(app_runtime.io(), dir, .{ .iterate = true });
    defer dir_handle.close(app_runtime.io());

    var it = dir_handle.iterate();
    while (try it.next(app_runtime.io())) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.startsWith(u8, entry.name, base_name)) continue;
        if (!std.mem.containsAtLeast(u8, entry.name, 1, ".bak.")) continue;

        const stat = try dir_handle.statFile(app_runtime.io(), entry.name, .{});
        const name = try allocator.dupe(u8, entry.name);
        try list.append(allocator, .{ .name = name, .mtime = stat.mtime.nanoseconds });
    }

    std.sort.insertion(BackupEntry, list.items, {}, backupEntryLessThan);
    if (list.items.len <= max) return;

    var i: usize = max;
    while (i < list.items.len) : (i += 1) {
        const old = list.items[i].name;
        dir_handle.deleteFile(app_runtime.io(), old) catch {};
    }
}

pub fn countBackupsByBaseName(allocator: std.mem.Allocator, dir: []const u8, base_name: []const u8) !usize {
    var count: usize = 0;
    var dir_handle = try std.Io.Dir.cwd().openDir(app_runtime.io(), dir, .{ .iterate = true });
    defer dir_handle.close(app_runtime.io());

    var it = dir_handle.iterate();
    while (try it.next(app_runtime.io())) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.startsWith(u8, entry.name, base_name)) continue;
        if (!std.mem.containsAtLeast(u8, entry.name, 1, ".bak.")) continue;
        _ = allocator;
        count += 1;
    }
    return count;
}

pub fn resolveStrictAccountAuthPath(
    allocator: std.mem.Allocator,
    codex_home: []const u8,
    account_key: []const u8,
) ![]u8 {
    const path = try accountAuthPath(allocator, codex_home, account_key);
    if (std.Io.Dir.cwd().openFile(app_runtime.io(), path, .{})) |file| {
        file.close(app_runtime.io());
        return path;
    } else |err| {
        allocator.free(path);
        return err;
    }
}

pub fn isAllowedCurrentSnapshot(reg: *const Registry, entry_name: []const u8) bool {
    for (reg.accounts.items) |rec| {
        const expected_name = accountSnapshotFileName(std.heap.page_allocator, rec.account_key) catch continue;
        defer std.heap.page_allocator.free(expected_name);
        if (std.mem.eql(u8, entry_name, expected_name)) {
            return true;
        }
    }
    return false;
}

pub fn isAllowedAccountsEntry(reg: *const Registry, entry_name: []const u8) bool {
    if (std.mem.eql(u8, entry_name, "registry.json")) return true;
    if (std.mem.eql(u8, entry_name, "auto-switch.lock")) return true;
    if (std.mem.eql(u8, entry_name, account_name_refresh_lock_file_name)) return true;
    if (std.mem.eql(u8, entry_name, "backups")) return true;
    return isAllowedCurrentSnapshot(reg, entry_name);
}

pub fn cleanAccountsBackupsWithLoader(allocator: std.mem.Allocator, codex_home: []const u8, load_registry: anytype) !CleanSummary {
    const dir = try backupDir(allocator, codex_home);
    defer allocator.free(dir);
    const reg_path = try registryPath(allocator, codex_home);
    defer allocator.free(reg_path);

    var cwd = std.Io.Dir.cwd();
    var dir_handle = cwd.openDir(app_runtime.io(), dir, .{}) catch |err| switch (err) {
        error.FileNotFound => return .{},
        else => return err,
    };
    dir_handle.close(app_runtime.io());

    const auth_before = try countBackupsByBaseName(allocator, dir, "auth.json");
    const registry_before = try countBackupsByBaseName(allocator, dir, "registry.json");

    try pruneBackups(allocator, dir, "auth.json", 0);
    try pruneBackups(allocator, dir, "registry.json", 0);

    const auth_after = try countBackupsByBaseName(allocator, dir, "auth.json");
    const registry_after = try countBackupsByBaseName(allocator, dir, "registry.json");

    if (!(try fileExists(reg_path))) {
        return .{
            .auth_backups_removed = if (auth_before >= auth_after) auth_before - auth_after else 0,
            .registry_backups_removed = if (registry_before >= registry_after) registry_before - registry_after else 0,
            .stale_snapshot_files_removed = 0,
        };
    }

    var reg = try load_registry(allocator, codex_home);
    defer reg.deinit(allocator);

    var stale_snapshot_files_removed: usize = 0;
    var accounts_dir = try std.Io.Dir.cwd().openDir(app_runtime.io(), dir, .{ .iterate = true });
    defer accounts_dir.close(app_runtime.io());
    var it = accounts_dir.iterate();
    while (try it.next(app_runtime.io())) |entry| {
        if (isAllowedAccountsEntry(&reg, entry.name)) {
            continue;
        }

        switch (entry.kind) {
            .file, .sym_link => try accounts_dir.deleteFile(app_runtime.io(), entry.name),
            .directory => try accounts_dir.deleteTree(app_runtime.io(), entry.name),
            else => continue,
        }
        stale_snapshot_files_removed += 1;
    }

    return .{
        .auth_backups_removed = if (auth_before >= auth_after) auth_before - auth_after else 0,
        .registry_backups_removed = if (registry_before >= registry_after) registry_before - registry_after else 0,
        .stale_snapshot_files_removed = stale_snapshot_files_removed,
    };
}

pub fn backupAuthIfChanged(
    allocator: std.mem.Allocator,
    codex_home: []const u8,
    current_auth_path: []const u8,
    new_auth_path: []const u8,
) !void {
    const dir = try backupDir(allocator, codex_home);
    defer allocator.free(dir);
    try ensureAccountsDir(allocator, codex_home);

    if (!(try filesEqual(allocator, current_auth_path, new_auth_path))) {
        if (std.Io.Dir.cwd().openFile(app_runtime.io(), current_auth_path, .{})) |file| {
            file.close(app_runtime.io());
        } else |_| {
            return;
        }
        const backup = try makeBackupPath(allocator, dir, "auth.json");
        defer allocator.free(backup);
        try copyManagedFile(current_auth_path, backup);
        try pruneBackups(allocator, dir, "auth.json", max_backups);
    }
}

pub fn backupRegistryIfChanged(
    allocator: std.mem.Allocator,
    codex_home: []const u8,
    current_registry_path: []const u8,
    new_registry_bytes: []const u8,
) !void {
    const dir = try backupDir(allocator, codex_home);
    defer allocator.free(dir);
    try ensureAccountsDir(allocator, codex_home);

    if (try fileEqualsBytes(allocator, current_registry_path, new_registry_bytes)) {
        return;
    }

    if (std.Io.Dir.cwd().openFile(app_runtime.io(), current_registry_path, .{})) |file| {
        file.close(app_runtime.io());
    } else |_| {
        return;
    }

    const backup = try makeBackupPath(allocator, dir, "registry.json");
    defer allocator.free(backup);
    try copyManagedFile(current_registry_path, backup);
    try pruneBackups(allocator, dir, "registry.json", max_backups);
}

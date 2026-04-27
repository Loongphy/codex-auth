const std = @import("std");
const app_runtime = @import("../core/runtime.zig");
const builtin = @import("builtin");
const clean = @import("clean.zig");
const common = @import("common.zig");

const AccountRecord = common.AccountRecord;
const ApiConfig = common.ApiConfig;
const AutoSwitchConfig = common.AutoSwitchConfig;
const LiveConfig = common.LiveConfig;
const Registry = common.Registry;
const current_schema_version = common.current_schema_version;
const ensureAccountsDir = common.ensureAccountsDir;
const hardenSensitiveFile = common.hardenSensitiveFile;
const private_file_permissions = common.private_file_permissions;
const registryPath = common.registryPath;
const backupRegistryIfChanged = clean.backupRegistryIfChanged;
const fileEqualsBytes = clean.fileEqualsBytes;

pub fn saveRegistry(allocator: std.mem.Allocator, codex_home: []const u8, reg: *Registry) !void {
    reg.schema_version = current_schema_version;
    try ensureAccountsDir(allocator, codex_home);
    const path = try registryPath(allocator, codex_home);
    defer allocator.free(path);

    const out = RegistryOut{
        .schema_version = current_schema_version,
        .active_account_key = reg.active_account_key,
        .active_account_activated_at_ms = reg.active_account_activated_at_ms,
        .auto_switch = reg.auto_switch,
        .api = reg.api,
        .live = reg.live,
        .accounts = reg.accounts.items,
    };
    var aw: std.Io.Writer.Allocating = .init(allocator);
    defer aw.deinit();
    const writer = &aw.writer;
    try std.json.Stringify.value(out, .{ .whitespace = .indent_2 }, writer);
    const data = aw.written();

    if (try fileEqualsBytes(allocator, path, data)) {
        try hardenSensitiveFile(path);
        return;
    }

    try backupRegistryIfChanged(allocator, codex_home, path, data);
    try writeRegistryFileAtomic(path, data);
}

fn writeRegistryFileReplace(path: []const u8, data: []const u8) !void {
    const allocator = std.heap.page_allocator;
    const temp_path = try std.fmt.allocPrint(allocator, "{s}.tmp.{d}", .{ path, @as(i128, std.Io.Timestamp.now(app_runtime.io(), .real).toNanoseconds()) });
    defer allocator.free(temp_path);
    const backup_path = try std.fmt.allocPrint(allocator, "{s}.bak.{d}", .{ path, @as(i128, std.Io.Timestamp.now(app_runtime.io(), .real).toNanoseconds()) });
    defer allocator.free(backup_path);

    {
        var file = try std.Io.Dir.cwd().createFile(app_runtime.io(), temp_path, .{
            .truncate = true,
            .permissions = private_file_permissions,
        });
        defer file.close(app_runtime.io());
        try file.writeStreamingAll(app_runtime.io(), data);
        try file.sync(app_runtime.io());
    }

    const had_original = blk: {
        std.Io.Dir.cwd().rename(path, std.Io.Dir.cwd(), backup_path, app_runtime.io()) catch |err| switch (err) {
            error.FileNotFound => break :blk false,
            else => return err,
        };
        break :blk true;
    };
    errdefer {
        std.Io.Dir.cwd().deleteFile(app_runtime.io(), temp_path) catch {};
        if (had_original) {
            std.Io.Dir.cwd().rename(backup_path, std.Io.Dir.cwd(), path, app_runtime.io()) catch {};
        }
    }
    try std.Io.Dir.cwd().rename(temp_path, std.Io.Dir.cwd(), path, app_runtime.io());
    if (had_original) {
        std.Io.Dir.cwd().deleteFile(app_runtime.io(), backup_path) catch |err| switch (err) {
            error.FileNotFound => {},
            else => return err,
        };
    }
    try hardenSensitiveFile(path);
}

fn writeRegistryFileAtomic(path: []const u8, data: []const u8) !void {
    if (builtin.os.tag == .windows) {
        return writeRegistryFileReplace(path, data);
    }
    var buf: [4096]u8 = undefined;
    var atomic_file = try std.Io.Dir.cwd().createFileAtomic(app_runtime.io(), path, .{
        .replace = true,
        .permissions = private_file_permissions,
    });
    defer atomic_file.deinit(app_runtime.io());
    var file_writer = atomic_file.file.writer(app_runtime.io(), &buf);
    try file_writer.interface.writeAll(data);
    try file_writer.interface.flush();
    try atomic_file.replace(app_runtime.io());
    try hardenSensitiveFile(path);
}

const RegistryOut = struct {
    schema_version: u32,
    active_account_key: ?[]const u8,
    active_account_activated_at_ms: ?i64,
    auto_switch: AutoSwitchConfig,
    api: ApiConfig,
    live: LiveConfig,
    accounts: []const AccountRecord,
};

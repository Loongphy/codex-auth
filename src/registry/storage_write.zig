const std = @import("std");
const clean = @import("clean.zig");
const common = @import("common.zig");

const AccountRecord = common.AccountRecord;
const Registry = common.Registry;
const current_schema_version = common.current_schema_version;
const ensureAccountsDir = common.ensureAccountsDir;
const hardenSensitiveFile = common.hardenSensitiveFile;
const registryPath = common.registryPath;
const backupRegistryIfChanged = clean.backupRegistryIfChanged;
const fileEqualsBytes = clean.fileEqualsBytes;
const sensitive_file = @import("../core/sensitive_file.zig");

pub fn saveRegistry(allocator: std.mem.Allocator, codex_home: []const u8, reg: *Registry) !void {
    reg.schema_version = current_schema_version;
    try ensureAccountsDir(allocator, codex_home);
    const path = try registryPath(allocator, codex_home);
    defer allocator.free(path);

    const out = RegistryOut{
        .schema_version = current_schema_version,
        .active_account_key = reg.active_account_key,
        .previous_active_account_key = reg.previous_active_account_key,
        .active_account_activated_at_ms = reg.active_account_activated_at_ms,
        .interval_seconds = reg.live.interval_seconds,
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

fn writeRegistryFileAtomic(path: []const u8, data: []const u8) !void {
    try sensitive_file.writeAtomic(path, data);
}

const RegistryOut = struct {
    schema_version: u32,
    active_account_key: ?[]const u8,
    previous_active_account_key: ?[]const u8,
    active_account_activated_at_ms: ?i64,
    interval_seconds: u16,
    accounts: []const AccountRecord,
};

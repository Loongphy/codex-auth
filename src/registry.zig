const std = @import("std");
const builtin = @import("builtin");
const c_time = @cImport({
    @cInclude("time.h");
});

pub const PlanType = enum { free, plus, pro, team, business, enterprise, edu, unknown };
pub const AuthMode = enum { chatgpt, apikey };
pub const current_schema_version: u32 = 3;
pub const min_supported_schema_version: u32 = 2;
pub const default_auto_switch_threshold_5h_percent: u8 = 10;
pub const default_auto_switch_threshold_weekly_percent: u8 = 5;

fn normalizeEmailAlloc(allocator: std.mem.Allocator, email: []const u8) ![]u8 {
    var buf = try allocator.alloc(u8, email.len);
    for (email, 0..) |ch, i| {
        buf[i] = std.ascii.toLower(ch);
    }
    return buf;
}

pub const RateLimitWindow = struct {
    used_percent: f64,
    window_minutes: ?i64,
    resets_at: ?i64,
};

pub const CreditsSnapshot = struct {
    has_credits: bool,
    unlimited: bool,
    balance: ?[]u8,
};

pub const RateLimitSnapshot = struct {
    primary: ?RateLimitWindow,
    secondary: ?RateLimitWindow,
    credits: ?CreditsSnapshot,
    plan_type: ?PlanType,
};

pub const RolloutSignature = struct {
    path: []u8,
    event_timestamp_ms: i64,
};

pub const AutoSwitchConfig = struct {
    enabled: bool = false,
    threshold_5h_percent: u8 = default_auto_switch_threshold_5h_percent,
    threshold_weekly_percent: u8 = default_auto_switch_threshold_weekly_percent,
};

pub const ApiConfig = struct {
    usage: bool = true,
};

pub const AccountRecord = struct {
    account_key: []u8,
    chatgpt_account_id: []u8,
    chatgpt_user_id: []u8,
    email: []u8,
    alias: []u8,
    plan: ?PlanType,
    auth_mode: ?AuthMode,
    created_at: i64,
    last_used_at: ?i64,
    last_usage: ?RateLimitSnapshot,
    last_usage_at: ?i64,
    last_local_rollout: ?RolloutSignature,
};

pub fn resolvePlan(rec: *const AccountRecord) ?PlanType {
    if (rec.plan) |p| return p;
    if (rec.last_usage) |u| return u.plan_type;
    return null;
}

pub const Registry = struct {
    schema_version: u32,
    active_account_key: ?[]u8,
    active_account_activated_at_ms: ?i64,
    auto_switch: AutoSwitchConfig,
    api: ApiConfig,
    accounts: std.ArrayList(AccountRecord),

    pub fn deinit(self: *Registry, allocator: std.mem.Allocator) void {
        for (self.accounts.items) |*rec| {
            freeAccountRecord(allocator, rec);
        }
        if (self.active_account_key) |k| allocator.free(k);
        self.accounts.deinit(allocator);
    }
};

pub fn defaultAutoSwitchConfig() AutoSwitchConfig {
    return .{};
}

pub fn defaultApiConfig() ApiConfig {
    return .{};
}

fn freeAccountRecord(allocator: std.mem.Allocator, rec: *const AccountRecord) void {
    allocator.free(rec.account_key);
    allocator.free(rec.chatgpt_account_id);
    allocator.free(rec.chatgpt_user_id);
    allocator.free(rec.email);
    allocator.free(rec.alias);
    if (rec.last_local_rollout) |*sig| freeRolloutSignature(allocator, sig);
    if (rec.last_usage) |*u| {
        freeRateLimitSnapshot(allocator, u);
    }
}

pub fn freeRateLimitSnapshot(allocator: std.mem.Allocator, snapshot: *const RateLimitSnapshot) void {
    if (snapshot.credits) |*c| {
        if (c.balance) |b| allocator.free(b);
    }
}

pub fn freeRolloutSignature(allocator: std.mem.Allocator, signature: *const RolloutSignature) void {
    allocator.free(signature.path);
}

pub fn rolloutSignaturesEqual(a: ?RolloutSignature, b: ?RolloutSignature) bool {
    if (a == null and b == null) return true;
    if (a == null or b == null) return false;
    return a.?.event_timestamp_ms == b.?.event_timestamp_ms and std.mem.eql(u8, a.?.path, b.?.path);
}

pub fn cloneRolloutSignature(allocator: std.mem.Allocator, signature: RolloutSignature) !RolloutSignature {
    return .{
        .path = try allocator.dupe(u8, signature.path),
        .event_timestamp_ms = signature.event_timestamp_ms,
    };
}

fn setRolloutSignature(
    allocator: std.mem.Allocator,
    target: *?RolloutSignature,
    path: []const u8,
    event_timestamp_ms: i64,
) !void {
    if (target.*) |*sig| {
        if (sig.event_timestamp_ms == event_timestamp_ms and std.mem.eql(u8, sig.path, path)) {
            return;
        }
    }
    const new_path = try allocator.dupe(u8, path);
    errdefer allocator.free(new_path);
    if (target.*) |*sig| {
        allocator.free(sig.path);
    }
    target.* = .{
        .path = new_path,
        .event_timestamp_ms = event_timestamp_ms,
    };
}

pub fn setAccountLastLocalRollout(
    allocator: std.mem.Allocator,
    rec: *AccountRecord,
    path: []const u8,
    event_timestamp_ms: i64,
) !void {
    try setRolloutSignature(allocator, &rec.last_local_rollout, path, event_timestamp_ms);
}

pub fn rateLimitSnapshotsEqual(a: ?RateLimitSnapshot, b: ?RateLimitSnapshot) bool {
    if (a == null and b == null) return true;
    if (a == null or b == null) return false;
    return rateLimitSnapshotEqual(a.?, b.?);
}

pub fn rateLimitSnapshotEqual(a: RateLimitSnapshot, b: RateLimitSnapshot) bool {
    return rateLimitWindowEqual(a.primary, b.primary) and
        rateLimitWindowEqual(a.secondary, b.secondary) and
        creditsEqual(a.credits, b.credits) and
        a.plan_type == b.plan_type;
}

fn rateLimitWindowEqual(a: ?RateLimitWindow, b: ?RateLimitWindow) bool {
    if (a == null and b == null) return true;
    if (a == null or b == null) return false;
    return a.?.used_percent == b.?.used_percent and
        a.?.window_minutes == b.?.window_minutes and
        a.?.resets_at == b.?.resets_at;
}

fn creditsEqual(a: ?CreditsSnapshot, b: ?CreditsSnapshot) bool {
    if (a == null and b == null) return true;
    if (a == null or b == null) return false;
    return a.?.has_credits == b.?.has_credits and
        a.?.unlimited == b.?.unlimited and
        optionalStringEqual(a.?.balance, b.?.balance);
}

fn optionalStringEqual(a: ?[]const u8, b: ?[]const u8) bool {
    if (a == null and b == null) return true;
    if (a == null or b == null) return false;
    return std.mem.eql(u8, a.?, b.?);
}

fn getNonEmptyEnvVarOwned(allocator: std.mem.Allocator, name: []const u8) !?[]u8 {
    const val = std.process.getEnvVarOwned(allocator, name) catch |err| switch (err) {
        error.EnvironmentVariableNotFound => return null,
        else => return err,
    };
    if (val.len == 0) {
        allocator.free(val);
        return null;
    }
    return val;
}

pub fn resolveCodexHome(allocator: std.mem.Allocator) ![]u8 {
    const home = try resolveUserHome(allocator);
    defer allocator.free(home);
    return try std.fs.path.join(allocator, &[_][]const u8{ home, ".codex" });
}

pub fn resolveUserHome(allocator: std.mem.Allocator) ![]u8 {
    if (try getNonEmptyEnvVarOwned(allocator, "HOME")) |home| return home;

    if (try getNonEmptyEnvVarOwned(allocator, "USERPROFILE")) |user_profile| return user_profile;

    return error.EnvironmentVariableNotFound;
}

pub fn ensureAccountsDir(allocator: std.mem.Allocator, codex_home: []const u8) !void {
    const accounts_dir = try std.fs.path.join(allocator, &[_][]const u8{ codex_home, "accounts" });
    defer allocator.free(accounts_dir);
    try std.fs.cwd().makePath(accounts_dir);
}

pub fn registryPath(allocator: std.mem.Allocator, codex_home: []const u8) ![]u8 {
    return try std.fs.path.join(allocator, &[_][]const u8{ codex_home, "accounts", "registry.json" });
}

fn encodedFileKey(allocator: std.mem.Allocator, key: []const u8) ![]u8 {
    const encoder = std.base64.url_safe_no_pad.Encoder;
    const out_len = encoder.calcSize(key.len);
    const buf = try allocator.alloc(u8, out_len);
    _ = encoder.encode(buf, key);
    return buf;
}

fn keyNeedsFilenameEncoding(key: []const u8) bool {
    if (key.len == 0) return true;
    if (std.mem.eql(u8, key, ".") or std.mem.eql(u8, key, "..")) return true;
    for (key) |ch| {
        switch (ch) {
            'a'...'z', 'A'...'Z', '0'...'9', '-', '_', '.' => {},
            else => return true,
        }
    }
    return false;
}

fn accountFileKey(allocator: std.mem.Allocator, account_key: []const u8) ![]u8 {
    if (keyNeedsFilenameEncoding(account_key)) {
        return encodedFileKey(allocator, account_key);
    }
    return allocator.dupe(u8, account_key);
}

fn accountSnapshotFileName(allocator: std.mem.Allocator, account_key: []const u8) ![]u8 {
    const key = try accountFileKey(allocator, account_key);
    defer allocator.free(key);
    return try std.mem.concat(allocator, u8, &[_][]const u8{ key, ".auth.json" });
}

pub fn accountAuthPath(allocator: std.mem.Allocator, codex_home: []const u8, account_key: []const u8) ![]u8 {
    const filename = try accountSnapshotFileName(allocator, account_key);
    defer allocator.free(filename);
    return try std.fs.path.join(allocator, &[_][]const u8{ codex_home, "accounts", filename });
}

fn legacyAccountAuthPath(allocator: std.mem.Allocator, codex_home: []const u8, email: []const u8) ![]u8 {
    const key = try encodedFileKey(allocator, email);
    defer allocator.free(key);
    const filename = try std.mem.concat(allocator, u8, &[_][]const u8{ key, ".auth.json" });
    defer allocator.free(filename);
    return try std.fs.path.join(allocator, &[_][]const u8{ codex_home, "accounts", filename });
}

pub fn activeAuthPath(allocator: std.mem.Allocator, codex_home: []const u8) ![]u8 {
    return try std.fs.path.join(allocator, &[_][]const u8{ codex_home, "auth.json" });
}

pub fn copyFile(src: []const u8, dest: []const u8) !void {
    try std.fs.cwd().copyFile(src, std.fs.cwd(), dest, .{});
}

const max_backups: usize = 5;

pub const CleanSummary = struct {
    auth_backups_removed: usize = 0,
    registry_backups_removed: usize = 0,
    stale_snapshot_files_removed: usize = 0,
};

fn fileExists(path: []const u8) !bool {
    std.fs.cwd().access(path, .{}) catch |err| switch (err) {
        error.FileNotFound => return false,
        else => return err,
    };
    return true;
}

fn readFileIfExists(allocator: std.mem.Allocator, path: []const u8) !?[]u8 {
    const cwd = std.fs.cwd();
    var file = cwd.openFile(path, .{}) catch |err| {
        if (err == error.FileNotFound) return null;
        return err;
    };
    defer file.close();
    return try file.readToEndAlloc(allocator, 10 * 1024 * 1024);
}

fn filesEqual(allocator: std.mem.Allocator, a_path: []const u8, b_path: []const u8) !bool {
    const a = try readFileIfExists(allocator, a_path);
    defer if (a) |buf| allocator.free(buf);
    const b = try readFileIfExists(allocator, b_path);
    defer if (b) |buf| allocator.free(buf);
    if (a == null or b == null) return false;
    return std.mem.eql(u8, a.?, b.?);
}

fn fileEqualsBytes(allocator: std.mem.Allocator, path: []const u8, bytes: []const u8) !bool {
    const data = try readFileIfExists(allocator, path);
    defer if (data) |buf| allocator.free(buf);
    if (data == null) return false;
    return std.mem.eql(u8, data.?, bytes);
}

fn ensureDir(path: []const u8) !void {
    try std.fs.cwd().makePath(path);
}

fn backupDir(allocator: std.mem.Allocator, codex_home: []const u8) ![]u8 {
    return try std.fs.path.join(allocator, &[_][]const u8{ codex_home, "accounts" });
}

fn localtimeCompat(ts: i64, out_tm: *c_time.struct_tm) bool {
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

fn formatBackupTimestamp(allocator: std.mem.Allocator, ts: i64) ![]u8 {
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

fn makeBackupPath(allocator: std.mem.Allocator, dir: []const u8, base_name: []const u8) ![]u8 {
    const timestamp = try formatBackupTimestamp(allocator, std.time.timestamp());
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

        if (std.fs.cwd().openFile(path, .{})) |file| {
            file.close();
            allocator.free(path);
            continue;
        } else |_| {
            return path;
        }
    }
}

const BackupEntry = struct {
    name: []u8,
    mtime: i128,
};

fn backupEntryLessThan(_: void, a: BackupEntry, b: BackupEntry) bool {
    return a.mtime > b.mtime;
}

fn pruneBackups(allocator: std.mem.Allocator, dir: []const u8, base_name: []const u8, max: usize) !void {
    var list = std.ArrayList(BackupEntry).empty;
    defer {
        for (list.items) |item| allocator.free(item.name);
        list.deinit(allocator);
    }

    var dir_handle = try std.fs.cwd().openDir(dir, .{ .iterate = true });
    defer dir_handle.close();

    var it = dir_handle.iterate();
    while (try it.next()) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.startsWith(u8, entry.name, base_name)) continue;
        if (!std.mem.containsAtLeast(u8, entry.name, 1, ".bak.")) continue;

        const stat = try dir_handle.statFile(entry.name);
        const name = try allocator.dupe(u8, entry.name);
        try list.append(allocator, .{ .name = name, .mtime = stat.mtime });
    }

    std.sort.insertion(BackupEntry, list.items, {}, backupEntryLessThan);
    if (list.items.len <= max) return;

    var i: usize = max;
    while (i < list.items.len) : (i += 1) {
        const old = list.items[i].name;
        dir_handle.deleteFile(old) catch {};
    }
}

fn countBackupsByBaseName(allocator: std.mem.Allocator, dir: []const u8, base_name: []const u8) !usize {
    var count: usize = 0;
    var dir_handle = try std.fs.cwd().openDir(dir, .{ .iterate = true });
    defer dir_handle.close();

    var it = dir_handle.iterate();
    while (try it.next()) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.startsWith(u8, entry.name, base_name)) continue;
        if (!std.mem.containsAtLeast(u8, entry.name, 1, ".bak.")) continue;
        _ = allocator;
        count += 1;
    }
    return count;
}

fn resolveStrictAccountAuthPath(
    allocator: std.mem.Allocator,
    codex_home: []const u8,
    account_key: []const u8,
) ![]u8 {
    const path = try accountAuthPath(allocator, codex_home, account_key);
    if (std.fs.cwd().openFile(path, .{})) |file| {
        file.close();
        return path;
    } else |err| {
        allocator.free(path);
        return err;
    }
}

fn isAllowedCurrentSnapshot(reg: *const Registry, entry_name: []const u8) bool {
    for (reg.accounts.items) |rec| {
        const expected_name = accountSnapshotFileName(std.heap.page_allocator, rec.account_key) catch continue;
        defer std.heap.page_allocator.free(expected_name);
        if (std.mem.eql(u8, entry_name, expected_name)) {
            return true;
        }
    }
    return false;
}

fn isAllowedAccountsEntry(reg: *const Registry, entry_name: []const u8) bool {
    if (std.mem.eql(u8, entry_name, "registry.json")) return true;
    if (std.mem.eql(u8, entry_name, "auto-switch.lock")) return true;
    if (std.mem.eql(u8, entry_name, "backups")) return true;
    return isAllowedCurrentSnapshot(reg, entry_name);
}

pub fn cleanAccountsBackups(allocator: std.mem.Allocator, codex_home: []const u8) !CleanSummary {
    const dir = try backupDir(allocator, codex_home);
    defer allocator.free(dir);
    const reg_path = try registryPath(allocator, codex_home);
    defer allocator.free(reg_path);

    var cwd = std.fs.cwd();
    var dir_handle = cwd.openDir(dir, .{}) catch |err| switch (err) {
        error.FileNotFound => return .{},
        else => return err,
    };
    dir_handle.close();

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

    var reg = try loadRegistry(allocator, codex_home);
    defer reg.deinit(allocator);

    var stale_snapshot_files_removed: usize = 0;
    var accounts_dir = try std.fs.cwd().openDir(dir, .{ .iterate = true });
    defer accounts_dir.close();
    var it = accounts_dir.iterate();
    while (try it.next()) |entry| {
        if (isAllowedAccountsEntry(&reg, entry.name)) {
            continue;
        }

        switch (entry.kind) {
            .file, .sym_link => try accounts_dir.deleteFile(entry.name),
            .directory => try accounts_dir.deleteTree(entry.name),
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
    try ensureDir(dir);

    if (!(try filesEqual(allocator, current_auth_path, new_auth_path))) {
        if (std.fs.cwd().openFile(current_auth_path, .{})) |file| {
            file.close();
        } else |_| {
            return;
        }
        const backup = try makeBackupPath(allocator, dir, "auth.json");
        defer allocator.free(backup);
        try std.fs.cwd().copyFile(current_auth_path, std.fs.cwd(), backup, .{});
        try pruneBackups(allocator, dir, "auth.json", max_backups);
    }
}

fn backupRegistryIfChanged(
    allocator: std.mem.Allocator,
    codex_home: []const u8,
    current_registry_path: []const u8,
    new_registry_bytes: []const u8,
) !void {
    const dir = try backupDir(allocator, codex_home);
    defer allocator.free(dir);
    try ensureDir(dir);

    if (try fileEqualsBytes(allocator, current_registry_path, new_registry_bytes)) {
        return;
    }

    if (std.fs.cwd().openFile(current_registry_path, .{})) |file| {
        file.close();
    } else |_| {
        return;
    }

    const backup = try makeBackupPath(allocator, dir, "registry.json");
    defer allocator.free(backup);
    try std.fs.cwd().copyFile(current_registry_path, std.fs.cwd(), backup, .{});
    try pruneBackups(allocator, dir, "registry.json", max_backups);
}

pub const ImportSummary = struct {
    imported: usize = 0,
    skipped: usize = 0,
};

const PurgeCarryForwardConfig = struct {
    auto_switch: AutoSwitchConfig = defaultAutoSwitchConfig(),
    api: ApiConfig = defaultApiConfig(),
};

pub fn purgeRegistryFromImportSource(
    allocator: std.mem.Allocator,
    codex_home: []const u8,
    auth_path: ?[]const u8,
    explicit_alias: ?[]const u8,
) !ImportSummary {
    if (auth_path == null and explicit_alias != null) {
        std.log.warn("--alias is ignored when purging from {s}", .{"~/.codex/accounts"});
    }

    const carry_forward = try loadPurgeCarryForwardConfig(allocator, codex_home);

    var reg = defaultRegistry();
    reg.auto_switch = carry_forward.auto_switch;
    reg.api = carry_forward.api;
    defer reg.deinit(allocator);

    var summary = if (auth_path) |path|
        try importAuthPath(allocator, codex_home, &reg, path, explicit_alias)
    else
        try importAccountsSnapshotDirectory(allocator, codex_home, &reg);

    if (try syncCurrentAuthBestEffort(allocator, codex_home, &reg)) {
        summary.imported += 1;
    }

    sortAccountsByEmail(&reg);
    try saveRegistry(allocator, codex_home, &reg);
    return summary;
}

fn loadPurgeCarryForwardConfig(allocator: std.mem.Allocator, codex_home: []const u8) !PurgeCarryForwardConfig {
    const path = try registryPath(allocator, codex_home);
    defer allocator.free(path);

    const cwd = std.fs.cwd();
    var file = cwd.openFile(path, .{}) catch |err| switch (err) {
        error.FileNotFound => return .{},
        else => return err,
    };
    defer file.close();

    const data = try file.readToEndAlloc(allocator, 10 * 1024 * 1024);
    defer allocator.free(data);

    return parsePurgeCarryForwardConfig(allocator, data);
}

fn parsePurgeCarryForwardConfig(allocator: std.mem.Allocator, data: []const u8) PurgeCarryForwardConfig {
    var cfg = PurgeCarryForwardConfig{};

    var parsed = std.json.parseFromSlice(std.json.Value, allocator, data, .{}) catch {
        applyCarryForwardObjectSlice(allocator, data, "auto_switch", &cfg.auto_switch, parseCarryForwardAutoSwitch);
        applyCarryForwardObjectSlice(allocator, data, "api", &cfg.api, parseCarryForwardApiConfig);
        return cfg;
    };
    defer parsed.deinit();

    switch (parsed.value) {
        .object => |obj| {
            if (obj.get("auto_switch")) |v| parseAutoSwitch(allocator, &cfg.auto_switch, v);
            if (obj.get("api")) |v| parseApiConfig(&cfg.api, v);
        },
        else => {},
    }
    return cfg;
}

fn parseCarryForwardAutoSwitch(allocator: std.mem.Allocator, value: std.json.Value, target: *AutoSwitchConfig) void {
    parseAutoSwitch(allocator, target, value);
}

fn parseCarryForwardApiConfig(_: std.mem.Allocator, value: std.json.Value, target: *ApiConfig) void {
    parseApiConfig(target, value);
}

fn applyCarryForwardObjectSlice(
    allocator: std.mem.Allocator,
    data: []const u8,
    field_name: []const u8,
    target: anytype,
    comptime parser: fn (std.mem.Allocator, std.json.Value, @TypeOf(target)) void,
) void {
    const slice = findJsonObjectFieldSlice(data, field_name) orelse return;
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, slice, .{}) catch return;
    defer parsed.deinit();
    parser(allocator, parsed.value, target);
}

fn findJsonObjectFieldSlice(data: []const u8, field_name: []const u8) ?[]const u8 {
    var pattern_buffer: [64]u8 = undefined;
    if (field_name.len + 2 > pattern_buffer.len) return null;
    pattern_buffer[0] = '"';
    @memcpy(pattern_buffer[1 .. 1 + field_name.len], field_name);
    pattern_buffer[1 + field_name.len] = '"';
    const pattern = pattern_buffer[0 .. field_name.len + 2];

    var search_start: usize = 0;
    while (std.mem.indexOfPos(u8, data, search_start, pattern)) |name_idx| {
        search_start = name_idx + pattern.len;
        var idx = skipJsonWhitespace(data, search_start);
        if (idx >= data.len or data[idx] != ':') continue;
        idx = skipJsonWhitespace(data, idx + 1);
        if (idx >= data.len or data[idx] != '{') continue;
        const end_idx = findBalancedObjectEnd(data, idx) orelse continue;
        return data[idx .. end_idx + 1];
    }
    return null;
}

fn skipJsonWhitespace(data: []const u8, start: usize) usize {
    var idx = start;
    while (idx < data.len and std.ascii.isWhitespace(data[idx])) : (idx += 1) {}
    return idx;
}

fn findBalancedObjectEnd(data: []const u8, start: usize) ?usize {
    var idx = start;
    var depth: usize = 0;
    var in_string = false;
    var escaped = false;

    while (idx < data.len) : (idx += 1) {
        const ch = data[idx];
        if (in_string) {
            if (escaped) {
                escaped = false;
                continue;
            }
            switch (ch) {
                '\\' => escaped = true,
                '"' => in_string = false,
                else => {},
            }
            continue;
        }

        switch (ch) {
            '"' => in_string = true,
            '{' => depth += 1,
            '}' => {
                if (depth == 0) return null;
                depth -= 1;
                if (depth == 0) return idx;
            },
            else => {},
        }
    }

    return null;
}

pub fn importAuthPath(
    allocator: std.mem.Allocator,
    codex_home: []const u8,
    reg: *Registry,
    auth_path: []const u8,
    explicit_alias: ?[]const u8,
) !ImportSummary {
    const stat = std.fs.cwd().statFile(auth_path) catch |err| switch (err) {
        error.IsDir => {
            if (explicit_alias != null) {
                std.log.warn("--alias is ignored when importing a directory: {s}", .{auth_path});
            }
            return try importAuthDirectory(allocator, codex_home, reg, auth_path);
        },
        else => return err,
    };
    if (stat.kind == .directory) {
        if (explicit_alias != null) {
            std.log.warn("--alias is ignored when importing a directory: {s}", .{auth_path});
        }
        return try importAuthDirectory(allocator, codex_home, reg, auth_path);
    }

    try importAuthFile(allocator, codex_home, reg, auth_path, explicit_alias);
    return ImportSummary{ .imported = 1 };
}

fn importAuthFile(
    allocator: std.mem.Allocator,
    codex_home: []const u8,
    reg: *Registry,
    auth_file: []const u8,
    explicit_alias: ?[]const u8,
) !void {
    const info = try @import("auth.zig").parseAuthInfo(allocator, auth_file);
    defer info.deinit(allocator);
    _ = info.email orelse return error.MissingEmail;
    const record_key = info.record_key orelse return error.MissingChatgptUserId;

    const alias = explicit_alias orelse "";

    const dest = try accountAuthPath(allocator, codex_home, record_key);
    defer allocator.free(dest);

    try ensureAccountsDir(allocator, codex_home);
    try copyFile(auth_file, dest);

    const record = try accountFromAuth(allocator, alias, &info);
    try upsertAccount(allocator, reg, record);
}

fn importAuthDirectory(
    allocator: std.mem.Allocator,
    codex_home: []const u8,
    reg: *Registry,
    dir_path: []const u8,
) !ImportSummary {
    var dir = try std.fs.cwd().openDir(dir_path, .{ .iterate = true });
    defer dir.close();

    var names = std.ArrayList([]u8).empty;
    defer {
        for (names.items) |name| allocator.free(name);
        names.deinit(allocator);
    }

    var it = dir.iterate();
    while (try it.next()) |entry| {
        if (entry.kind != .file and entry.kind != .sym_link) continue;
        if (!isImportConfigFile(entry.name)) continue;
        try names.append(allocator, try allocator.dupe(u8, entry.name));
    }

    std.sort.insertion([]u8, names.items, {}, importFileNameLessThan);

    var summary = ImportSummary{};
    for (names.items) |name| {
        const file_path = try std.fs.path.join(allocator, &[_][]const u8{ dir_path, name });
        defer allocator.free(file_path);
        importAuthFile(allocator, codex_home, reg, file_path, null) catch |err| {
            summary.skipped += 1;
            std.log.warn("skip import {s}: {s}", .{ file_path, @errorName(err) });
            continue;
        };
        summary.imported += 1;
    }
    return summary;
}

fn importAccountsSnapshotDirectory(
    allocator: std.mem.Allocator,
    codex_home: []const u8,
    reg: *Registry,
) !ImportSummary {
    const dir_path = try backupDir(allocator, codex_home);
    defer allocator.free(dir_path);

    var dir = std.fs.cwd().openDir(dir_path, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => return ImportSummary{},
        else => return err,
    };
    defer dir.close();

    var candidates = std.ArrayList(PurgeImportCandidate).empty;
    defer {
        for (candidates.items) |*candidate| candidate.deinit(allocator);
        candidates.deinit(allocator);
    }

    var summary = ImportSummary{};
    var it = dir.iterate();
    while (try it.next()) |entry| {
        if (entry.kind != .file and entry.kind != .sym_link) continue;
        if (!isPurgeImportAuthFile(entry.name)) continue;

        const file_path = try std.fs.path.join(allocator, &[_][]const u8{ dir_path, entry.name });
        var file_path_owned = true;
        errdefer if (file_path_owned) allocator.free(file_path);

        const stat = try dir.statFile(entry.name);
        var info = @import("auth.zig").parseAuthInfo(allocator, file_path) catch |err| {
            summary.skipped += 1;
            std.log.warn("skip purge import {s}: {s}", .{ file_path, @errorName(err) });
            file_path_owned = false;
            allocator.free(file_path);
            continue;
        };
        defer info.deinit(allocator);

        const email = info.email orelse {
            summary.skipped += 1;
            std.log.warn("skip purge import {s}: {s}", .{ file_path, @errorName(error.MissingEmail) });
            file_path_owned = false;
            allocator.free(file_path);
            continue;
        };
        const record_key = info.record_key orelse {
            summary.skipped += 1;
            std.log.warn("skip purge import {s}: {s}", .{ file_path, @errorName(error.MissingChatgptUserId) });
            file_path_owned = false;
            allocator.free(file_path);
            continue;
        };

        const canonical_name = try accountSnapshotFileName(allocator, record_key);
        defer allocator.free(canonical_name);

        const candidate_name = try allocator.dupe(u8, entry.name);
        errdefer allocator.free(candidate_name);
        const candidate_record_key = try allocator.dupe(u8, record_key);
        errdefer allocator.free(candidate_record_key);
        const candidate_email = try allocator.dupe(u8, email);
        errdefer allocator.free(candidate_email);

        var candidate = PurgeImportCandidate{
            .name = candidate_name,
            .path = file_path,
            .record_key = candidate_record_key,
            .email = candidate_email,
            .mtime = stat.mtime,
            .kind = if (std.mem.eql(u8, entry.name, canonical_name))
                .current_snapshot
            else if (std.mem.startsWith(u8, entry.name, "auth.json.bak."))
                .backup
            else
                .legacy_snapshot,
        };
        errdefer candidate.deinit(allocator);
        file_path_owned = false;

        if (findPurgeImportCandidateIndexByRecordKey(candidates.items, candidate.record_key)) |idx| {
            if (purgeImportCandidateIsNewer(&candidates.items[idx], &candidate)) {
                candidates.items[idx].deinit(allocator);
                candidates.items[idx] = candidate;
            } else {
                candidate.deinit(allocator);
            }
            continue;
        }

        try candidates.append(allocator, candidate);
    }

    std.sort.insertion(PurgeImportCandidate, candidates.items, {}, purgeImportCandidateLessThan);

    for (candidates.items) |candidate| {
        importAuthFile(allocator, codex_home, reg, candidate.path, null) catch |err| {
            summary.skipped += 1;
            std.log.warn("skip purge import {s}: {s}", .{ candidate.path, @errorName(err) });
            continue;
        };
        summary.imported += 1;
    }
    return summary;
}

const PurgeImportCandidateKind = enum(u8) {
    legacy_snapshot,
    backup,
    current_snapshot,
};

const PurgeImportCandidate = struct {
    name: []u8,
    path: []u8,
    record_key: []u8,
    email: []u8,
    mtime: i128,
    kind: PurgeImportCandidateKind,

    fn deinit(self: *PurgeImportCandidate, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        allocator.free(self.path);
        allocator.free(self.record_key);
        allocator.free(self.email);
    }
};

fn purgeImportCandidateRank(kind: PurgeImportCandidateKind) u8 {
    return switch (kind) {
        .legacy_snapshot => 0,
        .backup => 1,
        .current_snapshot => 2,
    };
}

fn purgeImportCandidateIsNewer(current: *const PurgeImportCandidate, incoming: *const PurgeImportCandidate) bool {
    if (incoming.mtime != current.mtime) return incoming.mtime > current.mtime;

    const incoming_rank = purgeImportCandidateRank(incoming.kind);
    const current_rank = purgeImportCandidateRank(current.kind);
    if (incoming_rank != current_rank) return incoming_rank > current_rank;

    return std.mem.order(u8, incoming.name, current.name) == .gt;
}

fn findPurgeImportCandidateIndexByRecordKey(candidates: []const PurgeImportCandidate, record_key: []const u8) ?usize {
    for (candidates, 0..) |candidate, idx| {
        if (std.mem.eql(u8, candidate.record_key, record_key)) return idx;
    }
    return null;
}

fn purgeImportCandidateLessThan(_: void, a: PurgeImportCandidate, b: PurgeImportCandidate) bool {
    return accountRecordOrderLessThan(a.email, a.record_key, b.email, b.record_key);
}

fn isImportConfigFile(name: []const u8) bool {
    return std.mem.endsWith(u8, name, ".json");
}

fn isPurgeImportAuthFile(name: []const u8) bool {
    return std.mem.endsWith(u8, name, ".auth.json") or
        std.mem.startsWith(u8, name, "auth.json.bak.");
}

fn importFileNameLessThan(_: void, a: []u8, b: []u8) bool {
    return std.mem.lessThan(u8, a, b);
}

fn accountRecordOrderLessThan(a_email: []const u8, a_account_key: []const u8, b_email: []const u8, b_account_key: []const u8) bool {
    return switch (std.mem.order(u8, a_email, b_email)) {
        .lt => true,
        .gt => false,
        .eq => std.mem.lessThan(u8, a_account_key, b_account_key),
    };
}

fn accountRecordLessThan(_: void, a: AccountRecord, b: AccountRecord) bool {
    return accountRecordOrderLessThan(a.email, a.account_key, b.email, b.account_key);
}

fn sortAccountsByEmail(reg: *Registry) void {
    std.sort.insertion(AccountRecord, reg.accounts.items, {}, accountRecordLessThan);
}

fn syncCurrentAuthBestEffort(
    allocator: std.mem.Allocator,
    codex_home: []const u8,
    reg: *Registry,
) !bool {
    const auth_path = try activeAuthPath(allocator, codex_home);
    defer allocator.free(auth_path);

    if (std.fs.cwd().openFile(auth_path, .{})) |file| {
        file.close();
    } else |_| {
        return false;
    }

    const info = @import("auth.zig").parseAuthInfo(allocator, auth_path) catch return false;
    defer info.deinit(allocator);
    _ = info.email orelse return false;
    const record_key = info.record_key orelse return false;

    const existing_idx = findAccountIndexByAccountKey(reg, record_key);
    const dest = try accountAuthPath(allocator, codex_home, record_key);
    defer allocator.free(dest);
    try ensureAccountsDir(allocator, codex_home);
    try copyFile(auth_path, dest);

    if (existing_idx) |idx| {
        const email = info.email.?;
        if (!std.mem.eql(u8, reg.accounts.items[idx].email, email)) {
            const new_email = try allocator.dupe(u8, email);
            allocator.free(reg.accounts.items[idx].email);
            reg.accounts.items[idx].email = new_email;
        }
        if (info.chatgpt_account_id) |chatgpt_account_id| {
            if (!std.mem.eql(u8, reg.accounts.items[idx].chatgpt_account_id, chatgpt_account_id)) {
                const new_chatgpt_account_id = try allocator.dupe(u8, chatgpt_account_id);
                allocator.free(reg.accounts.items[idx].chatgpt_account_id);
                reg.accounts.items[idx].chatgpt_account_id = new_chatgpt_account_id;
            }
        }
        if (info.chatgpt_user_id) |chatgpt_user_id| {
            if (!std.mem.eql(u8, reg.accounts.items[idx].chatgpt_user_id, chatgpt_user_id)) {
                const new_chatgpt_user_id = try allocator.dupe(u8, chatgpt_user_id);
                allocator.free(reg.accounts.items[idx].chatgpt_user_id);
                reg.accounts.items[idx].chatgpt_user_id = new_chatgpt_user_id;
            }
        }
        reg.accounts.items[idx].plan = info.plan;
        reg.accounts.items[idx].auth_mode = info.auth_mode;
    } else {
        var record = try accountFromAuth(allocator, "", &info);
        errdefer freeAccountRecord(allocator, &record);
        try upsertAccount(allocator, reg, record);
    }

    try setActiveAccountKey(allocator, reg, record_key);
    return true;
}

pub fn findAccountIndexByAccountKey(reg: *Registry, account_key: []const u8) ?usize {
    for (reg.accounts.items, 0..) |rec, i| {
        if (std.mem.eql(u8, rec.account_key, account_key)) return i;
    }
    return null;
}

pub fn setActiveAccountKey(allocator: std.mem.Allocator, reg: *Registry, account_key: []const u8) !void {
    if (reg.active_account_key) |k| {
        if (std.mem.eql(u8, k, account_key)) return;
    }
    const new_active_account_key = try allocator.dupe(u8, account_key);
    if (reg.active_account_key) |k| {
        allocator.free(k);
    }
    reg.active_account_key = new_active_account_key;
    reg.active_account_activated_at_ms = std.time.milliTimestamp();
    const now = std.time.timestamp();
    for (reg.accounts.items) |*rec| {
        if (std.mem.eql(u8, rec.account_key, account_key)) {
            rec.last_used_at = now;
            break;
        }
    }
}

pub fn updateUsage(allocator: std.mem.Allocator, reg: *Registry, account_key: []const u8, snapshot: RateLimitSnapshot) void {
    const now = std.time.timestamp();
    for (reg.accounts.items) |*rec| {
        if (std.mem.eql(u8, rec.account_key, account_key)) {
            if (rec.last_usage) |*u| {
                if (u.credits) |*c| {
                    if (c.balance) |b| allocator.free(b);
                }
            }
            rec.last_usage = snapshot;
            rec.last_usage_at = now;
            break;
        }
    }
}

pub fn syncActiveAccountFromAuth(allocator: std.mem.Allocator, codex_home: []const u8, reg: *Registry) !bool {
    if (reg.accounts.items.len == 0) {
        return try autoImportActiveAuth(allocator, codex_home, reg);
    }

    const auth_path = try activeAuthPath(allocator, codex_home);
    defer allocator.free(auth_path);

    const auth_bytes_opt = try readFileIfExists(allocator, auth_path);
    if (auth_bytes_opt == null) return false;
    const auth_bytes = auth_bytes_opt.?;
    defer allocator.free(auth_bytes);

    const info = @import("auth.zig").parseAuthInfo(allocator, auth_path) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => {
            std.log.warn("auth.json sync skipped: {s}", .{@errorName(err)});
            return false;
        },
    };
    defer info.deinit(allocator);

    const email = info.email orelse {
        std.log.warn("auth.json missing email; skipping sync", .{});
        return false;
    };
    const record_key = info.record_key orelse {
        std.log.warn("auth.json missing record_key; skipping sync", .{});
        return false;
    };

    const matched_index = findAccountIndexByAccountKey(reg, record_key);
    if (matched_index == null) {
        const dest = try accountAuthPath(allocator, codex_home, record_key);
        defer allocator.free(dest);

        try ensureAccountsDir(allocator, codex_home);
        try copyFile(auth_path, dest);

        var record = try accountFromAuth(allocator, "", &info);
        var record_owned = true;
        errdefer if (record_owned) freeAccountRecord(allocator, &record);
        try upsertAccount(allocator, reg, record);
        record_owned = false;
        try setActiveAccountKey(allocator, reg, record_key);
        return true;
    }

    const idx = matched_index.?;
    const rec_account_key = reg.accounts.items[idx].account_key;
    var changed = false;
    if (reg.active_account_key) |k| {
        if (!std.mem.eql(u8, k, rec_account_key)) changed = true;
    } else {
        changed = true;
    }

    if (!std.mem.eql(u8, reg.accounts.items[idx].email, email)) {
        const new_email = try allocator.dupe(u8, email);
        allocator.free(reg.accounts.items[idx].email);
        reg.accounts.items[idx].email = new_email;
        changed = true;
    }
    if (reg.accounts.items[idx].plan != info.plan) {
        changed = true;
    }
    reg.accounts.items[idx].plan = info.plan;
    if (reg.accounts.items[idx].auth_mode != info.auth_mode) {
        changed = true;
    }
    reg.accounts.items[idx].auth_mode = info.auth_mode;

    const dest = try accountAuthPath(allocator, codex_home, rec_account_key);
    defer allocator.free(dest);
    if (!(try fileEqualsBytes(allocator, dest, auth_bytes))) {
        try copyFile(auth_path, dest);
        changed = true;
    }

    try setActiveAccountKey(allocator, reg, rec_account_key);
    return changed;
}

pub fn removeAccounts(allocator: std.mem.Allocator, codex_home: []const u8, reg: *Registry, indices: []const usize) !void {
    if (indices.len == 0 or reg.accounts.items.len == 0) return;

    var removed = try allocator.alloc(bool, reg.accounts.items.len);
    defer allocator.free(removed);
    @memset(removed, false);
    for (indices) |idx| {
        if (idx < removed.len) removed[idx] = true;
    }

    if (reg.active_account_key) |key| {
        var active_removed = false;
        for (reg.accounts.items, 0..) |rec, i| {
            if (removed[i] and std.mem.eql(u8, rec.account_key, key)) {
                active_removed = true;
                break;
            }
        }
        if (active_removed) {
            allocator.free(key);
            reg.active_account_key = null;
            reg.active_account_activated_at_ms = null;
        }
    }

    var write_idx: usize = 0;
    for (reg.accounts.items, 0..) |*rec, i| {
        if (removed[i]) {
            const preferred_path = try accountAuthPath(allocator, codex_home, rec.account_key);
            defer allocator.free(preferred_path);
            std.fs.cwd().deleteFile(preferred_path) catch {};
            freeAccountRecord(allocator, rec);
            continue;
        }
        if (write_idx != i) {
            reg.accounts.items[write_idx] = rec.*;
        }
        write_idx += 1;
    }
    reg.accounts.items.len = write_idx;
}

pub fn selectBestAccountIndexByUsage(reg: *Registry) ?usize {
    if (reg.accounts.items.len == 0) return null;
    const now = std.time.timestamp();
    var best_idx: ?usize = null;
    var best_score: i64 = -2;
    var best_seen: i64 = -1;
    for (reg.accounts.items, 0..) |rec, i| {
        const score = usageScoreAt(rec.last_usage, now) orelse -1;
        const seen = rec.last_usage_at orelse -1;
        if (score > best_score) {
            best_score = score;
            best_seen = seen;
            best_idx = i;
        } else if (score == best_score and seen > best_seen) {
            best_seen = seen;
            best_idx = i;
        }
    }
    return best_idx;
}

pub fn usageScoreAt(usage: ?RateLimitSnapshot, now: i64) ?i64 {
    const rate_5h = resolveRateWindow(usage, 300, true);
    const rate_week = resolveRateWindow(usage, 10080, false);
    const rem_5h = remainingPercentAt(rate_5h, now);
    const rem_week = remainingPercentAt(rate_week, now);
    if (rem_5h != null and rem_week != null) return @min(rem_5h.?, rem_week.?);
    if (rem_5h != null) return rem_5h.?;
    if (rem_week != null) return rem_week.?;
    return null;
}

pub fn remainingPercentAt(window: ?RateLimitWindow, now: i64) ?i64 {
    if (window == null) return null;
    if (window.?.resets_at) |resets_at| {
        if (resets_at <= now) return 100;
    }
    const remaining = 100.0 - window.?.used_percent;
    if (remaining <= 0.0) return 0;
    if (remaining >= 100.0) return 100;
    return @as(i64, @intFromFloat(remaining));
}

pub fn resolveRateWindow(usage: ?RateLimitSnapshot, minutes: i64, fallback_primary: bool) ?RateLimitWindow {
    if (usage == null) return null;
    if (usage.?.primary) |p| {
        if (p.window_minutes != null and p.window_minutes.? == minutes) return p;
    }
    if (usage.?.secondary) |s| {
        if (s.window_minutes != null and s.window_minutes.? == minutes) return s;
    }
    return if (fallback_primary) usage.?.primary else usage.?.secondary;
}

pub fn activateAccountByKey(
    allocator: std.mem.Allocator,
    codex_home: []const u8,
    reg: *Registry,
    account_key: []const u8,
) !void {
    _ = findAccountIndexByAccountKey(reg, account_key) orelse return error.AccountNotFound;
    const src = try resolveStrictAccountAuthPath(allocator, codex_home, account_key);
    defer allocator.free(src);

    const dest = try activeAuthPath(allocator, codex_home);
    defer allocator.free(dest);

    try backupAuthIfChanged(allocator, codex_home, dest, src);
    try copyFile(src, dest);
    try setActiveAccountKey(allocator, reg, account_key);
}

pub fn accountFromAuth(
    allocator: std.mem.Allocator,
    alias: []const u8,
    info: *const @import("auth.zig").AuthInfo,
) !AccountRecord {
    const email = info.email orelse return error.MissingEmail;
    const chatgpt_account_id = info.chatgpt_account_id orelse return error.MissingAccountId;
    const record_key = info.record_key orelse return error.MissingChatgptUserId;
    const chatgpt_user_id = info.chatgpt_user_id orelse return error.MissingChatgptUserId;
    const owned_record_key = try allocator.dupe(u8, record_key);
    errdefer allocator.free(owned_record_key);
    const owned_chatgpt_account_id = try allocator.dupe(u8, chatgpt_account_id);
    errdefer allocator.free(owned_chatgpt_account_id);
    const owned_chatgpt_user_id = try allocator.dupe(u8, chatgpt_user_id);
    errdefer allocator.free(owned_chatgpt_user_id);
    const owned_email = try allocator.dupe(u8, email);
    errdefer allocator.free(owned_email);
    const owned_alias = try allocator.dupe(u8, alias);
    errdefer allocator.free(owned_alias);
    return AccountRecord{
        .account_key = owned_record_key,
        .chatgpt_account_id = owned_chatgpt_account_id,
        .chatgpt_user_id = owned_chatgpt_user_id,
        .email = owned_email,
        .alias = owned_alias,
        .plan = info.plan,
        .auth_mode = info.auth_mode,
        .created_at = std.time.timestamp(),
        .last_used_at = null,
        .last_usage = null,
        .last_usage_at = null,
        .last_local_rollout = null,
    };
}

fn recordFreshness(rec: *const AccountRecord) i64 {
    var best = rec.created_at;
    if (rec.last_used_at) |t| {
        if (t > best) best = t;
    }
    if (rec.last_usage_at) |t| {
        if (t > best) best = t;
    }
    return best;
}

fn mergeAccountRecord(allocator: std.mem.Allocator, dest: *AccountRecord, incoming: AccountRecord) void {
    if (recordFreshness(&incoming) > recordFreshness(dest)) {
        freeAccountRecord(allocator, dest);
        dest.* = incoming;
        return;
    }
    if (incoming.alias.len != 0 and dest.alias.len == 0) {
        const replacement = allocator.dupe(u8, incoming.alias) catch allocator.dupe(u8, "") catch unreachable;
        allocator.free(dest.alias);
        dest.alias = replacement;
    }
    if (dest.plan == null) dest.plan = incoming.plan;
    if (dest.auth_mode == null) dest.auth_mode = incoming.auth_mode;
    freeAccountRecord(allocator, &incoming);
}

pub fn upsertAccount(allocator: std.mem.Allocator, reg: *Registry, record: AccountRecord) !void {
    for (reg.accounts.items) |*rec| {
        if (std.mem.eql(u8, rec.account_key, record.account_key)) {
            mergeAccountRecord(allocator, rec, record);
            return;
        }
    }
    try reg.accounts.append(allocator, record);
}

const LegacyAccountRecord = struct {
    email: []u8,
    alias: []u8,
    plan: ?PlanType,
    auth_mode: ?AuthMode,
    created_at: i64,
    last_used_at: ?i64,
    last_usage: ?RateLimitSnapshot,
    last_usage_at: ?i64,
};

fn freeLegacyAccountRecord(allocator: std.mem.Allocator, rec: *LegacyAccountRecord) void {
    allocator.free(rec.email);
    allocator.free(rec.alias);
    if (rec.last_usage) |*u| freeRateLimitSnapshot(allocator, u);
}

fn defaultRegistry() Registry {
    return Registry{
        .schema_version = current_schema_version,
        .active_account_key = null,
        .active_account_activated_at_ms = null,
        .auto_switch = defaultAutoSwitchConfig(),
        .api = defaultApiConfig(),
        .accounts = std.ArrayList(AccountRecord).empty,
    };
}

fn parseLegacyAccountRecord(allocator: std.mem.Allocator, obj: std.json.ObjectMap) !LegacyAccountRecord {
    const email_val = obj.get("email") orelse return error.MissingEmail;
    const alias_val = obj.get("alias") orelse return error.MissingAlias;
    const email = switch (email_val) {
        .string => |s| s,
        else => return error.MissingEmail,
    };
    const alias = switch (alias_val) {
        .string => |s| s,
        else => return error.MissingAlias,
    };
    var rec = LegacyAccountRecord{
        .email = try normalizeEmailAlloc(allocator, email),
        .alias = try allocator.dupe(u8, alias),
        .plan = null,
        .auth_mode = null,
        .created_at = readInt(obj.get("created_at")) orelse std.time.timestamp(),
        .last_used_at = readInt(obj.get("last_used_at")),
        .last_usage = null,
        .last_usage_at = readInt(obj.get("last_usage_at")),
    };
    errdefer freeLegacyAccountRecord(allocator, &rec);

    if (obj.get("plan")) |p| {
        switch (p) {
            .string => |s| rec.plan = parsePlanType(s),
            else => {},
        }
    }
    if (obj.get("auth_mode")) |m| {
        switch (m) {
            .string => |s| rec.auth_mode = parseAuthMode(s),
            else => {},
        }
    }
    if (obj.get("last_usage")) |u| {
        rec.last_usage = parseUsage(allocator, u);
    }
    return rec;
}

fn parseAccountRecord(allocator: std.mem.Allocator, obj: std.json.ObjectMap) !AccountRecord {
    const account_key_val = obj.get("account_key") orelse return error.MissingAccountKey;
    const email_val = obj.get("email") orelse return error.MissingEmail;
    const alias_val = obj.get("alias") orelse return error.MissingAlias;
    const account_key = switch (account_key_val) {
        .string => |s| s,
        else => return error.MissingAccountKey,
    };
    const email = switch (email_val) {
        .string => |s| s,
        else => return error.MissingEmail,
    };
    const alias = switch (alias_val) {
        .string => |s| s,
        else => return error.MissingAlias,
    };
    var rec = AccountRecord{
        .account_key = try allocator.dupe(u8, account_key),
        .chatgpt_account_id = switch (obj.get("chatgpt_account_id") orelse return error.MissingChatgptAccountId) {
            .string => |s| try allocator.dupe(u8, s),
            else => return error.MissingChatgptAccountId,
        },
        .chatgpt_user_id = switch (obj.get("chatgpt_user_id") orelse return error.MissingChatgptUserId) {
            .string => |s| try allocator.dupe(u8, s),
            else => return error.MissingChatgptUserId,
        },
        .email = try normalizeEmailAlloc(allocator, email),
        .alias = try allocator.dupe(u8, alias),
        .plan = null,
        .auth_mode = null,
        .created_at = readInt(obj.get("created_at")) orelse std.time.timestamp(),
        .last_used_at = readInt(obj.get("last_used_at")),
        .last_usage = null,
        .last_usage_at = readInt(obj.get("last_usage_at")),
        .last_local_rollout = null,
    };
    errdefer freeAccountRecord(allocator, &rec);

    if (obj.get("plan")) |p| {
        switch (p) {
            .string => |s| rec.plan = parsePlanType(s),
            else => {},
        }
    }
    if (obj.get("auth_mode")) |m| {
        switch (m) {
            .string => |s| rec.auth_mode = parseAuthMode(s),
            else => {},
        }
    }
    if (obj.get("last_usage")) |u| {
        rec.last_usage = parseUsage(allocator, u);
    }
    if (obj.get("last_local_rollout")) |v| {
        rec.last_local_rollout = parseRolloutSignature(allocator, v);
    }
    return rec;
}

fn maybeCopyFile(src: []const u8, dest: []const u8) !void {
    if (std.mem.eql(u8, src, dest)) return;
    try copyFile(src, dest);
}

fn resolveLegacySnapshotPathForEmail(
    allocator: std.mem.Allocator,
    codex_home: []const u8,
    email: []const u8,
) ![]u8 {
    const legacy_path = try legacyAccountAuthPath(allocator, codex_home, email);
    if (std.fs.cwd().openFile(legacy_path, .{})) |file| {
        file.close();
        return legacy_path;
    } else |_| {
        allocator.free(legacy_path);
    }

    const accounts_dir = try backupDir(allocator, codex_home);
    defer allocator.free(accounts_dir);
    var dir = std.fs.cwd().openDir(accounts_dir, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => return error.FileNotFound,
        else => return err,
    };
    defer dir.close();

    var it = dir.iterate();
    while (try it.next()) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.name, ".auth.json")) continue;
        if (std.mem.startsWith(u8, entry.name, "auth.json.bak.")) continue;

        const path = try std.fs.path.join(allocator, &[_][]const u8{ accounts_dir, entry.name });
        errdefer allocator.free(path);
        const info = @import("auth.zig").parseAuthInfo(allocator, path) catch {
            allocator.free(path);
            continue;
        };
        defer info.deinit(allocator);
        if (info.email != null and std.mem.eql(u8, info.email.?, email)) {
            return path;
        }
        allocator.free(path);
    }

    const active_path = try activeAuthPath(allocator, codex_home);
    errdefer allocator.free(active_path);
    const active_info = @import("auth.zig").parseAuthInfo(allocator, active_path) catch {
        allocator.free(active_path);
        return error.FileNotFound;
    };
    defer active_info.deinit(allocator);
    if (active_info.email != null and std.mem.eql(u8, active_info.email.?, email)) {
        return active_path;
    }

    allocator.free(active_path);
    return error.FileNotFound;
}

fn migrateLegacyRecord(
    allocator: std.mem.Allocator,
    codex_home: []const u8,
    reg: *Registry,
    legacy_active_email: ?[]const u8,
    legacy: *LegacyAccountRecord,
) !void {
    const legacy_path = try resolveLegacySnapshotPathForEmail(allocator, codex_home, legacy.email);
    defer allocator.free(legacy_path);

    const info = try @import("auth.zig").parseAuthInfo(allocator, legacy_path);
    defer info.deinit(allocator);
    const email = info.email orelse return error.MissingEmail;
    const chatgpt_account_id = info.chatgpt_account_id orelse return error.MissingAccountId;
    if (!std.mem.eql(u8, email, legacy.email)) return error.EmailMismatch;

    var rec = AccountRecord{
        .account_key = try allocator.dupe(u8, info.record_key orelse return error.MissingChatgptUserId),
        .chatgpt_account_id = try allocator.dupe(u8, chatgpt_account_id),
        .chatgpt_user_id = try allocator.dupe(u8, info.chatgpt_user_id orelse return error.MissingChatgptUserId),
        .email = try allocator.dupe(u8, legacy.email),
        .alias = try allocator.dupe(u8, legacy.alias),
        .plan = info.plan orelse legacy.plan,
        .auth_mode = info.auth_mode,
        .created_at = legacy.created_at,
        .last_used_at = legacy.last_used_at,
        .last_usage = legacy.last_usage,
        .last_usage_at = legacy.last_usage_at,
        .last_local_rollout = null,
    };
    legacy.last_usage = null;
    var rec_owned = true;
    errdefer if (rec_owned) freeAccountRecord(allocator, &rec);

    const new_path = try accountAuthPath(allocator, codex_home, rec.account_key);
    defer allocator.free(new_path);
    try ensureAccountsDir(allocator, codex_home);
    if (!(try filesEqual(allocator, legacy_path, new_path))) {
        try maybeCopyFile(legacy_path, new_path);
    }

    const old_legacy_path = try legacyAccountAuthPath(allocator, codex_home, legacy.email);
    defer allocator.free(old_legacy_path);
    if (std.mem.eql(u8, legacy_path, old_legacy_path)) {
        std.fs.cwd().deleteFile(old_legacy_path) catch {};
    }

    const should_activate = if (legacy_active_email) |active_email|
        reg.active_account_key == null and std.mem.eql(u8, active_email, legacy.email)
    else
        false;
    const active_account_key = if (should_activate) try allocator.dupe(u8, rec.account_key) else null;
    errdefer if (active_account_key) |value| allocator.free(value);

    try upsertAccount(allocator, reg, rec);
    rec_owned = false;
    if (active_account_key) |value| {
        reg.active_account_key = value;
        reg.active_account_activated_at_ms = 0;
    }
}

fn loadLegacyRegistryV2(
    allocator: std.mem.Allocator,
    codex_home: []const u8,
    root_obj: std.json.ObjectMap,
) !Registry {
    var reg = defaultRegistry();
    errdefer reg.deinit(allocator);
    var legacy_active_email: ?[]u8 = null;
    var legacy_accounts = std.ArrayList(LegacyAccountRecord).empty;
    defer {
        for (legacy_accounts.items) |*rec| freeLegacyAccountRecord(allocator, rec);
        legacy_accounts.deinit(allocator);
        if (legacy_active_email) |value| allocator.free(value);
    }

    if (root_obj.get("active_account_key")) |v| {
        switch (v) {
            .string => |s| reg.active_account_key = try allocator.dupe(u8, s),
            else => {},
        }
    }
    if (reg.active_account_key != null) {
        reg.active_account_activated_at_ms = 0;
    }
    if (root_obj.get("active_email")) |v| {
        switch (v) {
            .string => |s| legacy_active_email = try normalizeEmailAlloc(allocator, s),
            else => {},
        }
    }

    if (root_obj.get("accounts")) |v| {
        switch (v) {
            .array => |arr| {
                for (arr.items) |item| {
                    const obj = switch (item) {
                        .object => |o| o,
                        else => continue,
                    };
                    if (obj.get("account_key") != null) {
                        const rec = try parseAccountRecord(allocator, obj);
                        try upsertAccount(allocator, &reg, rec);
                    } else {
                        try legacy_accounts.append(allocator, try parseLegacyAccountRecord(allocator, obj));
                    }
                }
            },
            else => {},
        }
    }

    if (root_obj.get("auto_switch")) |v| {
        parseAutoSwitch(allocator, &reg.auto_switch, v);
    }
    if (root_obj.get("api")) |v| {
        parseApiConfig(&reg.api, v);
    }

    for (legacy_accounts.items) |*legacy| {
        try migrateLegacyRecord(allocator, codex_home, &reg, legacy_active_email, legacy);
    }

    return reg;
}

fn loadCurrentRegistry(allocator: std.mem.Allocator, root_obj: std.json.ObjectMap) !Registry {
    if (root_obj.get("active_email") != null) return error.UnsupportedRegistryLayout;

    var reg = defaultRegistry();
    errdefer reg.deinit(allocator);

    if (root_obj.get("active_account_key")) |v| {
        switch (v) {
            .string => |s| reg.active_account_key = try allocator.dupe(u8, s),
            else => {},
        }
    }
    if (root_obj.get("active_account_activated_at_ms")) |v| {
        reg.active_account_activated_at_ms = readInt(v);
    } else if (reg.active_account_key != null) {
        reg.active_account_activated_at_ms = 0;
    }

    if (root_obj.get("accounts")) |v| {
        switch (v) {
            .array => |arr| {
                for (arr.items) |item| {
                    const obj = switch (item) {
                        .object => |o| o,
                        else => continue,
                    };
                    const rec = try parseAccountRecord(allocator, obj);
                    try upsertAccount(allocator, &reg, rec);
                }
            },
            else => {},
        }
    }

    if (root_obj.get("auto_switch")) |v| {
        parseAutoSwitch(allocator, &reg.auto_switch, v);
    }
    if (root_obj.get("api")) |v| {
        parseApiConfig(&reg.api, v);
    }

    return reg;
}

fn schemaVersionFieldValue(root_obj: std.json.ObjectMap) ?u32 {
    if (root_obj.get("schema_version") != null) {
        if (std.math.cast(u32, readInt(root_obj.get("schema_version")) orelse return null)) |value| return value;
        return null;
    }
    if (root_obj.get("version") != null) {
        if (std.math.cast(u32, readInt(root_obj.get("version")) orelse return null)) |value| return value;
        return null;
    }
    return null;
}

fn usesLegacyVersionField(root_obj: std.json.ObjectMap) bool {
    return root_obj.get("schema_version") == null and root_obj.get("version") != null;
}

fn currentLayoutNeedsRewrite(root_obj: std.json.ObjectMap) bool {
    if (root_obj.get("last_attributed_rollout") != null) return true;
    return root_obj.get("active_account_key") != null and root_obj.get("active_account_activated_at_ms") == null;
}

fn detectSchemaVersion(root_obj: std.json.ObjectMap) u32 {
    return schemaVersionFieldValue(root_obj) orelse if (root_obj.get("active_email") != null) 2 else current_schema_version;
}

fn logUnsupportedRegistryVersion(version_value: u32) void {
    if (builtin.is_test) return;
    std.log.err(
        "registry schema_version {d} is newer than this codex-auth binary supports (max {d}); upgrade codex-auth",
        .{ version_value, current_schema_version },
    );
}

pub fn loadRegistry(allocator: std.mem.Allocator, codex_home: []const u8) !Registry {
    const path = try registryPath(allocator, codex_home);
    defer allocator.free(path);

    const cwd = std.fs.cwd();
    const data = blk: {
        var file = cwd.openFile(path, .{}) catch |err| {
            if (err == error.FileNotFound) {
                return defaultRegistry();
            }
            return err;
        };
        defer file.close();

        break :blk try file.readToEndAlloc(allocator, 10 * 1024 * 1024);
    };
    defer allocator.free(data);

    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, data, .{});
    defer parsed.deinit();

    const root = parsed.value;
    const root_obj = switch (root) {
        .object => |o| o,
        else => return defaultRegistry(),
    };

    const schema_version = detectSchemaVersion(root_obj);
    if (schema_version > current_schema_version) {
        logUnsupportedRegistryVersion(schema_version);
        return error.UnsupportedRegistryVersion;
    }

    const needs_rewrite = schema_version < current_schema_version or
        usesLegacyVersionField(root_obj) or
        (schema_version == current_schema_version and currentLayoutNeedsRewrite(root_obj));
    var reg = switch (schema_version) {
        2 => try loadLegacyRegistryV2(allocator, codex_home, root_obj),
        3 => try loadCurrentRegistry(allocator, root_obj),
        else => {
            std.log.err(
                "registry schema_version {d} is older than the minimum supported {d}; use an intermediate codex-auth release or import --purge",
                .{ schema_version, min_supported_schema_version },
            );
            return error.UnsupportedRegistryVersion;
        },
    };
    errdefer reg.deinit(allocator);

    if (needs_rewrite) {
        try saveRegistry(allocator, codex_home, &reg);
    }

    return reg;
}

fn writeRegistryFileReplace(path: []const u8, data: []const u8) !void {
    const allocator = std.heap.page_allocator;
    const temp_path = try std.fmt.allocPrint(allocator, "{s}.tmp.{d}", .{ path, std.time.nanoTimestamp() });
    defer allocator.free(temp_path);
    const backup_path = try std.fmt.allocPrint(allocator, "{s}.bak.{d}", .{ path, std.time.nanoTimestamp() });
    defer allocator.free(backup_path);

    {
        var file = try std.fs.cwd().createFile(temp_path, .{ .truncate = true });
        defer file.close();
        try file.writeAll(data);
        try file.sync();
    }

    const had_original = blk: {
        std.fs.cwd().rename(path, backup_path) catch |err| switch (err) {
            error.FileNotFound => break :blk false,
            else => return err,
        };
        break :blk true;
    };
    errdefer {
        std.fs.cwd().deleteFile(temp_path) catch {};
        if (had_original) {
            std.fs.cwd().rename(backup_path, path) catch {};
        }
    }
    try std.fs.cwd().rename(temp_path, path);
    if (had_original) {
        std.fs.cwd().deleteFile(backup_path) catch |err| switch (err) {
            error.FileNotFound => {},
            else => return err,
        };
    }
}

fn writeRegistryFileAtomic(path: []const u8, data: []const u8) !void {
    if (builtin.os.tag == .windows) {
        return writeRegistryFileReplace(path, data);
    }
    var buf: [4096]u8 = undefined;
    var atomic_file = try std.fs.cwd().atomicFile(path, .{ .write_buffer = &buf });
    defer atomic_file.deinit();
    try atomic_file.file_writer.interface.writeAll(data);
    try atomic_file.finish();
}

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
        .accounts = reg.accounts.items,
    };
    var aw: std.Io.Writer.Allocating = .init(allocator);
    defer aw.deinit();
    const writer = &aw.writer;
    try std.json.Stringify.value(out, .{ .whitespace = .indent_2 }, writer);
    const data = aw.written();

    if (try fileEqualsBytes(allocator, path, data)) {
        return;
    }

    try backupRegistryIfChanged(allocator, codex_home, path, data);
    try writeRegistryFileAtomic(path, data);
}

const RegistryOut = struct {
    schema_version: u32,
    active_account_key: ?[]const u8,
    active_account_activated_at_ms: ?i64,
    auto_switch: AutoSwitchConfig,
    api: ApiConfig,
    accounts: []const AccountRecord,
};

fn parsePlanType(s: []const u8) ?PlanType {
    if (std.mem.eql(u8, s, "free")) return .free;
    if (std.mem.eql(u8, s, "plus")) return .plus;
    if (std.mem.eql(u8, s, "pro")) return .pro;
    if (std.mem.eql(u8, s, "team")) return .team;
    if (std.mem.eql(u8, s, "business")) return .business;
    if (std.mem.eql(u8, s, "enterprise")) return .enterprise;
    if (std.mem.eql(u8, s, "edu")) return .edu;
    return .unknown;
}

fn parseAuthMode(s: []const u8) ?AuthMode {
    if (std.mem.eql(u8, s, "chatgpt")) return .chatgpt;
    if (std.mem.eql(u8, s, "apikey")) return .apikey;
    return null;
}

fn parseUsage(allocator: std.mem.Allocator, v: std.json.Value) ?RateLimitSnapshot {
    const obj = switch (v) {
        .object => |o| o,
        else => return null,
    };
    var snap = RateLimitSnapshot{ .primary = null, .secondary = null, .credits = null, .plan_type = null };

    if (obj.get("plan_type")) |p| {
        switch (p) {
            .string => |s| snap.plan_type = parsePlanType(s),
            else => {},
        }
    }
    if (obj.get("primary")) |p| snap.primary = parseWindow(p);
    if (obj.get("secondary")) |p| snap.secondary = parseWindow(p);
    if (obj.get("credits")) |c| snap.credits = parseCredits(allocator, c);
    return snap;
}

fn parseAutoSwitch(allocator: std.mem.Allocator, cfg: *AutoSwitchConfig, v: std.json.Value) void {
    _ = allocator;
    const obj = switch (v) {
        .object => |o| o,
        else => return,
    };
    if (obj.get("enabled")) |enabled| {
        switch (enabled) {
            .bool => |flag| cfg.enabled = flag,
            else => {},
        }
    }
    if (obj.get("threshold_5h_percent")) |threshold| {
        if (parseThresholdPercent(threshold)) |value| {
            cfg.threshold_5h_percent = value;
        }
    }
    if (obj.get("threshold_weekly_percent")) |threshold| {
        if (parseThresholdPercent(threshold)) |value| {
            cfg.threshold_weekly_percent = value;
        }
    }
}

fn parseApiConfig(cfg: *ApiConfig, v: std.json.Value) void {
    const obj = switch (v) {
        .object => |o| o,
        else => return,
    };
    if (obj.get("usage")) |usage| {
        switch (usage) {
            .bool => |flag| cfg.usage = flag,
            else => {},
        }
    }
}

fn parseRolloutSignature(allocator: std.mem.Allocator, v: std.json.Value) ?RolloutSignature {
    const obj = switch (v) {
        .object => |o| o,
        else => return null,
    };
    const path = switch (obj.get("path") orelse return null) {
        .string => |s| s,
        else => return null,
    };
    const event_timestamp_ms = readInt(obj.get("event_timestamp_ms")) orelse return null;
    return .{
        .path = allocator.dupe(u8, path) catch return null,
        .event_timestamp_ms = event_timestamp_ms,
    };
}

fn parseWindow(v: std.json.Value) ?RateLimitWindow {
    const obj = switch (v) {
        .object => |o| o,
        else => return null,
    };
    const used = obj.get("used_percent") orelse return null;
    const used_percent = switch (used) {
        .float => |f| f,
        .integer => |i| @as(f64, @floatFromInt(i)),
        else => 0.0,
    };
    const window_minutes = if (obj.get("window_minutes")) |wm| switch (wm) {
        .integer => |i| i,
        else => null,
    } else null;
    const resets_at = if (obj.get("resets_at")) |ra| switch (ra) {
        .integer => |i| i,
        else => null,
    } else null;
    return RateLimitWindow{ .used_percent = used_percent, .window_minutes = window_minutes, .resets_at = resets_at };
}

fn parseCredits(allocator: std.mem.Allocator, v: std.json.Value) ?CreditsSnapshot {
    const obj = switch (v) {
        .object => |o| o,
        else => return null,
    };
    const has_credits = if (obj.get("has_credits")) |hc| switch (hc) {
        .bool => |b| b,
        else => false,
    } else false;
    const unlimited = if (obj.get("unlimited")) |u| switch (u) {
        .bool => |b| b,
        else => false,
    } else false;
    var balance: ?[]u8 = null;
    if (obj.get("balance")) |b| {
        switch (b) {
            .string => |s| balance = allocator.dupe(u8, s) catch null,
            else => {},
        }
    }
    return CreditsSnapshot{ .has_credits = has_credits, .unlimited = unlimited, .balance = balance };
}

fn readInt(v: ?std.json.Value) ?i64 {
    if (v == null) return null;
    switch (v.?) {
        .integer => |i| return i,
        else => return null,
    }
}

fn parseThresholdPercent(v: std.json.Value) ?u8 {
    const raw = switch (v) {
        .integer => |i| i,
        else => return null,
    };
    if (raw < 1 or raw > 100) return null;
    return @as(u8, @intCast(raw));
}

pub fn refreshAccountsFromAuth(allocator: std.mem.Allocator, codex_home: []const u8, reg: *Registry) !void {
    for (reg.accounts.items) |*rec| {
        const path = resolveStrictAccountAuthPath(allocator, codex_home, rec.account_key) catch |err| switch (err) {
            error.FileNotFound => continue,
            else => return err,
        };
        defer allocator.free(path);
        const info = try @import("auth.zig").parseAuthInfo(allocator, path);
        defer info.deinit(allocator);
        const email = info.email orelse {
            std.log.warn("auth file missing email for {s}; skipping refresh", .{rec.email});
            continue;
        };
        const chatgpt_account_id = info.chatgpt_account_id orelse {
            std.log.warn("auth file missing account_id for {s}; skipping refresh", .{rec.email});
            continue;
        };
        const record_key = info.record_key orelse {
            std.log.warn("auth file missing record key for {s}; skipping refresh", .{rec.email});
            continue;
        };
        if (!std.mem.eql(u8, email, rec.email)) {
            std.log.warn("auth file email mismatch for {s}; skipping refresh", .{rec.email});
            continue;
        }
        if (!std.mem.eql(u8, chatgpt_account_id, rec.chatgpt_account_id)) {
            std.log.warn("auth file account_id mismatch for {s}; skipping refresh", .{rec.email});
            continue;
        }
        if (!std.mem.eql(u8, record_key, rec.account_key)) {
            std.log.warn("auth file record_key mismatch for {s}; skipping refresh", .{rec.email});
            continue;
        }
        rec.plan = info.plan;
        rec.auth_mode = info.auth_mode;
    }
}

pub fn autoImportActiveAuth(allocator: std.mem.Allocator, codex_home: []const u8, reg: *Registry) !bool {
    if (reg.accounts.items.len != 0) return false;

    const auth_path = try activeAuthPath(allocator, codex_home);
    defer allocator.free(auth_path);

    if (std.fs.cwd().openFile(auth_path, .{})) |file| {
        file.close();
    } else |_| {
        return false;
    }

    const info = try @import("auth.zig").parseAuthInfo(allocator, auth_path);
    defer info.deinit(allocator);
    _ = info.email orelse {
        std.log.warn("auth.json missing email; cannot import", .{});
        return false;
    };
    const record_key = info.record_key orelse return error.MissingChatgptUserId;

    const dest = try accountAuthPath(allocator, codex_home, record_key);
    defer allocator.free(dest);

    try ensureAccountsDir(allocator, codex_home);
    try copyFile(auth_path, dest);

    const record = try accountFromAuth(allocator, "", &info);
    try upsertAccount(allocator, reg, record);
    try setActiveAccountKey(allocator, reg, record_key);
    return true;
}

const std = @import("std");
const auth = @import("auth.zig");

pub const PlanType = enum { free, plus, pro, team, business, enterprise, edu, unknown };
pub const AuthMode = enum { chatgpt, apikey };
const registry_version: u32 = 3;

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

pub const AccountRecord = struct {
    account_id: []u8,
    email: []u8,
    alias: []u8,
    plan: ?PlanType,
    api_key_fingerprint: ?[]u8,
    auth_mode: ?AuthMode,
    created_at: i64,
    last_used_at: ?i64,
    last_usage: ?RateLimitSnapshot,
    last_usage_at: ?i64,
};

pub fn resolvePlan(rec: *const AccountRecord) ?PlanType {
    if (rec.plan) |p| return p;
    if (rec.last_usage) |u| return u.plan_type;
    return null;
}

pub fn accountDisplayName(rec: *const AccountRecord) []const u8 {
    if (rec.auth_mode) |mode| {
        if (mode == .apikey) return rec.account_id;
    }
    return rec.email;
}

pub const Registry = struct {
    version: u32,
    active_account_id: ?[]u8,
    accounts: std.ArrayList(AccountRecord),

    pub fn deinit(self: *Registry, allocator: std.mem.Allocator) void {
        for (self.accounts.items) |*rec| {
            freeAccountRecord(allocator, rec);
        }
        if (self.active_account_id) |k| allocator.free(k);
        self.accounts.deinit(allocator);
    }
};

fn freeAccountRecord(allocator: std.mem.Allocator, rec: *const AccountRecord) void {
    allocator.free(rec.account_id);
    allocator.free(rec.email);
    allocator.free(rec.alias);
    if (rec.api_key_fingerprint) |fp| allocator.free(fp);
    if (rec.last_usage) |*u| {
        if (u.credits) |*c| {
            if (c.balance) |b| allocator.free(b);
        }
    }
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
    if (try getNonEmptyEnvVarOwned(allocator, "CODEX_HOME")) |val| return val;

    if (try getNonEmptyEnvVarOwned(allocator, "HOME")) |home| {
        defer allocator.free(home);
        return try std.fs.path.join(allocator, &[_][]const u8{ home, ".codex" });
    }

    if (try getNonEmptyEnvVarOwned(allocator, "USERPROFILE")) |user_profile| {
        defer allocator.free(user_profile);
        return try std.fs.path.join(allocator, &[_][]const u8{ user_profile, ".codex" });
    }

    const home_drive = try getNonEmptyEnvVarOwned(allocator, "HOMEDRIVE");
    defer if (home_drive) |v| allocator.free(v);
    const home_path = try getNonEmptyEnvVarOwned(allocator, "HOMEPATH");
    defer if (home_path) |v| allocator.free(v);

    if (home_drive != null and home_path != null) {
        const combined = try std.mem.concat(allocator, u8, &[_][]const u8{ home_drive.?, home_path.? });
        defer allocator.free(combined);
        return try std.fs.path.join(allocator, &[_][]const u8{ combined, ".codex" });
    }

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

fn base64UrlKey(allocator: std.mem.Allocator, value: []const u8) ![]u8 {
    const encoder = std.base64.url_safe_no_pad.Encoder;
    const out_len = encoder.calcSize(value.len);
    const buf = try allocator.alloc(u8, out_len);
    _ = encoder.encode(buf, value);
    return buf;
}

pub fn planTypeString(plan: PlanType) []const u8 {
    return @tagName(plan);
}

pub fn accountIdFromPartsAlloc(
    allocator: std.mem.Allocator,
    auth_mode: AuthMode,
    email: ?[]const u8,
    plan: ?PlanType,
    api_key_fingerprint: ?[]const u8,
) ![]u8 {
    switch (auth_mode) {
        .chatgpt => {
            const normalized_email = email orelse return error.MissingEmail;
            const resolved_plan = plan orelse @panic("chatgpt auth missing plan");
            return try std.fmt.allocPrint(allocator, "chatgpt:{s}#{s}", .{ normalized_email, planTypeString(resolved_plan) });
        },
        .apikey => {
            const fingerprint = api_key_fingerprint orelse return error.MissingApiKeyFingerprint;
            return try std.fmt.allocPrint(allocator, "apikey:{s}", .{fingerprint});
        },
    }
}

pub fn accountIdFromAuthInfoAlloc(allocator: std.mem.Allocator, info: *const auth.AuthInfo) ![]u8 {
    return accountIdFromPartsAlloc(allocator, info.auth_mode, info.email, info.plan, info.api_key_fingerprint);
}

fn oldEmailFileKeyAlloc(allocator: std.mem.Allocator, email: []const u8) ![]u8 {
    return base64UrlKey(allocator, email);
}

fn accountFileKeyAlloc(allocator: std.mem.Allocator, account_id: []const u8) ![]u8 {
    return base64UrlKey(allocator, account_id);
}

fn legacyAccountAuthPath(allocator: std.mem.Allocator, codex_home: []const u8, email: []const u8) ![]u8 {
    const key = try oldEmailFileKeyAlloc(allocator, email);
    defer allocator.free(key);
    const filename = try std.mem.concat(allocator, u8, &[_][]const u8{ key, ".auth.json" });
    defer allocator.free(filename);
    return try std.fs.path.join(allocator, &[_][]const u8{ codex_home, "accounts", filename });
}

pub fn accountAuthPath(allocator: std.mem.Allocator, codex_home: []const u8, account_id: []const u8) ![]u8 {
    const key = try accountFileKeyAlloc(allocator, account_id);
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

fn readFileIfExists(allocator: std.mem.Allocator, path: []const u8) !?[]u8 {
    var file = std.fs.cwd().openFile(path, .{}) catch |err| {
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

fn makeBackupPath(allocator: std.mem.Allocator, dir: []const u8, base_name: []const u8) ![]u8 {
    const ts_ms = std.time.milliTimestamp();
    const base = try std.fmt.allocPrint(allocator, "{s}.bak.{d}", .{ base_name, ts_ms });
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
        dir_handle.deleteFile(list.items[i].name) catch {};
    }
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

    if (try fileEqualsBytes(allocator, current_registry_path, new_registry_bytes)) return;

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

pub fn importAuthPath(
    allocator: std.mem.Allocator,
    codex_home: []const u8,
    reg: *Registry,
    auth_path: []const u8,
    explicit_alias: ?[]const u8,
) !ImportSummary {
    const stat = try std.fs.cwd().statFile(auth_path);
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
    const info = try auth.parseAuthInfo(allocator, auth_file);
    defer info.deinit(allocator);

    const alias = explicit_alias orelse "";
    const record = try accountFromAuth(allocator, alias, &info);
    errdefer freeAccountRecord(allocator, &record);

    const dest = try accountAuthPath(allocator, codex_home, record.account_id);
    defer allocator.free(dest);

    try ensureAccountsDir(allocator, codex_home);
    try copyFile(auth_file, dest);
    upsertAccount(allocator, reg, record);
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
        if (!std.mem.endsWith(u8, entry.name, ".json")) continue;
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

fn importFileNameLessThan(_: void, a: []u8, b: []u8) bool {
    return std.mem.lessThan(u8, a, b);
}

pub fn findAccountIndexById(reg: *Registry, account_id: []const u8) ?usize {
    for (reg.accounts.items, 0..) |rec, i| {
        if (std.mem.eql(u8, rec.account_id, account_id)) return i;
    }
    return null;
}

pub fn setActiveAccount(allocator: std.mem.Allocator, reg: *Registry, account_id: []const u8) !void {
    if (reg.active_account_id) |k| {
        if (std.mem.eql(u8, k, account_id)) return;
        allocator.free(k);
    }
    reg.active_account_id = try allocator.dupe(u8, account_id);
    const now = std.time.timestamp();
    for (reg.accounts.items) |*rec| {
        if (std.mem.eql(u8, rec.account_id, account_id)) {
            rec.last_used_at = now;
            break;
        }
    }
}

pub fn updateUsage(allocator: std.mem.Allocator, reg: *Registry, account_id: []const u8, snapshot: RateLimitSnapshot) void {
    const now = std.time.timestamp();
    for (reg.accounts.items) |*rec| {
        if (std.mem.eql(u8, rec.account_id, account_id)) {
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
    if (reg.accounts.items.len == 0) return try autoImportActiveAuth(allocator, codex_home, reg);

    const auth_path = try activeAuthPath(allocator, codex_home);
    defer allocator.free(auth_path);

    const auth_bytes_opt = try readFileIfExists(allocator, auth_path);
    if (auth_bytes_opt == null) return false;
    const auth_bytes = auth_bytes_opt.?;
    defer allocator.free(auth_bytes);

    const info = try auth.parseAuthInfo(allocator, auth_path);
    defer info.deinit(allocator);
    const account_id = try accountIdFromAuthInfoAlloc(allocator, &info);
    defer allocator.free(account_id);

    const matched_index = findAccountIndexById(reg, account_id);
    if (matched_index == null) {
        const record = try accountFromAuth(allocator, "", &info);
        errdefer freeAccountRecord(allocator, &record);
        const dest = try accountAuthPath(allocator, codex_home, record.account_id);
        defer allocator.free(dest);

        try ensureAccountsDir(allocator, codex_home);
        try copyFile(auth_path, dest);
        upsertAccount(allocator, reg, record);
        try setActiveAccount(allocator, reg, account_id);
        return true;
    }

    const idx = matched_index.?;
    const rec_account_id = reg.accounts.items[idx].account_id;
    var changed = false;
    if (reg.active_account_id) |k| {
        if (!std.mem.eql(u8, k, rec_account_id)) changed = true;
    } else {
        changed = true;
    }

    reg.accounts.items[idx].plan = info.plan;
    reg.accounts.items[idx].auth_mode = info.auth_mode;
    if (info.api_key_fingerprint) |fp| {
        if (reg.accounts.items[idx].api_key_fingerprint) |existing| allocator.free(existing);
        reg.accounts.items[idx].api_key_fingerprint = try allocator.dupe(u8, fp);
    }

    const dest = try accountAuthPath(allocator, codex_home, rec_account_id);
    defer allocator.free(dest);
    if (!(try fileEqualsBytes(allocator, dest, auth_bytes))) {
        try copyFile(auth_path, dest);
    }

    try setActiveAccount(allocator, reg, rec_account_id);
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

    if (reg.active_account_id) |key| {
        var active_removed = false;
        for (reg.accounts.items, 0..) |rec, i| {
            if (removed[i] and std.mem.eql(u8, rec.account_id, key)) {
                active_removed = true;
                break;
            }
        }
        if (active_removed) {
            allocator.free(key);
            reg.active_account_id = null;
        }
    }

    var write_idx: usize = 0;
    for (reg.accounts.items, 0..) |*rec, i| {
        if (removed[i]) {
            const path = try accountAuthPath(allocator, codex_home, rec.account_id);
            defer allocator.free(path);
            std.fs.cwd().deleteFile(path) catch {};
            freeAccountRecord(allocator, rec);
            continue;
        }
        if (write_idx != i) reg.accounts.items[write_idx] = rec.*;
        write_idx += 1;
    }
    reg.accounts.items.len = write_idx;
}

pub fn selectBestAccountIndexByUsage(reg: *Registry) ?usize {
    if (reg.accounts.items.len == 0) return null;
    var best_idx: ?usize = null;
    var best_score: i64 = -2;
    var best_seen: i64 = -1;
    for (reg.accounts.items, 0..) |rec, i| {
        const score = usageScore(rec.last_usage);
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

fn usageScore(usage: ?RateLimitSnapshot) i64 {
    const rate_5h = resolveRateWindow(usage, 300, true);
    const rate_week = resolveRateWindow(usage, 10080, false);
    const rem_5h = remainingPercent(rate_5h);
    const rem_week = remainingPercent(rate_week);
    if (rem_5h != null and rem_week != null) return @min(rem_5h.?, rem_week.?);
    if (rem_5h != null) return rem_5h.?;
    if (rem_week != null) return rem_week.?;
    return -1;
}

fn remainingPercent(window: ?RateLimitWindow) ?i64 {
    if (window == null) return null;
    const remaining = 100.0 - window.?.used_percent;
    if (remaining <= 0.0) return 0;
    if (remaining >= 100.0) return 100;
    return @as(i64, @intFromFloat(remaining));
}

fn resolveRateWindow(usage: ?RateLimitSnapshot, minutes: i64, fallback_primary: bool) ?RateLimitWindow {
    if (usage == null) return null;
    if (usage.?.primary) |p| {
        if (p.window_minutes != null and p.window_minutes.? == minutes) return p;
    }
    if (usage.?.secondary) |s| {
        if (s.window_minutes != null and s.window_minutes.? == minutes) return s;
    }
    return if (fallback_primary) usage.?.primary else usage.?.secondary;
}

pub fn accountFromAuth(
    allocator: std.mem.Allocator,
    alias: []const u8,
    info: *const auth.AuthInfo,
) !AccountRecord {
    const account_id = try accountIdFromAuthInfoAlloc(allocator, info);
    errdefer allocator.free(account_id);

    return AccountRecord{
        .account_id = account_id,
        .email = if (info.email) |email| try allocator.dupe(u8, email) else try allocator.dupe(u8, ""),
        .alias = try allocator.dupe(u8, alias),
        .plan = info.plan,
        .api_key_fingerprint = if (info.api_key_fingerprint) |fp| try allocator.dupe(u8, fp) else null,
        .auth_mode = info.auth_mode,
        .created_at = std.time.timestamp(),
        .last_used_at = null,
        .last_usage = null,
        .last_usage_at = null,
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

    allocator.free(incoming.account_id);
    allocator.free(incoming.email);
    if (dest.plan == null) dest.plan = incoming.plan;
    if (dest.auth_mode == null) dest.auth_mode = incoming.auth_mode;
    if (dest.alias.len == 0 and incoming.alias.len != 0) {
        allocator.free(dest.alias);
        dest.alias = incoming.alias;
    } else {
        allocator.free(incoming.alias);
    }
    if (dest.api_key_fingerprint == null and incoming.api_key_fingerprint != null) {
        dest.api_key_fingerprint = incoming.api_key_fingerprint;
    } else if (incoming.api_key_fingerprint) |fp| {
        allocator.free(fp);
    }
    if (incoming.last_usage) |*u| {
        if (u.credits) |*c| {
            if (c.balance) |b| allocator.free(b);
        }
    }
}

pub fn upsertAccount(allocator: std.mem.Allocator, reg: *Registry, record: AccountRecord) void {
    for (reg.accounts.items) |*rec| {
        if (std.mem.eql(u8, rec.account_id, record.account_id)) {
            mergeAccountRecord(allocator, rec, record);
            return;
        }
    }
    reg.accounts.append(allocator, record) catch {};
}

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

    if (obj.get("plan_type")) |p| switch (p) {
        .string => |s| snap.plan_type = parsePlanType(s),
        else => {},
    };
    if (obj.get("primary")) |p| snap.primary = parseWindow(p);
    if (obj.get("secondary")) |p| snap.secondary = parseWindow(p);
    if (obj.get("credits")) |c| snap.credits = parseCredits(allocator, c);
    return snap;
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
    if (obj.get("balance")) |b| switch (b) {
        .string => |s| balance = allocator.dupe(u8, s) catch null,
        else => {},
    };
    return CreditsSnapshot{ .has_credits = has_credits, .unlimited = unlimited, .balance = balance };
}

fn readInt(v: ?std.json.Value) ?i64 {
    if (v == null) return null;
    return switch (v.?) {
        .integer => |i| i,
        else => null,
    };
}

fn buildMigratedRecord(
    allocator: std.mem.Allocator,
    codex_home: []const u8,
    email: []const u8,
    alias: []const u8,
    plan: ?PlanType,
    auth_mode: ?AuthMode,
    api_key_fingerprint: ?[]const u8,
    created_at: i64,
    last_used_at: ?i64,
    last_usage: ?RateLimitSnapshot,
    last_usage_at: ?i64,
) !AccountRecord {
    const normalized_email = try normalizeEmailAlloc(allocator, email);
    var resolved_plan = plan;
    var resolved_mode = auth_mode;
    var resolved_fingerprint: ?[]u8 = if (api_key_fingerprint) |fp| try allocator.dupe(u8, fp) else null;

    if (resolved_mode == null or
        ((resolved_mode != null and resolved_mode.? == .chatgpt) and resolved_plan == null) or
        ((resolved_mode != null and resolved_mode.? == .apikey) and resolved_fingerprint == null))
    {
        const legacy_path = try legacyAccountAuthPath(allocator, codex_home, normalized_email);
        defer allocator.free(legacy_path);
        const info = try auth.parseAuthInfo(allocator, legacy_path);
        defer info.deinit(allocator);
        if (resolved_mode == null) resolved_mode = info.auth_mode;
        if (resolved_mode != null and resolved_mode.? == .chatgpt and resolved_plan == null) resolved_plan = info.plan;
        if (resolved_mode != null and resolved_mode.? == .apikey and resolved_fingerprint == null and info.api_key_fingerprint != null) {
            resolved_fingerprint = try allocator.dupe(u8, info.api_key_fingerprint.?);
        }
    }

    const account_id = try accountIdFromPartsAlloc(allocator, resolved_mode orelse .chatgpt, normalized_email, resolved_plan, resolved_fingerprint);

    return AccountRecord{
        .account_id = account_id,
        .email = normalized_email,
        .alias = try allocator.dupe(u8, alias),
        .plan = resolved_plan,
        .api_key_fingerprint = resolved_fingerprint,
        .auth_mode = resolved_mode,
        .created_at = created_at,
        .last_used_at = last_used_at,
        .last_usage = last_usage,
        .last_usage_at = last_usage_at,
    };
}

fn maybeMigrateLegacyAuthPath(allocator: std.mem.Allocator, codex_home: []const u8, rec: *const AccountRecord) !void {
    const new_path = try accountAuthPath(allocator, codex_home, rec.account_id);
    defer allocator.free(new_path);
    if (std.fs.cwd().openFile(new_path, .{})) |file| {
        file.close();
        return;
    } else |_| {}

    if (rec.email.len == 0) return;
    const old_path = try legacyAccountAuthPath(allocator, codex_home, rec.email);
    defer allocator.free(old_path);
    if (std.fs.cwd().openFile(old_path, .{})) |file| {
        file.close();
    } else |_| {
        return;
    }
    try ensureAccountsDir(allocator, codex_home);
    try copyFile(old_path, new_path);
    std.fs.cwd().deleteFile(old_path) catch {};
}

fn loadRegistryVAny(allocator: std.mem.Allocator, codex_home: []const u8, root_obj: std.json.ObjectMap) !Registry {
    var reg = Registry{ .version = registry_version, .active_account_id = null, .accounts = std.ArrayList(AccountRecord).empty };
    var legacy_active_email: ?[]u8 = null;
    defer if (legacy_active_email) |v| allocator.free(v);

    if (root_obj.get("active_account_id")) |v| switch (v) {
        .string => |s| reg.active_account_id = try allocator.dupe(u8, s),
        else => {},
    };
    if (reg.active_account_id == null) {
        if (root_obj.get("active_email")) |v| switch (v) {
            .string => |s| legacy_active_email = try normalizeEmailAlloc(allocator, s),
            else => {},
        };
    }

    if (root_obj.get("accounts")) |v| switch (v) {
        .array => |arr| {
            for (arr.items) |item| {
                const obj = switch (item) {
                    .object => |o| o,
                    else => continue,
                };

                const alias_val = obj.get("alias") orelse continue;
                const alias = switch (alias_val) {
                    .string => |s| s,
                    else => continue,
                };
                const email = if (obj.get("email")) |email_val| switch (email_val) {
                    .string => |s| s,
                    else => "",
                } else "";

                const account_id = if (obj.get("account_id")) |id_val| switch (id_val) {
                    .string => |s| s,
                    else => null,
                } else null;
                const plan = if (obj.get("plan")) |p| switch (p) {
                    .string => |s| parsePlanType(s),
                    else => null,
                } else null;
                const auth_mode = if (obj.get("auth_mode")) |m| switch (m) {
                    .string => |s| parseAuthMode(s),
                    else => null,
                } else null;
                const api_key_fingerprint = if (obj.get("api_key_fingerprint")) |fp| switch (fp) {
                    .string => |s| s,
                    else => null,
                } else null;

                var rec = if (account_id) |id|
                    AccountRecord{
                        .account_id = try allocator.dupe(u8, id),
                        .email = try normalizeEmailAlloc(allocator, email),
                        .alias = try allocator.dupe(u8, alias),
                        .plan = plan,
                        .api_key_fingerprint = if (api_key_fingerprint) |fp| try allocator.dupe(u8, fp) else null,
                        .auth_mode = auth_mode,
                        .created_at = readInt(obj.get("created_at")) orelse std.time.timestamp(),
                        .last_used_at = readInt(obj.get("last_used_at")),
                        .last_usage = null,
                        .last_usage_at = readInt(obj.get("last_usage_at")),
                    }
                else
                    try buildMigratedRecord(
                        allocator,
                        codex_home,
                        email,
                        alias,
                        plan,
                        auth_mode,
                        api_key_fingerprint,
                        readInt(obj.get("created_at")) orelse std.time.timestamp(),
                        readInt(obj.get("last_used_at")),
                        null,
                        readInt(obj.get("last_usage_at")),
                    );

                if (obj.get("last_usage")) |u| rec.last_usage = parseUsage(allocator, u);
                upsertAccount(allocator, &reg, rec);
            }
        },
        else => {},
    };

    for (reg.accounts.items) |*rec| {
        try maybeMigrateLegacyAuthPath(allocator, codex_home, rec);
    }

    if (reg.active_account_id == null and legacy_active_email != null) {
        for (reg.accounts.items) |rec| {
            if (std.mem.eql(u8, rec.email, legacy_active_email.?)) {
                reg.active_account_id = try allocator.dupe(u8, rec.account_id);
                break;
            }
        }
    }

    return reg;
}

pub fn loadRegistry(allocator: std.mem.Allocator, codex_home: []const u8) !Registry {
    const path = try registryPath(allocator, codex_home);
    defer allocator.free(path);

    var file = std.fs.cwd().openFile(path, .{}) catch |err| {
        if (err == error.FileNotFound) {
            return Registry{ .version = registry_version, .active_account_id = null, .accounts = std.ArrayList(AccountRecord).empty };
        }
        return err;
    };
    defer file.close();

    const data = try file.readToEndAlloc(allocator, 10 * 1024 * 1024);
    defer allocator.free(data);

    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, data, .{});
    defer parsed.deinit();

    const root_obj = switch (parsed.value) {
        .object => |o| o,
        else => return Registry{ .version = registry_version, .active_account_id = null, .accounts = std.ArrayList(AccountRecord).empty },
    };
    return loadRegistryVAny(allocator, codex_home, root_obj);
}

pub fn saveRegistry(allocator: std.mem.Allocator, codex_home: []const u8, reg: *Registry) !void {
    reg.version = registry_version;
    try ensureAccountsDir(allocator, codex_home);
    const path = try registryPath(allocator, codex_home);
    defer allocator.free(path);

    const out = RegistryOut{
        .version = registry_version,
        .active_account_id = reg.active_account_id,
        .accounts = reg.accounts.items,
    };
    var aw: std.Io.Writer.Allocating = .init(allocator);
    defer aw.deinit();
    try std.json.Stringify.value(out, .{ .whitespace = .indent_2 }, &aw.writer);
    const data = aw.written();

    if (try fileEqualsBytes(allocator, path, data)) return;
    try backupRegistryIfChanged(allocator, codex_home, path, data);

    var file = try std.fs.cwd().createFile(path, .{ .truncate = true });
    defer file.close();
    try file.writeAll(data);
}

const RegistryOut = struct {
    version: u32,
    active_account_id: ?[]const u8,
    accounts: []const AccountRecord,
};

pub fn refreshAccountsFromAuth(allocator: std.mem.Allocator, codex_home: []const u8, reg: *Registry) !void {
    for (reg.accounts.items) |*rec| {
        const path = try accountAuthPath(allocator, codex_home, rec.account_id);
        defer allocator.free(path);
        if (std.fs.cwd().openFile(path, .{})) |file| {
            file.close();
        } else |_| {
            continue;
        }
        const info = try auth.parseAuthInfo(allocator, path);
        defer info.deinit(allocator);
        const parsed_id = try accountIdFromAuthInfoAlloc(allocator, &info);
        defer allocator.free(parsed_id);
        if (!std.mem.eql(u8, parsed_id, rec.account_id)) {
            std.log.warn("auth file identity mismatch for {s}; skipping refresh", .{rec.account_id});
            continue;
        }
        rec.plan = info.plan;
        rec.auth_mode = info.auth_mode;
        if (info.api_key_fingerprint) |fp| {
            if (rec.api_key_fingerprint) |existing| allocator.free(existing);
            rec.api_key_fingerprint = try allocator.dupe(u8, fp);
        }
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

    const info = try auth.parseAuthInfo(allocator, auth_path);
    defer info.deinit(allocator);
    const record = try accountFromAuth(allocator, "", &info);
    errdefer freeAccountRecord(allocator, &record);

    const dest = try accountAuthPath(allocator, codex_home, record.account_id);
    defer allocator.free(dest);

    try ensureAccountsDir(allocator, codex_home);
    try copyFile(auth_path, dest);
    upsertAccount(allocator, reg, record);
    try setActiveAccount(allocator, reg, reg.accounts.items[0].account_id);
    return true;
}

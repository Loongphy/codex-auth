const std = @import("std");
const c = @cImport({
    @cInclude("time.h");
});
const auth = @import("auth.zig");
const auto = @import("auto.zig");
const io_util = @import("io_util.zig");
const registry = @import("registry.zig");

pub const latest_schema_version: u32 = registry.current_schema_version;
pub const Mode = enum { automatic, explicit };

pub const Result = struct {
    migrated: bool,
    current_version: u32,
};

const LegacyAccountRecord = struct {
    email: []u8,
    alias: []u8,
    plan: ?registry.PlanType,
    auth_mode: ?registry.AuthMode,
    created_at: i64,
    last_used_at: ?i64,
    last_usage: ?registry.RateLimitSnapshot,
    last_usage_at: ?i64,
};

const MigrationPlan = struct {
    reg: registry.Registry,
    old_files: std.ArrayList([]u8),
    backup_path: []u8,
    auto_enabled: bool,

    fn deinit(self: *MigrationPlan, allocator: std.mem.Allocator) void {
        self.reg.deinit(allocator);
        for (self.old_files.items) |path| allocator.free(path);
        self.old_files.deinit(allocator);
        allocator.free(self.backup_path);
    }
};

pub fn ensureMigrated(
    allocator: std.mem.Allocator,
    codex_home: []const u8,
    mode: Mode,
) !Result {
    var stdout: io_util.Stdout = undefined;
    stdout.init();
    return ensureMigratedWithWriter(allocator, codex_home, mode, stdout.out());
}

pub fn ensureMigratedWithWriter(
    allocator: std.mem.Allocator,
    codex_home: []const u8,
    mode: Mode,
    out: *std.Io.Writer,
) !Result {
    const detected_version = try detectSchemaVersion(allocator, codex_home);

    if (detected_version > latest_schema_version) return error.UnsupportedSchemaVersion;

    if (detected_version >= latest_schema_version) {
        if (mode == .explicit) {
            try out.print("当前已是最新版本：v{d}\n", .{latest_schema_version});
            try out.flush();
        }
        return .{ .migrated = false, .current_version = detected_version };
    }

    try out.print("正在迁移到新版本：v{d} -> v{d}\n", .{ detected_version, latest_schema_version });

    var current = detected_version;
    while (current < latest_schema_version) {
        switch (current) {
            2 => {
                try out.writeAll("迁移 v2 -> v3 中……\n");
                const backup_path = try migrateV2ToV3(allocator, codex_home, out);
                defer allocator.free(backup_path);
                try out.print("备份当前数据到：{s}\n", .{backup_path});
                current = 3;
            },
            else => return error.UnsupportedSchemaMigration,
        }
    }

    try out.print("迁移完成，当前版本：v{d}\n", .{latest_schema_version});
    try out.flush();
    return .{ .migrated = true, .current_version = latest_schema_version };
}

fn detectSchemaVersion(allocator: std.mem.Allocator, codex_home: []const u8) !u32 {
    const path = try registry.registryPath(allocator, codex_home);
    defer allocator.free(path);

    var file = std.fs.cwd().openFile(path, .{}) catch |err| {
        if (err == error.FileNotFound) return latest_schema_version;
        return err;
    };
    defer file.close();

    const data = try file.readToEndAlloc(allocator, 10 * 1024 * 1024);
    defer allocator.free(data);

    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, data, .{});
    defer parsed.deinit();
    const root_obj = switch (parsed.value) {
        .object => |o| o,
        else => return latest_schema_version,
    };

    if (readInt(root_obj.get("version"))) |version| {
        return @as(u32, @intCast(version));
    }
    if (root_obj.get("active_email") != null) return 2;
    return latest_schema_version;
}

fn migrateV2ToV3(allocator: std.mem.Allocator, codex_home: []const u8, out: *std.Io.Writer) ![]u8 {
    var plan = try buildV2ToV3Plan(allocator, codex_home, out);
    defer plan.deinit(allocator);

    if (plan.auto_enabled) {
        try auto.stopServiceForMigration(allocator, codex_home);
    }

    try writeNewAccountFiles(allocator, codex_home, &plan.reg);
    errdefer cleanupNewAccountFiles(allocator, codex_home, &plan.reg);

    try registry.saveRegistry(allocator, codex_home, &plan.reg);
    cleanupOldLegacyFiles(&plan);

    if (plan.auto_enabled) {
        try auto.startServiceForMigration(allocator, codex_home);
    }

    return try allocator.dupe(u8, plan.backup_path);
}

fn buildV2ToV3Plan(allocator: std.mem.Allocator, codex_home: []const u8, out: *std.Io.Writer) !MigrationPlan {
    const registry_path = try registry.registryPath(allocator, codex_home);
    defer allocator.free(registry_path);

    var file = try std.fs.cwd().openFile(registry_path, .{});
    defer file.close();

    const data = try file.readToEndAlloc(allocator, 10 * 1024 * 1024);
    defer allocator.free(data);

    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, data, .{});
    defer parsed.deinit();
    const root_obj = switch (parsed.value) {
        .object => |o| o,
        else => return error.InvalidRegistryJson,
    };

    var reg = registry.Registry{
        .version = registry.current_schema_version,
        .active_account_id = null,
        .auto_switch = registry.defaultAutoSwitchConfig(),
        .accounts = std.ArrayList(registry.AccountRecord).empty,
    };
    errdefer reg.deinit(allocator);

    var old_files = std.ArrayList([]u8).empty;
    errdefer {
        for (old_files.items) |path| allocator.free(path);
        old_files.deinit(allocator);
    }

    if (root_obj.get("auto_switch")) |v| {
        parseAutoSwitch(allocator, &reg.auto_switch, v);
    }
    const auto_enabled = reg.auto_switch.enabled;

    const backup_path = try backupSchemaData(allocator, codex_home, 2);
    errdefer allocator.free(backup_path);

    const active_email = if (root_obj.get("active_email")) |v| switch (v) {
        .string => |s| try normalizeEmailAlloc(allocator, s),
        else => null,
    } else null;
    defer if (active_email) |email| allocator.free(email);

    if (root_obj.get("accounts")) |v| switch (v) {
        .array => |arr| {
            for (arr.items) |item| {
                const obj = switch (item) {
                    .object => |o| o,
                    else => {
                        try reportSkippedLegacyAccount(out, "<unknown>", error.InvalidRegistryJson);
                        continue;
                    },
                };
                const legacy_label = legacyAccountLabel(obj);
                var legacy = parseLegacyAccountRecord(allocator, obj) catch |err| {
                    try reportSkippedLegacyAccount(out, legacy_label, err);
                    continue;
                };
                defer freeLegacyAccountRecord(allocator, &legacy);
                _ = try appendMigratedLegacyAccount(
                    allocator,
                    codex_home,
                    &reg,
                    &old_files,
                    active_email,
                    &legacy,
                    out,
                );
            }
        },
        else => {},
    };

    return .{
        .reg = reg,
        .old_files = old_files,
        .backup_path = backup_path,
        .auto_enabled = auto_enabled,
    };
}

fn appendMigratedLegacyAccount(
    allocator: std.mem.Allocator,
    codex_home: []const u8,
    reg: *registry.Registry,
    old_files: *std.ArrayList([]u8),
    active_email: ?[]const u8,
    legacy: *LegacyAccountRecord,
    out: *std.Io.Writer,
) !bool {
    const old_path = try legacyAccountAuthPath(allocator, codex_home, legacy.email);
    errdefer allocator.free(old_path);

    const info = auth.parseAuthInfo(allocator, old_path) catch |err| {
        try reportSkippedLegacyAccount(out, legacy.email, err);
        return false;
    };
    defer info.deinit(allocator);

    const email = info.email orelse {
        try reportSkippedLegacyAccount(out, legacy.email, error.MissingEmail);
        return false;
    };
    const account_id = info.account_id orelse {
        try reportSkippedLegacyAccount(out, legacy.email, error.MissingAccountId);
        return false;
    };
    if (!std.mem.eql(u8, email, legacy.email)) {
        try reportSkippedLegacyAccount(out, legacy.email, error.EmailMismatch);
        return false;
    }

    const rec = registry.AccountRecord{
        .account_id = try allocator.dupe(u8, account_id),
        .email = try allocator.dupe(u8, legacy.email),
        .alias = try allocator.dupe(u8, legacy.alias),
        .plan = info.plan orelse legacy.plan,
        .auth_mode = info.auth_mode,
        .created_at = legacy.created_at,
        .last_used_at = legacy.last_used_at,
        .last_usage = legacy.last_usage,
        .last_usage_at = legacy.last_usage_at,
    };
    legacy.last_usage = null;

    registry.upsertAccount(allocator, reg, rec);
    try old_files.append(allocator, old_path);

    if (active_email) |expected| {
        if (reg.active_account_id == null and std.mem.eql(u8, expected, legacy.email)) {
            try registry.setActiveAccount(allocator, reg, account_id);
        }
    }
    return true;
}

fn legacyAccountLabel(obj: std.json.ObjectMap) []const u8 {
    if (obj.get("email")) |v| switch (v) {
        .string => |s| return s,
        else => {},
    };
    return "<unknown>";
}

fn reportSkippedLegacyAccount(out: *std.Io.Writer, label: []const u8, err: anyerror) !void {
    try out.print("跳过损坏的旧账号 {s}: {s}\n", .{ label, @errorName(err) });
}

fn writeNewAccountFiles(
    allocator: std.mem.Allocator,
    codex_home: []const u8,
    reg: *registry.Registry,
) !void {
    try registry.ensureAccountsDir(allocator, codex_home);
    for (reg.accounts.items) |rec| {
        const old_path = try legacyAccountAuthPath(allocator, codex_home, rec.email);
        defer allocator.free(old_path);
        const new_path = try registry.accountAuthPath(allocator, codex_home, rec.account_id);
        defer allocator.free(new_path);
        if (!try filesEqual(allocator, old_path, new_path)) {
            try copyFileEnsuringParent(old_path, new_path);
        }
    }
}

fn cleanupNewAccountFiles(
    allocator: std.mem.Allocator,
    codex_home: []const u8,
    reg: *registry.Registry,
) void {
    for (reg.accounts.items) |rec| {
        const new_path = registry.accountAuthPath(allocator, codex_home, rec.account_id) catch continue;
        defer allocator.free(new_path);
        std.fs.cwd().deleteFile(new_path) catch {};
    }
}

fn cleanupOldLegacyFiles(plan: *MigrationPlan) void {
    for (plan.old_files.items) |path| {
        std.fs.cwd().deleteFile(path) catch {};
    }
}

fn backupSchemaData(
    allocator: std.mem.Allocator,
    codex_home: []const u8,
    schema_version: u32,
) ![]u8 {
    const label = try std.fmt.allocPrint(allocator, "v{d}", .{schema_version});
    defer allocator.free(label);
    return createAccountsBackupWithLabel(allocator, codex_home, label);
}

fn createAccountsBackupWithLabel(
    allocator: std.mem.Allocator,
    codex_home: []const u8,
    label: []const u8,
) ![]u8 {
    const timestamp = try formatBackupTimestampAlloc(allocator, std.time.timestamp());
    defer allocator.free(timestamp);

    const backup_path = try std.fs.path.join(allocator, &[_][]const u8{
        codex_home,
        "accounts",
        "backups",
        label,
        timestamp,
    });
    errdefer allocator.free(backup_path);

    const version_dir = std.fs.path.dirname(backup_path).?;
    try std.fs.cwd().makePath(version_dir);

    try registry.ensureAccountsDir(allocator, codex_home);
    const accounts_dir = try std.fs.path.join(allocator, &[_][]const u8{ codex_home, "accounts" });
    defer allocator.free(accounts_dir);
    try copyDirRecursiveExcludingBackups(allocator, accounts_dir, backup_path);
    return backup_path;
}

fn isBackupsEntryPath(entry_path: []const u8) bool {
    if (std.mem.eql(u8, entry_path, "backups")) return true;
    return entry_path.len > "backups".len and
        std.mem.startsWith(u8, entry_path, "backups") and
        entry_path["backups".len] == std.fs.path.sep;
}

fn copyDirRecursiveExcludingBackups(allocator: std.mem.Allocator, src_path: []const u8, dest_path: []const u8) !void {
    var src_dir = try std.fs.cwd().openDir(src_path, .{ .iterate = true });
    defer src_dir.close();

    try std.fs.cwd().makePath(dest_path);

    var walker = try src_dir.walk(allocator);
    defer walker.deinit();

    while (try walker.next()) |entry| {
        if (isBackupsEntryPath(entry.path)) continue;

        const dest_entry_path = try std.fs.path.join(allocator, &[_][]const u8{ dest_path, entry.path });
        defer allocator.free(dest_entry_path);

        switch (entry.kind) {
            .directory => try std.fs.cwd().makePath(dest_entry_path),
            .file, .sym_link => {
                if (std.fs.path.dirname(dest_entry_path)) |parent| {
                    try std.fs.cwd().makePath(parent);
                }
                try src_dir.copyFile(entry.path, std.fs.cwd(), dest_entry_path, .{});
            },
            else => {},
        }
    }
}

fn legacyAccountAuthPath(allocator: std.mem.Allocator, codex_home: []const u8, email: []const u8) ![]u8 {
    const key = try base64UrlNoPadEncode(allocator, email);
    defer allocator.free(key);
    const filename = try std.mem.concat(allocator, u8, &[_][]const u8{ key, ".auth.json" });
    defer allocator.free(filename);
    return try std.fs.path.join(allocator, &[_][]const u8{ codex_home, "accounts", filename });
}

fn base64UrlNoPadEncode(allocator: std.mem.Allocator, input: []const u8) ![]u8 {
    const encoder = std.base64.url_safe_no_pad.Encoder;
    const out_len = encoder.calcSize(input.len);
    const buf = try allocator.alloc(u8, out_len);
    _ = encoder.encode(buf, input);
    return buf;
}

fn copyFileEnsuringParent(src: []const u8, dest: []const u8) !void {
    if (std.fs.path.dirname(dest)) |parent| {
        try std.fs.cwd().makePath(parent);
    }
    try std.fs.cwd().copyFile(src, std.fs.cwd(), dest, .{});
}

fn filesEqual(allocator: std.mem.Allocator, a_path: []const u8, b_path: []const u8) !bool {
    const a = try readFileIfExists(allocator, a_path);
    defer if (a) |buf| allocator.free(buf);
    const b = try readFileIfExists(allocator, b_path);
    defer if (b) |buf| allocator.free(buf);
    if (a == null or b == null) return false;
    return std.mem.eql(u8, a.?, b.?);
}

fn readFileIfExists(allocator: std.mem.Allocator, path: []const u8) !?[]u8 {
    var file = std.fs.cwd().openFile(path, .{}) catch |err| {
        if (err == error.FileNotFound) return null;
        return err;
    };
    defer file.close();
    return try file.readToEndAlloc(allocator, 10 * 1024 * 1024);
}

fn normalizeEmailAlloc(allocator: std.mem.Allocator, email: []const u8) ![]u8 {
    var buf = try allocator.alloc(u8, email.len);
    for (email, 0..) |ch, i| {
        buf[i] = std.ascii.toLower(ch);
    }
    return buf;
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

fn freeLegacyAccountRecord(allocator: std.mem.Allocator, rec: *LegacyAccountRecord) void {
    allocator.free(rec.email);
    allocator.free(rec.alias);
    if (rec.last_usage) |*u| {
        registry.freeRateLimitSnapshot(allocator, u);
    }
}

fn parseAutoSwitch(allocator: std.mem.Allocator, cfg: *registry.AutoSwitchConfig, v: std.json.Value) void {
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
    if (obj.get("last_rollout")) |last_rollout| {
        parseRolloutSignature(allocator, &cfg.last_rollout, last_rollout);
    }
}

fn parseRolloutSignature(allocator: std.mem.Allocator, sig: *registry.RolloutSignature, v: std.json.Value) void {
    const obj = switch (v) {
        .object => |o| o,
        else => return,
    };
    if (obj.get("path")) |path_val| {
        switch (path_val) {
            .string => |path| sig.path = allocator.dupe(u8, path) catch null,
            else => {},
        }
    }
    sig.mtime = readInt(obj.get("mtime"));
}

fn parseUsage(allocator: std.mem.Allocator, v: std.json.Value) ?registry.RateLimitSnapshot {
    const obj = switch (v) {
        .object => |o| o,
        else => return null,
    };
    var snap = registry.RateLimitSnapshot{ .primary = null, .secondary = null, .credits = null, .plan_type = null };

    if (obj.get("plan_type")) |p| {
        switch (p) {
            .string => |s| snap.plan_type = parsePlanType(s),
            else => {},
        }
    }
    if (obj.get("primary")) |p| snap.primary = parseWindow(p);
    if (obj.get("secondary")) |p| snap.secondary = parseWindow(p);
    if (obj.get("credits")) |credits_val| snap.credits = parseCredits(allocator, credits_val);
    return snap;
}

fn parseWindow(v: std.json.Value) ?registry.RateLimitWindow {
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
    return .{ .used_percent = used_percent, .window_minutes = window_minutes, .resets_at = resets_at };
}

fn parseCredits(allocator: std.mem.Allocator, v: std.json.Value) ?registry.CreditsSnapshot {
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
    return .{ .has_credits = has_credits, .unlimited = unlimited, .balance = balance };
}

fn parsePlanType(s: []const u8) ?registry.PlanType {
    if (std.mem.eql(u8, s, "free")) return .free;
    if (std.mem.eql(u8, s, "plus")) return .plus;
    if (std.mem.eql(u8, s, "pro")) return .pro;
    if (std.mem.eql(u8, s, "team")) return .team;
    if (std.mem.eql(u8, s, "business")) return .business;
    if (std.mem.eql(u8, s, "enterprise")) return .enterprise;
    if (std.mem.eql(u8, s, "edu")) return .edu;
    return .unknown;
}

fn parseAuthMode(s: []const u8) ?registry.AuthMode {
    if (std.mem.eql(u8, s, "chatgpt")) return .chatgpt;
    if (std.mem.eql(u8, s, "apikey")) return .apikey;
    return null;
}

fn readInt(v: ?std.json.Value) ?i64 {
    if (v == null) return null;
    return switch (v.?) {
        .integer => |i| i,
        else => null,
    };
}

fn localtimeCompat(ts: i64, out_tm: *c.struct_tm) bool {
    if (builtin.os.tag == .windows) {
        if (comptime @hasDecl(c, "_localtime64_s") and @hasDecl(c, "__time64_t")) {
            var t64: c.__time64_t = @intCast(ts);
            return c._localtime64_s(out_tm, &t64) == 0;
        }
        return false;
    }

    var t: c.time_t = @intCast(ts);
    if (comptime @hasDecl(c, "localtime_r")) {
        return c.localtime_r(&t, out_tm) != null;
    }
    if (comptime @hasDecl(c, "localtime")) {
        const tm_ptr = c.localtime(&t);
        if (tm_ptr == null) return false;
        out_tm.* = tm_ptr.*;
        return true;
    }
    return false;
}

const builtin = @import("builtin");

fn formatBackupTimestampAlloc(allocator: std.mem.Allocator, ts: i64) ![]u8 {
    var tm: c.struct_tm = undefined;
    if (!localtimeCompat(ts, &tm)) return std.fmt.allocPrint(allocator, "{d}", .{ts});

    const year = @as(u32, @intCast(tm.tm_year + 1900));
    const month = @as(u32, @intCast(tm.tm_mon + 1));
    const day = @as(u32, @intCast(tm.tm_mday));
    const hour = @as(u32, @intCast(tm.tm_hour));
    const min = @as(u32, @intCast(tm.tm_min));
    const sec = @as(u32, @intCast(tm.tm_sec));
    return std.fmt.allocPrint(allocator, "{d:0>4}{d:0>2}{d:0>2}-{d:0>2}{d:0>2}{d:0>2}", .{
        year, month, day, hour, min, sec,
    });
}

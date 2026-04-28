const std = @import("std");
const app_runtime = @import("../core/runtime.zig");
const builtin = @import("builtin");
const auth = @import("../auth/auth.zig");
const common = @import("common.zig");
const clean = @import("clean.zig");
const account_ops = @import("account_ops.zig");
const import_mod = @import("import.zig");
const parse = @import("parse.zig");
const storage_parse = @import("storage_parse.zig");
const storage_write = @import("storage_write.zig");

const PlanType = common.PlanType;
const AuthMode = common.AuthMode;
const RateLimitSnapshot = common.RateLimitSnapshot;
const RolloutSignature = common.RolloutSignature;
const AutoSwitchConfig = common.AutoSwitchConfig;
const ApiConfig = common.ApiConfig;
const LiveConfig = common.LiveConfig;
const AccountRecord = common.AccountRecord;
const Registry = common.Registry;
const current_schema_version = common.current_schema_version;
const min_supported_schema_version = common.min_supported_schema_version;
const private_file_permissions = common.private_file_permissions;
const defaultAutoSwitchConfig = common.defaultAutoSwitchConfig;
const defaultApiConfig = common.defaultApiConfig;
const defaultLiveConfig = common.defaultLiveConfig;
const freeAccountRecord = common.freeAccountRecord;
const freeRateLimitSnapshot = common.freeRateLimitSnapshot;
const cloneOptionalStringAlloc = common.cloneOptionalStringAlloc;
const legacyAccountAuthPath = common.legacyAccountAuthPath;
const accountAuthPath = common.accountAuthPath;
const activeAuthPath = common.activeAuthPath;
const ensureAccountsDir = common.ensureAccountsDir;
const registryPath = common.registryPath;
const readFileAlloc = common.readFileAlloc;
const copyManagedFile = common.copyManagedFile;
const copyFile = common.copyFile;
const hardenSensitiveFile = common.hardenSensitiveFile;
const normalizeEmailAlloc = common.normalizeEmailAlloc;
const parsePlanType = parse.parsePlanType;
const parseAuthMode = parse.parseAuthMode;
const parseUsage = parse.parseUsage;
const parseAutoSwitch = parse.parseAutoSwitch;
const parseApiConfig = parse.parseApiConfig;
const apiConfigNeedsRewrite = parse.apiConfigNeedsRewrite;
const parseApiConfigDetailed = parse.parseApiConfigDetailed;
const parseLiveConfig = parse.parseLiveConfig;
const liveConfigNeedsRewrite = parse.liveConfigNeedsRewrite;
const parseRolloutSignature = parse.parseRolloutSignature;
const readInt = parse.readInt;
const parseThresholdPercent = parse.parseThresholdPercent;
const parseAccountRecord = storage_parse.parseAccountRecord;
const accountFromAuth = account_ops.accountFromAuth;
const upsertAccount = account_ops.upsertAccount;
const setActiveAccountKey = account_ops.setActiveAccountKey;
const syncCurrentAuthBestEffort = import_mod.syncCurrentAuthBestEffort;
const fileEqualsBytes = clean.fileEqualsBytes;
const filesEqual = clean.filesEqual;
const backupDir = clean.backupDir;

pub const saveRegistry = storage_write.saveRegistry;

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

pub fn defaultRegistry() Registry {
    return Registry{
        .schema_version = current_schema_version,
        .active_account_key = null,
        .active_account_activated_at_ms = null,
        .auto_switch = defaultAutoSwitchConfig(),
        .api = defaultApiConfig(),
        .live = defaultLiveConfig(),
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
        .created_at = readInt(obj.get("created_at")) orelse std.Io.Timestamp.now(app_runtime.io(), .real).toSeconds(),
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

fn maybeCopyFile(src: []const u8, dest: []const u8) !void {
    if (std.mem.eql(u8, src, dest)) return;
    try copyManagedFile(src, dest);
}

fn resolveLegacySnapshotPathForEmail(
    allocator: std.mem.Allocator,
    codex_home: []const u8,
    email: []const u8,
) ![]u8 {
    const legacy_path = try legacyAccountAuthPath(allocator, codex_home, email);
    if (std.Io.Dir.cwd().openFile(app_runtime.io(), legacy_path, .{})) |file| {
        file.close(app_runtime.io());
        return legacy_path;
    } else |_| {
        allocator.free(legacy_path);
    }

    const accounts_dir = try backupDir(allocator, codex_home);
    defer allocator.free(accounts_dir);
    var dir = std.Io.Dir.cwd().openDir(app_runtime.io(), accounts_dir, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => return error.FileNotFound,
        else => return err,
    };
    defer dir.close(app_runtime.io());

    var it = dir.iterate();
    while (try it.next(app_runtime.io())) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.name, ".auth.json")) continue;
        if (std.mem.startsWith(u8, entry.name, "auth.json.bak.")) continue;

        const path = try std.fs.path.join(allocator, &[_][]const u8{ accounts_dir, entry.name });
        errdefer allocator.free(path);
        const info = auth.parseAuthInfo(allocator, path) catch {
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
    const active_info = auth.parseAuthInfo(allocator, active_path) catch {
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

    const info = try auth.parseAuthInfo(allocator, legacy_path);
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
        .account_name = null,
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
        std.Io.Dir.cwd().deleteFile(app_runtime.io(), old_legacy_path) catch {};
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
    if (root_obj.get("live")) |v| {
        parseLiveConfig(&reg.live, v);
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
    if (root_obj.get("live")) |v| {
        parseLiveConfig(&reg.live, v);
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
    if (root_obj.get("api")) |v| {
        if (apiConfigNeedsRewrite(v)) return true;
    } else {
        return true;
    }
    if (root_obj.get("live")) |v| {
        if (liveConfigNeedsRewrite(v)) return true;
    } else {
        return true;
    }
    return root_obj.get("active_account_key") != null and root_obj.get("active_account_activated_at_ms") == null;
}

fn detectSchemaVersion(root_obj: std.json.ObjectMap) u32 {
    return schemaVersionFieldValue(root_obj) orelse if (root_obj.get("active_email") != null) 2 else current_schema_version;
}

fn applySchemaMigrations(reg: *Registry, loaded_schema_version: u32) void {
    if (loaded_schema_version < 4) {
        reg.auto_switch.threshold_5h_percent = common.default_auto_switch_threshold_5h_percent;
        reg.auto_switch.threshold_weekly_percent = common.default_auto_switch_threshold_weekly_percent;
    }
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

    const cwd = std.Io.Dir.cwd();
    const data = blk: {
        var file = cwd.openFile(app_runtime.io(), path, .{}) catch |err| {
            if (err == error.FileNotFound) {
                return defaultRegistry();
            }
            return err;
        };
        defer file.close(app_runtime.io());

        break :blk try readFileAlloc(file, allocator, 10 * 1024 * 1024);
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
        3, 4 => try loadCurrentRegistry(allocator, root_obj),
        else => {
            std.log.err(
                "registry schema_version {d} is older than the minimum supported {d}; use an intermediate codex-auth release or import --purge",
                .{ schema_version, min_supported_schema_version },
            );
            return error.UnsupportedRegistryVersion;
        },
    };
    errdefer reg.deinit(allocator);
    applySchemaMigrations(&reg, schema_version);

    if (needs_rewrite) {
        try saveRegistry(allocator, codex_home, &reg);
    }

    return reg;
}

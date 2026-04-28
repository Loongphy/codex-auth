const std = @import("std");
const app_runtime = @import("../core/runtime.zig");
const builtin = @import("builtin");
const account_api = @import("../api/account.zig");
const c_time = @cImport({
    @cInclude("time.h");
});

pub const PlanType = enum { free, plus, prolite, pro, team, business, enterprise, edu, unknown };
pub const AuthMode = enum { chatgpt, apikey };
pub const current_schema_version: u32 = 4;
pub const min_supported_schema_version: u32 = 2;
pub const default_auto_switch_threshold_5h_percent: u8 = 1;
pub const default_auto_switch_threshold_weekly_percent: u8 = 1;
pub const account_name_refresh_lock_file_name = "account-name-refresh.lock";
pub const private_file_permissions: std.Io.File.Permissions = switch (builtin.os.tag) {
    .windows => .default_file,
    else => .fromMode(0o600),
};
pub const private_dir_permissions: std.Io.File.Permissions = switch (builtin.os.tag) {
    .windows => .default_dir,
    else => .fromMode(0o700),
};

pub fn getEnvMap(allocator: std.mem.Allocator) !std.process.Environ.Map {
    return try app_runtime.currentEnviron().createMap(allocator);
}

pub fn getEnvVarOwned(allocator: std.mem.Allocator, name: []const u8) ![]u8 {
    var env_map = try getEnvMap(allocator);
    defer env_map.deinit();

    const value = env_map.get(name) orelse return error.EnvironmentVariableNotFound;
    return try allocator.dupe(u8, value);
}

pub fn normalizeEmailAlloc(allocator: std.mem.Allocator, email: []const u8) ![]u8 {
    var buf = try allocator.alloc(u8, email.len);
    for (email, 0..) |ch, i| {
        buf[i] = std.ascii.toLower(ch);
    }
    return buf;
}

pub fn realPathAlloc(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    if (std.fs.path.isAbsolute(path)) {
        return try app_runtime.realPathFileAbsoluteAlloc(allocator, path);
    }
    return try app_runtime.realPathFileAlloc(allocator, std.Io.Dir.cwd(), path);
}

pub fn readFileAlloc(file: std.Io.File, allocator: std.mem.Allocator, max_bytes: usize) ![]u8 {
    var read_buffer: [4096]u8 = undefined;
    var file_reader = file.reader(app_runtime.io(), &read_buffer);
    return try file_reader.interface.allocRemaining(allocator, .limited(max_bytes));
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
    account: bool = true,
};

pub const default_live_refresh_interval_seconds: u16 = 60;
pub const min_live_refresh_interval_seconds: u16 = 5;
pub const max_live_refresh_interval_seconds: u16 = 3600;

pub const LiveConfig = struct {
    interval_seconds: u16 = default_live_refresh_interval_seconds,
};

pub const ApiConfigParseResult = struct {
    has_object: bool = false,
    has_usage: bool = false,
    has_account: bool = false,
};

pub const AccountRecord = struct {
    account_key: []u8,
    chatgpt_account_id: []u8,
    chatgpt_user_id: []u8,
    email: []u8,
    alias: []u8,
    account_name: ?[]u8,
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

pub fn resolveDisplayPlan(rec: *const AccountRecord) ?PlanType {
    if (rec.last_usage) |u| {
        if (u.plan_type) |p| return p;
    }
    return resolvePlan(rec);
}

pub fn planLabel(plan: PlanType) []const u8 {
    return switch (plan) {
        .free => "Free",
        .plus => "Plus",
        .prolite => "Pro Lite",
        .pro => "Pro",
        .team => "Business",
        .business => "Business",
        .enterprise => "Enterprise",
        .edu => "Edu",
        .unknown => "Unknown",
    };
}

pub const Registry = struct {
    schema_version: u32,
    active_account_key: ?[]u8,
    active_account_activated_at_ms: ?i64,
    auto_switch: AutoSwitchConfig,
    api: ApiConfig,
    live: LiveConfig = defaultLiveConfig(),
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

pub fn defaultLiveConfig() LiveConfig {
    return .{};
}

pub fn freeAccountRecord(allocator: std.mem.Allocator, rec: *const AccountRecord) void {
    allocator.free(rec.account_key);
    allocator.free(rec.chatgpt_account_id);
    allocator.free(rec.chatgpt_user_id);
    allocator.free(rec.email);
    allocator.free(rec.alias);
    if (rec.account_name) |account_name| allocator.free(account_name);
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

pub fn cloneRateLimitSnapshot(allocator: std.mem.Allocator, snapshot: RateLimitSnapshot) !RateLimitSnapshot {
    var cloned_credits: ?CreditsSnapshot = null;
    if (snapshot.credits) |credits| {
        var cloned_balance: ?[]u8 = null;
        if (credits.balance) |balance| {
            cloned_balance = try allocator.dupe(u8, balance);
        }
        cloned_credits = .{
            .has_credits = credits.has_credits,
            .unlimited = credits.unlimited,
            .balance = cloned_balance,
        };
    }
    errdefer if (cloned_credits) |credits| {
        if (credits.balance) |balance| allocator.free(balance);
    };

    return .{
        .primary = snapshot.primary,
        .secondary = snapshot.secondary,
        .credits = cloned_credits,
        .plan_type = snapshot.plan_type,
    };
}

pub fn setRolloutSignature(
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

pub fn rateLimitWindowEqual(a: ?RateLimitWindow, b: ?RateLimitWindow) bool {
    if (a == null and b == null) return true;
    if (a == null or b == null) return false;
    return a.?.used_percent == b.?.used_percent and
        a.?.window_minutes == b.?.window_minutes and
        a.?.resets_at == b.?.resets_at;
}

pub fn creditsEqual(a: ?CreditsSnapshot, b: ?CreditsSnapshot) bool {
    if (a == null and b == null) return true;
    if (a == null or b == null) return false;
    return a.?.has_credits == b.?.has_credits and
        a.?.unlimited == b.?.unlimited and
        optionalStringEqual(a.?.balance, b.?.balance);
}

pub fn optionalStringEqual(a: ?[]const u8, b: ?[]const u8) bool {
    if (a == null and b == null) return true;
    if (a == null or b == null) return false;
    return std.mem.eql(u8, a.?, b.?);
}

pub fn cloneOptionalStringAlloc(allocator: std.mem.Allocator, value: ?[]const u8) !?[]u8 {
    return if (value) |text| try allocator.dupe(u8, text) else null;
}

pub fn replaceOptionalStringAlloc(
    allocator: std.mem.Allocator,
    target: *?[]u8,
    value: ?[]const u8,
) !bool {
    if (optionalStringEqual(target.*, value)) return false;
    const replacement = try cloneOptionalStringAlloc(allocator, value);
    if (target.*) |existing| allocator.free(existing);
    target.* = replacement;
    return true;
}

pub fn getNonEmptyEnvVarOwned(allocator: std.mem.Allocator, name: []const u8) !?[]u8 {
    const val = getEnvVarOwned(allocator, name) catch |err| switch (err) {
        error.EnvironmentVariableNotFound => return null,
        else => return err,
    };
    if (val.len == 0) {
        allocator.free(val);
        return null;
    }
    return val;
}

pub fn resolveExistingCodexHomeOverride(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    const stat = std.Io.Dir.cwd().statFile(app_runtime.io(), path, .{}) catch |err| switch (err) {
        error.IsDir => {
            return realPathAlloc(allocator, path) catch |realpath_err| {
                logCodexHomeResolutionError("failed to canonicalize CODEX_HOME `{s}`: {s}", .{ path, @errorName(realpath_err) });
                return realpath_err;
            };
        },
        error.FileNotFound => {
            logCodexHomeResolutionError("CODEX_HOME points to `{s}`, but that path does not exist", .{path});
            return err;
        },
        else => {
            logCodexHomeResolutionError("failed to read CODEX_HOME `{s}`: {s}", .{ path, @errorName(err) });
            return err;
        },
    };
    if (stat.kind != .directory) {
        logCodexHomeResolutionError("CODEX_HOME points to `{s}`, but that path is not a directory", .{path});
        return error.NotDir;
    }
    return realPathAlloc(allocator, path) catch |err| {
        logCodexHomeResolutionError("failed to canonicalize CODEX_HOME `{s}`: {s}", .{ path, @errorName(err) });
        return err;
    };
}

pub fn logCodexHomeResolutionError(
    comptime fmt: []const u8,
    args: anytype,
) void {
    if (builtin.is_test) return;
    std.log.err(fmt, args);
}

pub fn resolveCodexHomeFromEnv(
    allocator: std.mem.Allocator,
    codex_home_override: ?[]const u8,
    home: ?[]const u8,
    user_profile: ?[]const u8,
) ![]u8 {
    if (codex_home_override) |path| {
        if (path.len != 0) return try resolveExistingCodexHomeOverride(allocator, path);
    }
    if (home) |path| {
        if (path.len != 0) return try std.fs.path.join(allocator, &[_][]const u8{ path, ".codex" });
    }
    if (user_profile) |path| {
        if (path.len != 0) return try std.fs.path.join(allocator, &[_][]const u8{ path, ".codex" });
    }
    return error.EnvironmentVariableNotFound;
}

pub fn resolveCodexHome(allocator: std.mem.Allocator) ![]u8 {
    const codex_home_override = try getNonEmptyEnvVarOwned(allocator, "CODEX_HOME");
    defer if (codex_home_override) |path| allocator.free(path);

    const home = try getNonEmptyEnvVarOwned(allocator, "HOME");
    defer if (home) |path| allocator.free(path);

    const user_profile = try getNonEmptyEnvVarOwned(allocator, "USERPROFILE");
    defer if (user_profile) |path| allocator.free(path);

    return try resolveCodexHomeFromEnv(allocator, codex_home_override, home, user_profile);
}

pub fn resolveUserHome(allocator: std.mem.Allocator) ![]u8 {
    if (try getNonEmptyEnvVarOwned(allocator, "HOME")) |home| return home;

    if (try getNonEmptyEnvVarOwned(allocator, "USERPROFILE")) |user_profile| return user_profile;

    return error.EnvironmentVariableNotFound;
}

pub fn hardenPathPermissions(path: []const u8, permissions: std.Io.File.Permissions) !void {
    if (builtin.os.tag == .windows) return;
    try std.Io.Dir.cwd().setFilePermissions(app_runtime.io(), path, permissions, .{});
}

pub fn hardenSensitiveFile(path: []const u8) !void {
    try hardenPathPermissions(path, private_file_permissions);
}

pub fn hardenSensitiveDir(path: []const u8) !void {
    try hardenPathPermissions(path, private_dir_permissions);
}

pub fn ensurePrivateDir(path: []const u8) !void {
    try std.Io.Dir.cwd().createDirPath(app_runtime.io(), path);
    try hardenSensitiveDir(path);
}

pub fn ensureAccountsDir(allocator: std.mem.Allocator, codex_home: []const u8) !void {
    const accounts_dir = try std.fs.path.join(allocator, &[_][]const u8{ codex_home, "accounts" });
    defer allocator.free(accounts_dir);
    try ensurePrivateDir(accounts_dir);
}

pub fn registryPath(allocator: std.mem.Allocator, codex_home: []const u8) ![]u8 {
    return try std.fs.path.join(allocator, &[_][]const u8{ codex_home, "accounts", "registry.json" });
}

pub fn encodedFileKey(allocator: std.mem.Allocator, key: []const u8) ![]u8 {
    const encoder = std.base64.url_safe_no_pad.Encoder;
    const out_len = encoder.calcSize(key.len);
    const buf = try allocator.alloc(u8, out_len);
    _ = encoder.encode(buf, key);
    return buf;
}

pub fn keyNeedsFilenameEncoding(key: []const u8) bool {
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

pub fn accountFileKey(allocator: std.mem.Allocator, account_key: []const u8) ![]u8 {
    if (keyNeedsFilenameEncoding(account_key)) {
        return encodedFileKey(allocator, account_key);
    }
    return allocator.dupe(u8, account_key);
}

pub fn accountSnapshotFileName(allocator: std.mem.Allocator, account_key: []const u8) ![]u8 {
    const key = try accountFileKey(allocator, account_key);
    defer allocator.free(key);
    return try std.mem.concat(allocator, u8, &[_][]const u8{ key, ".auth.json" });
}

pub fn accountAuthPath(allocator: std.mem.Allocator, codex_home: []const u8, account_key: []const u8) ![]u8 {
    const filename = try accountSnapshotFileName(allocator, account_key);
    defer allocator.free(filename);
    return try std.fs.path.join(allocator, &[_][]const u8{ codex_home, "accounts", filename });
}

pub fn legacyAccountAuthPath(allocator: std.mem.Allocator, codex_home: []const u8, email: []const u8) ![]u8 {
    const key = try encodedFileKey(allocator, email);
    defer allocator.free(key);
    const filename = try std.mem.concat(allocator, u8, &[_][]const u8{ key, ".auth.json" });
    defer allocator.free(filename);
    return try std.fs.path.join(allocator, &[_][]const u8{ codex_home, "accounts", filename });
}

pub fn activeAuthPath(allocator: std.mem.Allocator, codex_home: []const u8) ![]u8 {
    return try std.fs.path.join(allocator, &[_][]const u8{ codex_home, "auth.json" });
}

pub fn copyFileWithPermissions(src: []const u8, dest: []const u8, permissions: ?std.Io.File.Permissions) !void {
    try std.Io.Dir.cwd().copyFile(src, std.Io.Dir.cwd(), dest, app_runtime.io(), .{ .permissions = permissions });
}

pub fn existingFilePermissions(path: []const u8) !?std.Io.File.Permissions {
    const stat = std.Io.Dir.cwd().statFile(app_runtime.io(), path, .{}) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return err,
    };
    return stat.permissions;
}

pub fn copyFile(src: []const u8, dest: []const u8) !void {
    try copyFileWithPermissions(src, dest, null);
}

pub fn copyManagedFile(src: []const u8, dest: []const u8) !void {
    try copyFileWithPermissions(src, dest, private_file_permissions);
    try hardenSensitiveFile(dest);
}

pub fn replaceFilePreservingPermissions(src: []const u8, dest: []const u8) !void {
    const permissions = try existingFilePermissions(dest);
    try copyFileWithPermissions(src, dest, permissions);
}

pub fn writeFile(path: []const u8, data: []const u8) !void {
    var file = try std.Io.Dir.cwd().createFile(app_runtime.io(), path, .{
        .truncate = true,
        .permissions = private_file_permissions,
    });
    defer file.close(app_runtime.io());
    try file.writeStreamingAll(app_runtime.io(), data);
    try hardenSensitiveFile(path);
}

pub const max_backups: usize = 5;

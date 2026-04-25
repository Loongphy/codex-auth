const std = @import("std");
const app_runtime = @import("../core/runtime.zig");
const account_api = @import("../api/account.zig");
const account_name_refresh = @import("../auth/account.zig");
const auth = @import("../auth/auth.zig");
const cli = @import("../cli/root.zig");
const registry = @import("../registry/root.zig");
const targets = @import("targets.zig");
const workflow_env = @import("env.zig");

const ForegroundUsageRefreshTarget = targets.ForegroundUsageRefreshTarget;
const getEnvMap = workflow_env.getEnvMap;
const account_name_refresh_only_env = workflow_env.account_name_refresh_only_env;
const disable_background_account_name_refresh_env = workflow_env.disable_background_account_name_refresh_env;
const skip_service_reconcile_env = workflow_env.skip_service_reconcile_env;
const isBackgroundAccountNameRefreshDisabled = workflow_env.isBackgroundAccountNameRefreshDisabled;

pub const AccountFetchFn = *const fn (
    allocator: std.mem.Allocator,
    access_token: []const u8,
    account_id: []const u8,
) anyerror!account_api.FetchResult;
pub const BackgroundRefreshLockAcquirer = *const fn (
    allocator: std.mem.Allocator,
    codex_home: []const u8,
) anyerror!?account_name_refresh.BackgroundRefreshLock;

pub fn maybeRefreshForegroundAccountNames(
    allocator: std.mem.Allocator,
    codex_home: []const u8,
    reg: *registry.Registry,
    target: ForegroundUsageRefreshTarget,
    fetcher: AccountFetchFn,
) !void {
    return try maybeRefreshForegroundAccountNamesWithAccountApiEnabled(
        allocator,
        codex_home,
        reg,
        target,
        fetcher,
        reg.api.account,
    );
}

pub fn maybeRefreshForegroundAccountNamesWithAccountApiEnabled(
    allocator: std.mem.Allocator,
    codex_home: []const u8,
    reg: *registry.Registry,
    target: ForegroundUsageRefreshTarget,
    fetcher: AccountFetchFn,
    account_api_enabled: bool,
) !void {
    _ = try maybeRefreshForegroundAccountNamesWithAccountApiEnabledAndPersist(
        allocator,
        codex_home,
        reg,
        target,
        fetcher,
        account_api_enabled,
        true,
    );
}

pub fn maybeRefreshForegroundAccountNamesWithAccountApiEnabledAndPersist(
    allocator: std.mem.Allocator,
    codex_home: []const u8,
    reg: *registry.Registry,
    target: ForegroundUsageRefreshTarget,
    fetcher: AccountFetchFn,
    account_api_enabled: bool,
    persist_registry: bool,
) !bool {
    const changed = switch (target) {
        .list, .remove_account => try refreshAccountNamesForListWithAccountApiEnabled(
            allocator,
            codex_home,
            reg,
            fetcher,
            account_api_enabled,
        ),
        .switch_account => try refreshAccountNamesAfterSwitchWithAccountApiEnabled(
            allocator,
            codex_home,
            reg,
            fetcher,
            account_api_enabled,
        ),
    };
    if (!changed) return false;
    if (persist_registry) try registry.saveRegistry(allocator, codex_home, reg);
    return true;
}

pub fn defaultAccountFetcher(
    allocator: std.mem.Allocator,
    access_token: []const u8,
    account_id: []const u8,
) !account_api.FetchResult {
    return try account_api.fetchAccountsForTokenDetailed(
        allocator,
        account_api.default_account_endpoint,
        access_token,
        account_id,
    );
}

pub fn maybeRefreshAccountNamesForAuthInfo(
    allocator: std.mem.Allocator,
    reg: *registry.Registry,
    info: *const auth.AuthInfo,
    fetcher: AccountFetchFn,
) !bool {
    return try maybeRefreshAccountNamesForAuthInfoWithAccountApiEnabled(
        allocator,
        reg,
        info,
        fetcher,
        reg.api.account,
    );
}

pub fn maybeRefreshAccountNamesForAuthInfoWithAccountApiEnabled(
    allocator: std.mem.Allocator,
    reg: *registry.Registry,
    info: *const auth.AuthInfo,
    fetcher: AccountFetchFn,
    account_api_enabled: bool,
) !bool {
    const chatgpt_user_id = info.chatgpt_user_id orelse return false;
    if (!shouldRefreshTeamAccountNamesForUserScopeWithAccountApiEnabled(reg, chatgpt_user_id, account_api_enabled)) return false;
    const access_token = info.access_token orelse return false;
    const chatgpt_account_id = info.chatgpt_account_id orelse return false;

    const result = fetcher(allocator, access_token, chatgpt_account_id) catch |err| {
        std.log.warn("account metadata refresh skipped: {s}", .{@errorName(err)});
        return false;
    };
    defer result.deinit(allocator);

    const entries = result.entries orelse return false;
    return try registry.applyAccountNamesForUser(allocator, reg, chatgpt_user_id, entries);
}

pub fn loadActiveAuthInfoForAccountRefresh(allocator: std.mem.Allocator, codex_home: []const u8) !?auth.AuthInfo {
    const auth_path = try registry.activeAuthPath(allocator, codex_home);
    defer allocator.free(auth_path);

    return auth.parseAuthInfo(allocator, auth_path) catch |err| switch (err) {
        error.OutOfMemory => return err,
        error.FileNotFound => null,
        else => {
            std.log.warn("account metadata refresh skipped: {s}", .{@errorName(err)});
            return null;
        },
    };
}

pub fn refreshAccountNamesForActiveAuth(
    allocator: std.mem.Allocator,
    codex_home: []const u8,
    reg: *registry.Registry,
    fetcher: AccountFetchFn,
) !bool {
    return try refreshAccountNamesForActiveAuthWithAccountApiEnabled(
        allocator,
        codex_home,
        reg,
        fetcher,
        reg.api.account,
    );
}

pub fn refreshAccountNamesForActiveAuthWithAccountApiEnabled(
    allocator: std.mem.Allocator,
    codex_home: []const u8,
    reg: *registry.Registry,
    fetcher: AccountFetchFn,
    account_api_enabled: bool,
) !bool {
    const active_user_id = registry.activeChatgptUserId(reg) orelse return false;
    if (!shouldRefreshTeamAccountNamesForUserScopeWithAccountApiEnabled(reg, active_user_id, account_api_enabled)) return false;

    var info = (try loadActiveAuthInfoForAccountRefresh(allocator, codex_home)) orelse return false;
    defer info.deinit(allocator);
    return try maybeRefreshAccountNamesForAuthInfoWithAccountApiEnabled(
        allocator,
        reg,
        &info,
        fetcher,
        account_api_enabled,
    );
}

pub fn refreshAccountNamesAfterLogin(
    allocator: std.mem.Allocator,
    reg: *registry.Registry,
    info: *const auth.AuthInfo,
    fetcher: AccountFetchFn,
) !bool {
    return try maybeRefreshAccountNamesForAuthInfo(allocator, reg, info, fetcher);
}

pub fn refreshAccountNamesAfterSwitch(
    allocator: std.mem.Allocator,
    codex_home: []const u8,
    reg: *registry.Registry,
    fetcher: AccountFetchFn,
) !bool {
    return try refreshAccountNamesAfterSwitchWithAccountApiEnabled(
        allocator,
        codex_home,
        reg,
        fetcher,
        reg.api.account,
    );
}

pub fn refreshAccountNamesAfterSwitchWithAccountApiEnabled(
    allocator: std.mem.Allocator,
    codex_home: []const u8,
    reg: *registry.Registry,
    fetcher: AccountFetchFn,
    account_api_enabled: bool,
) !bool {
    return try refreshAccountNamesForActiveAuthWithAccountApiEnabled(
        allocator,
        codex_home,
        reg,
        fetcher,
        account_api_enabled,
    );
}

pub fn refreshAccountNamesForList(
    allocator: std.mem.Allocator,
    codex_home: []const u8,
    reg: *registry.Registry,
    fetcher: AccountFetchFn,
) !bool {
    return try refreshAccountNamesForListWithAccountApiEnabled(
        allocator,
        codex_home,
        reg,
        fetcher,
        reg.api.account,
    );
}

pub fn refreshAccountNamesForListWithAccountApiEnabled(
    allocator: std.mem.Allocator,
    codex_home: []const u8,
    reg: *registry.Registry,
    fetcher: AccountFetchFn,
    account_api_enabled: bool,
) !bool {
    return try refreshAccountNamesForActiveAuthWithAccountApiEnabled(
        allocator,
        codex_home,
        reg,
        fetcher,
        account_api_enabled,
    );
}

pub fn shouldRefreshTeamAccountNamesForUserScope(reg: *registry.Registry, chatgpt_user_id: []const u8) bool {
    return shouldRefreshTeamAccountNamesForUserScopeWithAccountApiEnabled(reg, chatgpt_user_id, reg.api.account);
}

pub fn shouldRefreshTeamAccountNamesForUserScopeWithAccountApiEnabled(
    reg: *registry.Registry,
    chatgpt_user_id: []const u8,
    account_api_enabled: bool,
) bool {
    if (!account_api_enabled) return false;
    return registry.shouldFetchTeamAccountNamesForUser(reg, chatgpt_user_id);
}

pub fn shouldScheduleBackgroundAccountNameRefresh(reg: *registry.Registry) bool {
    if (!reg.api.account) return false;

    for (reg.accounts.items) |rec| {
        if (rec.auth_mode != null and rec.auth_mode.? != .chatgpt) continue;
        if (registry.shouldFetchTeamAccountNamesForUser(reg, rec.chatgpt_user_id)) return true;
    }

    return false;
}

pub fn applyAccountNameRefreshEntriesToLatestRegistry(
    allocator: std.mem.Allocator,
    codex_home: []const u8,
    chatgpt_user_id: []const u8,
    entries: []const account_api.AccountEntry,
) !bool {
    var latest = try registry.loadRegistry(allocator, codex_home);
    defer latest.deinit(allocator);

    if (!shouldRefreshTeamAccountNamesForUserScope(&latest, chatgpt_user_id)) return false;
    if (!try registry.applyAccountNamesForUser(allocator, &latest, chatgpt_user_id, entries)) return false;

    try registry.saveRegistry(allocator, codex_home, &latest);
    return true;
}

pub fn runBackgroundAccountNameRefresh(
    allocator: std.mem.Allocator,
    codex_home: []const u8,
    fetcher: AccountFetchFn,
) !void {
    return try runBackgroundAccountNameRefreshWithLockAcquirer(
        allocator,
        codex_home,
        fetcher,
        account_name_refresh.BackgroundRefreshLock.acquire,
    );
}

pub fn runBackgroundAccountNameRefreshWithLockAcquirer(
    allocator: std.mem.Allocator,
    codex_home: []const u8,
    fetcher: AccountFetchFn,
    lock_acquirer: BackgroundRefreshLockAcquirer,
) !void {
    var refresh_lock = (try lock_acquirer(allocator, codex_home)) orelse return;
    defer refresh_lock.release();

    var reg = try registry.loadRegistry(allocator, codex_home);
    defer reg.deinit(allocator);
    var candidates = try account_name_refresh.collectCandidates(allocator, &reg);
    defer {
        for (candidates.items) |*candidate| candidate.deinit(allocator);
        candidates.deinit(allocator);
    }

    for (candidates.items) |candidate| {
        var latest = try registry.loadRegistry(allocator, codex_home);
        defer latest.deinit(allocator);

        if (!shouldRefreshTeamAccountNamesForUserScope(&latest, candidate.chatgpt_user_id)) continue;

        var info = (try account_name_refresh.loadStoredAuthInfoForUser(
            allocator,
            codex_home,
            &latest,
            candidate.chatgpt_user_id,
        )) orelse continue;
        defer info.deinit(allocator);

        const access_token = info.access_token orelse continue;
        const chatgpt_account_id = info.chatgpt_account_id orelse continue;
        const result = fetcher(allocator, access_token, chatgpt_account_id) catch |err| {
            std.log.warn("account metadata refresh skipped: {s}", .{@errorName(err)});
            continue;
        };
        defer result.deinit(allocator);

        const entries = result.entries orelse continue;
        _ = try applyAccountNameRefreshEntriesToLatestRegistry(allocator, codex_home, candidate.chatgpt_user_id, entries);
    }
}

pub fn spawnBackgroundAccountNameRefresh(allocator: std.mem.Allocator) !void {
    var env_map = getEnvMap(allocator) catch |err| {
        std.log.warn("background account metadata refresh skipped: {s}", .{@errorName(err)});
        return;
    };
    defer env_map.deinit();

    try env_map.put(account_name_refresh_only_env, "1");
    try env_map.put(disable_background_account_name_refresh_env, "1");
    try env_map.put(skip_service_reconcile_env, "1");

    const self_exe = try std.process.executablePathAlloc(app_runtime.io(), allocator);
    defer allocator.free(self_exe);

    _ = try std.process.spawn(app_runtime.io(), .{
        .argv = &[_][]const u8{ self_exe, "list" },
        .environ_map = &env_map,
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .ignore,
        .create_no_window = true,
    });
}

pub fn maybeSpawnBackgroundAccountNameRefresh(
    allocator: std.mem.Allocator,
    reg: *registry.Registry,
) void {
    if (isBackgroundAccountNameRefreshDisabled()) return;
    if (!shouldScheduleBackgroundAccountNameRefresh(reg)) return;

    spawnBackgroundAccountNameRefresh(allocator) catch |err| {
        std.log.warn("background account metadata refresh skipped: {s}", .{@errorName(err)});
    };
}

pub fn refreshAccountNamesAfterImport(
    allocator: std.mem.Allocator,
    reg: *registry.Registry,
    purge: bool,
    render_kind: registry.ImportRenderKind,
    info: ?*const auth.AuthInfo,
    fetcher: AccountFetchFn,
) !bool {
    if (purge or render_kind != .single_file or info == null) return false;
    return try maybeRefreshAccountNamesForAuthInfo(allocator, reg, info.?, fetcher);
}

pub fn loadSingleFileImportAuthInfo(
    allocator: std.mem.Allocator,
    opts: cli.types.ImportOptions,
) !?auth.AuthInfo {
    if (opts.purge or opts.auth_path == null) return null;

    return switch (opts.source) {
        .standard => auth.parseAuthInfo(allocator, opts.auth_path.?) catch |err| switch (err) {
            error.OutOfMemory => return err,
            else => {
                std.log.warn("account metadata refresh skipped: {s}", .{@errorName(err)});
                return null;
            },
        },
        .cpa => blk: {
            var file = std.Io.Dir.cwd().openFile(app_runtime.io(), opts.auth_path.?, .{}) catch |err| {
                std.log.warn("account metadata refresh skipped: {s}", .{@errorName(err)});
                return null;
            };
            defer file.close(app_runtime.io());

            var read_buffer: [4096]u8 = undefined;
            var file_reader = file.reader(app_runtime.io(), &read_buffer);
            const data = file_reader.interface.allocRemaining(allocator, .limited(10 * 1024 * 1024)) catch |err| switch (err) {
                error.OutOfMemory => return err,
                else => {
                    std.log.warn("account metadata refresh skipped: {s}", .{@errorName(err)});
                    return null;
                },
            };
            defer allocator.free(data);

            const converted = auth.convertCpaAuthJson(allocator, data) catch |err| switch (err) {
                error.OutOfMemory => return err,
                else => {
                    std.log.warn("account metadata refresh skipped: {s}", .{@errorName(err)});
                    return null;
                },
            };
            defer allocator.free(converted);

            break :blk auth.parseAuthInfoData(allocator, converted) catch |err| switch (err) {
                error.OutOfMemory => return err,
                else => {
                    std.log.warn("account metadata refresh skipped: {s}", .{@errorName(err)});
                    return null;
                },
            };
        },
    };
}

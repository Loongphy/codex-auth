const std = @import("std");
const account_api = @import("account_api.zig");
const account_name_refresh = @import("account_name_refresh.zig");
const cli = @import("cli.zig");
const registry = @import("registry.zig");
const auth = @import("auth.zig");
const auto = @import("auto.zig");
const format = @import("format.zig");

const skip_service_reconcile_env = "CODEX_AUTH_SKIP_SERVICE_RECONCILE";
const account_name_refresh_only_env = "CODEX_AUTH_REFRESH_ACCOUNT_NAMES_ONLY";
const disable_background_account_name_refresh_env = "CODEX_AUTH_DISABLE_BACKGROUND_ACCOUNT_NAME_REFRESH";

const AccountFetchFn = *const fn (
    allocator: std.mem.Allocator,
    access_token: []const u8,
    account_id: []const u8,
) anyerror!account_api.FetchResult;
const BackgroundRefreshLockAcquirer = *const fn (
    allocator: std.mem.Allocator,
    codex_home: []const u8,
) anyerror!?account_name_refresh.BackgroundRefreshLock;

pub fn main() !void {
    var exit_code: u8 = 0;
    runMain() catch |err| {
        if (err == error.InvalidCliUsage) {
            exit_code = 2;
        } else if (isHandledCliError(err)) {
            exit_code = 1;
        } else {
            return err;
        }
    };
    if (exit_code != 0) std.process.exit(exit_code);
}

fn runMain() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    var parsed = try cli.parseArgs(allocator, args);
    defer cli.freeParseResult(allocator, &parsed);

    const cmd = switch (parsed) {
        .command => |command| command,
        .usage_error => |usage_err| {
            try cli.printUsageError(&usage_err);
            return error.InvalidCliUsage;
        },
    };

    const needs_codex_home = switch (cmd) {
        .version => false,
        .help => |topic| topic == .top_level,
        else => true,
    };
    const codex_home = if (needs_codex_home) try registry.resolveCodexHome(allocator) else null;
    defer if (codex_home) |path| allocator.free(path);

    switch (cmd) {
        .version => try cli.printVersion(),
        .help => |topic| switch (topic) {
            .top_level => try handleTopLevelHelp(allocator, codex_home.?),
            else => try cli.printCommandHelp(topic),
        },
        .status => try auto.printStatus(allocator, codex_home.?),
        .daemon => |opts| switch (opts.mode) {
            .watch => try auto.runDaemon(allocator, codex_home.?),
            .once => try auto.runDaemonOnce(allocator, codex_home.?),
        },
        .config => |opts| try handleConfig(allocator, codex_home.?, opts),
        .list => |opts| try handleList(allocator, codex_home.?, opts),
        .login => |opts| try handleLogin(allocator, codex_home.?, opts),
        .import_auth => |opts| try handleImport(allocator, codex_home.?, opts),
        .switch_account => |opts| try handleSwitch(allocator, codex_home.?, opts),
        .remove_account => |opts| try handleRemove(allocator, codex_home.?, opts),
        .clean => |_| try handleClean(allocator, codex_home.?),
    }

    if (shouldReconcileManagedService(cmd)) {
        try auto.reconcileManagedService(allocator, codex_home.?);
    }
}

fn isHandledCliError(err: anyerror) bool {
    return err == error.AccountNotFound or
        err == error.RemoveConfirmationUnavailable or
        err == error.RemoveSelectionRequiresTty or
        err == error.InvalidRemoveSelectionInput;
}

pub fn shouldReconcileManagedService(cmd: cli.Command) bool {
    if (std.process.hasNonEmptyEnvVarConstant(skip_service_reconcile_env)) return false;
    return switch (cmd) {
        .help, .version, .status, .daemon => false,
        else => true,
    };
}

pub const ForegroundUsageRefreshTarget = enum {
    list,
    switch_account,
    remove_account,
};

pub fn shouldRefreshForegroundUsage(target: ForegroundUsageRefreshTarget) bool {
    return target == .list or target == .switch_account;
}

fn isAccountNameRefreshOnlyMode() bool {
    return std.process.hasNonEmptyEnvVarConstant(account_name_refresh_only_env);
}

fn isBackgroundAccountNameRefreshDisabled() bool {
    return std.process.hasNonEmptyEnvVarConstant(disable_background_account_name_refresh_env);
}

fn trackedActiveAccountKey(reg: *registry.Registry) ?[]const u8 {
    const account_key = reg.active_account_key orelse return null;
    if (registry.findAccountIndexByAccountKey(reg, account_key) == null) return null;
    return account_key;
}

fn clearStaleActiveAccountKey(allocator: std.mem.Allocator, reg: *registry.Registry) void {
    const account_key = reg.active_account_key orelse return;
    if (registry.findAccountIndexByAccountKey(reg, account_key) != null) return;
    allocator.free(account_key);
    reg.active_account_key = null;
    reg.active_account_activated_at_ms = null;
}

pub fn reconcileActiveAuthAfterRemove(
    allocator: std.mem.Allocator,
    codex_home: []const u8,
    reg: *registry.Registry,
    allow_auth_file_update: bool,
) !void {
    clearStaleActiveAccountKey(allocator, reg);
    if (reg.active_account_key != null) return;

    if (reg.accounts.items.len > 0) {
        const best_idx = registry.selectBestAccountIndexByUsage(reg) orelse 0;
        const account_key = reg.accounts.items[best_idx].account_key;
        if (allow_auth_file_update) {
            try registry.replaceActiveAuthWithAccountByKey(allocator, codex_home, reg, account_key);
        } else {
            try registry.setActiveAccountKey(allocator, reg, account_key);
        }
        return;
    }

    if (!allow_auth_file_update) return;

    const auth_path = try registry.activeAuthPath(allocator, codex_home);
    defer allocator.free(auth_path);
    std.fs.cwd().deleteFile(auth_path) catch |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    };
}

pub const HelpConfig = struct {
    auto_switch: registry.AutoSwitchConfig,
    api: registry.ApiConfig,
};

pub fn loadHelpConfig(allocator: std.mem.Allocator, codex_home: []const u8) HelpConfig {
    var reg = registry.loadRegistry(allocator, codex_home) catch {
        return .{
            .auto_switch = registry.defaultAutoSwitchConfig(),
            .api = registry.defaultApiConfig(),
        };
    };
    defer reg.deinit(allocator);
    return .{
        .auto_switch = reg.auto_switch,
        .api = reg.api,
    };
}

fn maybeRefreshForegroundUsage(
    allocator: std.mem.Allocator,
    codex_home: []const u8,
    reg: *registry.Registry,
    target: ForegroundUsageRefreshTarget,
) !void {
    if (!shouldRefreshForegroundUsage(target)) return;
    if (try auto.refreshActiveUsage(allocator, codex_home, reg)) {
        try registry.saveRegistry(allocator, codex_home, reg);
    }
}

fn defaultAccountFetcher(
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

fn maybeRefreshAccountNamesForAuthInfo(
    allocator: std.mem.Allocator,
    reg: *registry.Registry,
    info: *const auth.AuthInfo,
    fetcher: AccountFetchFn,
) !bool {
    const chatgpt_user_id = info.chatgpt_user_id orelse return false;
    if (!shouldRefreshTeamAccountNamesForUserScope(reg, chatgpt_user_id)) return false;
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

fn loadActiveAuthInfoForAccountRefresh(allocator: std.mem.Allocator, codex_home: []const u8) !?auth.AuthInfo {
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

fn refreshAccountNamesForActiveAuth(
    allocator: std.mem.Allocator,
    codex_home: []const u8,
    reg: *registry.Registry,
    fetcher: AccountFetchFn,
) !bool {
    const active_user_id = registry.activeChatgptUserId(reg) orelse return false;
    if (!shouldRefreshTeamAccountNamesForUserScope(reg, active_user_id)) return false;

    var info = (try loadActiveAuthInfoForAccountRefresh(allocator, codex_home)) orelse return false;
    defer info.deinit(allocator);
    return try maybeRefreshAccountNamesForAuthInfo(allocator, reg, &info, fetcher);
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
    return try refreshAccountNamesForActiveAuth(allocator, codex_home, reg, fetcher);
}

pub fn refreshAccountNamesForList(
    allocator: std.mem.Allocator,
    codex_home: []const u8,
    reg: *registry.Registry,
    fetcher: AccountFetchFn,
) !bool {
    return try refreshAccountNamesForActiveAuth(allocator, codex_home, reg, fetcher);
}

fn shouldRefreshTeamAccountNamesForUserScope(reg: *registry.Registry, chatgpt_user_id: []const u8) bool {
    if (!reg.api.account) return false;
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

fn applyAccountNameRefreshEntriesToLatestRegistry(
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

fn runBackgroundAccountNameRefreshWithLockAcquirer(
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

fn spawnBackgroundAccountNameRefresh(allocator: std.mem.Allocator) !void {
    var env_map = std.process.getEnvMap(allocator) catch |err| {
        std.log.warn("background account metadata refresh skipped: {s}", .{@errorName(err)});
        return;
    };
    defer env_map.deinit();

    try env_map.put(account_name_refresh_only_env, "1");
    try env_map.put(disable_background_account_name_refresh_env, "1");
    try env_map.put(skip_service_reconcile_env, "1");

    const self_exe = try std.fs.selfExePathAlloc(allocator);
    defer allocator.free(self_exe);

    var child = std.process.Child.init(&[_][]const u8{ self_exe, "list" }, allocator);
    child.env_map = &env_map;
    child.stdin_behavior = .Ignore;
    child.stdout_behavior = .Ignore;
    child.stderr_behavior = .Ignore;
    child.create_no_window = true;
    try child.spawn();
}

fn maybeSpawnBackgroundAccountNameRefresh(
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

fn loadSingleFileImportAuthInfo(
    allocator: std.mem.Allocator,
    opts: cli.ImportOptions,
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
            var file = std.fs.cwd().openFile(opts.auth_path.?, .{}) catch |err| {
                std.log.warn("account metadata refresh skipped: {s}", .{@errorName(err)});
                return null;
            };
            defer file.close();

            const data = file.readToEndAlloc(allocator, 10 * 1024 * 1024) catch |err| switch (err) {
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

fn handleList(allocator: std.mem.Allocator, codex_home: []const u8, opts: cli.ListOptions) !void {
    _ = opts;
    if (isAccountNameRefreshOnlyMode()) return try runBackgroundAccountNameRefresh(allocator, codex_home, defaultAccountFetcher);

    var reg = try registry.loadRegistry(allocator, codex_home);
    defer reg.deinit(allocator);
    if (try registry.syncActiveAccountFromAuth(allocator, codex_home, &reg)) {
        try registry.saveRegistry(allocator, codex_home, &reg);
    }
    try maybeRefreshForegroundUsage(allocator, codex_home, &reg, .list);
    try format.printAccounts(&reg);
    maybeSpawnBackgroundAccountNameRefresh(allocator, &reg);
}

fn handleLogin(allocator: std.mem.Allocator, codex_home: []const u8, opts: cli.LoginOptions) !void {
    _ = opts;
    try cli.runCodexLogin(allocator);
    const auth_path = try registry.activeAuthPath(allocator, codex_home);
    defer allocator.free(auth_path);

    const info = try auth.parseAuthInfo(allocator, auth_path);
    defer info.deinit(allocator);

    var reg = try registry.loadRegistry(allocator, codex_home);
    defer reg.deinit(allocator);

    const email = info.email orelse return error.MissingEmail;
    _ = email;
    const record_key = info.record_key orelse return error.MissingChatgptUserId;
    const dest = try registry.accountAuthPath(allocator, codex_home, record_key);
    defer allocator.free(dest);

    try registry.ensureAccountsDir(allocator, codex_home);
    try registry.copyFile(auth_path, dest);

    const record = try registry.accountFromAuth(allocator, "", &info);
    try registry.upsertAccount(allocator, &reg, record);
    try registry.setActiveAccountKey(allocator, &reg, record_key);
    _ = try refreshAccountNamesAfterLogin(allocator, &reg, &info, defaultAccountFetcher);
    try registry.saveRegistry(allocator, codex_home, &reg);
}

fn handleImport(allocator: std.mem.Allocator, codex_home: []const u8, opts: cli.ImportOptions) !void {
    if (opts.purge) {
        var report = try registry.purgeRegistryFromImportSource(allocator, codex_home, opts.auth_path, opts.alias);
        defer report.deinit(allocator);
        try cli.printImportReport(&report);
        if (report.failure) |err| return err;
        return;
    }

    var reg = try registry.loadRegistry(allocator, codex_home);
    defer reg.deinit(allocator);
    var report = switch (opts.source) {
        .standard => try registry.importAuthPath(allocator, codex_home, &reg, opts.auth_path.?, opts.alias),
        .cpa => try registry.importCpaPath(allocator, codex_home, &reg, opts.auth_path, opts.alias),
    };
    defer report.deinit(allocator);
    if (report.appliedCount() > 0) {
        if (report.render_kind == .single_file) {
            var imported_info = try loadSingleFileImportAuthInfo(allocator, opts);
            defer if (imported_info) |*info| info.deinit(allocator);
            _ = try refreshAccountNamesAfterImport(
                allocator,
                &reg,
                opts.purge,
                report.render_kind,
                if (imported_info) |*info| info else null,
                defaultAccountFetcher,
            );
        }
        try registry.saveRegistry(allocator, codex_home, &reg);
    }
    try cli.printImportReport(&report);
    if (report.failure) |err| return err;
}

fn handleSwitch(allocator: std.mem.Allocator, codex_home: []const u8, opts: cli.SwitchOptions) !void {
    var reg = try registry.loadRegistry(allocator, codex_home);
    defer reg.deinit(allocator);
    if (try registry.syncActiveAccountFromAuth(allocator, codex_home, &reg)) {
        try registry.saveRegistry(allocator, codex_home, &reg);
    }
    try maybeRefreshForegroundUsage(allocator, codex_home, &reg, .switch_account);

    var selected_account_key: ?[]const u8 = null;
    if (opts.query) |query| {
        var matches = try findMatchingAccounts(allocator, &reg, query);
        defer matches.deinit(allocator);

        if (matches.items.len == 0) {
            try cli.printAccountNotFoundError(query);
            return error.AccountNotFound;
        }

        if (matches.items.len == 1) {
            selected_account_key = reg.accounts.items[matches.items[0]].account_key;
        } else {
            selected_account_key = try cli.selectAccountFromIndices(allocator, &reg, matches.items);
        }
        if (selected_account_key == null) return;
    } else {
        const selected = try cli.selectAccount(allocator, &reg);
        if (selected == null) return;
        selected_account_key = selected.?;
    }
    const account_key = selected_account_key.?;

    try registry.activateAccountByKey(allocator, codex_home, &reg, account_key);
    try registry.saveRegistry(allocator, codex_home, &reg);
    maybeSpawnBackgroundAccountNameRefresh(allocator, &reg);
}

fn handleConfig(allocator: std.mem.Allocator, codex_home: []const u8, opts: cli.ConfigOptions) !void {
    switch (opts) {
        .auto_switch => |auto_opts| try auto.handleAutoCommand(allocator, codex_home, auto_opts),
        .api => |action| try auto.handleApiCommand(allocator, codex_home, action),
    }
}

fn freeOwnedStrings(allocator: std.mem.Allocator, items: []const []const u8) void {
    for (items) |item| allocator.free(@constCast(item));
}

pub fn findMatchingAccounts(
    allocator: std.mem.Allocator,
    reg: *registry.Registry,
    query: []const u8,
) !std.ArrayList(usize) {
    var matches = std.ArrayList(usize).empty;
    for (reg.accounts.items, 0..) |*rec, idx| {
        const matches_email = std.ascii.indexOfIgnoreCase(rec.email, query) != null;
        const matches_alias = rec.alias.len != 0 and std.ascii.indexOfIgnoreCase(rec.alias, query) != null;
        const matches_name = if (rec.account_name) |name|
            name.len != 0 and std.ascii.indexOfIgnoreCase(name, query) != null
        else
            false;
        if (matches_email or matches_alias or matches_name) {
            try matches.append(allocator, idx);
        }
    }
    return matches;
}

const CurrentAuthState = struct {
    record_key: ?[]u8,
    syncable: bool,
    missing: bool,

    fn deinit(self: *CurrentAuthState, allocator: std.mem.Allocator) void {
        if (self.record_key) |key| allocator.free(key);
    }
};

fn loadCurrentAuthState(allocator: std.mem.Allocator, codex_home: []const u8) !CurrentAuthState {
    const auth_path = try registry.activeAuthPath(allocator, codex_home);
    defer allocator.free(auth_path);

    std.fs.cwd().access(auth_path, .{}) catch |err| switch (err) {
        error.FileNotFound => return .{
            .record_key = null,
            .syncable = false,
            .missing = true,
        },
        else => {},
    };

    const info = auth.parseAuthInfo(allocator, auth_path) catch return .{
        .record_key = null,
        .syncable = false,
        .missing = false,
    };
    defer info.deinit(allocator);

    const record_key = if (info.record_key) |key|
        try allocator.dupe(u8, key)
    else
        null;

    return .{
        .record_key = record_key,
        .syncable = info.email != null and info.record_key != null,
        .missing = false,
    };
}

fn selectionContainsAccountKey(reg: *registry.Registry, indices: []const usize, account_key: []const u8) bool {
    for (indices) |idx| {
        if (idx >= reg.accounts.items.len) continue;
        if (std.mem.eql(u8, reg.accounts.items[idx].account_key, account_key)) return true;
    }
    return false;
}

fn selectionContainsIndex(indices: []const usize, target: usize) bool {
    for (indices) |idx| {
        if (idx == target) return true;
    }
    return false;
}

fn selectBestRemainingAccountKeyByUsageAlloc(
    allocator: std.mem.Allocator,
    reg: *registry.Registry,
    removed_indices: []const usize,
) !?[]u8 {
    if (reg.accounts.items.len == 0) return null;

    const now = std.time.timestamp();
    var best_idx: ?usize = null;
    var best_score: i64 = -2;
    var best_seen: i64 = -1;
    for (reg.accounts.items, 0..) |rec, idx| {
        if (selectionContainsIndex(removed_indices, idx)) continue;

        const score = registry.usageScoreAt(rec.last_usage, now) orelse -1;
        const seen = rec.last_usage_at orelse -1;
        if (score > best_score or (score == best_score and seen > best_seen)) {
            best_idx = idx;
            best_score = score;
            best_seen = seen;
        }
    }

    if (best_idx) |idx| {
        return try allocator.dupe(u8, reg.accounts.items[idx].account_key);
    }
    return null;
}

fn handleRemove(allocator: std.mem.Allocator, codex_home: []const u8, opts: cli.RemoveOptions) !void {
    var reg = try registry.loadRegistry(allocator, codex_home);
    defer reg.deinit(allocator);

    if (try registry.syncActiveAccountFromAuth(allocator, codex_home, &reg)) {
        try registry.saveRegistry(allocator, codex_home, &reg);
    }
    try maybeRefreshForegroundUsage(allocator, codex_home, &reg, .remove_account);

    var selected: ?[]usize = null;
    if (opts.all) {
        selected = try allocator.alloc(usize, reg.accounts.items.len);
        for (selected.?, 0..) |*slot, idx| slot.* = idx;
    } else if (opts.query) |query| {
        var matches = try findMatchingAccounts(allocator, &reg, query);
        defer matches.deinit(allocator);

        if (matches.items.len == 0) {
            try cli.printAccountNotFoundError(query);
            return error.AccountNotFound;
        }

        if (matches.items.len > 1) {
            var matched_labels = try cli.buildRemoveLabels(allocator, &reg, matches.items);
            defer {
                freeOwnedStrings(allocator, matched_labels.items);
                matched_labels.deinit(allocator);
            }
            if (!std.fs.File.stdin().isTty()) {
                try cli.printRemoveConfirmationUnavailableError(matched_labels.items);
                return error.RemoveConfirmationUnavailable;
            }
            if (!(try cli.confirmRemoveMatches(matched_labels.items))) return;
        }

        selected = try allocator.dupe(usize, matches.items);
    } else {
        selected = cli.selectAccountsToRemove(allocator, &reg) catch |err| switch (err) {
            error.InvalidRemoveSelectionInput => {
                try cli.printInvalidRemoveSelectionError();
                return error.InvalidRemoveSelectionInput;
            },
            else => return err,
        };
    }
    if (selected == null) return;
    defer allocator.free(selected.?);
    if (selected.?.len == 0) return;

    var removed_labels = try cli.buildRemoveLabels(allocator, &reg, selected.?);
    defer {
        freeOwnedStrings(allocator, removed_labels.items);
        removed_labels.deinit(allocator);
    }

    const current_active_account_key = if (trackedActiveAccountKey(&reg)) |key|
        try allocator.dupe(u8, key)
    else
        null;
    defer if (current_active_account_key) |key| allocator.free(key);

    var current_auth_state = try loadCurrentAuthState(allocator, codex_home);
    defer current_auth_state.deinit(allocator);

    const active_removed = if (current_active_account_key) |key|
        selectionContainsAccountKey(&reg, selected.?, key)
    else
        false;
    const allow_auth_file_update = if (current_active_account_key) |key|
        active_removed and ((current_auth_state.syncable and current_auth_state.record_key != null and
            std.mem.eql(u8, current_auth_state.record_key.?, key)) or current_auth_state.missing)
    else if (current_auth_state.missing)
        true
    else if (opts.all)
        current_auth_state.syncable and current_auth_state.record_key != null and
            selectionContainsAccountKey(&reg, selected.?, current_auth_state.record_key.?)
    else
        false;

    const replacement_account_key = if (active_removed)
        try selectBestRemainingAccountKeyByUsageAlloc(allocator, &reg, selected.?)
    else
        null;
    defer if (replacement_account_key) |key| allocator.free(key);

    if (replacement_account_key) |key| {
        if (allow_auth_file_update) {
            try registry.replaceActiveAuthWithAccountByKey(allocator, codex_home, &reg, key);
        } else {
            try registry.setActiveAccountKey(allocator, &reg, key);
        }
    }

    try registry.removeAccounts(allocator, codex_home, &reg, selected.?);
    try reconcileActiveAuthAfterRemove(allocator, codex_home, &reg, allow_auth_file_update);
    try registry.saveRegistry(allocator, codex_home, &reg);
    try cli.printRemoveSummary(removed_labels.items);
}

fn handleTopLevelHelp(allocator: std.mem.Allocator, codex_home: []const u8) !void {
    const help_cfg = loadHelpConfig(allocator, codex_home);
    try cli.printHelp(&help_cfg.auto_switch, &help_cfg.api);
}

fn handleClean(allocator: std.mem.Allocator, codex_home: []const u8) !void {
    const summary = try registry.cleanAccountsBackups(allocator, codex_home);
    var stdout: [256]u8 = undefined;
    var writer = std.fs.File.stdout().writer(&stdout);
    const out = &writer.interface;
    try out.print(
        "cleaned accounts: auth_backups={d}, registry_backups={d}, stale_entries={d}\n",
        .{
            summary.auth_backups_removed,
            summary.registry_backups_removed,
            summary.stale_snapshot_files_removed,
        },
    );
    try out.flush();
}

test "background account-name refresh returns early when another refresh holds the lock" {
    const TestState = struct {
        var fetch_count: usize = 0;

        fn lockUnavailable(_: std.mem.Allocator, _: []const u8) !?account_name_refresh.BackgroundRefreshLock {
            return null;
        }

        fn unexpectedFetcher(
            allocator: std.mem.Allocator,
            access_token: []const u8,
            account_id: []const u8,
        ) !account_api.FetchResult {
            _ = allocator;
            _ = access_token;
            _ = account_id;
            fetch_count += 1;
            return error.TestUnexpectedFetch;
        }
    };

    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const codex_home = try tmp.dir.realpathAlloc(gpa, ".");
    defer gpa.free(codex_home);

    TestState.fetch_count = 0;
    try runBackgroundAccountNameRefreshWithLockAcquirer(
        gpa,
        codex_home,
        TestState.unexpectedFetcher,
        TestState.lockUnavailable,
    );
    try std.testing.expectEqual(@as(usize, 0), TestState.fetch_count);
}

// Tests live in separate files but are pulled in by main.zig for zig test.
test {
    _ = @import("tests/auth_test.zig");
    _ = @import("tests/sessions_test.zig");
    _ = @import("tests/account_api_test.zig");
    _ = @import("tests/usage_api_test.zig");
    _ = @import("tests/auto_test.zig");
    _ = @import("tests/registry_test.zig");
    _ = @import("tests/registry_bdd_test.zig");
    _ = @import("tests/cli_bdd_test.zig");
    _ = @import("tests/display_rows_test.zig");
    _ = @import("tests/main_test.zig");
    _ = @import("tests/purge_test.zig");
    _ = @import("tests/e2e_cli_test.zig");
}

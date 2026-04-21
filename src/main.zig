const std = @import("std");
const app_runtime = @import("runtime.zig");
const account_api = @import("account_api.zig");
const account_name_refresh = @import("account_name_refresh.zig");
const cli = @import("cli.zig");
const chatgpt_http = @import("chatgpt_http.zig");
const display_rows = @import("display_rows.zig");
const registry = @import("registry.zig");
const auth = @import("auth.zig");
const auto = @import("auto.zig");
const format = @import("format.zig");
const usage_api = @import("usage_api.zig");
const bdd = @import("tests/bdd_helpers.zig");

const skip_service_reconcile_env = "CODEX_AUTH_SKIP_SERVICE_RECONCILE";
const account_name_refresh_only_env = "CODEX_AUTH_REFRESH_ACCOUNT_NAMES_ONLY";
const disable_background_account_name_refresh_env = "CODEX_AUTH_DISABLE_BACKGROUND_ACCOUNT_NAME_REFRESH";
const foreground_usage_refresh_concurrency: usize = 5;
const switch_live_api_refresh_interval_ms: i64 = 30_000;
const switch_live_local_refresh_interval_ms: i64 = 10_000;

fn getEnvMap(allocator: std.mem.Allocator) !std.process.Environ.Map {
    return try app_runtime.currentEnviron().createMap(allocator);
}

fn getEnvVarOwned(allocator: std.mem.Allocator, name: []const u8) ![]u8 {
    var env_map = try getEnvMap(allocator);
    defer env_map.deinit();

    const value = env_map.get(name) orelse return error.EnvironmentVariableNotFound;
    return try allocator.dupe(u8, value);
}

fn nowMilliseconds() i64 {
    return std.Io.Timestamp.now(app_runtime.io(), .real).toMilliseconds();
}

fn nowSeconds() i64 {
    return std.Io.Timestamp.now(app_runtime.io(), .real).toSeconds();
}

const AccountFetchFn = *const fn (
    allocator: std.mem.Allocator,
    access_token: []const u8,
    account_id: []const u8,
) anyerror!account_api.FetchResult;
const UsageFetchDetailedFn = *const fn (
    allocator: std.mem.Allocator,
    auth_path: []const u8,
) anyerror!usage_api.UsageFetchResult;
const UsageBatchFetchDetailedFn = *const fn (
    allocator: std.mem.Allocator,
    auth_paths: []const []const u8,
    max_concurrency: usize,
) anyerror![]usage_api.BatchUsageFetchResult;
const ForegroundUsagePoolInitFn = *const fn (
    allocator: std.mem.Allocator,
    n_jobs: usize,
) anyerror!void;
const BackgroundRefreshLockAcquirer = *const fn (
    allocator: std.mem.Allocator,
    codex_home: []const u8,
) anyerror!?account_name_refresh.BackgroundRefreshLock;

const ForegroundUsageWorkerResult = struct {
    status_code: ?u16 = null,
    missing_auth: bool = false,
    error_name: ?[]const u8 = null,
    snapshot: ?registry.RateLimitSnapshot = null,

    fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
        if (self.snapshot) |*snapshot| {
            registry.freeRateLimitSnapshot(allocator, snapshot);
            self.snapshot = null;
        }
    }
};

pub const ForegroundUsageOutcome = struct {
    attempted: bool = false,
    status_code: ?u16 = null,
    missing_auth: bool = false,
    error_name: ?[]const u8 = null,
    has_usage_windows: bool = false,
    updated: bool = false,
    unchanged: bool = false,
};

pub const ForegroundUsageRefreshState = struct {
    usage_overrides: []?[]const u8,
    outcomes: []ForegroundUsageOutcome,
    attempted: usize = 0,
    updated: usize = 0,
    failed: usize = 0,
    unchanged: usize = 0,
    local_only_mode: bool = false,

    pub fn deinit(self: *ForegroundUsageRefreshState, allocator: std.mem.Allocator) void {
        for (self.usage_overrides) |override| {
            if (override) |value| allocator.free(value);
        }
        allocator.free(self.usage_overrides);
        allocator.free(self.outcomes);
        self.* = undefined;
    }
};

const SwitchQueryResolution = union(enum) {
    not_found,
    direct: []const u8,
    multiple: std.ArrayList(usize),

    pub fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
        switch (self.*) {
            .multiple => |*matches| matches.deinit(allocator),
            else => {},
        }
        self.* = undefined;
    }
};

pub fn main(init: std.process.Init.Minimal) !void {
    var exit_code: u8 = 0;
    runMain(init) catch |err| {
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

fn runMain(init: std.process.Init.Minimal) !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer std.debug.assert(gpa.deinit() == .ok);
    const allocator = gpa.allocator();

    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const args = try init.args.toSlice(arena_state.allocator());

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
        .clean => try handleClean(allocator, codex_home.?),
    }

    if (shouldReconcileManagedService(cmd)) {
        try auto.reconcileManagedService(allocator, codex_home.?);
    }
}

fn isHandledCliError(err: anyerror) bool {
    return err == error.AccountNotFound or
        err == error.CodexLoginFailed or
        err == error.ListLiveRequiresTty or
        err == error.NodeJsRequired or
        err == error.SwitchSelectionRequiresTty or
        err == error.RemoveConfirmationUnavailable or
        err == error.RemoveSelectionRequiresTty or
        err == error.InvalidRemoveSelectionInput;
}

pub fn shouldReconcileManagedService(cmd: cli.Command) bool {
    if (hasNonEmptyEnvVar(skip_service_reconcile_env)) return false;
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

const LiveTtyTarget = enum {
    list,
    switch_account,
    remove_account,
};

fn liveTtyPreflightError(target: LiveTtyTarget, stdin_is_tty: bool, stdout_is_tty: bool) ?anyerror {
    if (stdin_is_tty and stdout_is_tty) return null;
    return switch (target) {
        .list => error.ListLiveRequiresTty,
        .switch_account => error.SwitchSelectionRequiresTty,
        .remove_account => error.RemoveSelectionRequiresTty,
    };
}

fn ensureLiveTty(target: LiveTtyTarget) !void {
    const err = liveTtyPreflightError(
        target,
        std.Io.File.stdin().isTty(app_runtime.io()) catch false,
        std.Io.File.stdout().isTty(app_runtime.io()) catch false,
    ) orelse return;

    switch (target) {
        .list => try cli.printListRequiresTtyError(),
        .switch_account => try cli.printSwitchRequiresTtyError(),
        .remove_account => try cli.printRemoveRequiresTtyError(),
    }
    return err;
}

pub fn shouldRefreshForegroundUsage(target: ForegroundUsageRefreshTarget) bool {
    return target == .list or target == .switch_account or target == .remove_account;
}

fn apiModeUsesApi(default_enabled: bool, api_mode: cli.ApiMode) bool {
    return switch (api_mode) {
        .default => default_enabled,
        .force_api => true,
        .skip_api => false,
    };
}

fn shouldPreflightNodeForForegroundTargetWithApiEnabled(
    allocator: std.mem.Allocator,
    codex_home: []const u8,
    reg: *registry.Registry,
    target: ForegroundUsageRefreshTarget,
    usage_api_enabled: bool,
    account_api_enabled: bool,
) !bool {
    if (shouldRefreshForegroundUsage(target) and usage_api_enabled and reg.accounts.items.len != 0) {
        return true;
    }

    const active_user_id = registry.activeChatgptUserId(reg) orelse return false;
    if (!shouldRefreshTeamAccountNamesForUserScopeWithAccountApiEnabled(reg, active_user_id, account_api_enabled)) {
        return false;
    }

    var info = (try loadActiveAuthInfoForAccountRefresh(allocator, codex_home)) orelse return false;
    defer info.deinit(allocator);
    return info.access_token != null and info.chatgpt_account_id != null;
}

fn ensureForegroundNodeAvailableWithApiEnabled(
    allocator: std.mem.Allocator,
    codex_home: []const u8,
    reg: *registry.Registry,
    target: ForegroundUsageRefreshTarget,
    usage_api_enabled: bool,
    account_api_enabled: bool,
) !void {
    if (!try shouldPreflightNodeForForegroundTargetWithApiEnabled(
        allocator,
        codex_home,
        reg,
        target,
        usage_api_enabled,
        account_api_enabled,
    )) return;

    try chatgpt_http.ensureNodeExecutableAvailable(allocator);
}

fn isAccountNameRefreshOnlyMode() bool {
    return hasNonEmptyEnvVar(account_name_refresh_only_env);
}

fn isBackgroundAccountNameRefreshDisabled() bool {
    return hasNonEmptyEnvVar(disable_background_account_name_refresh_env);
}

fn hasNonEmptyEnvVar(name: []const u8) bool {
    const value = getEnvVarOwned(std.heap.page_allocator, name) catch |err| switch (err) {
        error.EnvironmentVariableNotFound => return false,
        else => return false,
    };
    defer std.heap.page_allocator.free(value);
    return value.len != 0;
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
    std.Io.Dir.cwd().deleteFile(app_runtime.io(), auth_path) catch |err| switch (err) {
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

fn initForegroundUsageRefreshState(
    allocator: std.mem.Allocator,
    account_count: usize,
) !ForegroundUsageRefreshState {
    const usage_overrides = try allocator.alloc(?[]const u8, account_count);
    errdefer allocator.free(usage_overrides);
    for (usage_overrides) |*slot| slot.* = null;

    const outcomes = try allocator.alloc(ForegroundUsageOutcome, account_count);
    errdefer allocator.free(outcomes);
    for (outcomes) |*outcome| outcome.* = .{};

    return .{
        .usage_overrides = usage_overrides,
        .outcomes = outcomes,
    };
}

pub fn refreshForegroundUsageForDisplayWithApiFetcher(
    allocator: std.mem.Allocator,
    codex_home: []const u8,
    reg: *registry.Registry,
    usage_fetcher: UsageFetchDetailedFn,
) !ForegroundUsageRefreshState {
    return refreshForegroundUsageForDisplayWithApiFetchersWithPoolInitUsingApiEnabled(
        allocator,
        codex_home,
        reg,
        usage_fetcher,
        null,
        initForegroundUsagePool,
        reg.api.usage,
        false,
    );
}

pub fn refreshForegroundUsageForDisplay(
    allocator: std.mem.Allocator,
    codex_home: []const u8,
    reg: *registry.Registry,
) !ForegroundUsageRefreshState {
    return refreshForegroundUsageForDisplayWithBatchFetcherUsingApiEnabled(
        allocator,
        codex_home,
        reg,
        reg.api.usage,
    );
}

fn refreshForegroundUsageForDisplayWithBatchFetcherUsingApiEnabled(
    allocator: std.mem.Allocator,
    codex_home: []const u8,
    reg: *registry.Registry,
    usage_api_enabled: bool,
) !ForegroundUsageRefreshState {
    return refreshForegroundUsageForDisplayWithBatchFetcherUsingApiEnabledWithBatchFailurePolicy(
        allocator,
        codex_home,
        reg,
        usage_api_enabled,
        false,
    );
}

fn refreshForegroundUsageForDisplayWithBatchFetcherUsingApiEnabledWithBatchFailurePolicy(
    allocator: std.mem.Allocator,
    codex_home: []const u8,
    reg: *registry.Registry,
    usage_api_enabled: bool,
    batch_fetch_failures_are_fatal: bool,
) !ForegroundUsageRefreshState {
    return refreshForegroundUsageForDisplayWithApiFetchersWithPoolInitUsingApiEnabled(
        allocator,
        codex_home,
        reg,
        usage_api.fetchUsageForAuthPathDetailed,
        usage_api.fetchUsageForAuthPathsDetailedBatch,
        initForegroundUsagePool,
        usage_api_enabled,
        batch_fetch_failures_are_fatal,
    );
}

pub fn refreshForegroundUsageForDisplayWithApiFetcherWithPoolInit(
    allocator: std.mem.Allocator,
    codex_home: []const u8,
    reg: *registry.Registry,
    usage_fetcher: UsageFetchDetailedFn,
    pool_init: ForegroundUsagePoolInitFn,
) !ForegroundUsageRefreshState {
    return refreshForegroundUsageForDisplayWithApiFetchersWithPoolInitUsingApiEnabled(
        allocator,
        codex_home,
        reg,
        usage_fetcher,
        null,
        pool_init,
        reg.api.usage,
        false,
    );
}

fn refreshForegroundUsageForDisplayWithApiFetchersWithPoolInitUsingApiEnabled(
    allocator: std.mem.Allocator,
    codex_home: []const u8,
    reg: *registry.Registry,
    usage_fetcher: UsageFetchDetailedFn,
    batch_fetcher: ?UsageBatchFetchDetailedFn,
    pool_init: ForegroundUsagePoolInitFn,
    usage_api_enabled: bool,
    batch_fetch_failures_are_fatal: bool,
) !ForegroundUsageRefreshState {
    return refreshForegroundUsageForDisplayWithApiFetchersWithPoolInitUsingApiEnabledAndPersist(
        allocator,
        codex_home,
        reg,
        usage_fetcher,
        batch_fetcher,
        pool_init,
        usage_api_enabled,
        batch_fetch_failures_are_fatal,
        true,
    );
}

fn refreshForegroundUsageForDisplayWithApiFetchersWithPoolInitUsingApiEnabledAndPersist(
    allocator: std.mem.Allocator,
    codex_home: []const u8,
    reg: *registry.Registry,
    usage_fetcher: UsageFetchDetailedFn,
    batch_fetcher: ?UsageBatchFetchDetailedFn,
    pool_init: ForegroundUsagePoolInitFn,
    usage_api_enabled: bool,
    batch_fetch_failures_are_fatal: bool,
    persist_registry: bool,
) !ForegroundUsageRefreshState {
    var state = try initForegroundUsageRefreshState(allocator, reg.accounts.items.len);
    errdefer state.deinit(allocator);

    if (!usage_api_enabled) {
        state.local_only_mode = true;
        if (try auto.refreshActiveUsage(allocator, codex_home, reg)) {
            if (persist_registry) try registry.saveRegistry(allocator, codex_home, reg);
        }
        return state;
    }

    if (reg.accounts.items.len == 0) return state;

    const worker_results = try allocator.alloc(ForegroundUsageWorkerResult, reg.accounts.items.len);
    defer {
        for (worker_results) |*worker_result| worker_result.deinit(allocator);
        allocator.free(worker_results);
    }
    for (worker_results) |*worker_result| worker_result.* = .{};

    if (batch_fetcher) |fetch_batch| batch_fetch: {
        var auth_path_arena_state = std.heap.ArenaAllocator.init(std.heap.smp_allocator);
        defer auth_path_arena_state.deinit();
        const auth_path_arena = auth_path_arena_state.allocator();

        const auth_paths = try auth_path_arena.alloc([]const u8, reg.accounts.items.len);
        for (reg.accounts.items, 0..) |account, idx| {
            auth_paths[idx] = try registry.accountAuthPath(auth_path_arena, codex_home, account.account_key);
        }

        const batch_results = fetch_batch(
            allocator,
            auth_paths,
            @min(reg.accounts.items.len, foreground_usage_refresh_concurrency),
        ) catch |err| switch (err) {
            error.OutOfMemory => return err,
            else => {
                if (batch_fetch_failures_are_fatal) return err;
                const error_name = @errorName(err);
                for (worker_results, 0..) |*worker_result, idx| {
                    _ = idx;
                    worker_result.* = .{ .error_name = error_name };
                }
                break :batch_fetch;
            },
        };
        defer {
            for (batch_results) |*batch_result| batch_result.deinit(allocator);
            allocator.free(batch_results);
        }

        for (batch_results, 0..) |*batch_result, idx| {
            worker_results[idx] = .{
                .status_code = batch_result.status_code,
                .missing_auth = batch_result.missing_auth,
                .error_name = batch_result.error_name,
                .snapshot = batch_result.snapshot,
            };
            batch_result.snapshot = null;
        }
    } else {
        var use_concurrent_usage_refresh = reg.accounts.items.len > 1;
        if (use_concurrent_usage_refresh) {
            pool_init(
                allocator,
                @min(reg.accounts.items.len, foreground_usage_refresh_concurrency),
            ) catch |err| switch (err) {
                error.OutOfMemory => return err,
                else => use_concurrent_usage_refresh = false,
            };
        }

        if (use_concurrent_usage_refresh) {
            try runForegroundUsageRefreshWorkersConcurrently(
                allocator,
                codex_home,
                reg,
                usage_fetcher,
                worker_results,
            );
        } else {
            runForegroundUsageRefreshWorkersSerially(allocator, codex_home, reg, usage_fetcher, worker_results);
        }
    }

    var registry_changed = false;
    for (worker_results, 0..) |*worker_result, idx| {
        const outcome = &state.outcomes[idx];
        outcome.* = .{
            .attempted = true,
            .status_code = worker_result.status_code,
            .missing_auth = worker_result.missing_auth,
            .error_name = worker_result.error_name,
            .has_usage_windows = worker_result.snapshot != null,
        };
        state.attempted += 1;

        if (worker_result.snapshot) |snapshot| {
            if (registry.rateLimitSnapshotsEqual(reg.accounts.items[idx].last_usage, snapshot)) {
                outcome.unchanged = true;
                state.unchanged += 1;
                worker_result.deinit(allocator);
            } else {
                registry.updateUsage(allocator, reg, reg.accounts.items[idx].account_key, snapshot);
                worker_result.snapshot = null;
                outcome.updated = true;
                state.updated += 1;
                registry_changed = true;
            }
        } else if (try setForegroundUsageOverrideForOutcome(allocator, &state.usage_overrides[idx], outcome.*)) {
            state.failed += 1;
        } else {
            outcome.unchanged = true;
            state.unchanged += 1;
        }
    }

    if (persist_registry and registry_changed) {
        try registry.saveRegistry(allocator, codex_home, reg);
    }

    return state;
}

fn initForegroundUsagePool(
    allocator: std.mem.Allocator,
    n_jobs: usize,
) !void {
    _ = allocator;
    _ = n_jobs;
}

const ForegroundUsageWorkerQueue = struct {
    allocator: std.mem.Allocator,
    codex_home: []const u8,
    reg: *registry.Registry,
    usage_fetcher: UsageFetchDetailedFn,
    results: []ForegroundUsageWorkerResult,
    next_index: std.atomic.Value(usize) = .init(0),

    fn run(self: *ForegroundUsageWorkerQueue) void {
        while (true) {
            const idx = self.next_index.fetchAdd(1, .monotonic);
            if (idx >= self.reg.accounts.items.len) return;

            foregroundUsageRefreshWorker(
                self.allocator,
                self.codex_home,
                self.reg,
                idx,
                self.usage_fetcher,
                self.results,
            );
        }
    }
};

fn runForegroundUsageRefreshWorkersConcurrently(
    allocator: std.mem.Allocator,
    codex_home: []const u8,
    reg: *registry.Registry,
    usage_fetcher: UsageFetchDetailedFn,
    results: []ForegroundUsageWorkerResult,
) !void {
    const worker_count = @min(reg.accounts.items.len, foreground_usage_refresh_concurrency);
    if (worker_count <= 1) {
        runForegroundUsageRefreshWorkersSerially(allocator, codex_home, reg, usage_fetcher, results);
        return;
    }

    var queue: ForegroundUsageWorkerQueue = .{
        .allocator = allocator,
        .codex_home = codex_home,
        .reg = reg,
        .usage_fetcher = usage_fetcher,
        .results = results,
    };

    const helper_count = worker_count - 1;
    var threads = try allocator.alloc(std.Thread, helper_count);
    defer allocator.free(threads);

    var spawned_count: usize = 0;
    defer {
        for (threads[0..spawned_count]) |thread| thread.join();
    }

    for (threads) |*thread| {
        thread.* = std.Thread.spawn(.{}, ForegroundUsageWorkerQueue.run, .{&queue}) catch |err| switch (err) {
            error.OutOfMemory => return err,
            else => break,
        };
        spawned_count += 1;
    }

    queue.run();
}

fn runForegroundUsageRefreshWorkersSerially(
    allocator: std.mem.Allocator,
    codex_home: []const u8,
    reg: *registry.Registry,
    usage_fetcher: UsageFetchDetailedFn,
    results: []ForegroundUsageWorkerResult,
) void {
    for (reg.accounts.items, 0..) |_, idx| {
        foregroundUsageRefreshWorker(allocator, codex_home, reg, idx, usage_fetcher, results);
    }
}

fn foregroundUsageRefreshWorker(
    allocator: std.mem.Allocator,
    codex_home: []const u8,
    reg: *registry.Registry,
    account_idx: usize,
    usage_fetcher: UsageFetchDetailedFn,
    results: []ForegroundUsageWorkerResult,
) void {
    var arena_state = std.heap.ArenaAllocator.init(std.heap.smp_allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const auth_path = registry.accountAuthPath(arena, codex_home, reg.accounts.items[account_idx].account_key) catch |err| {
        results[account_idx] = .{ .error_name = @errorName(err) };
        return;
    };

    const fetch_result = usage_fetcher(arena, auth_path) catch |err| {
        results[account_idx] = .{ .error_name = @errorName(err) };
        return;
    };

    var result: ForegroundUsageWorkerResult = .{
        .status_code = fetch_result.status_code,
        .missing_auth = fetch_result.missing_auth,
    };

    if (fetch_result.snapshot) |snapshot| {
        result.snapshot = registry.cloneRateLimitSnapshot(allocator, snapshot) catch |err| {
            results[account_idx] = .{
                .status_code = fetch_result.status_code,
                .missing_auth = fetch_result.missing_auth,
                .error_name = @errorName(err),
            };
            return;
        };
    }

    results[account_idx] = result;
}

fn setForegroundUsageOverrideForOutcome(
    allocator: std.mem.Allocator,
    slot: *?[]const u8,
    outcome: ForegroundUsageOutcome,
) !bool {
    if (outcome.error_name) |error_name| {
        slot.* = try allocator.dupe(u8, error_name);
        return true;
    }
    if (outcome.missing_auth) {
        slot.* = try allocator.dupe(u8, "MissingAuth");
        return true;
    }
    if (outcome.status_code) |status_code| {
        if (status_code != 200) {
            slot.* = try std.fmt.allocPrint(allocator, "{d}", .{status_code});
            return true;
        }
    }
    return false;
}

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

fn maybeRefreshForegroundAccountNamesWithAccountApiEnabled(
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

fn maybeRefreshForegroundAccountNamesWithAccountApiEnabledAndPersist(
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
    return try maybeRefreshAccountNamesForAuthInfoWithAccountApiEnabled(
        allocator,
        reg,
        info,
        fetcher,
        reg.api.account,
    );
}

fn maybeRefreshAccountNamesForAuthInfoWithAccountApiEnabled(
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
    return try refreshAccountNamesForActiveAuthWithAccountApiEnabled(
        allocator,
        codex_home,
        reg,
        fetcher,
        reg.api.account,
    );
}

fn refreshAccountNamesForActiveAuthWithAccountApiEnabled(
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

fn refreshAccountNamesAfterSwitchWithAccountApiEnabled(
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

fn refreshAccountNamesForListWithAccountApiEnabled(
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

fn shouldRefreshTeamAccountNamesForUserScope(reg: *registry.Registry, chatgpt_user_id: []const u8) bool {
    return shouldRefreshTeamAccountNamesForUserScopeWithAccountApiEnabled(reg, chatgpt_user_id, reg.api.account);
}

fn shouldRefreshTeamAccountNamesForUserScopeWithAccountApiEnabled(
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

fn handleList(allocator: std.mem.Allocator, codex_home: []const u8, opts: cli.ListOptions) !void {
    if (isAccountNameRefreshOnlyMode()) return try runBackgroundAccountNameRefresh(allocator, codex_home, defaultAccountFetcher);

    if (opts.live) {
        try ensureLiveTty(.list);
        const live_allocator = std.heap.smp_allocator;
        const loaded = try loadInitialLiveSelectionDisplay(
            live_allocator,
            codex_home,
            .list,
            opts.api_mode,
        );
        var initial_display: ?cli.OwnedSwitchSelectionDisplay = loaded.display;
        errdefer if (initial_display) |*display| display.deinit(live_allocator);

        var runtime = SwitchLiveRuntime.init(
            live_allocator,
            codex_home,
            .list,
            opts.api_mode,
            opts.api_mode == .force_api,
            loaded.policy,
            loaded.refresh_error_name,
        );
        defer runtime.deinit();

        const controller: cli.SwitchLiveController = .{
            .context = @ptrCast(&runtime),
            .maybe_start_refresh = switchLiveRuntimeMaybeStartRefresh,
            .maybe_take_updated_display = switchLiveRuntimeMaybeTakeUpdatedDisplay,
            .build_status_line = switchLiveRuntimeBuildStatusLine,
        };

        const transferred_display = initial_display.?;
        initial_display = null;
        cli.viewAccountsWithLiveUpdates(live_allocator, transferred_display, controller) catch |err| {
            if (err == error.TuiRequiresTty) {
                try cli.printListRequiresTtyError();
                return error.ListLiveRequiresTty;
            }
            return err;
        };
        return;
    }

    var reg = try registry.loadRegistry(allocator, codex_home);
    defer reg.deinit(allocator);
    if (try registry.syncActiveAccountFromAuth(allocator, codex_home, &reg)) {
        try registry.saveRegistry(allocator, codex_home, &reg);
    }

    const usage_api_enabled = apiModeUsesApi(reg.api.usage, opts.api_mode);
    const account_api_enabled = apiModeUsesApi(reg.api.account, opts.api_mode);

    try ensureForegroundNodeAvailableWithApiEnabled(
        allocator,
        codex_home,
        &reg,
        .list,
        usage_api_enabled,
        account_api_enabled,
    );

    var usage_state = try refreshForegroundUsageForDisplayWithBatchFetcherUsingApiEnabled(
        allocator,
        codex_home,
        &reg,
        usage_api_enabled,
    );
    defer usage_state.deinit(allocator);
    try maybeRefreshForegroundAccountNamesWithAccountApiEnabled(
        allocator,
        codex_home,
        &reg,
        .list,
        defaultAccountFetcher,
        account_api_enabled,
    );
    try format.printAccountsWithUsageOverrides(&reg, usage_state.usage_overrides);
}

fn handleLogin(allocator: std.mem.Allocator, codex_home: []const u8, opts: cli.LoginOptions) !void {
    try cli.runCodexLogin(opts);
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
    try registry.copyManagedFile(auth_path, dest);

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
    if (opts.query) |query| {
        var reg = try registry.loadRegistry(allocator, codex_home);
        defer reg.deinit(allocator);
        if (try registry.syncActiveAccountFromAuth(allocator, codex_home, &reg)) {
            try registry.saveRegistry(allocator, codex_home, &reg);
        }
        std.debug.assert(opts.api_mode == .default);
        std.debug.assert(!opts.live);
        std.debug.assert(!opts.auto);

        var resolution = try resolveSwitchQueryLocally(allocator, &reg, query);
        defer resolution.deinit(allocator);

        const selected_account_key = switch (resolution) {
            .not_found => {
                try cli.printAccountNotFoundError(query);
                return error.AccountNotFound;
            },
            .direct => |account_key| account_key,
            .multiple => |matches| cli.selectAccountFromIndicesWithUsageOverrides(
                allocator,
                &reg,
                matches.items,
                null,
            ) catch |err| {
                if (err == error.TuiRequiresTty) {
                    try cli.printSwitchRequiresTtyError();
                    return error.SwitchSelectionRequiresTty;
                }
                return err;
            },
        };
        if (selected_account_key == null) return;
        try registry.activateAccountByKey(allocator, codex_home, &reg, selected_account_key.?);
        try registry.saveRegistry(allocator, codex_home, &reg);
        return;
    }

    if (!opts.live) {
        var loaded = if (opts.api_mode == .skip_api)
            try loadStoredSwitchSelectionDisplay(
                allocator,
                codex_home,
                .switch_account,
                opts.api_mode,
            )
        else
            try loadSwitchSelectionDisplay(
                allocator,
                codex_home,
                opts.api_mode,
                .switch_account,
                true,
            );
        defer loaded.display.deinit(allocator);
        defer if (loaded.refresh_error_name) |name| allocator.free(name);

        const selected_account_key = cli.selectAccountWithUsageOverrides(
            allocator,
            &loaded.display.reg,
            loaded.display.usage_overrides,
        ) catch |err| {
            if (err == error.TuiRequiresTty) {
                try cli.printSwitchRequiresTtyError();
                return error.SwitchSelectionRequiresTty;
            }
            return err;
        };
        if (selected_account_key == null) return;
        try registry.activateAccountByKey(allocator, codex_home, &loaded.display.reg, selected_account_key.?);
        try registry.saveRegistry(allocator, codex_home, &loaded.display.reg);
        return;
    }

    try ensureLiveTty(.switch_account);
    const live_allocator = std.heap.smp_allocator;
    const strict_refresh = opts.api_mode == .force_api;
    const loaded = try loadInitialLiveSelectionDisplay(
        live_allocator,
        codex_home,
        .switch_account,
        opts.api_mode,
    );
    var initial_display: ?cli.OwnedSwitchSelectionDisplay = loaded.display;
    errdefer if (initial_display) |*display| display.deinit(live_allocator);

    var runtime = SwitchLiveRuntime.init(
        live_allocator,
        codex_home,
        .switch_account,
        opts.api_mode,
        strict_refresh,
        loaded.policy,
        loaded.refresh_error_name,
    );
    defer runtime.deinit();

    const controller: cli.SwitchLiveActionController = .{
        .refresh = .{
            .context = @ptrCast(&runtime),
            .maybe_start_refresh = switchLiveRuntimeMaybeStartRefresh,
            .maybe_take_updated_display = switchLiveRuntimeMaybeTakeUpdatedDisplay,
            .build_status_line = switchLiveRuntimeBuildStatusLine,
        },
        .apply_selection = switchLiveRuntimeApplySelection,
        .auto_switch = opts.auto,
    };

    const transferred_display = initial_display.?;
    initial_display = null;
    cli.runSwitchLiveActions(live_allocator, transferred_display, controller) catch |err| {
        if (err == error.TuiRequiresTty) {
            try cli.printSwitchRequiresTtyError();
            return error.SwitchSelectionRequiresTty;
        }
        return err;
    };
}

const SwitchLiveRefreshPolicy = struct {
    usage_api_enabled: bool,
    account_api_enabled: bool,
    interval_ms: i64,
    label: []const u8,
};

const SwitchLoadedDisplay = struct {
    display: cli.OwnedSwitchSelectionDisplay,
    policy: SwitchLiveRefreshPolicy,
    refresh_error_name: ?[]u8 = null,
};

const SwitchLiveRefreshTaskContext = struct {
    runtime: *SwitchLiveRuntime,
    display_generation: u64,
};

const SwitchLiveRuntime = struct {
    allocator: std.mem.Allocator,
    codex_home: []const u8,
    target: ForegroundUsageRefreshTarget,
    api_mode: cli.ApiMode,
    strict_refresh: bool,
    io_impl: std.Io.Threaded,
    mutex: std.Io.Mutex = .init,
    refresh_task: ?std.Io.Future(void) = null,
    updated_display: ?cli.OwnedSwitchSelectionDisplay = null,
    in_flight: bool = false,
    display_generation: u64 = 0,
    next_refresh_not_before_ms: i64,
    last_refresh_started_at_ms: ?i64 = null,
    last_refresh_finished_at_ms: ?i64 = null,
    last_refresh_duration_ms: ?i64 = null,
    last_refresh_error_name: ?[]u8 = null,
    refresh_interval_ms: i64,
    mode_label: []const u8,

    fn init(
        allocator: std.mem.Allocator,
        codex_home: []const u8,
        target: ForegroundUsageRefreshTarget,
        api_mode: cli.ApiMode,
        strict_refresh: bool,
        initial_policy: SwitchLiveRefreshPolicy,
        initial_refresh_error_name: ?[]u8,
    ) @This() {
        const io_impl = std.Io.Threaded.init(allocator, .{
            .concurrent_limit = .limited(1),
        });
        const now_ms = nowMilliseconds();
        return .{
            .allocator = allocator,
            .codex_home = codex_home,
            .target = target,
            .api_mode = api_mode,
            .strict_refresh = strict_refresh,
            .io_impl = io_impl,
            .next_refresh_not_before_ms = now_ms + initial_policy.interval_ms,
            .refresh_interval_ms = initial_policy.interval_ms,
            .mode_label = initial_policy.label,
            .last_refresh_error_name = initial_refresh_error_name,
        };
    }

    fn deinit(self: *@This()) void {
        self.cancelRefresh();
        if (self.updated_display) |*display| display.deinit(self.allocator);
        if (self.last_refresh_error_name) |name| self.allocator.free(name);
        self.io_impl.deinit();
        self.* = undefined;
    }

    fn cancelRefresh(self: *@This()) void {
        const io = self.io_impl.io();
        var future: ?std.Io.Future(void) = null;
        self.mutex.lockUncancelable(io);
        if (self.refresh_task) |task| {
            future = task;
            self.refresh_task = null;
        }
        self.mutex.unlock(io);
        if (future) |*task| task.cancel(io);
    }

    fn maybeStartRefresh(self: *@This()) void {
        const io = self.io_impl.io();
        const now_ms = nowMilliseconds();
        var display_generation: u64 = 0;

        self.mutex.lockUncancelable(io);
        if (self.in_flight or self.refresh_task != null or now_ms < self.next_refresh_not_before_ms) {
            self.mutex.unlock(io);
            return;
        }
        self.in_flight = true;
        display_generation = self.display_generation;
        self.last_refresh_started_at_ms = now_ms;
        self.mutex.unlock(io);

        const future = io.concurrent(runSwitchLiveRefreshRound, .{
            SwitchLiveRefreshTaskContext{
                .runtime = self,
                .display_generation = display_generation,
            },
        }) catch |err| {
            const finished_ms = nowMilliseconds();
            const error_name = self.allocator.dupe(u8, @errorName(err)) catch null;

            self.mutex.lockUncancelable(io);
            defer self.mutex.unlock(io);
            if (self.last_refresh_error_name) |name| self.allocator.free(name);
            self.last_refresh_error_name = error_name;
            self.last_refresh_finished_at_ms = finished_ms;
            self.last_refresh_duration_ms = finished_ms - now_ms;
            self.next_refresh_not_before_ms = finished_ms + self.refresh_interval_ms;
            self.in_flight = false;
            return;
        };

        self.mutex.lockUncancelable(io);
        self.refresh_task = future;
        self.mutex.unlock(io);
    }

    fn maybeTakeUpdatedDisplay(self: *@This()) ?cli.OwnedSwitchSelectionDisplay {
        const io = self.io_impl.io();
        var future: ?std.Io.Future(void) = null;
        var display: ?cli.OwnedSwitchSelectionDisplay = null;

        self.mutex.lockUncancelable(io);
        if (!self.in_flight and self.refresh_task != null) {
            future = self.refresh_task;
            self.refresh_task = null;
        }
        if (self.updated_display) |owned_display| {
            display = owned_display;
            self.updated_display = null;
        }
        self.mutex.unlock(io);

        if (future) |*task| task.await(io);
        return display;
    }

    fn invalidatePendingRefresh(self: *@This()) void {
        const io = self.io_impl.io();
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        self.display_generation +%= 1;
        if (self.updated_display) |*display| display.deinit(self.allocator);
        self.updated_display = null;
    }

    fn recordCompletedDisplayReload(self: *@This(), started_ms: i64, policy: SwitchLiveRefreshPolicy) void {
        const io = self.io_impl.io();
        const finished_ms = nowMilliseconds();
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        self.last_refresh_started_at_ms = started_ms;
        self.last_refresh_finished_at_ms = finished_ms;
        self.last_refresh_duration_ms = @max(finished_ms - started_ms, 0);
        self.refresh_interval_ms = policy.interval_ms;
        self.mode_label = policy.label;
        self.next_refresh_not_before_ms = finished_ms + policy.interval_ms;
    }

    fn buildStatusLine(self: *@This(), allocator: std.mem.Allocator, display: cli.SwitchSelectionDisplay) ![]u8 {
        _ = display;
        const io = self.io_impl.io();
        const now_ms = nowMilliseconds();

        var in_flight = false;
        var next_refresh_not_before_ms: i64 = now_ms;
        var mode_label: []const u8 = "local";
        var refresh_error_name: ?[]u8 = null;

        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        in_flight = self.in_flight;
        next_refresh_not_before_ms = self.next_refresh_not_before_ms;
        mode_label = self.mode_label;
        if (self.last_refresh_error_name) |error_name| {
            refresh_error_name = try allocator.dupe(u8, error_name);
        }
        defer if (refresh_error_name) |value| allocator.free(value);

        const refresh_state = if (in_flight)
            try allocator.dupe(u8, "Refresh running")
        else if (next_refresh_not_before_ms <= now_ms)
            try allocator.dupe(u8, "Refresh due")
        else
            try std.fmt.allocPrint(allocator, "Refresh in {d}s", .{@divFloor((next_refresh_not_before_ms - now_ms) + 999, 1000)});
        defer allocator.free(refresh_state);

        const error_suffix = if (refresh_error_name) |value|
            try std.fmt.allocPrint(allocator, " | Error: {s}", .{value})
        else
            try allocator.dupe(u8, "");
        defer allocator.free(error_suffix);

        return std.fmt.allocPrint(
            allocator,
            "Live refresh: {s} | {s}{s}",
            .{ mode_label, refresh_state, error_suffix },
        );
    }
};

fn switchLiveRefreshPolicy(
    reg: *const registry.Registry,
    _: ForegroundUsageRefreshTarget,
    api_mode: cli.ApiMode,
) SwitchLiveRefreshPolicy {
    const usage_api_enabled = apiModeUsesApi(reg.api.usage, api_mode);
    const account_api_enabled = apiModeUsesApi(reg.api.account, api_mode);
    if (usage_api_enabled or account_api_enabled) {
        return .{
            .usage_api_enabled = usage_api_enabled,
            .account_api_enabled = account_api_enabled,
            .interval_ms = switch_live_api_refresh_interval_ms,
            .label = "api",
        };
    }

    return .{
        .usage_api_enabled = false,
        .account_api_enabled = false,
        .interval_ms = switch_live_local_refresh_interval_ms,
        .label = "local",
    };
}

fn findAccountIndexByAccountKeyConst(reg: *const registry.Registry, account_key: []const u8) ?usize {
    for (reg.accounts.items, 0..) |rec, idx| {
        if (std.mem.eql(u8, rec.account_key, account_key)) return idx;
    }
    return null;
}

fn optionalBytesEqual(a: ?[]const u8, b: ?[]const u8) bool {
    if (a == null and b == null) return true;
    if (a == null or b == null) return false;
    return std.mem.eql(u8, a.?, b.?);
}

fn switchLiveUsageFieldsEqual(
    maybe_a: ?*const registry.AccountRecord,
    maybe_b: ?*const registry.AccountRecord,
) bool {
    const a_usage = if (maybe_a) |rec| rec.last_usage else null;
    const b_usage = if (maybe_b) |rec| rec.last_usage else null;
    if (!registry.rateLimitSnapshotsEqual(a_usage, b_usage)) return false;

    const a_last_usage_at = if (maybe_a) |rec| rec.last_usage_at else null;
    const b_last_usage_at = if (maybe_b) |rec| rec.last_usage_at else null;
    if (a_last_usage_at != b_last_usage_at) return false;

    const a_last_local_rollout = if (maybe_a) |rec| rec.last_local_rollout else null;
    const b_last_local_rollout = if (maybe_b) |rec| rec.last_local_rollout else null;
    return registry.rolloutSignaturesEqual(a_last_local_rollout, b_last_local_rollout);
}

fn switchLiveAccountNameEqual(
    maybe_a: ?*const registry.AccountRecord,
    maybe_b: ?*const registry.AccountRecord,
) bool {
    const a_account_name = if (maybe_a) |rec| rec.account_name else null;
    const b_account_name = if (maybe_b) |rec| rec.account_name else null;
    return optionalBytesEqual(a_account_name, b_account_name);
}

fn replaceOptionalOwnedString(
    allocator: std.mem.Allocator,
    target: *?[]u8,
    value: ?[]const u8,
) !bool {
    if (optionalBytesEqual(target.*, value)) return false;
    const replacement = if (value) |text| try allocator.dupe(u8, text) else null;
    if (target.*) |existing| allocator.free(existing);
    target.* = replacement;
    return true;
}

fn applySwitchLiveUsageDeltaToLatest(
    allocator: std.mem.Allocator,
    latest: *registry.Registry,
    base_rec: ?*const registry.AccountRecord,
    refreshed_rec: *const registry.AccountRecord,
) !bool {
    if (switchLiveUsageFieldsEqual(base_rec, refreshed_rec)) return false;

    const latest_idx = findAccountIndexByAccountKeyConst(latest, refreshed_rec.account_key) orelse return false;
    const latest_rec = &latest.accounts.items[latest_idx];
    if (!switchLiveUsageFieldsEqual(base_rec, latest_rec)) return false;

    if (refreshed_rec.last_usage) |snapshot| {
        const cloned_snapshot = try registry.cloneRateLimitSnapshot(allocator, snapshot);
        registry.updateUsage(allocator, latest, refreshed_rec.account_key, cloned_snapshot);
        latest.accounts.items[latest_idx].last_usage_at = refreshed_rec.last_usage_at;
    }
    if (refreshed_rec.last_local_rollout) |signature| {
        try registry.setAccountLastLocalRollout(
            allocator,
            &latest.accounts.items[latest_idx],
            signature.path,
            signature.event_timestamp_ms,
        );
    }
    return true;
}

fn applySwitchLiveAccountNameDeltaToLatest(
    allocator: std.mem.Allocator,
    latest: *registry.Registry,
    base_rec: ?*const registry.AccountRecord,
    refreshed_rec: *const registry.AccountRecord,
) !bool {
    if (switchLiveAccountNameEqual(base_rec, refreshed_rec)) return false;

    const latest_idx = findAccountIndexByAccountKeyConst(latest, refreshed_rec.account_key) orelse return false;
    const latest_rec = &latest.accounts.items[latest_idx];
    if (!switchLiveAccountNameEqual(base_rec, latest_rec)) return false;

    return try replaceOptionalOwnedString(allocator, &latest_rec.account_name, refreshed_rec.account_name);
}

fn allocEmptySwitchUsageOverrides(allocator: std.mem.Allocator, len: usize) ![]?[]const u8 {
    const usage_overrides = try allocator.alloc(?[]const u8, len);
    for (usage_overrides) |*usage_override| usage_override.* = null;
    return usage_overrides;
}

fn mapSwitchUsageOverridesToLatest(
    allocator: std.mem.Allocator,
    latest: *const registry.Registry,
    refreshed: *const registry.Registry,
    usage_overrides: []const ?[]const u8,
) ![]?[]const u8 {
    const mapped = try allocEmptySwitchUsageOverrides(allocator, latest.accounts.items.len);
    errdefer {
        for (mapped) |value| {
            if (value) |text| allocator.free(text);
        }
        allocator.free(mapped);
    }

    for (refreshed.accounts.items, 0..) |rec, refreshed_idx| {
        const usage_override = usage_overrides[refreshed_idx] orelse continue;
        const latest_idx = findAccountIndexByAccountKeyConst(latest, rec.account_key) orelse continue;
        mapped[latest_idx] = try allocator.dupe(u8, usage_override);
    }
    return mapped;
}

fn mergeSwitchLiveRefreshIntoLatest(
    allocator: std.mem.Allocator,
    latest: *registry.Registry,
    base: *const registry.Registry,
    refreshed: *const registry.Registry,
) !bool {
    var changed = false;
    for (refreshed.accounts.items) |*refreshed_rec| {
        const base_idx = findAccountIndexByAccountKeyConst(base, refreshed_rec.account_key);
        const base_rec = if (base_idx) |idx| &base.accounts.items[idx] else null;
        if (try applySwitchLiveUsageDeltaToLatest(allocator, latest, base_rec, refreshed_rec)) {
            changed = true;
        }
        if (try applySwitchLiveAccountNameDeltaToLatest(allocator, latest, base_rec, refreshed_rec)) {
            changed = true;
        }
    }
    return changed;
}

fn takeOwnedSwitchSelectionDisplay(
    allocator: std.mem.Allocator,
    reg: registry.Registry,
    usage_state: *ForegroundUsageRefreshState,
) cli.OwnedSwitchSelectionDisplay {
    const usage_overrides = usage_state.usage_overrides;
    allocator.free(usage_state.outcomes);
    usage_state.* = undefined;
    return .{
        .reg = reg,
        .usage_overrides = usage_overrides,
    };
}

fn cloneAccountRecord(allocator: std.mem.Allocator, rec: *const registry.AccountRecord) !registry.AccountRecord {
    const account_key = try allocator.dupe(u8, rec.account_key);
    errdefer allocator.free(account_key);
    const chatgpt_account_id = try allocator.dupe(u8, rec.chatgpt_account_id);
    errdefer allocator.free(chatgpt_account_id);
    const chatgpt_user_id = try allocator.dupe(u8, rec.chatgpt_user_id);
    errdefer allocator.free(chatgpt_user_id);
    const email = try allocator.dupe(u8, rec.email);
    errdefer allocator.free(email);
    const alias = try allocator.dupe(u8, rec.alias);
    errdefer allocator.free(alias);
    const account_name = if (rec.account_name) |value|
        try allocator.dupe(u8, value)
    else
        null;
    errdefer if (account_name) |value| allocator.free(value);
    const last_usage = if (rec.last_usage) |snapshot|
        try registry.cloneRateLimitSnapshot(allocator, snapshot)
    else
        null;
    errdefer if (last_usage) |*snapshot| registry.freeRateLimitSnapshot(allocator, snapshot);
    const last_local_rollout = if (rec.last_local_rollout) |signature|
        try registry.cloneRolloutSignature(allocator, signature)
    else
        null;
    errdefer if (last_local_rollout) |*signature| registry.freeRolloutSignature(allocator, signature);

    return .{
        .account_key = account_key,
        .chatgpt_account_id = chatgpt_account_id,
        .chatgpt_user_id = chatgpt_user_id,
        .email = email,
        .alias = alias,
        .account_name = account_name,
        .plan = rec.plan,
        .auth_mode = rec.auth_mode,
        .created_at = rec.created_at,
        .last_used_at = rec.last_used_at,
        .last_usage = last_usage,
        .last_usage_at = rec.last_usage_at,
        .last_local_rollout = last_local_rollout,
    };
}

fn freeOwnedAccountRecord(allocator: std.mem.Allocator, rec: *const registry.AccountRecord) void {
    allocator.free(rec.account_key);
    allocator.free(rec.chatgpt_account_id);
    allocator.free(rec.chatgpt_user_id);
    allocator.free(rec.email);
    allocator.free(rec.alias);
    if (rec.account_name) |value| allocator.free(value);
    if (rec.last_usage) |*snapshot| registry.freeRateLimitSnapshot(allocator, snapshot);
    if (rec.last_local_rollout) |*signature| registry.freeRolloutSignature(allocator, signature);
}

fn cloneRegistryAlloc(allocator: std.mem.Allocator, reg: *const registry.Registry) !registry.Registry {
    const active_account_key = if (reg.active_account_key) |value|
        try allocator.dupe(u8, value)
    else
        null;
    errdefer if (active_account_key) |value| allocator.free(value);

    var cloned: registry.Registry = .{
        .schema_version = reg.schema_version,
        .active_account_key = active_account_key,
        .active_account_activated_at_ms = reg.active_account_activated_at_ms,
        .auto_switch = reg.auto_switch,
        .api = reg.api,
        .accounts = std.ArrayList(registry.AccountRecord).empty,
    };
    errdefer cloned.deinit(allocator);

    for (reg.accounts.items) |*rec| {
        try cloned.accounts.append(allocator, try cloneAccountRecord(allocator, rec));
    }
    return cloned;
}

fn cloneSwitchUsageOverridesAlloc(
    allocator: std.mem.Allocator,
    usage_overrides: ?[]const ?[]const u8,
    fallback_len: usize,
) ![]?[]const u8 {
    const src = usage_overrides orelse return allocEmptySwitchUsageOverrides(allocator, fallback_len);
    const cloned = try allocEmptySwitchUsageOverrides(allocator, src.len);
    errdefer {
        for (cloned) |value| {
            if (value) |text| allocator.free(text);
        }
        allocator.free(cloned);
    }

    for (src, 0..) |value, idx| {
        if (value) |text| cloned[idx] = try allocator.dupe(u8, text);
    }
    return cloned;
}

fn cloneSwitchSelectionDisplayAlloc(
    allocator: std.mem.Allocator,
    display: cli.SwitchSelectionDisplay,
) !cli.OwnedSwitchSelectionDisplay {
    var reg = try cloneRegistryAlloc(allocator, display.reg);
    errdefer reg.deinit(allocator);
    return .{
        .reg = reg,
        .usage_overrides = try cloneSwitchUsageOverridesAlloc(allocator, display.usage_overrides, display.reg.accounts.items.len),
    };
}

fn applyPersistedActiveAccountToDisplay(
    allocator: std.mem.Allocator,
    display: *cli.OwnedSwitchSelectionDisplay,
    persisted_reg: *const registry.Registry,
) !void {
    const active_account_key = if (persisted_reg.active_account_key) |value|
        if (findAccountIndexByAccountKeyConst(&display.reg, value) != null) value else null
    else
        null;
    _ = try replaceOptionalOwnedString(allocator, &display.reg.active_account_key, active_account_key);
    display.reg.active_account_activated_at_ms = if (active_account_key != null)
        persisted_reg.active_account_activated_at_ms
    else
        null;

    if (active_account_key) |value| {
        const persisted_idx = findAccountIndexByAccountKeyConst(persisted_reg, value) orelse return;
        const display_idx = findAccountIndexByAccountKeyConst(&display.reg, value) orelse return;
        const replacement = try cloneAccountRecord(allocator, &persisted_reg.accounts.items[persisted_idx]);
        freeOwnedAccountRecord(allocator, &display.reg.accounts.items[display_idx]);
        display.reg.accounts.items[display_idx] = replacement;
    }
}

fn accountKeyMatchesAny(account_key: []const u8, selected_account_keys: []const []const u8) bool {
    for (selected_account_keys) |selected_account_key| {
        if (std.mem.eql(u8, account_key, selected_account_key)) return true;
    }
    return false;
}

fn buildSwitchLiveActionDisplay(
    allocator: std.mem.Allocator,
    current_display: cli.SwitchSelectionDisplay,
    persisted_reg: *const registry.Registry,
) !cli.OwnedSwitchSelectionDisplay {
    var updated_display = try cloneSwitchSelectionDisplayAlloc(allocator, current_display);
    errdefer updated_display.deinit(allocator);
    try applyPersistedActiveAccountToDisplay(allocator, &updated_display, persisted_reg);
    return updated_display;
}

fn buildRemoveLiveActionDisplay(
    allocator: std.mem.Allocator,
    current_display: cli.SwitchSelectionDisplay,
    persisted_reg: *const registry.Registry,
    removed_account_keys: []const []const u8,
) !cli.OwnedSwitchSelectionDisplay {
    var reg: registry.Registry = .{
        .schema_version = current_display.reg.schema_version,
        .active_account_key = null,
        .active_account_activated_at_ms = null,
        .auto_switch = current_display.reg.auto_switch,
        .api = current_display.reg.api,
        .accounts = std.ArrayList(registry.AccountRecord).empty,
    };
    errdefer reg.deinit(allocator);

    var kept_count: usize = 0;
    for (current_display.reg.accounts.items) |rec| {
        if (!accountKeyMatchesAny(rec.account_key, removed_account_keys)) kept_count += 1;
    }

    const usage_overrides = try allocEmptySwitchUsageOverrides(allocator, kept_count);
    errdefer {
        for (usage_overrides) |value| {
            if (value) |text| allocator.free(text);
        }
        allocator.free(usage_overrides);
    }

    var write_idx: usize = 0;
    for (current_display.reg.accounts.items, 0..) |*rec, idx| {
        if (accountKeyMatchesAny(rec.account_key, removed_account_keys)) continue;
        try reg.accounts.append(allocator, try cloneAccountRecord(allocator, rec));
        if (current_display.usage_overrides) |current_usage_overrides| {
            if (idx < current_usage_overrides.len) {
                if (current_usage_overrides[idx]) |text| usage_overrides[write_idx] = try allocator.dupe(u8, text);
            }
        }
        write_idx += 1;
    }

    var updated_display: cli.OwnedSwitchSelectionDisplay = .{
        .reg = reg,
        .usage_overrides = usage_overrides,
    };
    errdefer updated_display.deinit(allocator);
    try applyPersistedActiveAccountToDisplay(allocator, &updated_display, persisted_reg);
    return updated_display;
}

fn loadStoredSwitchSelectionDisplay(
    allocator: std.mem.Allocator,
    codex_home: []const u8,
    target: ForegroundUsageRefreshTarget,
    api_mode: cli.ApiMode,
) !SwitchLoadedDisplay {
    var latest = try registry.loadRegistry(allocator, codex_home);
    errdefer latest.deinit(allocator);
    if (try registry.syncActiveAccountFromAuth(allocator, codex_home, &latest)) {
        try registry.saveRegistry(allocator, codex_home, &latest);
    }
    return .{
        .display = .{
            .reg = latest,
            .usage_overrides = try allocEmptySwitchUsageOverrides(allocator, latest.accounts.items.len),
        },
        .policy = switchLiveRefreshPolicy(&latest, target, api_mode),
    };
}

fn loadStoredSwitchSelectionDisplayWithRefreshError(
    allocator: std.mem.Allocator,
    codex_home: []const u8,
    target: ForegroundUsageRefreshTarget,
    api_mode: cli.ApiMode,
    refresh_err: anyerror,
) !SwitchLoadedDisplay {
    var loaded = try loadStoredSwitchSelectionDisplay(allocator, codex_home, target, api_mode);
    errdefer loaded.display.deinit(allocator);
    loaded.refresh_error_name = try allocator.dupe(u8, @errorName(refresh_err));
    return loaded;
}

fn loadInitialLiveSelectionDisplay(
    allocator: std.mem.Allocator,
    codex_home: []const u8,
    target: ForegroundUsageRefreshTarget,
    api_mode: cli.ApiMode,
) !SwitchLoadedDisplay {
    return loadSwitchSelectionDisplay(
        allocator,
        codex_home,
        api_mode,
        target,
        api_mode == .force_api,
    );
}

fn loadSwitchSelectionDisplay(
    allocator: std.mem.Allocator,
    codex_home: []const u8,
    api_mode: cli.ApiMode,
    target: ForegroundUsageRefreshTarget,
    strict_refresh: bool,
) !SwitchLoadedDisplay {
    var base = try registry.loadRegistry(allocator, codex_home);
    defer base.deinit(allocator);

    var refreshed = try registry.loadRegistry(allocator, codex_home);
    errdefer refreshed.deinit(allocator);
    _ = try registry.syncActiveAccountFromAuth(allocator, codex_home, &refreshed);
    const initial_policy = switchLiveRefreshPolicy(&refreshed, target, api_mode);

    ensureForegroundNodeAvailableWithApiEnabled(
        allocator,
        codex_home,
        &refreshed,
        target,
        initial_policy.usage_api_enabled,
        initial_policy.account_api_enabled,
    ) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => {
            if (strict_refresh) return err;
            refreshed.deinit(allocator);
            return loadStoredSwitchSelectionDisplayWithRefreshError(allocator, codex_home, target, api_mode, err);
        },
    };

    var usage_state = refreshForegroundUsageForDisplayWithApiFetchersWithPoolInitUsingApiEnabledAndPersist(
        allocator,
        codex_home,
        &refreshed,
        usage_api.fetchUsageForAuthPathDetailed,
        usage_api.fetchUsageForAuthPathsDetailedBatch,
        initForegroundUsagePool,
        initial_policy.usage_api_enabled,
        false,
        false,
    ) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => {
            if (strict_refresh) return err;
            refreshed.deinit(allocator);
            return loadStoredSwitchSelectionDisplayWithRefreshError(allocator, codex_home, target, api_mode, err);
        },
    };
    errdefer usage_state.deinit(allocator);

    _ = maybeRefreshForegroundAccountNamesWithAccountApiEnabledAndPersist(
        allocator,
        codex_home,
        &refreshed,
        target,
        defaultAccountFetcher,
        initial_policy.account_api_enabled,
        false,
    ) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => {
            if (strict_refresh) return err;
            usage_state.deinit(allocator);
            refreshed.deinit(allocator);
            return loadStoredSwitchSelectionDisplayWithRefreshError(allocator, codex_home, target, api_mode, err);
        },
    };

    var latest = try registry.loadRegistry(allocator, codex_home);
    errdefer latest.deinit(allocator);
    var latest_changed = try registry.syncActiveAccountFromAuth(allocator, codex_home, &latest);

    if (try mergeSwitchLiveRefreshIntoLatest(allocator, &latest, &base, &refreshed)) {
        latest_changed = true;
    }

    if (latest_changed) try registry.saveRegistry(allocator, codex_home, &latest);
    const mapped_usage_overrides = try mapSwitchUsageOverridesToLatest(
        allocator,
        &latest,
        &refreshed,
        usage_state.usage_overrides,
    );
    usage_state.deinit(allocator);
    refreshed.deinit(allocator);

    return .{
        .display = .{
            .reg = latest,
            .usage_overrides = mapped_usage_overrides,
        },
        .policy = switchLiveRefreshPolicy(&latest, target, api_mode),
    };
}

fn runSwitchLiveRefreshRound(task_ctx: SwitchLiveRefreshTaskContext) void {
    const runtime = task_ctx.runtime;
    const io = runtime.io_impl.io();
    const started_ms = nowMilliseconds();
    const loaded = loadSwitchSelectionDisplay(
        runtime.allocator,
        runtime.codex_home,
        runtime.api_mode,
        runtime.target,
        runtime.strict_refresh,
    ) catch |err| {
        const finished_ms = nowMilliseconds();
        const error_name = runtime.allocator.dupe(u8, @errorName(err)) catch null;

        runtime.mutex.lockUncancelable(io);
        defer runtime.mutex.unlock(io);
        if (task_ctx.display_generation == runtime.display_generation) {
            if (runtime.last_refresh_error_name) |name| runtime.allocator.free(name);
            runtime.last_refresh_error_name = error_name;
        } else if (error_name) |name| {
            runtime.allocator.free(name);
        }
        runtime.last_refresh_finished_at_ms = finished_ms;
        runtime.last_refresh_duration_ms = finished_ms - (runtime.last_refresh_started_at_ms orelse started_ms);
        runtime.next_refresh_not_before_ms = finished_ms + runtime.refresh_interval_ms;
        runtime.in_flight = false;
        return;
    };

    const finished_ms = nowMilliseconds();
    runtime.mutex.lockUncancelable(io);
    defer runtime.mutex.unlock(io);

    if (task_ctx.display_generation == runtime.display_generation) {
        if (runtime.updated_display) |*display| display.deinit(runtime.allocator);
        runtime.updated_display = loaded.display;
        runtime.refresh_interval_ms = loaded.policy.interval_ms;
        runtime.mode_label = loaded.policy.label;
        if (runtime.last_refresh_error_name) |name| runtime.allocator.free(name);
        runtime.last_refresh_error_name = loaded.refresh_error_name;
    } else {
        var discarded_display = loaded.display;
        discarded_display.deinit(runtime.allocator);
        if (loaded.refresh_error_name) |name| runtime.allocator.free(name);
    }
    runtime.last_refresh_finished_at_ms = finished_ms;
    runtime.last_refresh_duration_ms = finished_ms - (runtime.last_refresh_started_at_ms orelse started_ms);
    runtime.next_refresh_not_before_ms = finished_ms + runtime.refresh_interval_ms;
    runtime.in_flight = false;
}

fn switchLiveRuntimeMaybeStartRefresh(context: *anyopaque) !void {
    const runtime: *SwitchLiveRuntime = @ptrCast(@alignCast(context));
    runtime.maybeStartRefresh();
}

fn switchLiveRuntimeMaybeTakeUpdatedDisplay(context: *anyopaque) !?cli.OwnedSwitchSelectionDisplay {
    const runtime: *SwitchLiveRuntime = @ptrCast(@alignCast(context));
    return runtime.maybeTakeUpdatedDisplay();
}

fn switchLiveRuntimeBuildStatusLine(
    context: *anyopaque,
    allocator: std.mem.Allocator,
    display: cli.SwitchSelectionDisplay,
) ![]u8 {
    const runtime: *SwitchLiveRuntime = @ptrCast(@alignCast(context));
    return runtime.buildStatusLine(allocator, display);
}

fn accountLabelForKeyAlloc(
    allocator: std.mem.Allocator,
    reg: *registry.Registry,
    account_key: []const u8,
) ![]u8 {
    const idx = registry.findAccountIndexByAccountKey(reg, account_key) orelse return error.AccountNotFound;
    return display_rows.buildPreferredAccountLabelAlloc(
        allocator,
        &reg.accounts.items[idx],
        reg.accounts.items[idx].email,
    );
}

fn buildRemoveSummaryMessageAlloc(allocator: std.mem.Allocator, labels: []const []const u8) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();

    try out.writer.print("Removed {d} account(s): ", .{labels.len});
    for (labels, 0..) |label, idx| {
        if (idx != 0) try out.writer.writeAll(", ");
        try out.writer.writeAll(label);
    }
    return try out.toOwnedSlice();
}

fn collectAccountIndicesByKeysAlloc(
    allocator: std.mem.Allocator,
    reg: *registry.Registry,
    account_keys: []const []const u8,
) ![]usize {
    var indices = std.ArrayList(usize).empty;
    defer indices.deinit(allocator);

    for (reg.accounts.items, 0..) |rec, idx| {
        for (account_keys) |account_key| {
            if (!std.mem.eql(u8, rec.account_key, account_key)) continue;
            try indices.append(allocator, idx);
            break;
        }
    }

    return try indices.toOwnedSlice(allocator);
}

fn removeSelectedAccountsAndPersist(
    allocator: std.mem.Allocator,
    codex_home: []const u8,
    reg: *registry.Registry,
    selected: []const usize,
    selected_all: bool,
) !void {
    const current_active_account_key = if (trackedActiveAccountKey(reg)) |key|
        try allocator.dupe(u8, key)
    else
        null;
    defer if (current_active_account_key) |key| allocator.free(key);

    var current_auth_state = try loadCurrentAuthState(allocator, codex_home);
    defer current_auth_state.deinit(allocator);

    const active_removed = if (current_active_account_key) |key|
        selectionContainsAccountKey(reg, selected, key)
    else
        false;
    const allow_auth_file_update = if (current_active_account_key) |key|
        active_removed and ((current_auth_state.syncable and current_auth_state.record_key != null and
            std.mem.eql(u8, current_auth_state.record_key.?, key)) or current_auth_state.missing)
    else if (current_auth_state.missing)
        true
    else if (selected_all)
        current_auth_state.syncable and current_auth_state.record_key != null and
            selectionContainsAccountKey(reg, selected, current_auth_state.record_key.?)
    else
        false;

    const replacement_account_key = if (active_removed)
        try selectBestRemainingAccountKeyByUsageAlloc(allocator, reg, selected)
    else
        null;
    defer if (replacement_account_key) |key| allocator.free(key);

    if (replacement_account_key) |key| {
        if (allow_auth_file_update) {
            try registry.replaceActiveAuthWithAccountByKey(allocator, codex_home, reg, key);
        } else {
            try registry.setActiveAccountKey(allocator, reg, key);
        }
    }

    try registry.removeAccounts(allocator, codex_home, reg, selected);
    try reconcileActiveAuthAfterRemove(allocator, codex_home, reg, allow_auth_file_update);
    try registry.saveRegistry(allocator, codex_home, reg);
}

fn switchLiveRuntimeApplySelection(
    context: *anyopaque,
    allocator: std.mem.Allocator,
    current_display: cli.SwitchSelectionDisplay,
    account_key: []const u8,
) !cli.LiveActionOutcome {
    const runtime: *SwitchLiveRuntime = @ptrCast(@alignCast(context));
    runtime.invalidatePendingRefresh();
    const reload_started_ms = nowMilliseconds();

    var reg = try registry.loadRegistry(allocator, runtime.codex_home);
    defer reg.deinit(allocator);
    if (try registry.syncActiveAccountFromAuth(allocator, runtime.codex_home, &reg)) {
        try registry.saveRegistry(allocator, runtime.codex_home, &reg);
    }

    try registry.activateAccountByKey(allocator, runtime.codex_home, &reg, account_key);
    try registry.saveRegistry(allocator, runtime.codex_home, &reg);

    const label = try accountLabelForKeyAlloc(allocator, &reg, account_key);
    defer allocator.free(label);

    var updated_display = try buildSwitchLiveActionDisplay(allocator, current_display, &reg);
    errdefer updated_display.deinit(allocator);
    runtime.recordCompletedDisplayReload(reload_started_ms, switchLiveRefreshPolicy(&reg, runtime.target, runtime.api_mode));

    return .{
        .updated_display = updated_display,
        .action_message = try std.fmt.allocPrint(allocator, "Switched to {s}", .{label}),
    };
}

fn removeLiveRuntimeApplySelection(
    context: *anyopaque,
    allocator: std.mem.Allocator,
    current_display: cli.SwitchSelectionDisplay,
    account_keys: []const []const u8,
) !cli.LiveActionOutcome {
    const runtime: *SwitchLiveRuntime = @ptrCast(@alignCast(context));
    runtime.invalidatePendingRefresh();
    const reload_started_ms = nowMilliseconds();

    var reg = try registry.loadRegistry(allocator, runtime.codex_home);
    defer reg.deinit(allocator);
    if (try registry.syncActiveAccountFromAuth(allocator, runtime.codex_home, &reg)) {
        try registry.saveRegistry(allocator, runtime.codex_home, &reg);
    }

    const selected = try collectAccountIndicesByKeysAlloc(allocator, &reg, account_keys);
    defer allocator.free(selected);

    if (selected.len == 0) {
        var updated_display = try cloneSwitchSelectionDisplayAlloc(allocator, current_display);
        errdefer updated_display.deinit(allocator);
        runtime.recordCompletedDisplayReload(reload_started_ms, switchLiveRefreshPolicy(&reg, runtime.target, runtime.api_mode));
        return .{
            .updated_display = updated_display,
            .action_message = try allocator.dupe(u8, "No matching accounts selected"),
        };
    }

    var removed_labels = try cli.buildRemoveLabels(allocator, &reg, selected);
    defer {
        freeOwnedStrings(allocator, removed_labels.items);
        removed_labels.deinit(allocator);
    }

    try removeSelectedAccountsAndPersist(allocator, runtime.codex_home, &reg, selected, false);

    var updated_display = try buildRemoveLiveActionDisplay(
        allocator,
        current_display,
        &reg,
        account_keys,
    );
    errdefer updated_display.deinit(allocator);
    runtime.recordCompletedDisplayReload(reload_started_ms, switchLiveRefreshPolicy(&reg, runtime.target, runtime.api_mode));

    return .{
        .updated_display = updated_display,
        .action_message = try buildRemoveSummaryMessageAlloc(allocator, removed_labels.items),
    };
}

pub fn resolveSwitchQueryLocally(
    allocator: std.mem.Allocator,
    reg: *registry.Registry,
    query: []const u8,
) !SwitchQueryResolution {
    if (try findAccountIndexByDisplayNumber(allocator, reg, query)) |account_idx| {
        return .{ .direct = reg.accounts.items[account_idx].account_key };
    }

    var matches = try findMatchingAccounts(allocator, reg, query);
    if (matches.items.len == 0) {
        matches.deinit(allocator);
        return .not_found;
    }
    if (matches.items.len == 1) {
        defer matches.deinit(allocator);
        return .{ .direct = reg.accounts.items[matches.items[0]].account_key };
    }
    return .{ .multiple = matches };
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

fn findMatchingAccountsForRemove(
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
        const matches_key = std.ascii.indexOfIgnoreCase(rec.account_key, query) != null;
        if (matches_email or matches_alias or matches_name or matches_key) {
            try matches.append(allocator, idx);
        }
    }
    return matches;
}

fn parseDisplayNumber(selector: []const u8) ?usize {
    if (selector.len == 0) return null;
    for (selector) |ch| {
        if (ch < '0' or ch > '9') return null;
    }

    const parsed = std.fmt.parseInt(usize, selector, 10) catch return null;
    if (parsed == 0) return null;
    return parsed;
}

fn findAccountIndexByDisplayNumber(
    allocator: std.mem.Allocator,
    reg: *registry.Registry,
    selector: []const u8,
) !?usize {
    const display_number = parseDisplayNumber(selector) orelse return null;

    var display = try display_rows.buildDisplayRows(allocator, reg, null);
    defer display.deinit(allocator);

    if (display_number > display.selectable_row_indices.len) return null;
    const row_idx = display.selectable_row_indices[display_number - 1];
    return display.rows[row_idx].account_index;
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

    std.Io.Dir.cwd().access(app_runtime.io(), auth_path, .{}) catch |err| switch (err) {
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

    const now = std.Io.Timestamp.now(app_runtime.io(), .real).toSeconds();
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
    const interactive_remove = !opts.all and opts.selectors.len == 0;
    if (interactive_remove and opts.live) {
        try ensureLiveTty(.remove_account);
        const live_allocator = std.heap.smp_allocator;
        const loaded = try loadInitialLiveSelectionDisplay(
            live_allocator,
            codex_home,
            .remove_account,
            opts.api_mode,
        );
        var initial_display: ?cli.OwnedSwitchSelectionDisplay = loaded.display;
        errdefer if (initial_display) |*display| display.deinit(live_allocator);

        var runtime = SwitchLiveRuntime.init(
            live_allocator,
            codex_home,
            .remove_account,
            opts.api_mode,
            opts.api_mode == .force_api,
            loaded.policy,
            loaded.refresh_error_name,
        );
        defer runtime.deinit();

        const controller: cli.RemoveLiveActionController = .{
            .refresh = .{
                .context = @ptrCast(&runtime),
                .maybe_start_refresh = switchLiveRuntimeMaybeStartRefresh,
                .maybe_take_updated_display = switchLiveRuntimeMaybeTakeUpdatedDisplay,
                .build_status_line = switchLiveRuntimeBuildStatusLine,
            },
            .apply_selection = removeLiveRuntimeApplySelection,
        };

        const transferred_display = initial_display.?;
        initial_display = null;
        cli.runRemoveLiveActions(live_allocator, transferred_display, controller) catch |err| {
            if (err == error.TuiRequiresTty) {
                try cli.printRemoveRequiresTtyError();
                return error.RemoveSelectionRequiresTty;
            }
            return err;
        };
        return;
    }

    if (interactive_remove) {
        var loaded = if (opts.api_mode == .skip_api)
            try loadStoredSwitchSelectionDisplay(
                allocator,
                codex_home,
                .remove_account,
                opts.api_mode,
            )
        else
            try loadSwitchSelectionDisplay(
                allocator,
                codex_home,
                opts.api_mode,
                .remove_account,
                true,
            );
        defer loaded.display.deinit(allocator);
        defer if (loaded.refresh_error_name) |name| allocator.free(name);

        const selected = cli.selectAccountsToRemoveWithUsageOverrides(
            allocator,
            &loaded.display.reg,
            loaded.display.usage_overrides,
        ) catch |err| {
            if (err == error.TuiRequiresTty) {
                try cli.printRemoveRequiresTtyError();
                return error.RemoveSelectionRequiresTty;
            }
            if (err == error.InvalidRemoveSelectionInput) {
                try cli.printInvalidRemoveSelectionError();
                return error.InvalidRemoveSelectionInput;
            }
            return err;
        };
        if (selected == null) return;
        defer allocator.free(selected.?);
        if (selected.?.len == 0) return;

        var removed_labels = try cli.buildRemoveLabels(allocator, &loaded.display.reg, selected.?);
        defer {
            freeOwnedStrings(allocator, removed_labels.items);
            removed_labels.deinit(allocator);
        }

        try removeSelectedAccountsAndPersist(allocator, codex_home, &loaded.display.reg, selected.?, opts.all);
        try cli.printRemoveSummary(removed_labels.items);
        return;
    }

    var reg = try registry.loadRegistry(allocator, codex_home);
    defer reg.deinit(allocator);

    if (try registry.syncActiveAccountFromAuth(allocator, codex_home, &reg)) {
        try registry.saveRegistry(allocator, codex_home, &reg);
    }

    var selected: ?[]usize = null;
    if (opts.all) {
        selected = try allocator.alloc(usize, reg.accounts.items.len);
        for (selected.?, 0..) |*slot, idx| slot.* = idx;
    } else if (opts.selectors.len != 0) {
        var selected_list = std.ArrayList(usize).empty;
        defer selected_list.deinit(allocator);
        var missing_selectors = std.ArrayList([]const u8).empty;
        defer missing_selectors.deinit(allocator);
        var requires_confirmation = false;

        for (opts.selectors) |selector| {
            if (try findAccountIndexByDisplayNumber(allocator, &reg, selector)) |account_idx| {
                if (!selectionContainsIndex(selected_list.items, account_idx)) {
                    try selected_list.append(allocator, account_idx);
                }
                continue;
            }

            var matches = try findMatchingAccountsForRemove(allocator, &reg, selector);
            defer matches.deinit(allocator);

            if (matches.items.len == 0) {
                try missing_selectors.append(allocator, selector);
                continue;
            }
            if (matches.items.len > 1) {
                requires_confirmation = true;
            }
            for (matches.items) |account_idx| {
                if (!selectionContainsIndex(selected_list.items, account_idx)) {
                    try selected_list.append(allocator, account_idx);
                }
            }
        }

        if (missing_selectors.items.len != 0) {
            try cli.printAccountNotFoundErrors(missing_selectors.items);
            return error.AccountNotFound;
        }
        if (selected_list.items.len == 0) return;
        if (requires_confirmation) {
            var matched_labels = try cli.buildRemoveLabels(allocator, &reg, selected_list.items);
            defer {
                freeOwnedStrings(allocator, matched_labels.items);
                matched_labels.deinit(allocator);
            }
            if (!(std.Io.File.stdin().isTty(app_runtime.io()) catch false)) {
                try cli.printRemoveConfirmationUnavailableError(matched_labels.items);
                return error.RemoveConfirmationUnavailable;
            }
            if (!(try cli.confirmRemoveMatches(matched_labels.items))) return;
        }

        selected = try allocator.dupe(usize, selected_list.items);
    } else {
        selected = cli.selectAccountsToRemoveWithUsageOverrides(
            allocator,
            &reg,
            null,
        ) catch |err| {
            if (err == error.InvalidRemoveSelectionInput) {
                try cli.printInvalidRemoveSelectionError();
                return error.InvalidRemoveSelectionInput;
            }
            if (err == error.TuiRequiresTty) {
                try cli.printRemoveRequiresTtyError();
                return error.RemoveSelectionRequiresTty;
            }
            return err;
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

    try removeSelectedAccountsAndPersist(allocator, codex_home, &reg, selected.?, opts.all);
    try cli.printRemoveSummary(removed_labels.items);
}

fn handleTopLevelHelp(allocator: std.mem.Allocator, codex_home: []const u8) !void {
    const help_cfg = loadHelpConfig(allocator, codex_home);
    try cli.printHelp(&help_cfg.auto_switch, &help_cfg.api);
}

fn handleClean(allocator: std.mem.Allocator, codex_home: []const u8) !void {
    const summary = try registry.cleanAccountsBackups(allocator, codex_home);
    var stdout: [256]u8 = undefined;
    var writer = std.Io.File.stdout().writer(app_runtime.io(), &stdout);
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

    const codex_home = try app_runtime.realPathFileAlloc(gpa, tmp.dir, ".");
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

test "handled cli errors include missing node" {
    try std.testing.expect(isHandledCliError(error.NodeJsRequired));
}

fn saveLivePolicyTestRegistry(
    allocator: std.mem.Allocator,
    codex_home: []const u8,
    api_config: registry.ApiConfig,
) !void {
    var reg: registry.Registry = .{
        .schema_version = registry.current_schema_version,
        .active_account_key = null,
        .active_account_activated_at_ms = null,
        .auto_switch = registry.defaultAutoSwitchConfig(),
        .api = api_config,
        .accounts = std.ArrayList(registry.AccountRecord).empty,
    };
    defer reg.deinit(allocator);
    try registry.saveRegistry(allocator, codex_home, &reg);
}

fn expectInitialLiveSelectionPolicy(
    allocator: std.mem.Allocator,
    codex_home: []const u8,
    target: ForegroundUsageRefreshTarget,
    api_mode: cli.ApiMode,
    expected: SwitchLiveRefreshPolicy,
) !void {
    var loaded = try loadInitialLiveSelectionDisplay(allocator, codex_home, target, api_mode);
    defer loaded.display.deinit(allocator);
    defer if (loaded.refresh_error_name) |name| allocator.free(name);

    try std.testing.expectEqual(expected.usage_api_enabled, loaded.policy.usage_api_enabled);
    try std.testing.expectEqual(expected.account_api_enabled, loaded.policy.account_api_enabled);
    try std.testing.expectEqual(expected.interval_ms, loaded.policy.interval_ms);
    try std.testing.expectEqualStrings(expected.label, loaded.policy.label);
    try std.testing.expect(loaded.refresh_error_name == null);
}

fn appendLiveMergeTestAccount(
    allocator: std.mem.Allocator,
    reg: *registry.Registry,
    account_key: []const u8,
    email: []const u8,
    alias: []const u8,
) !void {
    const sep = std.mem.lastIndexOf(u8, account_key, "::") orelse return error.InvalidRecordKey;
    const chatgpt_user_id = account_key[0..sep];
    const chatgpt_account_id = account_key[sep + 2 ..];
    try reg.accounts.append(allocator, .{
        .account_key = try allocator.dupe(u8, account_key),
        .chatgpt_account_id = try allocator.dupe(u8, chatgpt_account_id),
        .chatgpt_user_id = try allocator.dupe(u8, chatgpt_user_id),
        .email = try allocator.dupe(u8, email),
        .alias = try allocator.dupe(u8, alias),
        .account_name = null,
        .plan = .team,
        .auth_mode = .chatgpt,
        .created_at = 1,
        .last_used_at = null,
        .last_usage = null,
        .last_usage_at = null,
        .last_local_rollout = null,
    });
}

fn writeLiveActionTestSnapshot(
    allocator: std.mem.Allocator,
    codex_home: []const u8,
    account_key: []const u8,
    email: []const u8,
    plan: []const u8,
) !void {
    try registry.ensureAccountsDir(allocator, codex_home);
    const auth_path = try registry.accountAuthPath(allocator, codex_home, account_key);
    defer allocator.free(auth_path);
    const auth_json = try bdd.authJsonWithEmailPlan(allocator, email, plan);
    defer allocator.free(auth_json);
    try std.Io.Dir.cwd().writeFile(app_runtime.io(), .{ .sub_path = auth_path, .data = auth_json });
}

fn sleepLiveRefreshTask(io: std.Io) void {
    std.Io.sleep(io, .fromMilliseconds(800), .awake) catch {};
}

test "initial live selection display uses stored api defaults for list, switch, and remove" {
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const codex_home = try app_runtime.realPathFileAlloc(gpa, tmp.dir, ".");
    defer gpa.free(codex_home);

    try saveLivePolicyTestRegistry(gpa, codex_home, registry.defaultApiConfig());

    inline for ([_]ForegroundUsageRefreshTarget{ .list, .switch_account, .remove_account }) |target| {
        try expectInitialLiveSelectionPolicy(gpa, codex_home, target, .default, .{
            .usage_api_enabled = true,
            .account_api_enabled = true,
            .interval_ms = switch_live_api_refresh_interval_ms,
            .label = "api",
        });
    }
}

test "initial live selection display preserves mixed stored api defaults for list, switch, and remove" {
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const codex_home = try app_runtime.realPathFileAlloc(gpa, tmp.dir, ".");
    defer gpa.free(codex_home);

    try saveLivePolicyTestRegistry(gpa, codex_home, .{
        .usage = false,
        .account = true,
    });

    inline for ([_]ForegroundUsageRefreshTarget{ .list, .switch_account, .remove_account }) |target| {
        try expectInitialLiveSelectionPolicy(gpa, codex_home, target, .default, .{
            .usage_api_enabled = false,
            .account_api_enabled = true,
            .interval_ms = switch_live_api_refresh_interval_ms,
            .label = "api",
        });
    }
}

test "initial live selection display honors explicit api mode overrides for list, switch, and remove" {
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const codex_home = try app_runtime.realPathFileAlloc(gpa, tmp.dir, ".");
    defer gpa.free(codex_home);

    try saveLivePolicyTestRegistry(gpa, codex_home, .{
        .usage = false,
        .account = false,
    });

    inline for ([_]ForegroundUsageRefreshTarget{ .list, .switch_account, .remove_account }) |target| {
        try expectInitialLiveSelectionPolicy(gpa, codex_home, target, .force_api, .{
            .usage_api_enabled = true,
            .account_api_enabled = true,
            .interval_ms = switch_live_api_refresh_interval_ms,
            .label = "api",
        });
    }

    try saveLivePolicyTestRegistry(gpa, codex_home, registry.defaultApiConfig());

    inline for ([_]ForegroundUsageRefreshTarget{ .list, .switch_account, .remove_account }) |target| {
        try expectInitialLiveSelectionPolicy(gpa, codex_home, target, .skip_api, .{
            .usage_api_enabled = false,
            .account_api_enabled = false,
            .interval_ms = switch_live_local_refresh_interval_ms,
            .label = "local",
        });
    }
}

test "live refresh merge preserves accounts newly added to the latest registry" {
    const gpa = std.testing.allocator;

    var base: registry.Registry = .{
        .schema_version = registry.current_schema_version,
        .active_account_key = null,
        .active_account_activated_at_ms = null,
        .auto_switch = registry.defaultAutoSwitchConfig(),
        .api = registry.defaultApiConfig(),
        .accounts = std.ArrayList(registry.AccountRecord).empty,
    };
    defer base.deinit(gpa);
    try appendLiveMergeTestAccount(gpa, &base, "user-alpha::acct-alpha", "alpha@example.com", "alpha");

    var refreshed: registry.Registry = .{
        .schema_version = registry.current_schema_version,
        .active_account_key = null,
        .active_account_activated_at_ms = null,
        .auto_switch = registry.defaultAutoSwitchConfig(),
        .api = registry.defaultApiConfig(),
        .accounts = std.ArrayList(registry.AccountRecord).empty,
    };
    defer refreshed.deinit(gpa);
    try appendLiveMergeTestAccount(gpa, &refreshed, "user-alpha::acct-alpha", "alpha@example.com", "alpha");
    refreshed.accounts.items[0].account_name = try gpa.dupe(u8, "Alpha Workspace");

    var latest: registry.Registry = .{
        .schema_version = registry.current_schema_version,
        .active_account_key = null,
        .active_account_activated_at_ms = null,
        .auto_switch = registry.defaultAutoSwitchConfig(),
        .api = registry.defaultApiConfig(),
        .accounts = std.ArrayList(registry.AccountRecord).empty,
    };
    defer latest.deinit(gpa);
    try appendLiveMergeTestAccount(gpa, &latest, "user-alpha::acct-alpha", "alpha@example.com", "alpha");
    try appendLiveMergeTestAccount(gpa, &latest, "user-beta::acct-beta", "beta@example.com", "beta");

    const changed = try mergeSwitchLiveRefreshIntoLatest(gpa, &latest, &base, &refreshed);
    try std.testing.expect(changed);
    try std.testing.expectEqual(@as(usize, 2), latest.accounts.items.len);

    const alpha_idx = findAccountIndexByAccountKeyConst(&latest, "user-alpha::acct-alpha") orelse return error.TestExpectedEqual;
    const beta_idx = findAccountIndexByAccountKeyConst(&latest, "user-beta::acct-beta") orelse return error.TestExpectedEqual;
    try std.testing.expectEqualStrings("Alpha Workspace", latest.accounts.items[alpha_idx].account_name.?);
    try std.testing.expect(latest.accounts.items[beta_idx].account_name == null);

    const usage_overrides = try gpa.alloc(?[]const u8, refreshed.accounts.items.len);
    defer {
        for (usage_overrides) |value| {
            if (value) |text| gpa.free(@constCast(text));
        }
        gpa.free(usage_overrides);
    }
    for (usage_overrides) |*value| value.* = null;
    usage_overrides[0] = try gpa.dupe(u8, "403");

    const mapped_usage_overrides = try mapSwitchUsageOverridesToLatest(gpa, &latest, &refreshed, usage_overrides);
    defer {
        for (mapped_usage_overrides) |value| {
            if (value) |text| gpa.free(@constCast(text));
        }
        gpa.free(mapped_usage_overrides);
    }

    try std.testing.expectEqual(@as(usize, 2), mapped_usage_overrides.len);
    try std.testing.expectEqualStrings("403", mapped_usage_overrides[alpha_idx].?);
    try std.testing.expect(mapped_usage_overrides[beta_idx] == null);
}

test "switch live action patches the current display after switching" {
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const codex_home = try app_runtime.realPathFileAlloc(gpa, tmp.dir, ".");
    defer gpa.free(codex_home);

    const alpha_key = try bdd.accountKeyForEmailAlloc(gpa, "alpha@example.com");
    defer gpa.free(alpha_key);
    const beta_key = try bdd.accountKeyForEmailAlloc(gpa, "beta@example.com");
    defer gpa.free(beta_key);

    var reg: registry.Registry = .{
        .schema_version = registry.current_schema_version,
        .active_account_key = null,
        .active_account_activated_at_ms = null,
        .auto_switch = registry.defaultAutoSwitchConfig(),
        .api = registry.defaultApiConfig(),
        .accounts = std.ArrayList(registry.AccountRecord).empty,
    };
    defer reg.deinit(gpa);
    try appendLiveMergeTestAccount(gpa, &reg, alpha_key, "alpha@example.com", "");
    try appendLiveMergeTestAccount(gpa, &reg, beta_key, "beta@example.com", "");
    reg.accounts.items[1].account_name = try gpa.dupe(u8, "Registry Beta");
    try registry.setActiveAccountKey(gpa, &reg, alpha_key);
    try registry.saveRegistry(gpa, codex_home, &reg);
    try writeLiveActionTestSnapshot(gpa, codex_home, alpha_key, "alpha@example.com", "team");
    try writeLiveActionTestSnapshot(gpa, codex_home, beta_key, "beta@example.com", "plus");

    var runtime = SwitchLiveRuntime.init(
        gpa,
        codex_home,
        .switch_account,
        .skip_api,
        false,
        .{
            .usage_api_enabled = false,
            .account_api_enabled = false,
            .interval_ms = switch_live_local_refresh_interval_ms,
            .label = "local",
        },
        try gpa.dupe(u8, "PreviousRefreshError"),
    );
    defer runtime.deinit();

    const live_io = runtime.io_impl.io();
    runtime.mutex.lockUncancelable(live_io);
    runtime.next_refresh_not_before_ms = nowMilliseconds() - 1;
    runtime.refresh_interval_ms = 1;
    runtime.mode_label = "stale";
    runtime.last_refresh_started_at_ms = null;
    runtime.last_refresh_finished_at_ms = null;
    runtime.last_refresh_duration_ms = null;
    runtime.mutex.unlock(live_io);

    var current_display = try loadStoredSwitchSelectionDisplay(gpa, codex_home, .switch_account, .skip_api);
    defer current_display.display.deinit(gpa);
    defer if (current_display.refresh_error_name) |name| gpa.free(name);
    const alpha_idx = findAccountIndexByAccountKeyConst(&current_display.display.reg, alpha_key) orelse return error.TestExpectedEqual;
    const beta_idx = findAccountIndexByAccountKeyConst(&current_display.display.reg, beta_key) orelse return error.TestExpectedEqual;
    _ = try replaceOptionalOwnedString(gpa, &current_display.display.reg.accounts.items[beta_idx].account_name, "Display Beta");
    current_display.display.usage_overrides[alpha_idx] = try gpa.dupe(u8, "403");
    current_display.display.usage_overrides[beta_idx] = try gpa.dupe(u8, "401");

    const action_started_ms = nowMilliseconds();
    const outcome = try switchLiveRuntimeApplySelection(
        @ptrCast(&runtime),
        gpa,
        current_display.display.borrowed(),
        beta_key,
    );
    const action_finished_ms = nowMilliseconds();
    defer {
        if (outcome.action_message) |message| gpa.free(message);
        var owned_display = outcome.updated_display;
        owned_display.deinit(gpa);
    }

    try std.testing.expectEqualStrings("Switched to Registry Beta", outcome.action_message.?);
    try std.testing.expectEqualStrings(beta_key, outcome.updated_display.reg.active_account_key.?);
    try std.testing.expectEqual(@as(usize, 2), outcome.updated_display.reg.accounts.items.len);
    try std.testing.expectEqualStrings("Registry Beta", outcome.updated_display.reg.accounts.items[beta_idx].account_name.?);
    try std.testing.expectEqualStrings("403", outcome.updated_display.usage_overrides[alpha_idx].?);
    try std.testing.expectEqualStrings("401", outcome.updated_display.usage_overrides[beta_idx].?);
    try std.testing.expect(runtime.last_refresh_error_name != null);
    try std.testing.expectEqualStrings("PreviousRefreshError", runtime.last_refresh_error_name.?);
    try std.testing.expectEqualStrings("local", runtime.mode_label);
    try std.testing.expectEqual(switch_live_local_refresh_interval_ms, runtime.refresh_interval_ms);
    try std.testing.expect(runtime.last_refresh_started_at_ms != null);
    try std.testing.expect(runtime.last_refresh_finished_at_ms != null);
    try std.testing.expect(runtime.last_refresh_duration_ms != null);
    try std.testing.expect(runtime.last_refresh_started_at_ms.? >= action_started_ms);
    try std.testing.expect(runtime.last_refresh_finished_at_ms.? >= runtime.last_refresh_started_at_ms.?);
    try std.testing.expect(runtime.last_refresh_finished_at_ms.? <= action_finished_ms);
    try std.testing.expectEqual(
        runtime.last_refresh_finished_at_ms.? + switch_live_local_refresh_interval_ms,
        runtime.next_refresh_not_before_ms,
    );

    var loaded = try registry.loadRegistry(gpa, codex_home);
    defer loaded.deinit(gpa);
    try std.testing.expectEqualStrings(beta_key, loaded.active_account_key.?);
}

test "switch live action does not wait for an in-flight refresh" {
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const codex_home = try app_runtime.realPathFileAlloc(gpa, tmp.dir, ".");
    defer gpa.free(codex_home);

    const alpha_key = try bdd.accountKeyForEmailAlloc(gpa, "alpha@example.com");
    defer gpa.free(alpha_key);
    const beta_key = try bdd.accountKeyForEmailAlloc(gpa, "beta@example.com");
    defer gpa.free(beta_key);

    var reg: registry.Registry = .{
        .schema_version = registry.current_schema_version,
        .active_account_key = null,
        .active_account_activated_at_ms = null,
        .auto_switch = registry.defaultAutoSwitchConfig(),
        .api = registry.defaultApiConfig(),
        .accounts = std.ArrayList(registry.AccountRecord).empty,
    };
    defer reg.deinit(gpa);
    try appendLiveMergeTestAccount(gpa, &reg, alpha_key, "alpha@example.com", "");
    try appendLiveMergeTestAccount(gpa, &reg, beta_key, "beta@example.com", "");
    try registry.setActiveAccountKey(gpa, &reg, alpha_key);
    try registry.saveRegistry(gpa, codex_home, &reg);
    try writeLiveActionTestSnapshot(gpa, codex_home, alpha_key, "alpha@example.com", "team");
    try writeLiveActionTestSnapshot(gpa, codex_home, beta_key, "beta@example.com", "plus");

    var runtime = SwitchLiveRuntime.init(
        gpa,
        codex_home,
        .switch_account,
        .skip_api,
        false,
        .{
            .usage_api_enabled = false,
            .account_api_enabled = false,
            .interval_ms = switch_live_local_refresh_interval_ms,
            .label = "local",
        },
        null,
    );
    defer runtime.deinit();

    const live_io = runtime.io_impl.io();
    const refresh_task = live_io.concurrent(sleepLiveRefreshTask, .{live_io}) catch |err| switch (err) {
        error.ConcurrencyUnavailable => return error.SkipZigTest,
    };
    runtime.mutex.lockUncancelable(live_io);
    runtime.refresh_task = refresh_task;
    runtime.in_flight = true;
    runtime.last_refresh_started_at_ms = nowMilliseconds();
    runtime.mutex.unlock(live_io);

    var current_display = try loadStoredSwitchSelectionDisplay(gpa, codex_home, .switch_account, .skip_api);
    defer current_display.display.deinit(gpa);
    defer if (current_display.refresh_error_name) |name| gpa.free(name);

    const started_ms = nowMilliseconds();
    const outcome = try switchLiveRuntimeApplySelection(
        @ptrCast(&runtime),
        gpa,
        current_display.display.borrowed(),
        beta_key,
    );
    const elapsed_ms = nowMilliseconds() - started_ms;
    defer {
        if (outcome.action_message) |message| gpa.free(message);
        var owned_display = outcome.updated_display;
        owned_display.deinit(gpa);
    }

    try std.testing.expect(elapsed_ms < 500);
    try std.testing.expectEqualStrings("Switched to beta@example.com", outcome.action_message.?);
    try std.testing.expectEqual(@as(u64, 1), runtime.display_generation);
}

test "remove live action patches the current display after deleting the active account" {
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const codex_home = try app_runtime.realPathFileAlloc(gpa, tmp.dir, ".");
    defer gpa.free(codex_home);

    const alpha_key = try bdd.accountKeyForEmailAlloc(gpa, "alpha@example.com");
    defer gpa.free(alpha_key);
    const beta_key = try bdd.accountKeyForEmailAlloc(gpa, "beta@example.com");
    defer gpa.free(beta_key);

    var reg: registry.Registry = .{
        .schema_version = registry.current_schema_version,
        .active_account_key = null,
        .active_account_activated_at_ms = null,
        .auto_switch = registry.defaultAutoSwitchConfig(),
        .api = registry.defaultApiConfig(),
        .accounts = std.ArrayList(registry.AccountRecord).empty,
    };
    defer reg.deinit(gpa);
    try appendLiveMergeTestAccount(gpa, &reg, alpha_key, "alpha@example.com", "");
    try appendLiveMergeTestAccount(gpa, &reg, beta_key, "beta@example.com", "");
    reg.accounts.items[0].account_name = try gpa.dupe(u8, "Registry Alpha");
    reg.accounts.items[1].account_name = try gpa.dupe(u8, "Registry Beta");
    const future_primary_reset_at = nowSeconds() + 60 * 60;
    const future_secondary_reset_at = nowSeconds() + 7 * 24 * 60 * 60;
    reg.accounts.items[1].last_usage = try registry.cloneRateLimitSnapshot(gpa, .{
        .primary = .{ .used_percent = 12.0, .window_minutes = 300, .resets_at = future_primary_reset_at },
        .secondary = .{ .used_percent = 18.0, .window_minutes = 10080, .resets_at = future_secondary_reset_at },
        .credits = null,
        .plan_type = .plus,
    });
    reg.accounts.items[1].last_usage_at = nowSeconds() - 60;
    try registry.setActiveAccountKey(gpa, &reg, alpha_key);
    try registry.saveRegistry(gpa, codex_home, &reg);
    try writeLiveActionTestSnapshot(gpa, codex_home, alpha_key, "alpha@example.com", "team");
    try writeLiveActionTestSnapshot(gpa, codex_home, beta_key, "beta@example.com", "plus");

    var runtime = SwitchLiveRuntime.init(
        gpa,
        codex_home,
        .remove_account,
        .skip_api,
        false,
        .{
            .usage_api_enabled = false,
            .account_api_enabled = false,
            .interval_ms = switch_live_local_refresh_interval_ms,
            .label = "local",
        },
        try gpa.dupe(u8, "PreviousRefreshError"),
    );
    defer runtime.deinit();

    const selected = [_][]const u8{alpha_key};
    const live_io = runtime.io_impl.io();
    runtime.mutex.lockUncancelable(live_io);
    runtime.next_refresh_not_before_ms = nowMilliseconds() - 1;
    runtime.refresh_interval_ms = 1;
    runtime.mode_label = "stale";
    runtime.last_refresh_started_at_ms = null;
    runtime.last_refresh_finished_at_ms = null;
    runtime.last_refresh_duration_ms = null;
    runtime.mutex.unlock(live_io);

    var current_display = try loadStoredSwitchSelectionDisplay(gpa, codex_home, .remove_account, .skip_api);
    defer current_display.display.deinit(gpa);
    defer if (current_display.refresh_error_name) |name| gpa.free(name);
    const alpha_idx = findAccountIndexByAccountKeyConst(&current_display.display.reg, alpha_key) orelse return error.TestExpectedEqual;
    const beta_idx = findAccountIndexByAccountKeyConst(&current_display.display.reg, beta_key) orelse return error.TestExpectedEqual;
    _ = try replaceOptionalOwnedString(gpa, &current_display.display.reg.accounts.items[alpha_idx].account_name, "Display Alpha");
    _ = try replaceOptionalOwnedString(gpa, &current_display.display.reg.accounts.items[beta_idx].account_name, "Display Beta");
    current_display.display.usage_overrides[alpha_idx] = try gpa.dupe(u8, "403");
    current_display.display.usage_overrides[beta_idx] = try gpa.dupe(u8, "401");

    const action_started_ms = nowMilliseconds();
    const outcome = try removeLiveRuntimeApplySelection(
        @ptrCast(&runtime),
        gpa,
        current_display.display.borrowed(),
        &selected,
    );
    const action_finished_ms = nowMilliseconds();
    defer {
        if (outcome.action_message) |message| gpa.free(message);
        var owned_display = outcome.updated_display;
        owned_display.deinit(gpa);
    }

    try std.testing.expectEqualStrings("Removed 1 account(s): alpha@example.com / Registry Alpha", outcome.action_message.?);
    try std.testing.expectEqual(@as(usize, 1), outcome.updated_display.reg.accounts.items.len);
    try std.testing.expect(findAccountIndexByAccountKeyConst(&outcome.updated_display.reg, alpha_key) == null);
    try std.testing.expectEqualStrings(beta_key, outcome.updated_display.reg.active_account_key.?);
    try std.testing.expectEqualStrings("Registry Beta", outcome.updated_display.reg.accounts.items[0].account_name.?);
    try std.testing.expectEqual(@as(usize, 1), outcome.updated_display.usage_overrides.len);
    try std.testing.expectEqualStrings("401", outcome.updated_display.usage_overrides[0].?);
    try std.testing.expect(runtime.last_refresh_error_name != null);
    try std.testing.expectEqualStrings("PreviousRefreshError", runtime.last_refresh_error_name.?);
    try std.testing.expectEqualStrings("local", runtime.mode_label);
    try std.testing.expectEqual(switch_live_local_refresh_interval_ms, runtime.refresh_interval_ms);
    try std.testing.expect(runtime.last_refresh_started_at_ms != null);
    try std.testing.expect(runtime.last_refresh_finished_at_ms != null);
    try std.testing.expect(runtime.last_refresh_duration_ms != null);
    try std.testing.expect(runtime.last_refresh_started_at_ms.? >= action_started_ms);
    try std.testing.expect(runtime.last_refresh_finished_at_ms.? >= runtime.last_refresh_started_at_ms.?);
    try std.testing.expect(runtime.last_refresh_finished_at_ms.? <= action_finished_ms);
    try std.testing.expectEqual(
        runtime.last_refresh_finished_at_ms.? + switch_live_local_refresh_interval_ms,
        runtime.next_refresh_not_before_ms,
    );

    var loaded = try registry.loadRegistry(gpa, codex_home);
    defer loaded.deinit(gpa);
    try std.testing.expectEqual(@as(usize, 1), loaded.accounts.items.len);
    try std.testing.expect(findAccountIndexByAccountKeyConst(&loaded, alpha_key) == null);
    try std.testing.expectEqualStrings(beta_key, loaded.active_account_key.?);
}

test "remove live action does not wait for an in-flight refresh" {
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const codex_home = try app_runtime.realPathFileAlloc(gpa, tmp.dir, ".");
    defer gpa.free(codex_home);

    const alpha_key = try bdd.accountKeyForEmailAlloc(gpa, "alpha@example.com");
    defer gpa.free(alpha_key);
    const beta_key = try bdd.accountKeyForEmailAlloc(gpa, "beta@example.com");
    defer gpa.free(beta_key);

    var reg: registry.Registry = .{
        .schema_version = registry.current_schema_version,
        .active_account_key = null,
        .active_account_activated_at_ms = null,
        .auto_switch = registry.defaultAutoSwitchConfig(),
        .api = registry.defaultApiConfig(),
        .accounts = std.ArrayList(registry.AccountRecord).empty,
    };
    defer reg.deinit(gpa);
    try appendLiveMergeTestAccount(gpa, &reg, alpha_key, "alpha@example.com", "");
    try appendLiveMergeTestAccount(gpa, &reg, beta_key, "beta@example.com", "");
    try registry.setActiveAccountKey(gpa, &reg, alpha_key);
    try registry.saveRegistry(gpa, codex_home, &reg);
    try writeLiveActionTestSnapshot(gpa, codex_home, alpha_key, "alpha@example.com", "team");
    try writeLiveActionTestSnapshot(gpa, codex_home, beta_key, "beta@example.com", "plus");

    var runtime = SwitchLiveRuntime.init(
        gpa,
        codex_home,
        .remove_account,
        .skip_api,
        false,
        .{
            .usage_api_enabled = false,
            .account_api_enabled = false,
            .interval_ms = switch_live_local_refresh_interval_ms,
            .label = "local",
        },
        null,
    );
    defer runtime.deinit();

    const live_io = runtime.io_impl.io();
    const refresh_task = live_io.concurrent(sleepLiveRefreshTask, .{live_io}) catch |err| switch (err) {
        error.ConcurrencyUnavailable => return error.SkipZigTest,
    };
    runtime.mutex.lockUncancelable(live_io);
    runtime.refresh_task = refresh_task;
    runtime.in_flight = true;
    runtime.last_refresh_started_at_ms = nowMilliseconds();
    runtime.mutex.unlock(live_io);

    const selected = [_][]const u8{beta_key};
    var current_display = try loadStoredSwitchSelectionDisplay(gpa, codex_home, .remove_account, .skip_api);
    defer current_display.display.deinit(gpa);
    defer if (current_display.refresh_error_name) |name| gpa.free(name);

    const started_ms = nowMilliseconds();
    const outcome = try removeLiveRuntimeApplySelection(
        @ptrCast(&runtime),
        gpa,
        current_display.display.borrowed(),
        &selected,
    );
    const elapsed_ms = nowMilliseconds() - started_ms;
    defer {
        if (outcome.action_message) |message| gpa.free(message);
        var owned_display = outcome.updated_display;
        owned_display.deinit(gpa);
    }

    try std.testing.expect(elapsed_ms < 500);
    try std.testing.expectEqualStrings("Removed 1 account(s): beta@example.com", outcome.action_message.?);
    try std.testing.expectEqual(@as(u64, 1), runtime.display_generation);
}

test "live runtime deinit cancels an in-flight refresh promptly" {
    const gpa = std.testing.allocator;

    var runtime = SwitchLiveRuntime.init(
        gpa,
        ".",
        .list,
        .default,
        false,
        .{
            .usage_api_enabled = false,
            .account_api_enabled = false,
            .interval_ms = switch_live_local_refresh_interval_ms,
            .label = "local",
        },
        null,
    );

    const live_io = runtime.io_impl.io();
    const refresh_task = live_io.concurrent(sleepLiveRefreshTask, .{live_io}) catch |err| switch (err) {
        error.ConcurrencyUnavailable => return error.SkipZigTest,
    };
    runtime.mutex.lockUncancelable(live_io);
    runtime.refresh_task = refresh_task;
    runtime.in_flight = true;
    runtime.last_refresh_started_at_ms = nowMilliseconds();
    runtime.mutex.unlock(live_io);

    const started_ms = nowMilliseconds();
    runtime.deinit();
    const elapsed_ms = nowMilliseconds() - started_ms;

    try std.testing.expect(elapsed_ms < 500);
}

test "live fallback display preserves the refresh error name" {
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const codex_home = try app_runtime.realPathFileAlloc(gpa, tmp.dir, ".");
    defer gpa.free(codex_home);

    var reg: registry.Registry = .{
        .schema_version = registry.current_schema_version,
        .active_account_key = null,
        .active_account_activated_at_ms = null,
        .auto_switch = registry.defaultAutoSwitchConfig(),
        .api = registry.defaultApiConfig(),
        .accounts = std.ArrayList(registry.AccountRecord).empty,
    };
    defer reg.deinit(gpa);
    try registry.saveRegistry(gpa, codex_home, &reg);

    var loaded = try loadStoredSwitchSelectionDisplayWithRefreshError(
        gpa,
        codex_home,
        .switch_account,
        .skip_api,
        error.NodeJsRequired,
    );
    defer loaded.display.deinit(gpa);
    defer if (loaded.refresh_error_name) |name| gpa.free(name);

    try std.testing.expectEqualStrings("NodeJsRequired", loaded.refresh_error_name.?);
}

test "live tty preflight reports command-specific errors" {
    try std.testing.expect(liveTtyPreflightError(.list, true, true) == null);
    try std.testing.expect(liveTtyPreflightError(.switch_account, true, true) == null);
    try std.testing.expect(liveTtyPreflightError(.remove_account, true, true) == null);

    try std.testing.expect(liveTtyPreflightError(.list, false, true).? == error.ListLiveRequiresTty);
    try std.testing.expect(liveTtyPreflightError(.switch_account, true, false).? == error.SwitchSelectionRequiresTty);
    try std.testing.expect(liveTtyPreflightError(.remove_account, false, false).? == error.RemoveSelectionRequiresTty);
}

test "buildStatusLine releases mutex on allocation failure" {
    const gpa = std.testing.allocator;

    var reg: registry.Registry = .{
        .schema_version = registry.current_schema_version,
        .active_account_key = null,
        .active_account_activated_at_ms = null,
        .auto_switch = registry.defaultAutoSwitchConfig(),
        .api = registry.defaultApiConfig(),
        .accounts = std.ArrayList(registry.AccountRecord).empty,
    };
    defer reg.deinit(gpa);

    var runtime = SwitchLiveRuntime.init(
        gpa,
        ".",
        .list,
        .default,
        false,
        .{
            .usage_api_enabled = false,
            .account_api_enabled = false,
            .interval_ms = switch_live_local_refresh_interval_ms,
            .label = "local",
        },
        try gpa.dupe(u8, "NodeJsRequired"),
    );
    defer runtime.deinit();

    var failing_allocator_state = std.testing.FailingAllocator.init(gpa, .{ .fail_index = 0 });
    const failing_allocator = failing_allocator_state.allocator();

    try std.testing.expectError(
        error.OutOfMemory,
        runtime.buildStatusLine(failing_allocator, .{
            .reg = &reg,
            .usage_overrides = null,
        }),
    );

    try std.testing.expect(runtime.mutex.tryLock());
    runtime.mutex.unlock(app_runtime.io());
}

// Tests live in separate files but are pulled in by main.zig for zig test.
test {
    // Keep every src/*.zig module with top-level tests listed here so `zig build test`
    // covers the same source-file tests as direct `zig test src/<file>.zig`.
    _ = @import("account_name_refresh.zig");
    _ = @import("auto.zig");
    _ = @import("chatgpt_http.zig");
    _ = @import("cli.zig");
    _ = @import("compat_fs.zig");
    _ = @import("format.zig");
    _ = @import("timefmt.zig");
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

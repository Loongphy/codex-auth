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
const io_util = @import("io_util.zig");
const usage_api = @import("usage_api.zig");

const skip_service_reconcile_env = "CODEX_AUTH_SKIP_SERVICE_RECONCILE";
const account_name_refresh_only_env = "CODEX_AUTH_REFRESH_ACCOUNT_NAMES_ONLY";
const disable_background_account_name_refresh_env = "CODEX_AUTH_DISABLE_BACKGROUND_ACCOUNT_NAME_REFRESH";
const foreground_usage_refresh_concurrency: usize = 5;
const switch_live_api_refresh_interval_ms: i64 = 30_000;
const switch_live_local_refresh_interval_ms: i64 = 10_000;
const switch_live_stored_refresh_interval_ms: i64 = 10_000;

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

const DebugUsageLabelState = struct {
    labels: [][]const u8,

    fn deinit(self: *DebugUsageLabelState, allocator: std.mem.Allocator) void {
        for (self.labels) |label| allocator.free(@constCast(label));
        allocator.free(self.labels);
        self.* = undefined;
    }
};

pub const ForegroundUsageDebugLogger = struct {
    writer: *std.Io.Writer,
    mutex: std.Io.Mutex = .init,

    pub fn init(writer: *std.Io.Writer) ForegroundUsageDebugLogger {
        return .{
            .writer = writer,
        };
    }

    pub fn print(self: *ForegroundUsageDebugLogger, comptime fmt: []const u8, args: anytype) !void {
        self.mutex.lockUncancelable(app_runtime.io());
        defer self.mutex.unlock(app_runtime.io());

        try self.writer.print(fmt, args);
        try self.writer.flush();
    }
};

const ForegroundUsageDebugContext = struct {
    logger: *ForegroundUsageDebugLogger,
    label_state: *const DebugUsageLabelState,
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

pub fn shouldRefreshForegroundUsage(target: ForegroundUsageRefreshTarget) bool {
    return target == .list or target == .switch_account;
}

fn apiModeUsesApi(default_enabled: bool, api_mode: cli.ApiMode) bool {
    return switch (api_mode) {
        .default => default_enabled,
        .force_api => true,
        .skip_api => false,
    };
}

fn apiModeUsesStoredDataOnly(api_mode: cli.ApiMode) bool {
    return api_mode == .skip_api;
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
    return refreshForegroundUsageForDisplayWithApiFetchersWithPoolInitAndDebugUsingApiEnabled(
        allocator,
        codex_home,
        reg,
        usage_fetcher,
        null,
        initForegroundUsagePool,
        null,
        reg.api.usage,
        false,
    );
}

pub fn refreshForegroundUsageForDisplay(
    allocator: std.mem.Allocator,
    codex_home: []const u8,
    reg: *registry.Registry,
) !ForegroundUsageRefreshState {
    return refreshForegroundUsageForDisplayWithBatchFetcherAndDebugUsingApiEnabled(
        allocator,
        codex_home,
        reg,
        null,
        reg.api.usage,
    );
}

pub fn refreshForegroundUsageForDisplayWithBatchFetcherAndDebug(
    allocator: std.mem.Allocator,
    codex_home: []const u8,
    reg: *registry.Registry,
    debug_logger: ?*ForegroundUsageDebugLogger,
) !ForegroundUsageRefreshState {
    return refreshForegroundUsageForDisplayWithBatchFetcherAndDebugUsingApiEnabled(
        allocator,
        codex_home,
        reg,
        debug_logger,
        reg.api.usage,
    );
}

fn refreshForegroundUsageForDisplayWithBatchFetcherAndDebugUsingApiEnabled(
    allocator: std.mem.Allocator,
    codex_home: []const u8,
    reg: *registry.Registry,
    debug_logger: ?*ForegroundUsageDebugLogger,
    usage_api_enabled: bool,
) !ForegroundUsageRefreshState {
    return refreshForegroundUsageForDisplayWithBatchFetcherAndDebugUsingApiEnabledWithBatchFailurePolicy(
        allocator,
        codex_home,
        reg,
        debug_logger,
        usage_api_enabled,
        false,
    );
}

fn refreshForegroundUsageForDisplayWithBatchFetcherAndDebugUsingApiEnabledWithBatchFailurePolicy(
    allocator: std.mem.Allocator,
    codex_home: []const u8,
    reg: *registry.Registry,
    debug_logger: ?*ForegroundUsageDebugLogger,
    usage_api_enabled: bool,
    batch_fetch_failures_are_fatal: bool,
) !ForegroundUsageRefreshState {
    return refreshForegroundUsageForDisplayWithApiFetchersWithPoolInitAndDebugUsingApiEnabled(
        allocator,
        codex_home,
        reg,
        usage_api.fetchUsageForAuthPathDetailed,
        usage_api.fetchUsageForAuthPathsDetailedBatch,
        initForegroundUsagePool,
        debug_logger,
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
    return refreshForegroundUsageForDisplayWithApiFetchersWithPoolInitAndDebugUsingApiEnabled(
        allocator,
        codex_home,
        reg,
        usage_fetcher,
        null,
        pool_init,
        null,
        reg.api.usage,
        false,
    );
}

pub fn refreshForegroundUsageForDisplayWithApiFetcherWithPoolInitAndDebug(
    allocator: std.mem.Allocator,
    codex_home: []const u8,
    reg: *registry.Registry,
    usage_fetcher: UsageFetchDetailedFn,
    pool_init: ForegroundUsagePoolInitFn,
    debug_logger: ?*ForegroundUsageDebugLogger,
) !ForegroundUsageRefreshState {
    return refreshForegroundUsageForDisplayWithApiFetchersWithPoolInitAndDebugUsingApiEnabled(
        allocator,
        codex_home,
        reg,
        usage_fetcher,
        null,
        pool_init,
        debug_logger,
        reg.api.usage,
        false,
    );
}

fn refreshForegroundUsageForDisplayWithApiFetchersWithPoolInitAndDebugUsingApiEnabled(
    allocator: std.mem.Allocator,
    codex_home: []const u8,
    reg: *registry.Registry,
    usage_fetcher: UsageFetchDetailedFn,
    batch_fetcher: ?UsageBatchFetchDetailedFn,
    pool_init: ForegroundUsagePoolInitFn,
    debug_logger: ?*ForegroundUsageDebugLogger,
    usage_api_enabled: bool,
    batch_fetch_failures_are_fatal: bool,
) !ForegroundUsageRefreshState {
    return refreshForegroundUsageForDisplayWithApiFetchersWithPoolInitAndDebugUsingApiEnabledAndPersist(
        allocator,
        codex_home,
        reg,
        usage_fetcher,
        batch_fetcher,
        pool_init,
        debug_logger,
        usage_api_enabled,
        batch_fetch_failures_are_fatal,
        true,
    );
}

fn refreshForegroundUsageForDisplayWithApiFetchersWithPoolInitAndDebugUsingApiEnabledAndPersist(
    allocator: std.mem.Allocator,
    codex_home: []const u8,
    reg: *registry.Registry,
    usage_fetcher: UsageFetchDetailedFn,
    batch_fetcher: ?UsageBatchFetchDetailedFn,
    pool_init: ForegroundUsagePoolInitFn,
    debug_logger: ?*ForegroundUsageDebugLogger,
    usage_api_enabled: bool,
    batch_fetch_failures_are_fatal: bool,
    persist_registry: bool,
) !ForegroundUsageRefreshState {
    var state = try initForegroundUsageRefreshState(allocator, reg.accounts.items.len);
    errdefer state.deinit(allocator);

    var debug_label_state: ?DebugUsageLabelState = null;
    defer if (debug_label_state) |*label_state| label_state.deinit(allocator);

    var debug_context: ?ForegroundUsageDebugContext = null;

    if (!usage_api_enabled) {
        state.local_only_mode = true;
        if (try auto.refreshActiveUsage(allocator, codex_home, reg)) {
            if (persist_registry) try registry.saveRegistry(allocator, codex_home, reg);
        }
        if (debug_logger) |logger| {
            try logger.print("[debug] usage refresh skipped: mode=local-only; only the active account can refresh from local rollout data\n", .{});
            try printForegroundUsageDebugDone(logger, &state);
        }
        return state;
    }

    if (reg.accounts.items.len == 0) {
        if (debug_logger) |logger| {
            try printForegroundUsageDebugDone(logger, &state);
        }
        return state;
    }

    if (debug_logger) |logger| {
        debug_label_state = try buildDebugUsageLabelState(allocator, reg);
        debug_context = .{
            .logger = logger,
            .label_state = &debug_label_state.?,
        };
        const node_executable = try chatgpt_http.resolveNodeExecutableForDebugAlloc(allocator);
        defer allocator.free(node_executable);
        try printForegroundUsageDebugStart(logger, reg.accounts.items.len, node_executable);
    }

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
            if (debug_context) |debug| {
                try printForegroundUsageDebugRequest(debug.logger, reg, idx, debug.label_state.labels[idx]);
            }
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
                    worker_result.* = .{ .error_name = error_name };
                    if (debug_context) |debug| {
                        printForegroundUsageDebugWorkerResult(
                            auth_path_arena,
                            debug.logger,
                            debug.label_state.labels[idx],
                            reg.accounts.items[idx].last_usage,
                            worker_result.*,
                        );
                    }
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

            if (debug_context) |debug| {
                printForegroundUsageDebugWorkerResult(
                    auth_path_arena,
                    debug.logger,
                    debug.label_state.labels[idx],
                    reg.accounts.items[idx].last_usage,
                    worker_results[idx],
                );
            }
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
                debug_context,
            );
        } else {
            runForegroundUsageRefreshWorkersSerially(allocator, codex_home, reg, usage_fetcher, worker_results, debug_context);
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

    if (debug_logger) |logger| {
        try printForegroundUsageDebugDone(logger, &state);
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
    debug_context: ?ForegroundUsageDebugContext,
    next_index: std.atomic.Value(usize) = .init(0),

    fn run(self: *ForegroundUsageWorkerQueue) void {
        while (true) {
            const idx = self.next_index.fetchAdd(1, .monotonic);
            if (idx >= self.reg.accounts.items.len) return;

            if (self.debug_context) |debug| {
                printForegroundUsageDebugRequest(debug.logger, self.reg, idx, debug.label_state.labels[idx]) catch {};
            }
            foregroundUsageRefreshWorker(
                self.allocator,
                self.codex_home,
                self.reg,
                idx,
                self.usage_fetcher,
                self.results,
                self.debug_context,
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
    debug_context: ?ForegroundUsageDebugContext,
) !void {
    const worker_count = @min(reg.accounts.items.len, foreground_usage_refresh_concurrency);
    if (worker_count <= 1) {
        runForegroundUsageRefreshWorkersSerially(allocator, codex_home, reg, usage_fetcher, results, debug_context);
        return;
    }

    var queue: ForegroundUsageWorkerQueue = .{
        .allocator = allocator,
        .codex_home = codex_home,
        .reg = reg,
        .usage_fetcher = usage_fetcher,
        .results = results,
        .debug_context = debug_context,
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
    debug_context: ?ForegroundUsageDebugContext,
) void {
    for (reg.accounts.items, 0..) |_, idx| {
        if (debug_context) |debug| {
            printForegroundUsageDebugRequest(debug.logger, reg, idx, debug.label_state.labels[idx]) catch {};
        }
        foregroundUsageRefreshWorker(allocator, codex_home, reg, idx, usage_fetcher, results, debug_context);
    }
}

fn foregroundUsageRefreshWorker(
    allocator: std.mem.Allocator,
    codex_home: []const u8,
    reg: *registry.Registry,
    account_idx: usize,
    usage_fetcher: UsageFetchDetailedFn,
    results: []ForegroundUsageWorkerResult,
    debug_context: ?ForegroundUsageDebugContext,
) void {
    var arena_state = std.heap.ArenaAllocator.init(std.heap.smp_allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const auth_path = registry.accountAuthPath(arena, codex_home, reg.accounts.items[account_idx].account_key) catch |err| {
        results[account_idx] = .{ .error_name = @errorName(err) };
        if (debug_context) |debug| {
            printForegroundUsageDebugWorkerResult(
                arena,
                debug.logger,
                debug.label_state.labels[account_idx],
                reg.accounts.items[account_idx].last_usage,
                results[account_idx],
            );
        }
        return;
    };

    const fetch_result = usage_fetcher(arena, auth_path) catch |err| {
        results[account_idx] = .{ .error_name = @errorName(err) };
        if (debug_context) |debug| {
            printForegroundUsageDebugWorkerResult(
                arena,
                debug.logger,
                debug.label_state.labels[account_idx],
                reg.accounts.items[account_idx].last_usage,
                results[account_idx],
            );
        }
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
            if (debug_context) |debug| {
                printForegroundUsageDebugWorkerResult(
                    arena,
                    debug.logger,
                    debug.label_state.labels[account_idx],
                    reg.accounts.items[account_idx].last_usage,
                    results[account_idx],
                );
            }
            return;
        };
    }

    results[account_idx] = result;
    if (debug_context) |debug| {
        printForegroundUsageDebugWorkerResult(
            arena,
            debug.logger,
            debug.label_state.labels[account_idx],
            reg.accounts.items[account_idx].last_usage,
            result,
        );
    }
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

fn buildDebugUsageLabelState(
    allocator: std.mem.Allocator,
    reg: *const registry.Registry,
) !DebugUsageLabelState {
    var labels = try allocator.alloc([]const u8, reg.accounts.items.len);
    errdefer allocator.free(labels);
    for (reg.accounts.items, 0..) |rec, idx| {
        labels[idx] = try allocator.dupe(u8, rec.email);
    }
    errdefer {
        for (labels) |label| allocator.free(@constCast(label));
    }

    var display = try display_rows.buildDisplayRows(allocator, reg, null);
    defer display.deinit(allocator);
    for (display.rows) |row| {
        const account_idx = row.account_index orelse continue;
        const next_label = if (row.depth == 0)
            try allocator.dupe(u8, row.account_cell)
        else
            try std.fmt.allocPrint(allocator, "{s} | {s}", .{
                reg.accounts.items[account_idx].email,
                row.account_cell,
            });
        allocator.free(@constCast(labels[account_idx]));
        labels[account_idx] = next_label;
    }

    return .{
        .labels = labels,
    };
}

fn debugWorkerStatusLabel(buf: *[32]u8, result: ForegroundUsageWorkerResult) []const u8 {
    if (result.error_name) |error_name| return error_name;
    if (result.missing_auth) return "MissingAuth";
    if (result.status_code) |status_code| {
        return std.fmt.bufPrint(buf, "{d}", .{status_code}) catch "-";
    }
    return if (result.snapshot != null) "200" else "-";
}

fn workerResultHasNoUsageWindow(result: ForegroundUsageWorkerResult) bool {
    return result.error_name == null and
        !result.missing_auth and
        result.snapshot == null and
        result.status_code != null and
        result.status_code.? == 200;
}

fn formatRemainingPercentAlloc(
    allocator: std.mem.Allocator,
    window: ?registry.RateLimitWindow,
) ![]const u8 {
    const remaining = registry.remainingPercentAt(window, std.Io.Timestamp.now(app_runtime.io(), .real).toSeconds()) orelse return allocator.dupe(u8, "-");
    return std.fmt.allocPrint(allocator, "{d}%", .{remaining});
}

fn printForegroundUsageDebugStart(
    logger: *ForegroundUsageDebugLogger,
    account_count: usize,
    node_executable: []const u8,
) !void {
    try logger.print(
        "[debug] usage refresh start: accounts={d} concurrency={d} timeout_ms={s} child_timeout_ms={s} endpoint={s} node={s}\n",
        .{
            account_count,
            @min(account_count, foreground_usage_refresh_concurrency),
            chatgpt_http.request_timeout_ms,
            chatgpt_http.child_process_timeout_ms,
            usage_api.default_usage_endpoint,
            node_executable,
        },
    );
}

fn printForegroundUsageDebugDone(logger: *ForegroundUsageDebugLogger, state: *const ForegroundUsageRefreshState) !void {
    try logger.print(
        "[debug] usage refresh done: attempted={d} updated={d} failed={d} unchanged={d}\n",
        .{ state.attempted, state.updated, state.failed, state.unchanged },
    );
}

fn printForegroundUsageDebugRequest(
    logger: *ForegroundUsageDebugLogger,
    reg: *const registry.Registry,
    account_idx: usize,
    label: []const u8,
) !void {
    try logger.print(
        "[debug] request usage: {s} account_id={s}\n",
        .{
            label,
            reg.accounts.items[account_idx].chatgpt_account_id,
        },
    );
}

fn printForegroundUsageDebugWorkerResult(
    allocator: std.mem.Allocator,
    logger: *ForegroundUsageDebugLogger,
    label: []const u8,
    previous_snapshot: ?registry.RateLimitSnapshot,
    result: ForegroundUsageWorkerResult,
) void {
    var status_buf: [32]u8 = undefined;
    if (workerResultHasNoUsageWindow(result)) {
        logger.print(
            "[debug] response usage: {s} status={s} result=no-usage-limits-window\n",
            .{
                label,
                debugWorkerStatusLabel(&status_buf, result),
            },
        ) catch return;
    } else if (result.snapshot != null) {
        logger.print(
            "[debug] response usage: {s} status={s} result=usage-windows\n",
            .{
                label,
                debugWorkerStatusLabel(&status_buf, result),
            },
        ) catch return;
    } else if (result.missing_auth) {
        logger.print(
            "[debug] response usage: {s} status={s} result=missing-auth\n",
            .{
                label,
                debugWorkerStatusLabel(&status_buf, result),
            },
        ) catch return;
    } else if (result.error_name != null) {
        const result_kind = if (std.mem.eql(u8, result.error_name.?, "NodeProcessTimedOut"))
            "node-process-timeout"
        else if (std.mem.eql(u8, result.error_name.?, "NodeJsRequired"))
            "node-launch-failed"
        else
            "error";
        logger.print(
            "[debug] response usage: {s} status={s} result={s}\n",
            .{
                label,
                debugWorkerStatusLabel(&status_buf, result),
                result_kind,
            },
        ) catch return;
    } else {
        logger.print(
            "[debug] response usage: {s} status={s} result=http-response\n",
            .{
                label,
                debugWorkerStatusLabel(&status_buf, result),
            },
        ) catch return;
    }

    const snapshot = result.snapshot orelse return;
    if (registry.rateLimitSnapshotsEqual(previous_snapshot, snapshot)) return;

    const rate_5h = registry.resolveRateWindow(snapshot, 300, true);
    const rate_weekly = registry.resolveRateWindow(snapshot, 10080, false);
    const rate_5h_text = formatRemainingPercentAlloc(allocator, rate_5h) catch return;
    defer allocator.free(rate_5h_text);
    const rate_weekly_text = formatRemainingPercentAlloc(allocator, rate_weekly) catch return;
    defer allocator.free(rate_weekly_text);

    logger.print(
        "[debug] updated usage: {s} 5h={s} weekly={s}\n",
        .{
            label,
            rate_5h_text,
            rate_weekly_text,
        },
    ) catch {};
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

    var reg = try registry.loadRegistry(allocator, codex_home);
    defer reg.deinit(allocator);
    if (try registry.syncActiveAccountFromAuth(allocator, codex_home, &reg)) {
        try registry.saveRegistry(allocator, codex_home, &reg);
    }
    if (apiModeUsesStoredDataOnly(opts.api_mode)) {
        try format.printAccounts(&reg);
        return;
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

    var debug_stdout: io_util.Stdout = undefined;
    var debug_logger: ?ForegroundUsageDebugLogger = null;
    if (opts.debug) {
        debug_stdout.init();
        debug_logger = ForegroundUsageDebugLogger.init(debug_stdout.out());
    }

    var usage_state = try refreshForegroundUsageForDisplayWithBatchFetcherAndDebugUsingApiEnabled(
        allocator,
        codex_home,
        &reg,
        if (debug_logger) |*logger| logger else null,
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
            ) catch |err| switch (err) {
                error.TuiRequiresTty => {
                    try cli.printSwitchRequiresTtyError();
                    return error.SwitchSelectionRequiresTty;
                },
                else => return err,
            },
        };
        if (selected_account_key == null) return;
        try registry.activateAccountByKey(allocator, codex_home, &reg, selected_account_key.?);
        try registry.saveRegistry(allocator, codex_home, &reg);
        return;
    }

    const live_allocator = std.heap.smp_allocator;

    const loaded = try loadSwitchSelectionDisplay(live_allocator, codex_home, opts.api_mode);
    var initial_display: ?cli.OwnedSwitchSelectionDisplay = loaded.display;
    errdefer if (initial_display) |*display| display.deinit(live_allocator);

    const selected_account_key = blk: {
        var runtime = SwitchLiveRuntime.init(live_allocator, codex_home, opts.api_mode, loaded.policy);
        defer runtime.deinit();

        const controller: cli.SwitchLiveController = .{
            .context = @ptrCast(&runtime),
            .maybe_start_refresh = switchLiveRuntimeMaybeStartRefresh,
            .maybe_take_updated_display = switchLiveRuntimeMaybeTakeUpdatedDisplay,
            .build_status_line = switchLiveRuntimeBuildStatusLine,
        };

        const transferred_display = initial_display.?;
        initial_display = null;
        break :blk cli.selectAccountWithLiveUpdates(live_allocator, transferred_display, controller) catch |err| switch (err) {
            error.TuiRequiresTty => {
                try cli.printSwitchRequiresTtyError();
                return error.SwitchSelectionRequiresTty;
            },
            else => return err,
        };
    };
    defer if (selected_account_key) |account_key| live_allocator.free(@constCast(account_key));

    if (selected_account_key == null) return;

    var reg = try registry.loadRegistry(live_allocator, codex_home);
    defer reg.deinit(live_allocator);
    if (try registry.syncActiveAccountFromAuth(live_allocator, codex_home, &reg)) {
        try registry.saveRegistry(live_allocator, codex_home, &reg);
    }
    try registry.activateAccountByKey(live_allocator, codex_home, &reg, selected_account_key.?);
    try registry.saveRegistry(live_allocator, codex_home, &reg);
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
};

const SwitchLiveRuntime = struct {
    allocator: std.mem.Allocator,
    codex_home: []const u8,
    api_mode: cli.ApiMode,
    io_impl: std.Io.Threaded,
    mutex: std.Io.Mutex = .init,
    refresh_task: ?std.Io.Future(void) = null,
    updated_display: ?cli.OwnedSwitchSelectionDisplay = null,
    in_flight: bool = false,
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
        api_mode: cli.ApiMode,
        initial_policy: SwitchLiveRefreshPolicy,
    ) @This() {
        const io_impl = std.Io.Threaded.init(allocator, .{
            .concurrent_limit = .limited(1),
        });
        const now_ms = nowMilliseconds();
        return .{
            .allocator = allocator,
            .codex_home = codex_home,
            .api_mode = api_mode,
            .io_impl = io_impl,
            .next_refresh_not_before_ms = now_ms + initial_policy.interval_ms,
            .refresh_interval_ms = initial_policy.interval_ms,
            .mode_label = initial_policy.label,
        };
    }

    fn deinit(self: *@This()) void {
        self.awaitRefresh();
        if (self.updated_display) |*display| display.deinit(self.allocator);
        if (self.last_refresh_error_name) |name| self.allocator.free(name);
        self.io_impl.deinit();
        self.* = undefined;
    }

    fn awaitRefresh(self: *@This()) void {
        const io = self.io_impl.io();
        var future: ?std.Io.Future(void) = null;
        self.mutex.lockUncancelable(io);
        if (self.refresh_task) |task| {
            future = task;
            self.refresh_task = null;
        }
        self.mutex.unlock(io);
        if (future) |*task| task.await(io);
    }

    fn maybeStartRefresh(self: *@This()) void {
        const io = self.io_impl.io();
        const now_ms = nowMilliseconds();

        self.mutex.lockUncancelable(io);
        if (self.in_flight or self.refresh_task != null or now_ms < self.next_refresh_not_before_ms) {
            self.mutex.unlock(io);
            return;
        }
        self.in_flight = true;
        self.last_refresh_started_at_ms = now_ms;
        self.mutex.unlock(io);

        const future = io.concurrent(runSwitchLiveRefreshRound, .{self}) catch |err| {
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

    fn buildStatusLine(self: *@This(), allocator: std.mem.Allocator, display: cli.SwitchSelectionDisplay) ![]u8 {
        _ = display;
        const io = self.io_impl.io();
        const now_ms = nowMilliseconds();

        var in_flight = false;
        var next_refresh_not_before_ms: i64 = now_ms;
        var last_round_duration_ms: ?i64 = null;
        var mode_label: []const u8 = "stored";
        var refresh_error_name: ?[]u8 = null;

        self.mutex.lockUncancelable(io);
        in_flight = self.in_flight;
        next_refresh_not_before_ms = self.next_refresh_not_before_ms;
        last_round_duration_ms = self.last_refresh_duration_ms;
        mode_label = self.mode_label;
        if (self.last_refresh_error_name) |error_name| {
            refresh_error_name = try allocator.dupe(u8, error_name);
        }
        self.mutex.unlock(io);
        defer if (refresh_error_name) |value| allocator.free(value);

        const refresh_state = if (in_flight)
            try allocator.dupe(u8, "running")
        else if (next_refresh_not_before_ms <= now_ms)
            try allocator.dupe(u8, "due")
        else
            try std.fmt.allocPrint(allocator, "in {d}s", .{@divFloor((next_refresh_not_before_ms - now_ms) + 999, 1000)});
        defer allocator.free(refresh_state);

        const round_state = if (last_round_duration_ms) |duration_ms|
            try std.fmt.allocPrint(allocator, "{d}s", .{@divFloor(duration_ms + 999, 1000)})
        else
            try allocator.dupe(u8, "-");
        defer allocator.free(round_state);

        const error_suffix = if (refresh_error_name) |value|
            try std.fmt.allocPrint(allocator, " | Error: {s}", .{value})
        else
            try allocator.dupe(u8, "");
        defer allocator.free(error_suffix);

        return std.fmt.allocPrint(
            allocator,
            "Live refresh: {s} | Next: {s} | Last round: {s}{s}",
            .{
                mode_label,
                refresh_state,
                round_state,
                error_suffix,
            },
        );
    }
};

fn switchLiveRefreshPolicy(reg: *const registry.Registry, api_mode: cli.ApiMode) SwitchLiveRefreshPolicy {
    if (apiModeUsesStoredDataOnly(api_mode)) {
        return .{
            .usage_api_enabled = false,
            .account_api_enabled = false,
            .interval_ms = switch_live_stored_refresh_interval_ms,
            .label = "stored",
        };
    }

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

fn loadSwitchSelectionDisplay(
    allocator: std.mem.Allocator,
    codex_home: []const u8,
    api_mode: cli.ApiMode,
) !SwitchLoadedDisplay {
    if (apiModeUsesStoredDataOnly(api_mode)) {
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
            .policy = switchLiveRefreshPolicy(&latest, api_mode),
        };
    }

    var base = try registry.loadRegistry(allocator, codex_home);
    defer base.deinit(allocator);

    var refreshed = try registry.loadRegistry(allocator, codex_home);
    errdefer refreshed.deinit(allocator);
    _ = try registry.syncActiveAccountFromAuth(allocator, codex_home, &refreshed);
    const initial_policy = switchLiveRefreshPolicy(&refreshed, api_mode);

    try ensureForegroundNodeAvailableWithApiEnabled(
        allocator,
        codex_home,
        &refreshed,
        .switch_account,
        initial_policy.usage_api_enabled,
        initial_policy.account_api_enabled,
    );
    var usage_state = try refreshForegroundUsageForDisplayWithApiFetchersWithPoolInitAndDebugUsingApiEnabledAndPersist(
        allocator,
        codex_home,
        &refreshed,
        usage_api.fetchUsageForAuthPathDetailed,
        usage_api.fetchUsageForAuthPathsDetailedBatch,
        initForegroundUsagePool,
        null,
        initial_policy.usage_api_enabled,
        false,
        false,
    );
    errdefer usage_state.deinit(allocator);
    _ = try maybeRefreshForegroundAccountNamesWithAccountApiEnabledAndPersist(
        allocator,
        codex_home,
        &refreshed,
        .switch_account,
        defaultAccountFetcher,
        initial_policy.account_api_enabled,
        false,
    );

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
        .policy = switchLiveRefreshPolicy(&latest, api_mode),
    };
}

fn runSwitchLiveRefreshRound(runtime: *SwitchLiveRuntime) void {
    const io = runtime.io_impl.io();
    const started_ms = nowMilliseconds();
    const loaded = loadSwitchSelectionDisplay(runtime.allocator, runtime.codex_home, runtime.api_mode) catch |err| {
        const finished_ms = nowMilliseconds();
        const error_name = runtime.allocator.dupe(u8, @errorName(err)) catch null;

        runtime.mutex.lockUncancelable(io);
        defer runtime.mutex.unlock(io);
        if (runtime.last_refresh_error_name) |name| runtime.allocator.free(name);
        runtime.last_refresh_error_name = error_name;
        runtime.last_refresh_finished_at_ms = finished_ms;
        runtime.last_refresh_duration_ms = finished_ms - (runtime.last_refresh_started_at_ms orelse started_ms);
        runtime.next_refresh_not_before_ms = finished_ms + runtime.refresh_interval_ms;
        runtime.in_flight = false;
        return;
    };

    const finished_ms = nowMilliseconds();
    runtime.mutex.lockUncancelable(io);
    defer runtime.mutex.unlock(io);

    if (runtime.updated_display) |*display| display.deinit(runtime.allocator);
    runtime.updated_display = loaded.display;
    runtime.refresh_interval_ms = loaded.policy.interval_ms;
    runtime.mode_label = loaded.policy.label;
    if (runtime.last_refresh_error_name) |name| runtime.allocator.free(name);
    runtime.last_refresh_error_name = null;
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
    var reg = try registry.loadRegistry(allocator, codex_home);
    defer reg.deinit(allocator);

    if (try registry.syncActiveAccountFromAuth(allocator, codex_home, &reg)) {
        try registry.saveRegistry(allocator, codex_home, &reg);
    }

    const interactive_remove = !opts.all and opts.selectors.len == 0;
    const usage_api_enabled = if (interactive_remove) apiModeUsesApi(false, opts.api_mode) else false;
    const account_api_enabled = if (interactive_remove) apiModeUsesApi(false, opts.api_mode) else false;

    var usage_state: ?ForegroundUsageRefreshState = null;
    defer if (usage_state) |*state| state.deinit(allocator);

    if (interactive_remove) {
        if (usage_api_enabled) {
            usage_state = refreshForegroundUsageForDisplayWithBatchFetcherAndDebugUsingApiEnabledWithBatchFailurePolicy(
                allocator,
                codex_home,
                &reg,
                null,
                usage_api_enabled,
                true,
            ) catch |err| switch (err) {
                error.OutOfMemory => return err,
                else => null,
            };
        }
        maybeRefreshForegroundAccountNamesWithAccountApiEnabled(
            allocator,
            codex_home,
            &reg,
            .remove_account,
            defaultAccountFetcher,
            account_api_enabled,
        ) catch |err| switch (err) {
            error.OutOfMemory => return err,
            else => {},
        };
    }

    const usage_overrides = if (usage_state) |state| state.usage_overrides else null;

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

            var matches = try findMatchingAccounts(allocator, &reg, selector);
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
            usage_overrides,
        ) catch |err| switch (err) {
            error.InvalidRemoveSelectionInput => {
                try cli.printInvalidRemoveSelectionError();
                return error.InvalidRemoveSelectionInput;
            },
            error.TuiRequiresTty => {
                try cli.printRemoveRequiresTtyError();
                return error.RemoveSelectionRequiresTty;
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

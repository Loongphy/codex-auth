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

fn getEnvMap(allocator: std.mem.Allocator) !std.process.Environ.Map {
    return try app_runtime.currentEnviron().createMap(allocator);
}

fn getEnvVarOwned(allocator: std.mem.Allocator, name: []const u8) ![]u8 {
    var env_map = try getEnvMap(allocator);
    defer env_map.deinit();

    const value = env_map.get(name) orelse return error.EnvironmentVariableNotFound;
    return try allocator.dupe(u8, value);
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
    var state = try initForegroundUsageRefreshState(allocator, reg.accounts.items.len);
    errdefer state.deinit(allocator);

    var debug_label_state: ?DebugUsageLabelState = null;
    defer if (debug_label_state) |*label_state| label_state.deinit(allocator);

    var debug_context: ?ForegroundUsageDebugContext = null;

    if (!usage_api_enabled) {
        state.local_only_mode = true;
        if (try auto.refreshActiveUsage(allocator, codex_home, reg)) {
            try registry.saveRegistry(allocator, codex_home, reg);
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

    if (registry_changed) {
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
    if (!changed) return;
    try registry.saveRegistry(allocator, codex_home, reg);
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
    var reg = try registry.loadRegistry(allocator, codex_home);
    defer reg.deinit(allocator);
    if (try registry.syncActiveAccountFromAuth(allocator, codex_home, &reg)) {
        try registry.saveRegistry(allocator, codex_home, &reg);
    }
    if (opts.query) |query| {
        std.debug.assert(opts.api_mode == .default);

        var resolution = try resolveSwitchQueryLocally(allocator, &reg, query);
        defer resolution.deinit(allocator);

        const selected_account_key = switch (resolution) {
            .not_found => {
                try cli.printAccountNotFoundError(query);
                return error.AccountNotFound;
            },
            .direct => |account_key| account_key,
            .multiple => |matches| try cli.selectAccountFromIndicesWithUsageOverrides(
                allocator,
                &reg,
                matches.items,
                null,
            ),
        };
        if (selected_account_key == null) return;
        try registry.activateAccountByKey(allocator, codex_home, &reg, selected_account_key.?);
        try registry.saveRegistry(allocator, codex_home, &reg);
        return;
    }
    if (apiModeUsesStoredDataOnly(opts.api_mode)) {
        const selected_account_key = try cli.selectAccount(allocator, &reg);
        if (selected_account_key == null) return;
        try registry.activateAccountByKey(allocator, codex_home, &reg, selected_account_key.?);
        try registry.saveRegistry(allocator, codex_home, &reg);
        return;
    }

    const usage_api_enabled = apiModeUsesApi(reg.api.usage, opts.api_mode);
    const account_api_enabled = apiModeUsesApi(reg.api.account, opts.api_mode);

    try ensureForegroundNodeAvailableWithApiEnabled(
        allocator,
        codex_home,
        &reg,
        .switch_account,
        usage_api_enabled,
        account_api_enabled,
    );

    var usage_state = try refreshForegroundUsageForDisplayWithBatchFetcherAndDebugUsingApiEnabled(
        allocator,
        codex_home,
        &reg,
        null,
        usage_api_enabled,
    );
    defer usage_state.deinit(allocator);
    try maybeRefreshForegroundAccountNamesWithAccountApiEnabled(
        allocator,
        codex_home,
        &reg,
        .switch_account,
        defaultAccountFetcher,
        account_api_enabled,
    );

    const selected_account_key = try cli.selectAccountWithUsageOverrides(allocator, &reg, usage_state.usage_overrides);
    if (selected_account_key == null) return;

    try registry.activateAccountByKey(allocator, codex_home, &reg, selected_account_key.?);
    try registry.saveRegistry(allocator, codex_home, &reg);
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

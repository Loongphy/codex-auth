const std = @import("std");
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
const foreground_usage_refresh_concurrency: usize = 3;

const AccountFetchFn = *const fn (
    allocator: std.mem.Allocator,
    access_token: []const u8,
    account_id: []const u8,
) anyerror!account_api.FetchResult;
const UsageFetchDetailedFn = *const fn (
    allocator: std.mem.Allocator,
    auth_path: []const u8,
) anyerror!usage_api.UsageFetchResult;
const ForegroundUsagePoolInitFn = *const fn (
    pool: *std.Thread.Pool,
    allocator: std.mem.Allocator,
    n_jobs: usize,
) anyerror!void;
const NodeAvailabilityFn = *const fn (allocator: std.mem.Allocator) anyerror!void;
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
    mutex: std.Thread.Mutex = .{},

    pub fn init(writer: *std.Io.Writer) ForegroundUsageDebugLogger {
        return .{
            .writer = writer,
        };
    }

    pub fn print(self: *ForegroundUsageDebugLogger, comptime fmt: []const u8, args: anytype) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        try self.writer.print(fmt, args);
        try self.writer.flush();
    }
};

const ForegroundUsageDebugContext = struct {
    logger: *ForegroundUsageDebugLogger,
    label_state: *const DebugUsageLabelState,
};

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
        err == error.CodexLoginFailed or
        err == error.NodeJsRequired or
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

pub fn refreshForegroundUsageForDisplayWithApiFetcher(
    allocator: std.mem.Allocator,
    codex_home: []const u8,
    reg: *registry.Registry,
    usage_fetcher: UsageFetchDetailedFn,
) !ForegroundUsageRefreshState {
    return refreshForegroundUsageForDisplayWithApiFetcherWithPoolInitAndDebug(
        allocator,
        codex_home,
        reg,
        usage_fetcher,
        initForegroundUsagePool,
        null,
    );
}

pub fn refreshForegroundUsageForDisplayWithApiFetcherWithPoolInit(
    allocator: std.mem.Allocator,
    codex_home: []const u8,
    reg: *registry.Registry,
    usage_fetcher: UsageFetchDetailedFn,
    pool_init: ForegroundUsagePoolInitFn,
) !ForegroundUsageRefreshState {
    return refreshForegroundUsageForDisplayWithApiFetcherWithPoolInitAndDebug(
        allocator,
        codex_home,
        reg,
        usage_fetcher,
        pool_init,
        null,
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
    var state = try initForegroundUsageRefreshState(allocator, reg.accounts.items.len);
    errdefer state.deinit(allocator);

    var debug_label_state: ?DebugUsageLabelState = null;
    defer if (debug_label_state) |*label_state| label_state.deinit(allocator);

    var debug_context: ?ForegroundUsageDebugContext = null;

    if (!reg.api.usage) {
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

    if (reg.accounts.items.len == 0) {
        if (debug_logger) |logger| {
            try printForegroundUsageDebugDone(logger, &state);
        }
        return state;
    }

    const worker_results = try allocator.alloc(ForegroundUsageWorkerResult, reg.accounts.items.len);
    defer {
        for (worker_results) |*worker_result| worker_result.deinit(allocator);
        allocator.free(worker_results);
    }
    for (worker_results) |*worker_result| worker_result.* = .{};

    if (reg.accounts.items.len <= 1) {
        runForegroundUsageRefreshWorkersSerially(allocator, codex_home, reg, usage_fetcher, worker_results, debug_context);
    } else {
        var thread_safe_allocator: std.heap.ThreadSafeAllocator = .{ .child_allocator = allocator };
        const thread_allocator = thread_safe_allocator.allocator();
        var pool: std.Thread.Pool = undefined;
        const pool_started = blk: {
            pool_init(
                &pool,
                thread_allocator,
                @min(reg.accounts.items.len, foreground_usage_refresh_concurrency),
            ) catch |err| switch (err) {
                error.OutOfMemory => return err,
                else => break :blk false,
            };
            break :blk true;
        };

        if (pool_started) {
            defer pool.deinit();

            var wait_group: std.Thread.WaitGroup = .{};
            for (reg.accounts.items, 0..) |_, idx| {
                if (debug_context) |debug| {
                    try printForegroundUsageDebugRequest(debug.logger, reg, idx, debug.label_state.labels[idx]);
                }
                pool.spawnWg(&wait_group, foregroundUsageRefreshWorker, .{
                    thread_allocator,
                    codex_home,
                    reg,
                    idx,
                    usage_fetcher,
                    worker_results,
                    debug_context,
                });
            }
            wait_group.wait();
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
    pool: *std.Thread.Pool,
    allocator: std.mem.Allocator,
    n_jobs: usize,
) !void {
    try pool.init(.{
        .allocator = allocator,
        .n_jobs = n_jobs,
    });
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
    var arena_state = std.heap.ArenaAllocator.init(allocator);
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
    const remaining = registry.remainingPercentAt(window, std.time.timestamp()) orelse return allocator.dupe(u8, "-");
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
    const changed = switch (target) {
        .list => try refreshAccountNamesForList(allocator, codex_home, reg, fetcher),
        .switch_account => try refreshAccountNamesAfterSwitch(allocator, codex_home, reg, fetcher),
        .remove_account => false,
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

fn shouldPreflightNodeForAccountNameRefresh(
    allocator: std.mem.Allocator,
    codex_home: []const u8,
    reg: *registry.Registry,
    target: ForegroundUsageRefreshTarget,
) !bool {
    switch (target) {
        .list, .switch_account => {},
        .remove_account => return false,
    }

    const active_user_id = registry.activeChatgptUserId(reg) orelse return false;
    if (!shouldRefreshTeamAccountNamesForUserScope(reg, active_user_id)) return false;

    var info = (try loadActiveAuthInfoForAccountRefresh(allocator, codex_home)) orelse return false;
    defer info.deinit(allocator);

    return info.access_token != null and info.chatgpt_account_id != null;
}

fn shouldPreflightNodeForForegroundTarget(
    allocator: std.mem.Allocator,
    codex_home: []const u8,
    reg: *registry.Registry,
    target: ForegroundUsageRefreshTarget,
) !bool {
    if (shouldRefreshForegroundUsage(target) and reg.api.usage and reg.accounts.items.len > 0) return true;
    return try shouldPreflightNodeForAccountNameRefresh(allocator, codex_home, reg, target);
}

fn ensureForegroundNodeAvailable(
    allocator: std.mem.Allocator,
    codex_home: []const u8,
    reg: *registry.Registry,
    target: ForegroundUsageRefreshTarget,
) !void {
    try ensureForegroundNodeAvailableWithChecker(
        allocator,
        codex_home,
        reg,
        target,
        chatgpt_http.ensureNodeExecutableAvailable,
    );
}

fn ensureForegroundNodeAvailableWithChecker(
    allocator: std.mem.Allocator,
    codex_home: []const u8,
    reg: *registry.Registry,
    target: ForegroundUsageRefreshTarget,
    checker: NodeAvailabilityFn,
) !void {
    if (!try shouldPreflightNodeForForegroundTarget(allocator, codex_home, reg, target)) return;
    try checker(allocator);
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
    if (isAccountNameRefreshOnlyMode()) return try runBackgroundAccountNameRefresh(allocator, codex_home, defaultAccountFetcher);

    var reg = try registry.loadRegistry(allocator, codex_home);
    defer reg.deinit(allocator);
    if (try registry.syncActiveAccountFromAuth(allocator, codex_home, &reg)) {
        try registry.saveRegistry(allocator, codex_home, &reg);
    }
    try ensureForegroundNodeAvailable(allocator, codex_home, &reg, .list);
    var debug_stdout: io_util.Stdout = undefined;
    var debug_logger: ?ForegroundUsageDebugLogger = null;
    if (opts.debug) {
        debug_stdout.init();
        debug_logger = ForegroundUsageDebugLogger.init(debug_stdout.out());
    }

    var usage_state = try refreshForegroundUsageForDisplayWithApiFetcherWithPoolInitAndDebug(
        allocator,
        codex_home,
        &reg,
        usage_api.fetchUsageForAuthPathDetailed,
        initForegroundUsagePool,
        if (debug_logger) |*logger| logger else null,
    );
    defer usage_state.deinit(allocator);
    try maybeRefreshForegroundAccountNames(allocator, codex_home, &reg, .list, defaultAccountFetcher);
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
    try ensureForegroundNodeAvailable(allocator, codex_home, &reg, .switch_account);
    var usage_state = try refreshForegroundUsageForDisplayWithApiFetcher(
        allocator,
        codex_home,
        &reg,
        usage_api.fetchUsageForAuthPathDetailed,
    );
    defer usage_state.deinit(allocator);
    try maybeRefreshForegroundAccountNames(allocator, codex_home, &reg, .switch_account, defaultAccountFetcher);

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
            selected_account_key = try cli.selectAccountFromIndicesWithUsageOverrides(
                allocator,
                &reg,
                matches.items,
                usage_state.usage_overrides,
            );
        }
        if (selected_account_key == null) return;
    } else {
        const selected = try cli.selectAccountWithUsageOverrides(allocator, &reg, usage_state.usage_overrides);
        if (selected == null) return;
        selected_account_key = selected.?;
    }
    const account_key = selected_account_key.?;

    try registry.activateAccountByKey(allocator, codex_home, &reg, account_key);
    try registry.saveRegistry(allocator, codex_home, &reg);
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

test "foreground node preflight fails fast when usage refresh needs node" {
    const TestState = struct {
        var check_count: usize = 0;

        fn missingNode(allocator: std.mem.Allocator) !void {
            _ = allocator;
            check_count += 1;
            return error.NodeJsRequired;
        }
    };

    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const codex_home = try tmp.dir.realpathAlloc(gpa, ".");
    defer gpa.free(codex_home);

    var reg = registry.Registry{
        .schema_version = registry.current_schema_version,
        .active_account_key = null,
        .active_account_activated_at_ms = null,
        .auto_switch = registry.defaultAutoSwitchConfig(),
        .api = registry.defaultApiConfig(),
        .accounts = std.ArrayList(registry.AccountRecord).empty,
    };
    defer reg.deinit(gpa);

    try reg.accounts.append(gpa, .{
        .account_key = try gpa.dupe(u8, "user-1::acct-1"),
        .chatgpt_account_id = try gpa.dupe(u8, "acct-1"),
        .chatgpt_user_id = try gpa.dupe(u8, "user-1"),
        .email = try gpa.dupe(u8, "alpha@example.com"),
        .alias = try gpa.dupe(u8, ""),
        .account_name = null,
        .plan = .plus,
        .auth_mode = .chatgpt,
        .created_at = 1,
        .last_used_at = null,
        .last_usage = null,
        .last_usage_at = null,
        .last_local_rollout = null,
    });

    TestState.check_count = 0;
    try std.testing.expectError(
        error.NodeJsRequired,
        ensureForegroundNodeAvailableWithChecker(gpa, codex_home, &reg, .list, TestState.missingNode),
    );
    try std.testing.expectEqual(@as(usize, 1), TestState.check_count);
}

test "foreground node preflight fails fast when account-name refresh needs node" {
    const TestState = struct {
        var check_count: usize = 0;

        fn missingNode(allocator: std.mem.Allocator) !void {
            _ = allocator;
            check_count += 1;
            return error.NodeJsRequired;
        }

        fn appendAccount(
            allocator: std.mem.Allocator,
            reg: *registry.Registry,
            record_key: []const u8,
            email: []const u8,
            plan: registry.PlanType,
        ) !void {
            const sep = std.mem.lastIndexOf(u8, record_key, "::") orelse return error.InvalidRecordKey;
            const user_id = record_key[0..sep];
            const account_id = record_key[sep + 2 ..];
            try reg.accounts.append(allocator, .{
                .account_key = try allocator.dupe(u8, record_key),
                .chatgpt_account_id = try allocator.dupe(u8, account_id),
                .chatgpt_user_id = try allocator.dupe(u8, user_id),
                .email = try allocator.dupe(u8, email),
                .alias = try allocator.dupe(u8, ""),
                .account_name = null,
                .plan = plan,
                .auth_mode = .chatgpt,
                .created_at = 1,
                .last_used_at = null,
                .last_usage = null,
                .last_usage_at = null,
                .last_local_rollout = null,
            });
        }

        fn authJsonWithIds(
            allocator: std.mem.Allocator,
            email: []const u8,
            plan: []const u8,
            chatgpt_user_id: []const u8,
            chatgpt_account_id: []const u8,
        ) ![]u8 {
            const encoder = std.base64.url_safe_no_pad.Encoder;
            const header = "{\"alg\":\"none\",\"typ\":\"JWT\"}";
            const payload = try std.fmt.allocPrint(
                allocator,
                "{{\"email\":\"{s}\",\"https://api.openai.com/auth\":{{\"chatgpt_account_id\":\"{s}\",\"chatgpt_user_id\":\"{s}\",\"user_id\":\"{s}\",\"chatgpt_plan_type\":\"{s}\"}}}}",
                .{ email, chatgpt_account_id, chatgpt_user_id, chatgpt_user_id, plan },
            );
            defer allocator.free(payload);

            const header_b64 = try allocator.alloc(u8, encoder.calcSize(header.len));
            defer allocator.free(header_b64);
            _ = encoder.encode(header_b64, header);
            const payload_b64 = try allocator.alloc(u8, encoder.calcSize(payload.len));
            defer allocator.free(payload_b64);
            _ = encoder.encode(payload_b64, payload);
            const jwt = try std.mem.concat(allocator, u8, &[_][]const u8{ header_b64, ".", payload_b64, ".sig" });
            defer allocator.free(jwt);

            return try std.fmt.allocPrint(
                allocator,
                "{{\"tokens\":{{\"access_token\":\"access-{s}\",\"account_id\":\"{s}\",\"id_token\":\"{s}\"}}}}",
                .{ email, chatgpt_account_id, jwt },
            );
        }

        fn writeActiveAuth(
            allocator: std.mem.Allocator,
            codex_home: []const u8,
            email: []const u8,
            plan: []const u8,
            chatgpt_user_id: []const u8,
            chatgpt_account_id: []const u8,
        ) !void {
            const auth_path = try registry.activeAuthPath(allocator, codex_home);
            defer allocator.free(auth_path);

            const auth_json = try authJsonWithIds(
                allocator,
                email,
                plan,
                chatgpt_user_id,
                chatgpt_account_id,
            );
            defer allocator.free(auth_json);
            try std.fs.cwd().writeFile(.{ .sub_path = auth_path, .data = auth_json });
        }
    };

    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const codex_home = try tmp.dir.realpathAlloc(gpa, ".");
    defer gpa.free(codex_home);

    var reg = registry.Registry{
        .schema_version = registry.current_schema_version,
        .active_account_key = null,
        .active_account_activated_at_ms = null,
        .auto_switch = registry.defaultAutoSwitchConfig(),
        .api = registry.defaultApiConfig(),
        .accounts = std.ArrayList(registry.AccountRecord).empty,
    };
    defer reg.deinit(gpa);
    reg.api.usage = false;

    const user_id = "user-shared";
    const primary_record_key = "user-shared::acct-primary";
    const secondary_record_key = "user-shared::acct-secondary";
    try TestState.appendAccount(gpa, &reg, primary_record_key, "team@example.com", .team);
    try TestState.appendAccount(gpa, &reg, secondary_record_key, "team@example.com", .team);
    try registry.setActiveAccountKey(gpa, &reg, primary_record_key);
    try TestState.writeActiveAuth(gpa, codex_home, "team@example.com", "team", user_id, "acct-primary");

    TestState.check_count = 0;
    try std.testing.expectError(
        error.NodeJsRequired,
        ensureForegroundNodeAvailableWithChecker(gpa, codex_home, &reg, .list, TestState.missingNode),
    );
    try std.testing.expectEqual(@as(usize, 1), TestState.check_count);
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

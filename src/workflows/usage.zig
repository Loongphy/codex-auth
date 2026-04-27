const std = @import("std");
const auto = @import("../auto/root.zig");
const registry = @import("../registry/root.zig");
const usage_api = @import("../api/usage.zig");

const foreground_usage_refresh_concurrency: usize = 5;
pub const max_usage_override_display_width: usize = 25;
pub const UsageFetchDetailedFn = *const fn (
    allocator: std.mem.Allocator,
    auth_path: []const u8,
) anyerror!usage_api.UsageFetchResult;
pub const UsageBatchFetchDetailedFn = *const fn (
    allocator: std.mem.Allocator,
    auth_paths: []const []const u8,
    max_concurrency: usize,
) anyerror![]usage_api.BatchUsageFetchResult;
pub const ForegroundUsagePoolInitFn = *const fn (
    allocator: std.mem.Allocator,
    n_jobs: usize,
) anyerror!void;
const ForegroundUsageWorkerResult = struct {
    status_code: ?u16 = null,
    error_code: ?usage_api.ResponseErrorCode = null,
    missing_auth: bool = false,
    error_name: ?[]const u8 = null,
    snapshot: ?registry.RateLimitSnapshot = null,

    pub fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
        if (self.snapshot) |*snapshot| {
            registry.freeRateLimitSnapshot(allocator, snapshot);
            self.snapshot = null;
        }
    }
};

pub const ForegroundUsageOutcome = struct {
    attempted: bool = false,
    status_code: ?u16 = null,
    error_code: ?usage_api.ResponseErrorCode = null,
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

pub fn refreshForegroundUsageForDisplayWithBatchFetcherUsingApiEnabled(
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

pub fn refreshForegroundUsageForDisplayWithBatchFetcherUsingApiEnabledWithBatchFailurePolicy(
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

pub fn refreshForegroundUsageForDisplayWithApiFetchersWithPoolInitUsingApiEnabled(
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

pub fn refreshForegroundUsageForDisplayWithApiFetchersWithPoolInitUsingApiEnabledAndPersist(
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
                .error_code = batch_result.error_code,
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
            .error_code = worker_result.error_code,
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

pub fn initForegroundUsagePool(
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
        .error_code = fetch_result.error_code,
        .missing_auth = fetch_result.missing_auth,
    };

    if (fetch_result.snapshot) |snapshot| {
        result.snapshot = registry.cloneRateLimitSnapshot(allocator, snapshot) catch |err| {
            results[account_idx] = .{
                .status_code = fetch_result.status_code,
                .error_code = fetch_result.error_code,
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
            slot.* = try formatStatusOverrideAlloc(allocator, status_code, outcome.error_code);
            return true;
        }
    }
    return false;
}

pub fn formatStatusOverrideAlloc(
    allocator: std.mem.Allocator,
    status_code: u16,
    error_code: ?usage_api.ResponseErrorCode,
) ![]u8 {
    var status_buf: [5]u8 = undefined;
    var status_writer: std.Io.Writer = .fixed(&status_buf);
    status_writer.print("{d}", .{status_code}) catch unreachable;
    const status_text = status_writer.buffered();

    const code = if (error_code) |value| value.text() else "";
    if (code.len == 0 or status_text.len + 1 >= max_usage_override_display_width) {
        return allocator.dupe(u8, status_text);
    }

    const max_code_len = max_usage_override_display_width - status_text.len - 1;
    if (code.len <= max_code_len) {
        return std.fmt.allocPrint(allocator, "{s} {s}", .{ status_text, code });
    }
    if (max_code_len <= 3) {
        return std.fmt.allocPrint(allocator, "{s} {s}", .{ status_text, "..."[0..max_code_len] });
    }
    return std.fmt.allocPrint(allocator, "{s} {s}...", .{ status_text, code[0 .. max_code_len - 3] });
}

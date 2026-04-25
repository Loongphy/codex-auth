const std = @import("std");
const app_runtime = @import("../core/runtime.zig");
const registry = @import("../registry/root.zig");
const usage_api = @import("../api/usage.zig");
const candidate_mod = @import("candidate.zig");
const state = @import("state.zig");
const logging = @import("logging.zig");

const DaemonRefreshState = state.DaemonRefreshState;
const CandidateScore = candidate_mod.CandidateScore;
const candidate_switch_validation_limit = candidate_mod.candidate_switch_validation_limit;
const candidateScore = candidate_mod.candidateScore;
const candidateBetter = candidate_mod.candidateBetter;
const emitAutoSwitchLog = logging.emitAutoSwitchLog;

const free_plan_realtime_guard_5h_percent: i64 = 35;

pub const AutoSwitchAttempt = struct {
    refreshed_candidates: bool,
    state_changed: bool = false,
    switched: bool,
};

pub fn bestAutoSwitchCandidateIndex(reg: *registry.Registry, now: i64) ?usize {
    const active = reg.active_account_key orelse return null;
    var best_idx: ?usize = null;
    var best: ?CandidateScore = null;
    for (reg.accounts.items, 0..) |*rec, idx| {
        if (std.mem.eql(u8, rec.account_key, active)) continue;
        const score = candidateScore(rec, now);
        if (best == null or candidateBetter(score, best.?)) {
            best = score;
            best_idx = idx;
        }
    }
    return best_idx;
}

pub fn shouldSwitchCurrent(reg: *registry.Registry, now: i64) bool {
    const account_key = reg.active_account_key orelse return false;
    const idx = registry.findAccountIndexByAccountKey(reg, account_key) orelse return false;
    const rec = &reg.accounts.items[idx];
    const resolved_5h = resolve5hTriggerWindow(rec.last_usage);
    const threshold_5h_percent = effective5hThresholdPercent(reg, rec, resolved_5h.allow_free_guard);
    const rem_5h = registry.remainingPercentAt(resolved_5h.window, now);
    const rem_week = registry.remainingPercentAt(registry.resolveRateWindow(rec.last_usage, 10080, false), now);
    return (rem_5h != null and rem_5h.? < threshold_5h_percent) or
        (rem_week != null and rem_week.? < @as(i64, reg.auto_switch.threshold_weekly_percent));
}

pub fn effective5hThresholdPercent(reg: *registry.Registry, rec: *const registry.AccountRecord, allow_free_guard: bool) i64 {
    var threshold = @as(i64, reg.auto_switch.threshold_5h_percent);
    if (allow_free_guard and registry.resolvePlan(rec) == .free) {
        threshold = @max(threshold, free_plan_realtime_guard_5h_percent);
    }
    return threshold;
}

pub fn maybeAutoSwitch(allocator: std.mem.Allocator, codex_home: []const u8, reg: *registry.Registry) !bool {
    const attempt = try maybeAutoSwitchWithUsageFetcher(allocator, codex_home, reg, usage_api.fetchUsageForAuthPath);
    return attempt.switched;
}

pub fn maybeAutoSwitchWithUsageFetcher(
    allocator: std.mem.Allocator,
    codex_home: []const u8,
    reg: *registry.Registry,
    usage_fetcher: anytype,
) !AutoSwitchAttempt {
    return maybeAutoSwitchWithUsageFetcherAndRefreshState(allocator, codex_home, reg, null, usage_fetcher);
}

pub fn maybeAutoSwitchForDaemonWithUsageFetcher(
    allocator: std.mem.Allocator,
    codex_home: []const u8,
    reg: *registry.Registry,
    refresh_state: *DaemonRefreshState,
    usage_fetcher: anytype,
) !AutoSwitchAttempt {
    if (!reg.auto_switch.enabled) return .{ .refreshed_candidates = false, .switched = false };
    const now = std.Io.Timestamp.now(app_runtime.io(), .real).toSeconds();
    if (refresh_state.current_reg == null and refresh_state.candidate_index.heap.items.len == 0) {
        try refresh_state.candidate_index.rebuild(allocator, reg, now);
    } else {
        try refresh_state.candidate_index.rebuildIfScoreExpired(allocator, reg, now);
    }
    const active = reg.active_account_key orelse return .{ .refreshed_candidates = false, .switched = false };
    const now_ns = @as(i128, std.Io.Timestamp.now(app_runtime.io(), .real).toNanoseconds());
    const active_idx = registry.findAccountIndexByAccountKey(reg, active) orelse return .{
        .refreshed_candidates = false,
        .switched = false,
    };
    const current = candidateScore(&reg.accounts.items[active_idx], now);
    const should_switch_current = shouldSwitchCurrent(reg, now);

    var changed = false;
    var refreshed_candidates = false;

    if (reg.api.usage and !should_switch_current) {
        const upkeep = try refreshDaemonCandidateUpkeepWithUsageFetcher(
            allocator,
            codex_home,
            reg,
            refresh_state,
            usage_fetcher,
            now,
            now_ns,
        );
        refreshed_candidates = upkeep.attempted != 0;
        changed = upkeep.updated != 0;
    }

    if (!should_switch_current) {
        return .{
            .refreshed_candidates = refreshed_candidates,
            .state_changed = changed,
            .switched = false,
        };
    }

    if (reg.api.usage) {
        var skipped_candidates = std.ArrayListUnmanaged([]const u8).empty;
        defer skipped_candidates.deinit(allocator);
        const validation = try refreshDaemonSwitchCandidatesWithUsageFetcher(
            allocator,
            codex_home,
            reg,
            refresh_state,
            usage_fetcher,
            now,
            now_ns,
            &skipped_candidates,
        );
        refreshed_candidates = refreshed_candidates or validation.attempted != 0;
        changed = changed or validation.updated != 0;

        const best_candidate_key = (try bestDaemonCandidateForSwitch(allocator, refresh_state, skipped_candidates.items, now_ns)) orelse return .{
            .refreshed_candidates = refreshed_candidates,
            .state_changed = changed,
            .switched = false,
        };
        const candidate_idx = registry.findAccountIndexByAccountKey(reg, best_candidate_key) orelse return .{
            .refreshed_candidates = refreshed_candidates,
            .state_changed = changed,
            .switched = false,
        };
        const candidate = candidateScore(&reg.accounts.items[candidate_idx], now);
        if (candidate.value <= current.value) {
            return .{
                .refreshed_candidates = refreshed_candidates,
                .state_changed = changed,
                .switched = false,
            };
        }

        const previous_active_key = reg.accounts.items[active_idx].account_key;
        const next_active_key = reg.accounts.items[candidate_idx].account_key;
        try registry.activateAccountByKey(allocator, codex_home, reg, next_active_key);
        try refresh_state.candidate_index.handleActiveSwitch(
            allocator,
            reg,
            previous_active_key,
            next_active_key,
            std.Io.Timestamp.now(app_runtime.io(), .real).toSeconds(),
        );
        try refresh_state.markCandidateChecked(allocator, previous_active_key, now_ns);
        refresh_state.clearCandidateChecked(next_active_key);
        return .{
            .refreshed_candidates = refreshed_candidates,
            .state_changed = true,
            .switched = true,
        };
    }

    const candidate_entry = refresh_state.candidate_index.best() orelse return .{
        .refreshed_candidates = refreshed_candidates,
        .state_changed = changed,
        .switched = false,
    };
    const candidate_idx = registry.findAccountIndexByAccountKey(reg, candidate_entry.account_key) orelse return .{
        .refreshed_candidates = refreshed_candidates,
        .state_changed = changed,
        .switched = false,
    };
    const candidate = candidateScore(&reg.accounts.items[candidate_idx], now);
    if (candidate.value <= current.value) {
        return .{
            .refreshed_candidates = refreshed_candidates,
            .state_changed = changed,
            .switched = false,
        };
    }

    const previous_active_key = reg.accounts.items[active_idx].account_key;
    const next_active_key = reg.accounts.items[candidate_idx].account_key;
    try registry.activateAccountByKey(allocator, codex_home, reg, next_active_key);
    try refresh_state.candidate_index.handleActiveSwitch(
        allocator,
        reg,
        previous_active_key,
        next_active_key,
        std.Io.Timestamp.now(app_runtime.io(), .real).toSeconds(),
    );
    try refresh_state.markCandidateChecked(allocator, previous_active_key, now_ns);
    refresh_state.clearCandidateChecked(next_active_key);
    return .{
        .refreshed_candidates = refreshed_candidates,
        .state_changed = true,
        .switched = true,
    };
}

pub fn maybeAutoSwitchWithUsageFetcherAndRefreshState(
    allocator: std.mem.Allocator,
    codex_home: []const u8,
    reg: *registry.Registry,
    refresh_state: ?*DaemonRefreshState,
    usage_fetcher: anytype,
) !AutoSwitchAttempt {
    if (!reg.auto_switch.enabled) return .{ .refreshed_candidates = false, .switched = false };
    const active = reg.active_account_key orelse return .{ .refreshed_candidates = false, .switched = false };
    const now = std.Io.Timestamp.now(app_runtime.io(), .real).toSeconds();
    if (!shouldSwitchCurrent(reg, now)) return .{ .refreshed_candidates = false, .switched = false };

    _ = refresh_state;
    const should_refresh_candidates = reg.api.usage;

    const refreshed_candidates = if (should_refresh_candidates)
        try refreshAutoSwitchCandidatesWithUsageFetcher(allocator, codex_home, reg, usage_fetcher)
    else
        false;

    const active_idx = registry.findAccountIndexByAccountKey(reg, active) orelse return .{
        .refreshed_candidates = refreshed_candidates,
        .switched = false,
    };
    const current = candidateScore(&reg.accounts.items[active_idx], now);
    const candidate_idx = bestAutoSwitchCandidateIndex(reg, now) orelse return .{
        .refreshed_candidates = refreshed_candidates,
        .switched = false,
    };
    const candidate = candidateScore(&reg.accounts.items[candidate_idx], now);
    if (candidate.value <= current.value) {
        return .{
            .refreshed_candidates = refreshed_candidates,
            .switched = false,
        };
    }

    try registry.activateAccountByKey(allocator, codex_home, reg, reg.accounts.items[candidate_idx].account_key);
    return .{ .refreshed_candidates = refreshed_candidates, .state_changed = true, .switched = true };
}

pub fn refreshAutoSwitchCandidatesWithUsageFetcher(
    allocator: std.mem.Allocator,
    codex_home: []const u8,
    reg: *registry.Registry,
    usage_fetcher: anytype,
) !bool {
    const active = reg.active_account_key orelse return false;
    var changed = false;
    var attempted: usize = 0;
    var updated: usize = 0;

    for (reg.accounts.items) |rec| {
        if (std.mem.eql(u8, rec.account_key, active)) continue;
        if (rec.auth_mode != null and rec.auth_mode.? != .chatgpt) continue;
        attempted += 1;

        const auth_path = registry.accountAuthPath(allocator, codex_home, rec.account_key) catch continue;
        defer allocator.free(auth_path);

        const latest_usage = usage_fetcher(allocator, auth_path) catch continue;
        if (latest_usage == null) continue;

        var latest = latest_usage.?;
        var snapshot_consumed = false;
        defer if (!snapshot_consumed) registry.freeRateLimitSnapshot(allocator, &latest);

        if (registry.rateLimitSnapshotsEqual(rec.last_usage, latest)) continue;
        registry.updateUsage(allocator, reg, rec.account_key, latest);
        snapshot_consumed = true;
        changed = true;
        updated += 1;
    }

    return changed;
}

pub const CandidateRefreshSummary = struct {
    attempted: usize = 0,
    updated: usize = 0,
};

pub fn keyIsSkipped(skipped_keys: []const []const u8, account_key: []const u8) bool {
    for (skipped_keys) |skipped| {
        if (std.mem.eql(u8, skipped, account_key)) return true;
    }
    return false;
}

pub fn bestDaemonCandidateForSwitch(
    allocator: std.mem.Allocator,
    refresh_state: *DaemonRefreshState,
    skipped_keys: []const []const u8,
    now_ns: i128,
) !?[]const u8 {
    var ordered = try refresh_state.candidate_index.orderedKeys(allocator);
    defer ordered.deinit(allocator);

    for (ordered.items) |account_key| {
        if (refresh_state.candidateIsRejected(account_key, now_ns)) continue;
        if (!keyIsSkipped(skipped_keys, account_key)) return account_key;
    }
    return null;
}

pub fn refreshDaemonCandidateUpkeepWithUsageFetcher(
    allocator: std.mem.Allocator,
    codex_home: []const u8,
    reg: *registry.Registry,
    refresh_state: *DaemonRefreshState,
    usage_fetcher: anytype,
    now: i64,
    now_ns: i128,
) !CandidateRefreshSummary {
    var ordered = try refresh_state.candidate_index.orderedKeys(allocator);
    defer ordered.deinit(allocator);

    var summary: CandidateRefreshSummary = .{};
    for (ordered.items) |account_key| {
        if (!refresh_state.candidateIsStale(account_key, now_ns)) break;
        const result = try refreshDaemonCandidateUsageByKeyWithFetcher(
            allocator,
            codex_home,
            reg,
            refresh_state,
            account_key,
            usage_fetcher,
            now_ns,
        );
        summary.attempted += result.attempted;
        summary.updated += result.updated;
        if (result.visited) break;
    }

    _ = now;
    return summary;
}

pub fn refreshDaemonSwitchCandidatesWithUsageFetcher(
    allocator: std.mem.Allocator,
    codex_home: []const u8,
    reg: *registry.Registry,
    refresh_state: *DaemonRefreshState,
    usage_fetcher: anytype,
    now: i64,
    now_ns: i128,
    skipped_keys: *std.ArrayListUnmanaged([]const u8),
) !CandidateRefreshSummary {
    var summary: CandidateRefreshSummary = .{};
    var visited: usize = 0;
    while (visited < candidate_switch_validation_limit) : (visited += 1) {
        const best_account_key = (try bestDaemonCandidateForSwitch(allocator, refresh_state, skipped_keys.items, now_ns)) orelse break;
        if (!refresh_state.candidateIsStale(best_account_key, now_ns)) break;

        const result = try refreshDaemonCandidateUsageByKeyWithFetcher(
            allocator,
            codex_home,
            reg,
            refresh_state,
            best_account_key,
            usage_fetcher,
            now_ns,
        );
        summary.attempted += result.attempted;
        summary.updated += result.updated;
        if (result.disqualify_for_switch) {
            try skipped_keys.append(allocator, best_account_key);
        }
        if (!result.visited) break;
    }

    _ = now;
    return summary;
}

pub const SingleCandidateRefreshResult = struct {
    visited: bool = false,
    attempted: usize = 0,
    updated: usize = 0,
    disqualify_for_switch: bool = false,
};

pub fn refreshDaemonCandidateUsageByKeyWithFetcher(
    allocator: std.mem.Allocator,
    codex_home: []const u8,
    reg: *registry.Registry,
    refresh_state: *DaemonRefreshState,
    account_key: []const u8,
    usage_fetcher: anytype,
    now_ns: i128,
) !SingleCandidateRefreshResult {
    const idx = registry.findAccountIndexByAccountKey(reg, account_key) orelse return .{};
    const rec = &reg.accounts.items[idx];

    if (rec.auth_mode != null and rec.auth_mode.? != .chatgpt) {
        try refresh_state.markCandidateChecked(allocator, account_key, now_ns);
        refresh_state.clearCandidateRejected(account_key);
        return .{ .visited = true };
    }

    const auth_path = registry.accountAuthPath(allocator, codex_home, account_key) catch {
        try refresh_state.markCandidateChecked(allocator, account_key, now_ns);
        return .{ .visited = true };
    };
    defer allocator.free(auth_path);

    try refresh_state.markCandidateChecked(allocator, account_key, now_ns);
    const fetch_result = usage_fetcher(allocator, auth_path) catch {
        return .{
            .visited = true,
            .attempted = 1,
        };
    };
    if (fetch_result.missing_auth) {
        try refresh_state.markCandidateRejected(allocator, account_key);
        return .{
            .visited = true,
            .attempted = 1,
            .disqualify_for_switch = true,
        };
    }
    if (fetch_result.status_code) |status_code| {
        if (status_code != 200) {
            try refresh_state.markCandidateRejected(allocator, account_key);
            return .{
                .visited = true,
                .attempted = 1,
                .disqualify_for_switch = true,
            };
        }
    }

    const latest_usage = fetch_result.snapshot;
    if (latest_usage == null) {
        if (fetch_result.status_code != null) {
            try refresh_state.markCandidateRejected(allocator, account_key);
        }
        return .{
            .visited = true,
            .attempted = 1,
            .disqualify_for_switch = fetch_result.status_code != null,
        };
    }

    var latest = latest_usage.?;
    var snapshot_consumed = false;
    defer if (!snapshot_consumed) registry.freeRateLimitSnapshot(allocator, &latest);

    refresh_state.clearCandidateRejected(account_key);

    if (registry.rateLimitSnapshotsEqual(rec.last_usage, latest)) {
        return .{ .visited = true, .attempted = 1 };
    }

    registry.updateUsage(allocator, reg, account_key, latest);
    snapshot_consumed = true;
    try refresh_state.candidate_index.upsertFromRegistry(allocator, reg, account_key, std.Io.Timestamp.now(app_runtime.io(), .real).toSeconds());
    return .{ .visited = true, .attempted = 1, .updated = 1 };
}

pub const Resolved5hWindow = struct {
    window: ?registry.RateLimitWindow,
    allow_free_guard: bool,
};

pub fn resolve5hTriggerWindow(usage: ?registry.RateLimitSnapshot) Resolved5hWindow {
    if (usage == null) return .{ .window = null, .allow_free_guard = false };
    if (usage.?.primary) |primary| {
        if (primary.window_minutes == null) {
            return .{ .window = primary, .allow_free_guard = true };
        }
        if (primary.window_minutes.? == 300) {
            return .{ .window = primary, .allow_free_guard = true };
        }
    }
    if (usage.?.secondary) |secondary| {
        if (secondary.window_minutes != null and secondary.window_minutes.? == 300) {
            return .{ .window = secondary, .allow_free_guard = true };
        }
    }
    if (usage.?.primary) |primary| {
        return .{ .window = primary, .allow_free_guard = false };
    }
    return .{ .window = null, .allow_free_guard = false };
}

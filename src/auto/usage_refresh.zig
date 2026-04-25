const std = @import("std");
const app_runtime = @import("../core/runtime.zig");
const account_api = @import("../api/account.zig");
const account_name_refresh = @import("../auth/account.zig");
const registry = @import("../registry/root.zig");
const sessions = @import("../session.zig");
const usage_api = @import("../api/usage.zig");
const files = @import("files.zig");
const logging = @import("logging.zig");
const state = @import("state.zig");

const DaemonRefreshState = state.DaemonRefreshState;
const api_refresh_interval_ns = state.api_refresh_interval_ns;
const fileMtimeNsIfExists = files.fileMtimeNsIfExists;
const emitDaemonLog = logging.emitDaemonLog;
const emitTaggedDaemonLog = logging.emitTaggedDaemonLog;
const localDateTimeLabel = logging.localDateTimeLabel;
const rolloutFileLabel = logging.rolloutFileLabel;
const rolloutWindowsLabel = logging.rolloutWindowsLabel;
const apiStatusLabel = logging.apiStatusLabel;
const fieldSeparator = logging.fieldSeparator;

pub fn refreshActiveUsage(allocator: std.mem.Allocator, codex_home: []const u8, reg: *registry.Registry) !bool {
    return refreshActiveUsageWithApiFetcher(allocator, codex_home, reg, usage_api.fetchActiveUsage);
}

pub fn fetchActiveAccountNames(
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

fn applyDaemonAccountNameEntriesToLatestRegistry(
    allocator: std.mem.Allocator,
    codex_home: []const u8,
    chatgpt_user_id: []const u8,
    entries: []const account_api.AccountEntry,
) !bool {
    var latest = try registry.loadRegistry(allocator, codex_home);
    defer latest.deinit(allocator);

    if (!latest.auto_switch.enabled or !latest.api.account) return false;
    if (!registry.shouldFetchTeamAccountNamesForUser(&latest, chatgpt_user_id)) return false;
    if (!try registry.applyAccountNamesForUser(allocator, &latest, chatgpt_user_id, entries)) return false;

    try registry.saveRegistry(allocator, codex_home, &latest);
    return true;
}

pub fn refreshActiveAccountNamesForDaemon(
    allocator: std.mem.Allocator,
    codex_home: []const u8,
    reg: *registry.Registry,
    refresh_state: *DaemonRefreshState,
) !bool {
    return refreshActiveAccountNamesForDaemonWithFetcher(
        allocator,
        codex_home,
        reg,
        refresh_state,
        fetchActiveAccountNames,
    );
}

pub fn refreshActiveAccountNamesForDaemonWithFetcher(
    allocator: std.mem.Allocator,
    codex_home: []const u8,
    reg: *registry.Registry,
    refresh_state: *DaemonRefreshState,
    fetcher: anytype,
) !bool {
    if (!reg.auto_switch.enabled) return false;
    if (!reg.api.account) return false;
    const account_key = reg.active_account_key orelse return false;
    try refresh_state.resetAccountNameCooldownIfAccountChanged(allocator, account_key);

    const now_ns = @as(i128, std.Io.Timestamp.now(app_runtime.io(), .real).toNanoseconds());
    if (refresh_state.last_account_name_refresh_at_ns != 0 and
        (now_ns - refresh_state.last_account_name_refresh_at_ns) < api_refresh_interval_ns)
    {
        return false;
    }

    var candidates = try account_name_refresh.collectCandidates(allocator, reg);
    defer {
        for (candidates.items) |*candidate| candidate.deinit(allocator);
        candidates.deinit(allocator);
    }
    if (candidates.items.len == 0) return false;

    var attempted = false;
    var changed = false;

    for (candidates.items) |candidate| {
        var latest = try registry.loadRegistry(allocator, codex_home);
        defer latest.deinit(allocator);

        if (!latest.auto_switch.enabled or !latest.api.account) continue;
        if (!registry.shouldFetchTeamAccountNamesForUser(&latest, candidate.chatgpt_user_id)) continue;

        var info = (try account_name_refresh.loadStoredAuthInfoForUser(
            allocator,
            codex_home,
            &latest,
            candidate.chatgpt_user_id,
        )) orelse continue;
        defer info.deinit(allocator);

        const access_token = info.access_token orelse continue;
        const chatgpt_account_id = info.chatgpt_account_id orelse continue;
        if (!attempted) {
            refresh_state.last_account_name_refresh_at_ns = now_ns;
            attempted = true;
        }

        const result = fetcher(allocator, access_token, chatgpt_account_id) catch |err| {
            std.log.warn("account metadata refresh skipped: {s}", .{@errorName(err)});
            continue;
        };
        defer result.deinit(allocator);

        const entries = result.entries orelse continue;
        if (try applyDaemonAccountNameEntriesToLatestRegistry(allocator, codex_home, candidate.chatgpt_user_id, entries)) {
            changed = true;
        }
    }

    return changed;
}

pub fn refreshActiveUsageWithApiFetcher(
    allocator: std.mem.Allocator,
    codex_home: []const u8,
    reg: *registry.Registry,
    api_fetcher: anytype,
) !bool {
    if (reg.api.usage) {
        return switch (try refreshActiveUsageFromApi(allocator, codex_home, reg, api_fetcher)) {
            .updated => true,
            .unchanged, .unavailable => false,
        };
    }
    return refreshActiveUsageFromSessions(allocator, codex_home, reg);
}

pub const ApiRefreshResult = enum { unavailable, unchanged, updated };

fn refreshActiveUsageFromApi(
    allocator: std.mem.Allocator,
    codex_home: []const u8,
    reg: *registry.Registry,
    api_fetcher: anytype,
) !ApiRefreshResult {
    const latest_usage = api_fetcher(allocator, codex_home) catch return .unavailable;
    if (latest_usage == null) return .unavailable;

    var latest = latest_usage.?;
    var snapshot_consumed = false;
    defer if (!snapshot_consumed) registry.freeRateLimitSnapshot(allocator, &latest);

    const account_key = reg.active_account_key orelse return .unchanged;
    const idx = registry.findAccountIndexByAccountKey(reg, account_key) orelse return .unchanged;
    if (registry.rateLimitSnapshotsEqual(reg.accounts.items[idx].last_usage, latest)) return .unchanged;

    registry.updateUsage(allocator, reg, account_key, latest);
    snapshot_consumed = true;
    return .updated;
}

fn refreshActiveUsageFromSessions(
    allocator: std.mem.Allocator,
    codex_home: []const u8,
    reg: *registry.Registry,
) !bool {
    const latest_usage = sessions.scanLatestUsageWithSource(allocator, codex_home) catch |err| switch (err) {
        error.FileNotFound => return false,
        else => return err,
    };
    if (latest_usage == null) return false;
    var latest = latest_usage.?;
    var snapshot_consumed = false;
    defer {
        allocator.free(latest.path);
        if (!snapshot_consumed) {
            registry.freeRateLimitSnapshot(allocator, &latest.snapshot);
        }
    }
    const signature: registry.RolloutSignature = .{
        .path = latest.path,
        .event_timestamp_ms = latest.event_timestamp_ms,
    };
    const account_key = reg.active_account_key orelse return false;
    const activated_at_ms = reg.active_account_activated_at_ms orelse 0;
    if (latest.event_timestamp_ms < activated_at_ms) return false;
    const idx = registry.findAccountIndexByAccountKey(reg, account_key) orelse return false;
    if (registry.rolloutSignaturesEqual(reg.accounts.items[idx].last_local_rollout, signature)) return false;
    registry.updateUsage(allocator, reg, account_key, latest.snapshot);
    snapshot_consumed = true;
    try registry.setAccountLastLocalRollout(allocator, &reg.accounts.items[idx], latest.path, latest.event_timestamp_ms);
    return true;
}

pub fn refreshActiveUsageForDaemon(
    allocator: std.mem.Allocator,
    codex_home: []const u8,
    reg: *registry.Registry,
    refresh_state: *DaemonRefreshState,
) !bool {
    return refreshActiveUsageForDaemonWithDetailedApiFetcher(
        allocator,
        codex_home,
        reg,
        refresh_state,
        usage_api.fetchActiveUsageDetailed,
    );
}

pub fn refreshActiveUsageForDaemonWithDetailedApiFetcher(
    allocator: std.mem.Allocator,
    codex_home: []const u8,
    reg: *registry.Registry,
    refresh_state: *DaemonRefreshState,
    api_fetcher: anytype,
) !bool {
    const account_key = reg.active_account_key orelse return false;
    refresh_state.clearPendingIfAccountChanged(allocator, account_key);
    try refresh_state.resetApiCooldownIfAccountChanged(allocator, account_key);
    const active_idx = registry.findAccountIndexByAccountKey(reg, account_key);

    if (try refreshActiveUsageFromSessionsForDaemon(allocator, codex_home, reg, refresh_state)) {
        return true;
    }
    if (!reg.api.usage) return false;

    const now_ns = @as(i128, std.Io.Timestamp.now(app_runtime.io(), .real).toNanoseconds());
    if (refresh_state.last_api_refresh_at_ns != 0 and (now_ns - refresh_state.last_api_refresh_at_ns) < api_refresh_interval_ns) {
        return false;
    }
    refresh_state.last_api_refresh_at_ns = now_ns;

    const fetch_result = api_fetcher(allocator, codex_home) catch |err| {
        emitTaggedDaemonLog(.warning, "api", "refresh usage{s}status={s}", .{
            fieldSeparator(),
            @errorName(err),
        });
        return false;
    };

    const latest_usage = fetch_result.snapshot;
    const status_code = fetch_result.status_code;
    const missing_auth = fetch_result.missing_auth;
    var status_buf: [24]u8 = undefined;
    if (latest_usage == null) {
        emitTaggedDaemonLog(.warning, "api", "refresh usage{s}status={s}", .{
            fieldSeparator(),
            apiStatusLabel(&status_buf, status_code, false, missing_auth),
        });
        return false;
    }

    var latest = latest_usage.?;
    var snapshot_consumed = false;
    defer if (!snapshot_consumed) registry.freeRateLimitSnapshot(allocator, &latest);

    if (active_idx == null) {
        emitTaggedDaemonLog(.debug, "api", "refresh usage{s}status={s}", .{
            fieldSeparator(),
            apiStatusLabel(&status_buf, status_code, true, missing_auth),
        });
        return false;
    }
    if (registry.rateLimitSnapshotsEqual(reg.accounts.items[active_idx.?].last_usage, latest)) {
        emitTaggedDaemonLog(.debug, "api", "refresh usage{s}status={s}", .{
            fieldSeparator(),
            apiStatusLabel(&status_buf, status_code, true, missing_auth),
        });
        refresh_state.clearPending(allocator);
        return false;
    }

    registry.updateUsage(allocator, reg, account_key, latest);
    snapshot_consumed = true;
    emitTaggedDaemonLog(.info, "api", "refresh usage{s}status={s}", .{
        fieldSeparator(),
        apiStatusLabel(&status_buf, status_code, true, missing_auth),
    });
    refresh_state.clearPending(allocator);
    return true;
}

pub fn refreshActiveUsageForDaemonWithApiFetcher(
    allocator: std.mem.Allocator,
    codex_home: []const u8,
    reg: *registry.Registry,
    refresh_state: *DaemonRefreshState,
    api_fetcher: anytype,
) !bool {
    const account_key = reg.active_account_key orelse return false;
    refresh_state.clearPendingIfAccountChanged(allocator, account_key);
    try refresh_state.resetApiCooldownIfAccountChanged(allocator, account_key);
    if (try refreshActiveUsageFromSessionsForDaemon(allocator, codex_home, reg, refresh_state)) {
        return true;
    }
    if (!reg.api.usage) return false;

    const now_ns = @as(i128, std.Io.Timestamp.now(app_runtime.io(), .real).toNanoseconds());
    if (refresh_state.last_api_refresh_at_ns != 0 and (now_ns - refresh_state.last_api_refresh_at_ns) < api_refresh_interval_ns) {
        return false;
    }
    refresh_state.last_api_refresh_at_ns = now_ns;

    return switch (try refreshActiveUsageFromApi(allocator, codex_home, reg, api_fetcher)) {
        .updated => blk: {
            emitTaggedDaemonLog(.info, "api", "refresh usage{s}status=200", .{fieldSeparator()});
            refresh_state.clearPending(allocator);
            break :blk true;
        },
        .unchanged => blk: {
            emitTaggedDaemonLog(.debug, "api", "refresh usage{s}status=200", .{fieldSeparator()});
            refresh_state.clearPending(allocator);
            break :blk false;
        },
        .unavailable => blk: {
            emitTaggedDaemonLog(.warning, "api", "refresh usage{s}status=NoUsageLimitsWindow", .{fieldSeparator()});
            break :blk false;
        },
    };
}

fn refreshActiveUsageFromSessionsForDaemon(
    allocator: std.mem.Allocator,
    codex_home: []const u8,
    reg: *registry.Registry,
    refresh_state: *DaemonRefreshState,
) !bool {
    var latest_event = (sessions.scanLatestRolloutEventWithCache(allocator, codex_home, &refresh_state.rollout_scan_cache) catch |err| switch (err) {
        error.FileNotFound => return false,
        else => return err,
    }) orelse return false;
    defer latest_event.deinit(allocator);

    const account_key = reg.active_account_key orelse return false;
    const activated_at_ms = reg.active_account_activated_at_ms orelse 0;
    if (latest_event.event_timestamp_ms < activated_at_ms) return false;

    const signature: registry.RolloutSignature = .{
        .path = latest_event.path,
        .event_timestamp_ms = latest_event.event_timestamp_ms,
    };
    const idx = registry.findAccountIndexByAccountKey(reg, account_key) orelse return false;
    if (registry.rolloutSignaturesEqual(reg.accounts.items[idx].last_local_rollout, signature)) {
        refresh_state.clearPending(allocator);
        return false;
    }

    var event_time_buf: [19]u8 = undefined;
    const event_time = localDateTimeLabel(&event_time_buf, latest_event.event_timestamp_ms);
    var file_buf: [96]u8 = undefined;
    const file_label = rolloutFileLabel(&file_buf, latest_event.path);

    if (!latest_event.hasUsableWindows()) {
        if (try applyLatestUsableSnapshotFromRolloutFile(
            allocator,
            reg,
            account_key,
            idx,
            latest_event.path,
            latest_event.mtime,
            activated_at_ms,
        )) {
            refresh_state.clearPending(allocator);
            return true;
        }
        if (refresh_state.pendingMatches(account_key, signature)) {
            return false;
        }
        emitTaggedDaemonLog(.warning, "local", "no usage limits window{s}fallback-to-api{s}event={s}{s}file={s}", .{
            fieldSeparator(),
            fieldSeparator(),
            event_time,
            fieldSeparator(),
            file_label,
        });
        try refresh_state.setPending(allocator, account_key, signature);
        return false;
    }

    const now = std.Io.Timestamp.now(app_runtime.io(), .real).toSeconds();
    var windows_buf: [64]u8 = undefined;
    emitTaggedDaemonLog(.notice, "local", "{s}{s}event={s}{s}file={s}", .{
        rolloutWindowsLabel(&windows_buf, latest_event.snapshot.?, now),
        fieldSeparator(),
        event_time,
        fieldSeparator(),
        file_label,
    });
    registry.updateUsage(allocator, reg, account_key, latest_event.snapshot.?);
    latest_event.snapshot = null;
    try registry.setAccountLastLocalRollout(allocator, &reg.accounts.items[idx], latest_event.path, latest_event.event_timestamp_ms);
    refresh_state.clearPending(allocator);
    return true;
}

fn applyLatestUsableSnapshotFromRolloutFile(
    allocator: std.mem.Allocator,
    reg: *registry.Registry,
    account_key: []const u8,
    idx: usize,
    rollout_path: []const u8,
    rollout_mtime: i64,
    activated_at_ms: i64,
) !bool {
    const latest_usage = sessions.scanLatestUsableUsageInFile(allocator, rollout_path, rollout_mtime) catch |err| switch (err) {
        error.FileNotFound => return false,
        else => return err,
    };
    if (latest_usage == null) return false;

    var usable = latest_usage.?;
    var snapshot_consumed = false;
    defer {
        allocator.free(usable.path);
        if (!snapshot_consumed) {
            registry.freeRateLimitSnapshot(allocator, &usable.snapshot);
        }
    }

    if (usable.event_timestamp_ms < activated_at_ms) return false;

    const usable_signature: registry.RolloutSignature = .{
        .path = usable.path,
        .event_timestamp_ms = usable.event_timestamp_ms,
    };
    if (registry.rolloutSignaturesEqual(reg.accounts.items[idx].last_local_rollout, usable_signature)) {
        return false;
    }

    registry.updateUsage(allocator, reg, account_key, usable.snapshot);
    snapshot_consumed = true;
    try registry.setAccountLastLocalRollout(allocator, &reg.accounts.items[idx], usable.path, usable.event_timestamp_ms);
    return true;
}

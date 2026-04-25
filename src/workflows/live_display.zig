const std = @import("std");
const cli = @import("../cli/root.zig");
const registry = @import("../registry/root.zig");
const usage_api = @import("../api/usage.zig");
const account_names = @import("account_names.zig");
const preflight = @import("preflight.zig");
const targets = @import("targets.zig");
const usage_refresh = @import("usage.zig");
const live_types = @import("live_types.zig");

const ForegroundUsageRefreshTarget = targets.ForegroundUsageRefreshTarget;
const ForegroundUsageRefreshState = usage_refresh.ForegroundUsageRefreshState;
const SwitchLoadedDisplay = live_types.SwitchLoadedDisplay;
const SwitchLiveRefreshPolicy = live_types.SwitchLiveRefreshPolicy;
const switchLiveRefreshPolicy = live_types.switchLiveRefreshPolicy;
const ensureForegroundNodeAvailableWithApiEnabled = preflight.ensureForegroundNodeAvailableWithApiEnabled;
const refreshForegroundUsageForDisplayWithApiFetchersWithPoolInitUsingApiEnabledAndPersist = usage_refresh.refreshForegroundUsageForDisplayWithApiFetchersWithPoolInitUsingApiEnabledAndPersist;
const initForegroundUsagePool = usage_refresh.initForegroundUsagePool;
const maybeRefreshForegroundAccountNamesWithAccountApiEnabledAndPersist = account_names.maybeRefreshForegroundAccountNamesWithAccountApiEnabledAndPersist;
const defaultAccountFetcher = account_names.defaultAccountFetcher;

pub fn findAccountIndexByAccountKeyConst(reg: *const registry.Registry, account_key: []const u8) ?usize {
    for (reg.accounts.items, 0..) |rec, idx| {
        if (std.mem.eql(u8, rec.account_key, account_key)) return idx;
    }
    return null;
}

pub fn optionalBytesEqual(a: ?[]const u8, b: ?[]const u8) bool {
    if (a == null and b == null) return true;
    if (a == null or b == null) return false;
    return std.mem.eql(u8, a.?, b.?);
}

pub fn switchLiveUsageFieldsEqual(
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

pub fn switchLiveAccountNameEqual(
    maybe_a: ?*const registry.AccountRecord,
    maybe_b: ?*const registry.AccountRecord,
) bool {
    const a_account_name = if (maybe_a) |rec| rec.account_name else null;
    const b_account_name = if (maybe_b) |rec| rec.account_name else null;
    return optionalBytesEqual(a_account_name, b_account_name);
}

pub fn replaceOptionalOwnedString(
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

pub fn applySwitchLiveUsageDeltaToLatest(
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

pub fn applySwitchLiveAccountNameDeltaToLatest(
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

pub fn allocEmptySwitchUsageOverrides(allocator: std.mem.Allocator, len: usize) ![]?[]const u8 {
    const usage_overrides = try allocator.alloc(?[]const u8, len);
    for (usage_overrides) |*usage_override| usage_override.* = null;
    return usage_overrides;
}

pub fn mapSwitchUsageOverridesToLatest(
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

pub fn mergeSwitchLiveRefreshIntoLatest(
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

pub fn takeOwnedSwitchSelectionDisplay(
    allocator: std.mem.Allocator,
    reg: registry.Registry,
    usage_state: *ForegroundUsageRefreshState,
) cli.live.OwnedSwitchSelectionDisplay {
    const usage_overrides = usage_state.usage_overrides;
    allocator.free(usage_state.outcomes);
    usage_state.* = undefined;
    return .{
        .reg = reg,
        .usage_overrides = usage_overrides,
    };
}

pub fn cloneAccountRecord(allocator: std.mem.Allocator, rec: *const registry.AccountRecord) !registry.AccountRecord {
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

pub fn freeOwnedAccountRecord(allocator: std.mem.Allocator, rec: *const registry.AccountRecord) void {
    allocator.free(rec.account_key);
    allocator.free(rec.chatgpt_account_id);
    allocator.free(rec.chatgpt_user_id);
    allocator.free(rec.email);
    allocator.free(rec.alias);
    if (rec.account_name) |value| allocator.free(value);
    if (rec.last_usage) |*snapshot| registry.freeRateLimitSnapshot(allocator, snapshot);
    if (rec.last_local_rollout) |*signature| registry.freeRolloutSignature(allocator, signature);
}

pub fn cloneRegistryAlloc(allocator: std.mem.Allocator, reg: *const registry.Registry) !registry.Registry {
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

pub fn cloneSwitchUsageOverridesAlloc(
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

pub fn cloneSwitchSelectionDisplayAlloc(
    allocator: std.mem.Allocator,
    display: cli.live.SwitchSelectionDisplay,
) !cli.live.OwnedSwitchSelectionDisplay {
    var reg = try cloneRegistryAlloc(allocator, display.reg);
    errdefer reg.deinit(allocator);
    return .{
        .reg = reg,
        .usage_overrides = try cloneSwitchUsageOverridesAlloc(allocator, display.usage_overrides, display.reg.accounts.items.len),
    };
}

pub fn applyPersistedActiveAccountToDisplay(
    allocator: std.mem.Allocator,
    display: *cli.live.OwnedSwitchSelectionDisplay,
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

pub fn accountKeyMatchesAny(account_key: []const u8, selected_account_keys: []const []const u8) bool {
    for (selected_account_keys) |selected_account_key| {
        if (std.mem.eql(u8, account_key, selected_account_key)) return true;
    }
    return false;
}

pub fn buildSwitchLiveActionDisplay(
    allocator: std.mem.Allocator,
    current_display: cli.live.SwitchSelectionDisplay,
    persisted_reg: *const registry.Registry,
) !cli.live.OwnedSwitchSelectionDisplay {
    var updated_display = try cloneSwitchSelectionDisplayAlloc(allocator, current_display);
    errdefer updated_display.deinit(allocator);
    try applyPersistedActiveAccountToDisplay(allocator, &updated_display, persisted_reg);
    return updated_display;
}

pub fn buildRemoveLiveActionDisplay(
    allocator: std.mem.Allocator,
    current_display: cli.live.SwitchSelectionDisplay,
    persisted_reg: *const registry.Registry,
    removed_account_keys: []const []const u8,
) !cli.live.OwnedSwitchSelectionDisplay {
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

    var updated_display: cli.live.OwnedSwitchSelectionDisplay = .{
        .reg = reg,
        .usage_overrides = usage_overrides,
    };
    errdefer updated_display.deinit(allocator);
    try applyPersistedActiveAccountToDisplay(allocator, &updated_display, persisted_reg);
    return updated_display;
}

pub fn loadStoredSwitchSelectionDisplay(
    allocator: std.mem.Allocator,
    codex_home: []const u8,
    target: ForegroundUsageRefreshTarget,
    api_mode: cli.types.ApiMode,
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

pub fn loadStoredSwitchSelectionDisplayWithRefreshError(
    allocator: std.mem.Allocator,
    codex_home: []const u8,
    target: ForegroundUsageRefreshTarget,
    api_mode: cli.types.ApiMode,
    refresh_err: anyerror,
) !SwitchLoadedDisplay {
    var loaded = try loadStoredSwitchSelectionDisplay(allocator, codex_home, target, api_mode);
    errdefer loaded.display.deinit(allocator);
    loaded.refresh_error_name = try allocator.dupe(u8, @errorName(refresh_err));
    return loaded;
}

pub fn loadInitialLiveSelectionDisplay(
    allocator: std.mem.Allocator,
    codex_home: []const u8,
    target: ForegroundUsageRefreshTarget,
    api_mode: cli.types.ApiMode,
) !SwitchLoadedDisplay {
    return loadSwitchSelectionDisplay(
        allocator,
        codex_home,
        api_mode,
        target,
        api_mode == .force_api,
    );
}

pub fn loadSwitchSelectionDisplay(
    allocator: std.mem.Allocator,
    codex_home: []const u8,
    api_mode: cli.types.ApiMode,
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

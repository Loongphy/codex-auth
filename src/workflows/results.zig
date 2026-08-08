const std = @import("std");
const display_rows = @import("../tui/display.zig");
const registry = @import("../registry/root.zig");
const usage_refresh = @import("usage.zig");

pub const UsageSource = enum {
    api,
    local,
    cache,
    none,
};

pub const UsageRefreshMethod = enum {
    api,
    local,
};

pub const UsageRefreshStatus = enum {
    not_requested,
    ok,
    no_data,
    http_error,
    missing_auth,
    error_status,
};

pub const UsageRefreshView = struct {
    requested: bool,
    method: ?UsageRefreshMethod,
    status: UsageRefreshStatus,
    http_status: ?u16 = null,
    error_code: ?[]u8 = null,

    pub fn deinit(self: *UsageRefreshView, allocator: std.mem.Allocator) void {
        if (self.error_code) |error_code| allocator.free(error_code);
        self.* = undefined;
    }
};

pub const CreditsView = struct {
    has_credits: bool,
    unlimited: bool,
    balance: ?[]u8,

    pub fn deinit(self: *CreditsView, allocator: std.mem.Allocator) void {
        if (self.balance) |balance| allocator.free(balance);
        self.* = undefined;
    }
};

pub const UsageView = struct {
    source: UsageSource,
    updated_at: ?i64 = null,
    primary: ?registry.RateLimitWindow = null,
    secondary: ?registry.RateLimitWindow = null,
    credits: ?CreditsView = null,
    reset_credits: ?i64 = null,
    refresh: UsageRefreshView,

    pub fn deinit(self: *UsageView, allocator: std.mem.Allocator) void {
        if (self.credits) |*credits| credits.deinit(allocator);
        self.refresh.deinit(allocator);
        self.* = undefined;
    }
};

pub const AccountView = struct {
    number: usize,
    account_key: []u8,
    email: []u8,
    alias: ?[]u8,
    account_name: ?[]u8,
    plan: ?registry.PlanType,
    auth_mode: ?registry.AuthMode,
    active: bool,
    created_at: i64,
    last_used_at: ?i64,
    usage: UsageView,

    pub fn deinit(self: *AccountView, allocator: std.mem.Allocator) void {
        allocator.free(self.account_key);
        allocator.free(self.email);
        if (self.alias) |alias| allocator.free(alias);
        if (self.account_name) |account_name| allocator.free(account_name);
        self.usage.deinit(allocator);
        self.* = undefined;
    }
};

pub const ListResult = struct {
    active_account_key: ?[]u8,
    accounts: []AccountView,
    warnings: [][]u8,

    pub fn deinit(self: *ListResult, allocator: std.mem.Allocator) void {
        if (self.active_account_key) |account_key| allocator.free(account_key);
        deinitAccountViews(allocator, self.accounts);
        for (self.warnings) |warning| allocator.free(warning);
        allocator.free(self.warnings);
        self.* = undefined;
    }
};

pub const SwitchResult = struct {
    switched_to: AccountView,

    pub fn deinit(self: *SwitchResult, allocator: std.mem.Allocator) void {
        self.switched_to.deinit(allocator);
        self.* = undefined;
    }
};

pub const RemoveResult = struct {
    removed: []AccountView,
    new_active_account_key: ?[]u8,

    pub fn deinit(self: *RemoveResult, allocator: std.mem.Allocator) void {
        deinitAccountViews(allocator, self.removed);
        if (self.new_active_account_key) |account_key| allocator.free(account_key);
        self.* = undefined;
    }
};

pub const SelectorResolutionStatus = enum {
    resolved,
    ambiguous,
    not_found,
};

pub const SelectorResolutionView = struct {
    selector: []u8,
    status: SelectorResolutionStatus,
    account_key: ?[]u8,
    candidates: []AccountView,

    pub fn deinit(self: *SelectorResolutionView, allocator: std.mem.Allocator) void {
        allocator.free(self.selector);
        if (self.account_key) |account_key| allocator.free(account_key);
        deinitAccountViews(allocator, self.candidates);
        self.* = undefined;
    }
};

pub fn deinitSelectorResolutionViews(allocator: std.mem.Allocator, resolutions: []SelectorResolutionView) void {
    for (resolutions) |*resolution| resolution.deinit(allocator);
    allocator.free(resolutions);
}

pub fn deinitAccountViews(allocator: std.mem.Allocator, accounts: []AccountView) void {
    for (accounts) |*account| account.deinit(allocator);
    allocator.free(accounts);
}

pub fn buildListResult(
    allocator: std.mem.Allocator,
    reg: *const registry.Registry,
    usage_state: ?*const usage_refresh.ForegroundUsageRefreshState,
) !ListResult {
    const active_account_key = try dupeOptional(allocator, reg.active_account_key);
    errdefer if (active_account_key) |account_key| allocator.free(account_key);

    const accounts = try buildAccountViewsForIndices(allocator, reg, usage_state, null);
    errdefer deinitAccountViews(allocator, accounts);

    const warnings = try buildUsageWarnings(allocator, reg, usage_state);
    errdefer {
        for (warnings) |warning| allocator.free(warning);
        allocator.free(warnings);
    }

    return .{
        .active_account_key = active_account_key,
        .accounts = accounts,
        .warnings = warnings,
    };
}

pub fn buildSwitchResult(
    allocator: std.mem.Allocator,
    reg: *const registry.Registry,
    account_key: []const u8,
) !SwitchResult {
    var switched_to = try buildAccountViewForKey(allocator, reg, null, account_key);
    errdefer switched_to.deinit(allocator);

    return .{
        .switched_to = switched_to,
    };
}

pub fn buildRemoveResult(
    allocator: std.mem.Allocator,
    reg_before_remove: *const registry.Registry,
    selected: []const usize,
    new_active_account_key: ?[]const u8,
) !RemoveResult {
    const removed = try buildAccountViewsForIndices(allocator, reg_before_remove, null, selected);
    errdefer deinitAccountViews(allocator, removed);

    const new_active = try dupeOptional(allocator, new_active_account_key);
    errdefer if (new_active) |key| allocator.free(key);

    return .{
        .removed = removed,
        .new_active_account_key = new_active,
    };
}

pub fn buildAccountViewsForIndices(
    allocator: std.mem.Allocator,
    reg: *const registry.Registry,
    usage_state: ?*const usage_refresh.ForegroundUsageRefreshState,
    account_indices: ?[]const usize,
) ![]AccountView {
    var display = try display_rows.buildDisplayRows(allocator, reg, null);
    defer display.deinit(allocator);

    var accounts = std.ArrayList(AccountView).empty;
    errdefer {
        for (accounts.items) |*account| account.deinit(allocator);
        accounts.deinit(allocator);
    }

    var number: usize = 0;
    for (display.rows) |row| {
        const account_idx = row.account_index orelse continue;
        number += 1;
        if (!includesIndex(account_indices, account_idx)) continue;

        const outcome = usageOutcomeForIndex(usage_state, account_idx);
        const view = try buildAccountView(allocator, reg, account_idx, number, outcome);
        try accounts.append(allocator, view);
    }

    return try accounts.toOwnedSlice(allocator);
}

fn buildAccountViewForKey(
    allocator: std.mem.Allocator,
    reg: *const registry.Registry,
    usage_state: ?*const usage_refresh.ForegroundUsageRefreshState,
    account_key: []const u8,
) !AccountView {
    const account_idx = registry.findAccountIndexByAccountKey(reg, account_key) orelse return error.AccountNotFound;
    const selected = [_]usize{account_idx};
    const views = try buildAccountViewsForIndices(allocator, reg, usage_state, &selected);
    std.debug.assert(views.len == 1);
    defer allocator.free(views);
    return views[0];
}

fn buildAccountView(
    allocator: std.mem.Allocator,
    reg: *const registry.Registry,
    account_idx: usize,
    number: usize,
    outcome: ?usage_refresh.ForegroundUsageOutcome,
) !AccountView {
    const rec = &reg.accounts.items[account_idx];

    const account_key = try allocator.dupe(u8, rec.account_key);
    errdefer allocator.free(account_key);
    const email = try allocator.dupe(u8, rec.email);
    errdefer allocator.free(email);
    const alias = try dupeOptionalNonEmpty(allocator, rec.alias);
    errdefer if (alias) |value| allocator.free(value);
    const account_name = try dupeOptionalNonEmpty(allocator, rec.account_name orelse "");
    errdefer if (account_name) |value| allocator.free(value);
    var usage = try buildUsageView(allocator, rec, outcome);
    errdefer usage.deinit(allocator);

    return .{
        .number = number,
        .account_key = account_key,
        .email = email,
        .alias = alias,
        .account_name = account_name,
        .plan = registry.resolveDisplayPlan(rec),
        .auth_mode = rec.auth_mode,
        .active = isActive(reg, account_idx),
        .created_at = rec.created_at,
        .last_used_at = rec.last_used_at,
        .usage = usage,
    };
}

fn buildUsageView(
    allocator: std.mem.Allocator,
    rec: *const registry.AccountRecord,
    outcome: ?usage_refresh.ForegroundUsageOutcome,
) !UsageView {
    var refresh = try buildUsageRefreshView(allocator, outcome);
    errdefer refresh.deinit(allocator);

    const snapshot = rec.last_usage orelse return .{
        .source = .none,
        .refresh = refresh,
    };
    const credits = try cloneCreditsView(allocator, snapshot.credits);
    errdefer if (credits) |*value| value.deinit(allocator);

    return .{
        .source = usageSource(outcome),
        .updated_at = rec.last_usage_at,
        .primary = snapshot.primary,
        .secondary = snapshot.secondary,
        .credits = credits,
        .reset_credits = snapshot.reset_credits,
        .refresh = refresh,
    };
}

fn cloneCreditsView(allocator: std.mem.Allocator, credits: ?registry.CreditsSnapshot) !?CreditsView {
    const value = credits orelse return null;

    const balance = try dupeOptional(allocator, value.balance);
    errdefer if (balance) |text| allocator.free(text);

    return .{
        .has_credits = value.has_credits,
        .unlimited = value.unlimited,
        .balance = balance,
    };
}

fn usageSource(outcome: ?usage_refresh.ForegroundUsageOutcome) UsageSource {
    const value = outcome orelse return .cache;
    if (!value.received_snapshot) return .cache;
    return switch (value.method) {
        .api => .api,
        .local => .local,
        .none => .cache,
    };
}

fn buildUsageRefreshView(
    allocator: std.mem.Allocator,
    outcome: ?usage_refresh.ForegroundUsageOutcome,
) !UsageRefreshView {
    const value = outcome orelse return .{
        .requested = false,
        .method = null,
        .status = .not_requested,
    };
    if (!value.attempted) return .{
        .requested = false,
        .method = null,
        .status = .not_requested,
    };

    const method: ?UsageRefreshMethod = switch (value.method) {
        .api => .api,
        .local => .local,
        .none => null,
    };
    if (value.missing_auth) return .{
        .requested = true,
        .method = method,
        .status = .missing_auth,
    };
    if (value.status_code) |status_code| {
        if (status_code != 200) {
            const error_code = if (value.error_code) |code|
                try allocator.dupe(u8, code.text())
            else
                null;
            return .{
                .requested = true,
                .method = method,
                .status = .http_error,
                .http_status = status_code,
                .error_code = error_code,
            };
        }
    }
    if (value.error_name) |error_name| return .{
        .requested = true,
        .method = method,
        .status = .error_status,
        .error_code = try allocator.dupe(u8, error_name),
    };
    return .{
        .requested = true,
        .method = method,
        .status = if (value.received_snapshot) .ok else .no_data,
    };
}

fn buildUsageWarnings(
    allocator: std.mem.Allocator,
    reg: *const registry.Registry,
    usage_state: ?*const usage_refresh.ForegroundUsageRefreshState,
) ![][]u8 {
    const state = usage_state orelse {
        var warnings = std.ArrayList([]u8).empty;
        return try warnings.toOwnedSlice(allocator);
    };

    var warnings = std.ArrayList([]u8).empty;
    errdefer {
        for (warnings.items) |warning| allocator.free(warning);
        warnings.deinit(allocator);
    }

    for (state.outcomes, 0..) |outcome, idx| {
        if (!outcome.attempted) continue;
        if (outcome.error_name == null) continue;
        if (idx >= reg.accounts.items.len) continue;
        try warnings.append(
            allocator,
            try std.fmt.allocPrint(
                allocator,
                "usage refresh failed for {s}: {s}",
                .{ reg.accounts.items[idx].email, outcome.error_name.? },
            ),
        );
    }

    return try warnings.toOwnedSlice(allocator);
}

fn usageOutcomeForIndex(
    usage_state: ?*const usage_refresh.ForegroundUsageRefreshState,
    account_idx: usize,
) ?usage_refresh.ForegroundUsageOutcome {
    const state = usage_state orelse return null;
    if (account_idx >= state.outcomes.len) return null;
    return state.outcomes[account_idx];
}

fn includesIndex(indices: ?[]const usize, account_idx: usize) bool {
    const selected = indices orelse return true;
    for (selected) |idx| {
        if (idx == account_idx) return true;
    }
    return false;
}

fn isActive(reg: *const registry.Registry, account_idx: usize) bool {
    const active_account_key = reg.active_account_key orelse return false;
    return std.mem.eql(u8, active_account_key, reg.accounts.items[account_idx].account_key);
}

fn dupeOptional(allocator: std.mem.Allocator, value: ?[]const u8) !?[]u8 {
    return if (value) |text| try allocator.dupe(u8, text) else null;
}

fn dupeOptionalNonEmpty(allocator: std.mem.Allocator, value: []const u8) !?[]u8 {
    if (value.len == 0) return null;
    return try allocator.dupe(u8, value);
}

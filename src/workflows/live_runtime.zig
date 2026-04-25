const std = @import("std");
const cli = @import("../cli/root.zig");
const display_rows = @import("../tui/display.zig");
const registry = @import("../registry/root.zig");
const active_auth = @import("active_auth.zig");
const targets = @import("targets.zig");
const workflow_env = @import("env.zig");
const live_types = @import("live_types.zig");
const live_display = @import("live_display.zig");

const ForegroundUsageRefreshTarget = targets.ForegroundUsageRefreshTarget;
const SwitchLiveRefreshPolicy = live_types.SwitchLiveRefreshPolicy;
const SwitchLoadedDisplay = live_types.SwitchLoadedDisplay;
const switchLiveRefreshPolicy = live_types.switchLiveRefreshPolicy;
const nowMilliseconds = workflow_env.nowMilliseconds;
const loadSwitchSelectionDisplay = live_display.loadSwitchSelectionDisplay;
const cloneSwitchSelectionDisplayAlloc = live_display.cloneSwitchSelectionDisplayAlloc;
const buildSwitchLiveActionDisplay = live_display.buildSwitchLiveActionDisplay;
const buildRemoveLiveActionDisplay = live_display.buildRemoveLiveActionDisplay;
const trackedActiveAccountKey = active_auth.trackedActiveAccountKey;
const loadCurrentAuthState = active_auth.loadCurrentAuthState;
const selectionContainsAccountKey = active_auth.selectionContainsAccountKey;
const selectionContainsIndex = active_auth.selectionContainsIndex;
const selectBestRemainingAccountKeyByUsageAlloc = active_auth.selectBestRemainingAccountKeyByUsageAlloc;
const reconcileActiveAuthAfterRemove = active_auth.reconcileActiveAuthAfterRemove;

fn freeOwnedStrings(allocator: std.mem.Allocator, items: []const []const u8) void {
    for (items) |item| allocator.free(@constCast(item));
}

pub const SwitchLiveRefreshTaskContext = struct {
    runtime: *SwitchLiveRuntime,
    display_generation: u64,
};

pub const SwitchLiveRuntime = struct {
    allocator: std.mem.Allocator,
    codex_home: []const u8,
    target: ForegroundUsageRefreshTarget,
    api_mode: cli.types.ApiMode,
    strict_refresh: bool,
    io_impl: std.Io.Threaded,
    mutex: std.Io.Mutex = .init,
    refresh_task: ?std.Io.Future(void) = null,
    updated_display: ?cli.live.OwnedSwitchSelectionDisplay = null,
    in_flight: bool = false,
    display_generation: u64 = 0,
    next_refresh_not_before_ms: i64,
    last_refresh_started_at_ms: ?i64 = null,
    last_refresh_finished_at_ms: ?i64 = null,
    last_refresh_duration_ms: ?i64 = null,
    last_refresh_error_name: ?[]u8 = null,
    refresh_interval_ms: i64,
    mode_label: []const u8,

    pub fn init(
        allocator: std.mem.Allocator,
        codex_home: []const u8,
        target: ForegroundUsageRefreshTarget,
        api_mode: cli.types.ApiMode,
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

    pub fn deinit(self: *@This()) void {
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

    fn maybeTakeUpdatedDisplay(self: *@This()) ?cli.live.OwnedSwitchSelectionDisplay {
        const io = self.io_impl.io();
        var future: ?std.Io.Future(void) = null;
        var display: ?cli.live.OwnedSwitchSelectionDisplay = null;

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

    pub fn buildStatusLine(self: *@This(), allocator: std.mem.Allocator, display: cli.live.SwitchSelectionDisplay) ![]u8 {
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

pub fn runSwitchLiveRefreshRound(task_ctx: SwitchLiveRefreshTaskContext) void {
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

pub fn switchLiveRuntimeMaybeStartRefresh(context: *anyopaque) !void {
    const runtime: *SwitchLiveRuntime = @ptrCast(@alignCast(context));
    runtime.maybeStartRefresh();
}

pub fn switchLiveRuntimeMaybeTakeUpdatedDisplay(context: *anyopaque) !?cli.live.OwnedSwitchSelectionDisplay {
    const runtime: *SwitchLiveRuntime = @ptrCast(@alignCast(context));
    return runtime.maybeTakeUpdatedDisplay();
}

pub fn switchLiveRuntimeBuildStatusLine(
    context: *anyopaque,
    allocator: std.mem.Allocator,
    display: cli.live.SwitchSelectionDisplay,
) ![]u8 {
    const runtime: *SwitchLiveRuntime = @ptrCast(@alignCast(context));
    return runtime.buildStatusLine(allocator, display);
}

pub fn accountLabelForKeyAlloc(
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

pub fn buildRemoveSummaryMessageAlloc(allocator: std.mem.Allocator, labels: []const []const u8) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();

    try out.writer.print("Removed {d} account(s): ", .{labels.len});
    for (labels, 0..) |label, idx| {
        if (idx != 0) try out.writer.writeAll(", ");
        try out.writer.writeAll(label);
    }
    return try out.toOwnedSlice();
}

pub fn collectAccountIndicesByKeysAlloc(
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

pub fn removeSelectedAccountsAndPersist(
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

pub fn switchLiveRuntimeApplySelection(
    context: *anyopaque,
    allocator: std.mem.Allocator,
    current_display: cli.live.SwitchSelectionDisplay,
    account_key: []const u8,
) !cli.live.LiveActionOutcome {
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

pub fn removeLiveRuntimeApplySelection(
    context: *anyopaque,
    allocator: std.mem.Allocator,
    current_display: cli.live.SwitchSelectionDisplay,
    account_keys: []const []const u8,
) !cli.live.LiveActionOutcome {
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

    var removed_labels = try cli.output.buildRemoveLabels(allocator, &reg, selected);
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

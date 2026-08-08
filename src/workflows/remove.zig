const std = @import("std");
const app_runtime = @import("../core/runtime.zig");
const cli = @import("../cli/root.zig");
const registry = @import("../registry/root.zig");
const live_flow = @import("live.zig");
const preflight = @import("preflight.zig");
const query_mod = @import("query.zig");
const active_auth = @import("active_auth.zig");
const results = @import("results.zig");

const ensureLiveTty = preflight.ensureLiveTty;
const findMatchingAccountsForRemove = query_mod.findMatchingAccountsForRemove;
const findAccountIndexByDisplayNumber = query_mod.findAccountIndexByDisplayNumber;
const loadCurrentAuthState = active_auth.loadCurrentAuthState;
const selectionContainsAccountKey = active_auth.selectionContainsAccountKey;
const selectionContainsIndex = active_auth.selectionContainsIndex;
const selectBestRemainingAccountKeyByUsageAlloc = active_auth.selectBestRemainingAccountKeyByUsageAlloc;
const reconcileActiveAuthAfterRemove = active_auth.reconcileActiveAuthAfterRemove;
const loadStoredSwitchSelectionDisplay = live_flow.loadStoredSwitchSelectionDisplay;
const loadSwitchSelectionDisplay = live_flow.loadSwitchSelectionDisplay;
const loadInitialLiveSelectionDisplay = live_flow.loadInitialLiveSelectionDisplay;
const SwitchLiveRuntime = live_flow.SwitchLiveRuntime;
const switchLiveRuntimeMaybeStartRefresh = live_flow.switchLiveRuntimeMaybeStartRefresh;
const switchLiveRuntimeMaybeTakeUpdatedDisplay = live_flow.switchLiveRuntimeMaybeTakeUpdatedDisplay;
const switchLiveRuntimeBuildStatusLine = live_flow.switchLiveRuntimeBuildStatusLine;
const removeLiveRuntimeApplySelection = live_flow.removeLiveRuntimeApplySelection;
const removeSelectedAccountsAndPersist = live_flow.removeSelectedAccountsAndPersist;

fn freeOwnedStrings(allocator: std.mem.Allocator, items: []const []const u8) void {
    for (items) |item| allocator.free(@constCast(item));
}

const RemoveSelectorMatch = union(enum) {
    resolved: usize,
    ambiguous: []usize,
    not_found,

    fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
        switch (self.*) {
            .ambiguous => |indices| allocator.free(indices),
            else => {},
        }
        self.* = undefined;
    }
};

const RemoveSelectorResolution = struct {
    selector: []const u8,
    match: RemoveSelectorMatch,

    fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
        self.match.deinit(allocator);
        self.* = undefined;
    }
};

const RemoveResolutionSet = struct {
    resolutions: []RemoveSelectorResolution,
    selected: []usize,

    fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
        for (self.resolutions) |*resolution| resolution.deinit(allocator);
        allocator.free(self.resolutions);
        allocator.free(self.selected);
        self.* = undefined;
    }

    fn hasNotFound(self: *const @This()) bool {
        for (self.resolutions) |resolution| {
            if (resolution.match == .not_found) return true;
        }
        return false;
    }

    fn hasAmbiguous(self: *const @This()) bool {
        for (self.resolutions) |resolution| {
            if (resolution.match == .ambiguous) return true;
        }
        return false;
    }
};

pub fn handleRemove(allocator: std.mem.Allocator, codex_home: []const u8, opts: cli.types.RemoveOptions) !void {
    if (opts.json) return handleRemoveJson(allocator, codex_home, opts);

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
        var initial_display: ?cli.live.OwnedSwitchSelectionDisplay = loaded.display;
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

        const controller: cli.live.RemoveLiveActionController = .{
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
        cli.live.runRemoveLiveActions(live_allocator, transferred_display, controller) catch |err| {
            if (err == error.TuiRequiresTty) {
                try cli.output.printRemoveRequiresTtyError();
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

        const selected = cli.picker.selectAccountsToRemoveWithUsageOverrides(
            allocator,
            &loaded.display.reg,
            loaded.display.usage_overrides,
        ) catch |err| {
            if (err == error.TuiRequiresTty) {
                try cli.output.printRemoveRequiresTtyError();
                return error.RemoveSelectionRequiresTty;
            }
            if (err == error.InvalidRemoveSelectionInput) {
                try cli.output.printInvalidRemoveSelectionError();
                return error.InvalidRemoveSelectionInput;
            }
            return err;
        };
        if (selected == null) return;
        defer allocator.free(selected.?);
        if (selected.?.len == 0) return;

        var removed_labels = try cli.output.buildRemoveLabels(allocator, &loaded.display.reg, selected.?);
        defer {
            freeOwnedStrings(allocator, removed_labels.items);
            removed_labels.deinit(allocator);
        }

        try removeSelectedAccountsAndPersist(allocator, codex_home, &loaded.display.reg, selected.?, opts.all);
        try cli.output.printRemoveSummary(removed_labels.items);
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
        var resolution_set = try resolveRemoveSelectors(allocator, &reg, opts.selectors);
        defer resolution_set.deinit(allocator);
        var missing_selectors = std.ArrayList([]const u8).empty;
        defer missing_selectors.deinit(allocator);
        for (resolution_set.resolutions) |resolution| {
            if (resolution.match == .not_found) try missing_selectors.append(allocator, resolution.selector);
        }

        if (resolution_set.hasNotFound()) {
            try cli.output.printAccountNotFoundErrors(missing_selectors.items);
            return error.AccountNotFound;
        }
        if (resolution_set.selected.len == 0) return;
        if (resolution_set.hasAmbiguous()) {
            var matched_labels = try cli.output.buildRemoveLabels(allocator, &reg, resolution_set.selected);
            defer {
                freeOwnedStrings(allocator, matched_labels.items);
                matched_labels.deinit(allocator);
            }
            if (!(std.Io.File.stdin().isTty(app_runtime.io()) catch false)) {
                try cli.output.printRemoveConfirmationUnavailableError(matched_labels.items);
                return error.RemoveConfirmationUnavailable;
            }
            if (!(try cli.output.confirmRemoveMatches(matched_labels.items))) return;
        }

        selected = try allocator.dupe(usize, resolution_set.selected);
    } else {
        selected = cli.picker.selectAccountsToRemoveWithUsageOverrides(
            allocator,
            &reg,
            null,
        ) catch |err| {
            if (err == error.InvalidRemoveSelectionInput) {
                try cli.output.printInvalidRemoveSelectionError();
                return error.InvalidRemoveSelectionInput;
            }
            if (err == error.TuiRequiresTty) {
                try cli.output.printRemoveRequiresTtyError();
                return error.RemoveSelectionRequiresTty;
            }
            return err;
        };
    }
    if (selected == null) return;
    defer allocator.free(selected.?);
    if (selected.?.len == 0) return;

    var removed_labels = try cli.output.buildRemoveLabels(allocator, &reg, selected.?);
    defer {
        freeOwnedStrings(allocator, removed_labels.items);
        removed_labels.deinit(allocator);
    }

    try removeSelectedAccountsAndPersist(allocator, codex_home, &reg, selected.?, opts.all);
    try cli.output.printRemoveSummary(removed_labels.items);
}

fn handleRemoveJson(allocator: std.mem.Allocator, codex_home: []const u8, opts: cli.types.RemoveOptions) !void {
    var reg = registry.loadRegistry(allocator, codex_home) catch |err| return printJsonWorkflowError(err);
    defer reg.deinit(allocator);

    if (registry.syncActiveAccountFromAuth(allocator, codex_home, &reg) catch |err| return printJsonWorkflowError(err)) {
        registry.saveRegistry(allocator, codex_home, &reg) catch |err| return printJsonWorkflowError(err);
    }

    var selected: []usize = undefined;
    var selected_owned = false;
    defer if (selected_owned) allocator.free(selected);
    if (opts.all) {
        selected = try allocator.alloc(usize, reg.accounts.items.len);
        selected_owned = true;
        for (selected, 0..) |*slot, idx| slot.* = idx;
    } else {
        var resolution_set = resolveRemoveSelectors(allocator, &reg, opts.selectors) catch |err| return printJsonWorkflowError(err);
        defer resolution_set.deinit(allocator);
        if (resolution_set.hasNotFound() or resolution_set.hasAmbiguous()) {
            const resolution_views = buildSelectorResolutionViews(allocator, &reg, resolution_set.resolutions) catch |err| return printJsonWorkflowError(err);
            defer results.deinitSelectorResolutionViews(allocator, resolution_views);
            try cli.json_output.printSelectorResolutionError(resolution_views);
            return error.SelectorResolutionFailed;
        }
        selected = try allocator.dupe(usize, resolution_set.selected);
        selected_owned = true;
    }

    const removed_views = results.buildAccountViewsForIndices(allocator, &reg, null, selected) catch |err| return printJsonWorkflowError(err);
    var removed_views_owned = true;
    defer if (removed_views_owned) results.deinitAccountViews(allocator, removed_views);

    if (selected.len != 0) {
        removeSelectedAccountsAndPersist(allocator, codex_home, &reg, selected, opts.all) catch |err| return printJsonMutationError(err);
    }

    var result: results.RemoveResult = .{
        .removed = removed_views,
        .new_active_account_key = try optionalDupe(allocator, reg.active_account_key),
    };
    removed_views_owned = false;
    defer result.deinit(allocator);

    try cli.json_output.printRemoveResult(&result);
}

fn appendSelectedIndex(
    allocator: std.mem.Allocator,
    selected_list: *std.ArrayList(usize),
    account_idx: usize,
) !void {
    if (!selectionContainsIndex(selected_list.items, account_idx)) {
        try selected_list.append(allocator, account_idx);
    }
}

fn resolveRemoveSelectors(
    allocator: std.mem.Allocator,
    reg: *registry.Registry,
    selectors: []const []const u8,
) !RemoveResolutionSet {
    var resolutions = std.ArrayList(RemoveSelectorResolution).empty;
    errdefer {
        for (resolutions.items) |*resolution| resolution.deinit(allocator);
        resolutions.deinit(allocator);
    }
    var selected = std.ArrayList(usize).empty;
    errdefer selected.deinit(allocator);

    for (selectors) |selector| {
        if (registry.findAccountIndexByAccountKey(reg, selector)) |account_idx| {
            try appendSelectedIndex(allocator, &selected, account_idx);
            try resolutions.append(allocator, .{ .selector = selector, .match = .{ .resolved = account_idx } });
            continue;
        }

        if (try findAccountIndexByDisplayNumber(allocator, reg, selector)) |account_idx| {
            try appendSelectedIndex(allocator, &selected, account_idx);
            try resolutions.append(allocator, .{ .selector = selector, .match = .{ .resolved = account_idx } });
            continue;
        }

        var matches = try findMatchingAccountsForRemove(allocator, reg, selector);
        defer matches.deinit(allocator);
        switch (matches.items.len) {
            0 => try resolutions.append(allocator, .{ .selector = selector, .match = .not_found }),
            1 => {
                const account_idx = matches.items[0];
                try appendSelectedIndex(allocator, &selected, account_idx);
                try resolutions.append(allocator, .{ .selector = selector, .match = .{ .resolved = account_idx } });
            },
            else => {
                const ambiguous = try allocator.dupe(usize, matches.items);
                errdefer allocator.free(ambiguous);
                for (matches.items) |account_idx| try appendSelectedIndex(allocator, &selected, account_idx);
                try resolutions.append(allocator, .{ .selector = selector, .match = .{ .ambiguous = ambiguous } });
            },
        }
    }

    const owned_resolutions = try resolutions.toOwnedSlice(allocator);
    errdefer {
        for (owned_resolutions) |*resolution| resolution.deinit(allocator);
        allocator.free(owned_resolutions);
    }
    const owned_selected = try selected.toOwnedSlice(allocator);
    return .{ .resolutions = owned_resolutions, .selected = owned_selected };
}

fn buildSelectorResolutionViews(
    allocator: std.mem.Allocator,
    reg: *const registry.Registry,
    resolutions: []const RemoveSelectorResolution,
) ![]results.SelectorResolutionView {
    var views = std.ArrayList(results.SelectorResolutionView).empty;
    errdefer {
        for (views.items) |*view| view.deinit(allocator);
        views.deinit(allocator);
    }

    for (resolutions) |resolution| {
        const selector = try allocator.dupe(u8, resolution.selector);
        var selector_owned = true;
        errdefer if (selector_owned) allocator.free(selector);
        var view: results.SelectorResolutionView = switch (resolution.match) {
            .resolved => |account_idx| blk: {
                const candidates = try allocator.alloc(results.AccountView, 0);
                errdefer allocator.free(candidates);
                const account_key = try allocator.dupe(u8, reg.accounts.items[account_idx].account_key);
                break :blk .{
                    .selector = selector,
                    .status = .resolved,
                    .account_key = account_key,
                    .candidates = candidates,
                };
            },
            .ambiguous => |indices| .{
                .selector = selector,
                .status = .ambiguous,
                .account_key = null,
                .candidates = try results.buildAccountViewsForIndices(allocator, reg, null, indices),
            },
            .not_found => .{
                .selector = selector,
                .status = .not_found,
                .account_key = null,
                .candidates = try allocator.alloc(results.AccountView, 0),
            },
        };
        selector_owned = false;
        errdefer view.deinit(allocator);
        try views.append(allocator, view);
    }

    return try views.toOwnedSlice(allocator);
}

fn optionalDupe(allocator: std.mem.Allocator, value: ?[]const u8) !?[]u8 {
    return if (value) |text| try allocator.dupe(u8, text) else null;
}

fn printJsonWorkflowError(err: anyerror) anyerror {
    switch (err) {
        error.OutOfMemory => return err,
        error.CurlRequired => {
            try cli.json_output.printError(
                "curl_unavailable",
                "curl is required for API-backed refresh. Install curl or use --skip-api.",
                null,
            );
            return err;
        },
        else => {
            try cli.json_output.printError("registry_error", @errorName(err), null);
            return error.RegistryError;
        },
    }
}

fn printJsonMutationError(err: anyerror) anyerror {
    if (err == error.OutOfMemory) return err;
    try cli.json_output.printError(
        "state_uncertain",
        "the remove operation could not be completed; stored state may have changed; run `list --json` before retrying",
        null,
    );
    return error.StateUncertain;
}

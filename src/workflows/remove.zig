const std = @import("std");
const app_runtime = @import("../core/runtime.zig");
const cli = @import("../cli/root.zig");
const registry = @import("../registry/root.zig");
const live_flow = @import("live.zig");
const preflight = @import("preflight.zig");
const query_mod = @import("query.zig");
const active_auth = @import("active_auth.zig");

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

pub fn handleRemove(allocator: std.mem.Allocator, codex_home: []const u8, opts: cli.types.RemoveOptions) !void {
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

            var matches = try findMatchingAccountsForRemove(allocator, &reg, selector);
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
            try cli.output.printAccountNotFoundErrors(missing_selectors.items);
            return error.AccountNotFound;
        }
        if (selected_list.items.len == 0) return;
        if (requires_confirmation) {
            var matched_labels = try cli.output.buildRemoveLabels(allocator, &reg, selected_list.items);
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

        selected = try allocator.dupe(usize, selected_list.items);
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

const std = @import("std");
const cli = @import("../cli/root.zig");
const registry = @import("../registry/root.zig");
const live_flow = @import("live.zig");
const preflight = @import("preflight.zig");
const query_mod = @import("query.zig");

const ensureLiveTty = preflight.ensureLiveTty;
const resolveSwitchQueryLocally = query_mod.resolveSwitchQueryLocally;
const loadStoredSwitchSelectionDisplay = live_flow.loadStoredSwitchSelectionDisplay;
const loadSwitchSelectionDisplay = live_flow.loadSwitchSelectionDisplay;
const loadInitialLiveSelectionDisplay = live_flow.loadInitialLiveSelectionDisplay;
const SwitchLiveRuntime = live_flow.SwitchLiveRuntime;
const switchLiveRuntimeMaybeStartRefresh = live_flow.switchLiveRuntimeMaybeStartRefresh;
const switchLiveRuntimeMaybeTakeUpdatedDisplay = live_flow.switchLiveRuntimeMaybeTakeUpdatedDisplay;
const switchLiveRuntimeBuildStatusLine = live_flow.switchLiveRuntimeBuildStatusLine;
const switchLiveRuntimeApplySelection = live_flow.switchLiveRuntimeApplySelection;

pub fn handleSwitch(allocator: std.mem.Allocator, codex_home: []const u8, opts: cli.types.SwitchOptions) !void {
    if (opts.query) |query| {
        var reg = try registry.loadRegistry(allocator, codex_home);
        defer reg.deinit(allocator);
        if (try registry.syncActiveAccountFromAuth(allocator, codex_home, &reg)) {
            try registry.saveRegistry(allocator, codex_home, &reg);
        }
        std.debug.assert(opts.api_mode == .default);
        std.debug.assert(!opts.live);

        var resolution = try resolveSwitchQueryLocally(allocator, &reg, query);
        defer resolution.deinit(allocator);

        const selected_account_key = switch (resolution) {
            .not_found => {
                try cli.output.printSwitchAccountNotFoundError(query);
                return error.AccountNotFound;
            },
            .direct => |account_key| account_key,
            .multiple => |matches| cli.picker.selectAccountFromIndicesWithUsageOverrides(
                allocator,
                &reg,
                matches.items,
                null,
            ) catch |err| {
                if (err == error.TuiRequiresTty) {
                    try cli.output.printSwitchRequiresTtyError();
                    return error.SwitchSelectionRequiresTty;
                }
                return err;
            },
        };
        if (selected_account_key == null) return;
        try registry.activateAccountByKey(allocator, codex_home, &reg, selected_account_key.?);
        try registry.saveRegistry(allocator, codex_home, &reg);
        try cli.output.printSwitchedAccount(allocator, &reg, selected_account_key.?);
        return;
    }

    if (!opts.live) {
        var loaded = if (opts.api_mode == .skip_api)
            try loadStoredSwitchSelectionDisplay(
                allocator,
                codex_home,
                .switch_account,
                opts.api_mode,
            )
        else
            try loadSwitchSelectionDisplay(
                allocator,
                codex_home,
                opts.api_mode,
                .switch_account,
                true,
            );
        defer loaded.display.deinit(allocator);
        defer if (loaded.refresh_error_name) |name| allocator.free(name);

        const selected_account_key = cli.picker.selectAccountWithUsageOverrides(
            allocator,
            &loaded.display.reg,
            loaded.display.usage_overrides,
        ) catch |err| {
            if (err == error.TuiRequiresTty) {
                try cli.output.printSwitchRequiresTtyError();
                return error.SwitchSelectionRequiresTty;
            }
            return err;
        };
        if (selected_account_key == null) return;
        try registry.activateAccountByKey(allocator, codex_home, &loaded.display.reg, selected_account_key.?);
        try registry.saveRegistry(allocator, codex_home, &loaded.display.reg);
        try cli.output.printSwitchedAccount(allocator, &loaded.display.reg, selected_account_key.?);
        return;
    }

    try ensureLiveTty(.switch_account);
    const live_allocator = std.heap.smp_allocator;
    const strict_refresh = opts.api_mode == .force_api;
    const loaded = try loadInitialLiveSelectionDisplay(
        live_allocator,
        codex_home,
        .switch_account,
        opts.api_mode,
    );
    var initial_display: ?cli.live.OwnedSwitchSelectionDisplay = loaded.display;
    errdefer if (initial_display) |*display| display.deinit(live_allocator);

    var runtime = SwitchLiveRuntime.init(
        live_allocator,
        codex_home,
        .switch_account,
        opts.api_mode,
        strict_refresh,
        loaded.policy,
        loaded.refresh_error_name,
    );
    defer runtime.deinit();

    const controller: cli.live.SwitchLiveActionController = .{
        .refresh = .{
            .context = @ptrCast(&runtime),
            .maybe_start_refresh = switchLiveRuntimeMaybeStartRefresh,
            .maybe_take_updated_display = switchLiveRuntimeMaybeTakeUpdatedDisplay,
            .build_status_line = switchLiveRuntimeBuildStatusLine,
        },
        .apply_selection = switchLiveRuntimeApplySelection,
        .auto_switch = true,
    };

    const transferred_display = initial_display.?;
    initial_display = null;
    cli.live.runSwitchLiveActions(live_allocator, transferred_display, controller) catch |err| {
        if (err == error.TuiRequiresTty) {
            try cli.output.printSwitchRequiresTtyError();
            return error.SwitchSelectionRequiresTty;
        }
        return err;
    };
}

const std = @import("std");
const cli = @import("../cli/root.zig");
const format = @import("../tui/table.zig");
const registry = @import("../registry/root.zig");
const account_names = @import("account_names.zig");
const live_flow = @import("live.zig");
const preflight = @import("preflight.zig");
const usage_refresh = @import("usage.zig");
const workflow_env = @import("env.zig");

const isAccountNameRefreshOnlyMode = workflow_env.isAccountNameRefreshOnlyMode;
const runBackgroundAccountNameRefresh = account_names.runBackgroundAccountNameRefresh;
const defaultAccountFetcher = account_names.defaultAccountFetcher;
const maybeRefreshForegroundAccountNamesWithAccountApiEnabled = account_names.maybeRefreshForegroundAccountNamesWithAccountApiEnabled;
const ensureLiveTty = preflight.ensureLiveTty;
const apiModeUsesApi = preflight.apiModeUsesApi;
const ensureForegroundNodeAvailableWithApiEnabled = preflight.ensureForegroundNodeAvailableWithApiEnabled;
const refreshForegroundUsageForDisplayWithBatchFetcherUsingApiEnabled = usage_refresh.refreshForegroundUsageForDisplayWithBatchFetcherUsingApiEnabled;
const loadInitialLiveSelectionDisplay = live_flow.loadInitialLiveSelectionDisplay;
const SwitchLiveRuntime = live_flow.SwitchLiveRuntime;
const switchLiveRuntimeMaybeStartRefresh = live_flow.switchLiveRuntimeMaybeStartRefresh;
const switchLiveRuntimeMaybeTakeUpdatedDisplay = live_flow.switchLiveRuntimeMaybeTakeUpdatedDisplay;
const switchLiveRuntimeBuildStatusLine = live_flow.switchLiveRuntimeBuildStatusLine;

pub fn handleList(allocator: std.mem.Allocator, codex_home: []const u8, opts: cli.types.ListOptions) !void {
    if (isAccountNameRefreshOnlyMode()) return try runBackgroundAccountNameRefresh(allocator, codex_home, defaultAccountFetcher);

    if (opts.live) {
        try ensureLiveTty(.list);
        const live_allocator = std.heap.smp_allocator;
        const loaded = try loadInitialLiveSelectionDisplay(
            live_allocator,
            codex_home,
            .list,
            opts.api_mode,
        );
        var initial_display: ?cli.live.OwnedSwitchSelectionDisplay = loaded.display;
        errdefer if (initial_display) |*display| display.deinit(live_allocator);

        var runtime = SwitchLiveRuntime.init(
            live_allocator,
            codex_home,
            .list,
            opts.api_mode,
            opts.api_mode == .force_api,
            loaded.policy,
            loaded.refresh_error_name,
        );
        defer runtime.deinit();

        const controller: cli.live.SwitchLiveController = .{
            .context = @ptrCast(&runtime),
            .maybe_start_refresh = switchLiveRuntimeMaybeStartRefresh,
            .maybe_take_updated_display = switchLiveRuntimeMaybeTakeUpdatedDisplay,
            .build_status_line = switchLiveRuntimeBuildStatusLine,
        };

        const transferred_display = initial_display.?;
        initial_display = null;
        cli.live.viewAccountsWithLiveUpdates(live_allocator, transferred_display, controller) catch |err| {
            if (err == error.TuiRequiresTty) {
                try cli.output.printListRequiresTtyError();
                return error.ListLiveRequiresTty;
            }
            return err;
        };
        return;
    }

    var reg = try registry.loadRegistry(allocator, codex_home);
    defer reg.deinit(allocator);
    if (try registry.syncActiveAccountFromAuth(allocator, codex_home, &reg)) {
        try registry.saveRegistry(allocator, codex_home, &reg);
    }

    const usage_api_enabled = apiModeUsesApi(reg.api.usage, opts.api_mode);
    const account_api_enabled = apiModeUsesApi(reg.api.account, opts.api_mode);

    try ensureForegroundNodeAvailableWithApiEnabled(
        allocator,
        codex_home,
        &reg,
        .list,
        usage_api_enabled,
        account_api_enabled,
    );

    var usage_state = try refreshForegroundUsageForDisplayWithBatchFetcherUsingApiEnabled(
        allocator,
        codex_home,
        &reg,
        usage_api_enabled,
    );
    defer usage_state.deinit(allocator);
    try maybeRefreshForegroundAccountNamesWithAccountApiEnabled(
        allocator,
        codex_home,
        &reg,
        .list,
        defaultAccountFetcher,
        account_api_enabled,
    );
    try format.printAccountsWithUsageOverrides(&reg, usage_state.usage_overrides);
}

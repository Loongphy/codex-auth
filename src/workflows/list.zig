const std = @import("std");
const cli = @import("../cli/root.zig");
const format = @import("../tui/table.zig");
const registry = @import("../registry/root.zig");
const account_names = @import("account_names.zig");
const live_flow = @import("live.zig");
const preflight = @import("preflight.zig");
const results = @import("results.zig");
const usage_refresh = @import("usage.zig");

const defaultAccountFetcher = account_names.defaultAccountFetcher;
const maybeRefreshForegroundAccountNamesWithAccountApiEnabled = account_names.maybeRefreshForegroundAccountNamesWithAccountApiEnabled;
const ensureLiveTty = preflight.ensureLiveTty;
const apiModeUsesApi = preflight.apiModeUsesApi;
const ensureForegroundCurlAvailableWithApiEnabled = preflight.ensureForegroundCurlAvailableWithApiEnabled;
const refreshForegroundUsageForDisplayWithBatchFetcherUsingApiEnabledAndActiveOnly = usage_refresh.refreshForegroundUsageForDisplayWithBatchFetcherUsingApiEnabledAndActiveOnly;
const loadInitialLiveSelectionDisplay = live_flow.loadInitialLiveSelectionDisplay;
const SwitchLiveRuntime = live_flow.SwitchLiveRuntime;
const switchLiveRuntimeMaybeStartRefresh = live_flow.switchLiveRuntimeMaybeStartRefresh;
const switchLiveRuntimeMaybeTakeUpdatedDisplay = live_flow.switchLiveRuntimeMaybeTakeUpdatedDisplay;
const switchLiveRuntimeBuildStatusLine = live_flow.switchLiveRuntimeBuildStatusLine;

const ListComputation = struct {
    reg: registry.Registry,
    usage_state: usage_refresh.ForegroundUsageRefreshState,

    fn deinit(self: *ListComputation, allocator: std.mem.Allocator) void {
        self.usage_state.deinit(allocator);
        self.reg.deinit(allocator);
        self.* = undefined;
    }
};

pub fn handleList(allocator: std.mem.Allocator, codex_home: []const u8, opts: cli.types.ListOptions) !void {
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

    if (opts.json) {
        var result = computeList(allocator, codex_home, opts) catch |err| return printJsonWorkflowError(err);
        defer result.deinit(allocator);
        for (result.warnings) |warning| std.log.warn("{s}", .{warning});
        try cli.json_output.printListResult(&result);
        return;
    }

    var computed = try computeListState(allocator, codex_home, opts);
    defer computed.deinit(allocator);
    try format.printAccountsWithUsageOverrides(&computed.reg, computed.usage_state.usage_overrides);
}

pub fn computeList(allocator: std.mem.Allocator, codex_home: []const u8, opts: cli.types.ListOptions) !results.ListResult {
    var computed = try computeListState(allocator, codex_home, opts);
    defer computed.deinit(allocator);
    return try results.buildListResult(allocator, &computed.reg, &computed.usage_state);
}

fn computeListState(allocator: std.mem.Allocator, codex_home: []const u8, opts: cli.types.ListOptions) !ListComputation {
    var reg = try registry.loadRegistry(allocator, codex_home);
    errdefer reg.deinit(allocator);
    if (try registry.syncActiveAccountFromAuth(allocator, codex_home, &reg)) {
        try registry.saveRegistry(allocator, codex_home, &reg);
    }

    const usage_api_enabled = apiModeUsesApi(reg.api.usage, opts.api_mode);
    const account_api_enabled = apiModeUsesApi(reg.api.account, opts.api_mode) and !opts.active_only;

    try ensureForegroundCurlAvailableWithApiEnabled(
        allocator,
        codex_home,
        &reg,
        .list,
        usage_api_enabled,
        opts.active_only,
        account_api_enabled,
    );

    var usage_state = try refreshForegroundUsageForDisplayWithBatchFetcherUsingApiEnabledAndActiveOnly(
        allocator,
        codex_home,
        &reg,
        usage_api_enabled,
        opts.active_only,
    );
    errdefer usage_state.deinit(allocator);
    try maybeRefreshForegroundAccountNamesWithAccountApiEnabled(
        allocator,
        codex_home,
        &reg,
        .list,
        defaultAccountFetcher,
        account_api_enabled,
    );
    return .{
        .reg = reg,
        .usage_state = usage_state,
    };
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

const std = @import("std");
const app_runtime = @import("../core/runtime.zig");
const cli = @import("../cli/root.zig");
const registry = @import("../registry/root.zig");
const live_flow = @import("live.zig");
const preflight = @import("preflight.zig");
const query_mod = @import("query.zig");
const results = @import("results.zig");
const daemon = @import("codex_daemon.zig");

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
    switch (opts.target) {
        .query => |query| return handleSwitchQuery(allocator, codex_home, opts, query),
        .previous => return handleSwitchPrevious(allocator, codex_home, opts),
        .picker => {},
    }

    {
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
            try activateSelection(allocator, codex_home, &loaded.display.reg, selected_account_key.?, opts);
            return;
        }

        try ensureLiveTty(.switch_account);
        const live_allocator = app_runtime.fastAllocator();
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
            opts.no_restart_daemon,
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
}

fn handleSwitchQuery(
    allocator: std.mem.Allocator,
    codex_home: []const u8,
    opts: cli.types.SwitchOptions,
    query: []const u8,
) !void {
    if (opts.json) return handleSwitchQueryJson(allocator, codex_home, query, opts);

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
    try activateSelection(allocator, codex_home, &reg, selected_account_key.?, opts);
    return;
}

fn handleSwitchPrevious(
    allocator: std.mem.Allocator,
    codex_home: []const u8,
    opts: cli.types.SwitchOptions,
) !void {
    std.debug.assert(opts.api_mode == .default);
    std.debug.assert(!opts.live);

    var reg = registry.loadRegistry(allocator, codex_home) catch |err| return if (opts.json) printJsonWorkflowError(err) else err;
    defer reg.deinit(allocator);
    if (registry.syncActiveAccountFromAuth(allocator, codex_home, &reg) catch |err| return if (opts.json) printJsonWorkflowError(err) else err) {
        registry.saveRegistry(allocator, codex_home, &reg) catch |err| return if (opts.json) printJsonWorkflowError(err) else err;
    }

    const previous_account_key_value = reg.previous_active_account_key orelse {
        if (opts.json) {
            try cli.json_output.printError("no_previous_account", "no previous account to switch to.", null);
        } else {
            try cli.output.printNoPreviousAccountError();
        }
        return error.NoPreviousAccount;
    };
    const previous_account_key = try allocator.dupe(u8, previous_account_key_value);
    defer allocator.free(previous_account_key);

    if (registry.findAccountIndexByAccountKey(&reg, previous_account_key) == null) {
        if (opts.json) {
            try cli.json_output.printError("account_not_found", "previous account is no longer available.", null);
        } else {
            try cli.output.printPreviousAccountUnavailableError();
        }
        return error.PreviousAccountUnavailable;
    }

    if (reg.active_account_key) |active_account_key| {
        if (std.mem.eql(u8, active_account_key, previous_account_key)) {
            if (opts.json) {
                try cli.json_output.printError("no_previous_account", "no previous account to switch to.", null);
            } else {
                try cli.output.printNoPreviousAccountError();
            }
            return error.NoPreviousAccount;
        }
    }

    try activateSelection(allocator, codex_home, &reg, previous_account_key, opts);
}

fn handleSwitchQueryJson(
    allocator: std.mem.Allocator,
    codex_home: []const u8,
    query: []const u8,
    opts: cli.types.SwitchOptions,
) !void {
    var reg = registry.loadRegistry(allocator, codex_home) catch |err| return printJsonWorkflowError(err);
    defer reg.deinit(allocator);
    if (registry.syncActiveAccountFromAuth(allocator, codex_home, &reg) catch |err| return printJsonWorkflowError(err)) {
        registry.saveRegistry(allocator, codex_home, &reg) catch |err| return printJsonWorkflowError(err);
    }

    var resolution = resolveSwitchQueryLocally(allocator, &reg, query) catch |err| return printJsonWorkflowError(err);
    defer resolution.deinit(allocator);

    const selected_account_key = switch (resolution) {
        .not_found => {
            const message = try allocator.print("no account matches \"{s}\"", .{query});
            defer allocator.free(message);
            try cli.json_output.printError("account_not_found", message, null);
            return error.AccountNotFound;
        },
        .direct => |account_key| account_key,
        .multiple => |matches| {
            const candidates = try results.buildAccountViewsForIndices(allocator, &reg, null, matches.items);
            defer results.deinitAccountViews(allocator, candidates);
            const message = try allocator.print("query \"{s}\" matches multiple accounts", .{query});
            defer allocator.free(message);
            try cli.json_output.printError("ambiguous_query", message, candidates);
            return error.AmbiguousQuery;
        },
    };

    try activateSelection(allocator, codex_home, &reg, selected_account_key, opts);
}

// One-shot picker, query, previous, and JSON routes share this boundary. Live,
// login, import, and remove retain their existing activation behavior.
fn activateSelection(
    allocator: std.mem.Allocator,
    codex_home: []const u8,
    reg: *registry.Registry,
    account_key: []const u8,
    opts: cli.types.SwitchOptions,
) !void {
    registry.activateAccountByKey(allocator, codex_home, reg, account_key) catch |err| {
        return if (opts.json) printJsonMutationError(err) else err;
    };
    registry.saveRegistry(allocator, codex_home, reg) catch |err| {
        return if (opts.json) printJsonMutationError(err) else err;
    };
    if (!opts.json) try cli.output.printSwitchedAccount(allocator, reg, account_key);
    var client = daemon.Client.init(allocator, codex_home) catch |err| {
        if (err == error.OutOfMemory) return err;
        // A missing executable is only absence when the control socket is
        // gone too; a live endpoint with an unlaunchable helper stays
        // unconfirmed, because that daemon may still serve old credentials.
        const outcome: daemon.Outcome = if (err == error.ExecutableRequired)
            (if (try daemon.Client.controlEndpointPresent(codex_home)) .unknown else .not_running)
        else
            .unknown;
        cli.output.printCodexDaemonDiagnostic(codex_home, "codex", outcome) catch {};
        if (!opts.json) return;
        var result = results.buildSwitchResult(allocator, reg, account_key, outcome) catch |build_err| return printJsonWorkflowError(build_err);
        defer result.deinit(allocator);
        try cli.json_output.printSwitchResult(&result);
        return;
    };
    defer client.deinit();
    const outcome = if (opts.no_restart_daemon)
        try client.reload()
    else
        try client.ensure(daemon.restart_timeout_ms);
    // Best-effort stderr: a closed stderr must not skip JSON emission or
    // replace the restart exit contract with a write error.
    cli.output.printCodexDaemonDiagnostic(codex_home, client.executable, outcome) catch {};
    if (opts.json) {
        var result = results.buildSwitchResult(allocator, reg, account_key, outcome) catch |err| return printJsonWorkflowError(err);
        defer result.deinit(allocator);
        try cli.json_output.printSwitchResult(&result);
    }
    if (outcome == .restart_failed or outcome == .timed_out)
        return error.CodexDaemonRestartFailed;
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
        "the switch operation could not be completed; stored state may have changed; run `list --json` before retrying",
        null,
    );
    return error.StateUncertain;
}

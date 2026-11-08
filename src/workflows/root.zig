const std = @import("std");
const app_runtime = @import("../core/runtime.zig");
const transport = @import("../api/transport.zig");
const cli = @import("../cli/root.zig");
const registry = @import("../registry/root.zig");
const account_names = @import("account_names.zig");
const active_auth = @import("active_auth.zig");
const query_mod = @import("query.zig");
const preflight = @import("preflight.zig");
const live_flow = @import("live.zig");
const help_workflow = @import("help.zig");
const clean_workflow = @import("clean.zig");
const completion_workflow = @import("completion.zig");
const config_workflow = @import("config.zig");
const app_workflow = @import("app.zig");
const list_workflow = @import("list.zig");
const login_workflow = @import("login.zig");
const import_workflow = @import("import.zig");
const export_workflow = @import("export.zig");
const switch_workflow = @import("switch.zig");
const remove_workflow = @import("remove.zig");
const reset_workflow = @import("reset.zig");
const alias_workflow = @import("alias.zig");
const workflow_env = @import("env.zig");
const targets = @import("targets.zig");
const usage_refresh = @import("usage.zig");
pub const results = @import("results.zig");
pub const codex_daemon = @import("codex_daemon.zig");

pub const nowMilliseconds = workflow_env.nowMilliseconds;
pub const nowSeconds = workflow_env.nowSeconds;
pub const ForegroundUsageRefreshTarget = targets.ForegroundUsageRefreshTarget;
pub const LiveTtyTarget = targets.LiveTtyTarget;
pub const liveTtyPreflightError = targets.liveTtyPreflightError;
pub const shouldRefreshForegroundUsage = targets.shouldRefreshForegroundUsage;
pub const ForegroundUsageOutcome = usage_refresh.ForegroundUsageOutcome;
pub const ForegroundUsageRefreshState = usage_refresh.ForegroundUsageRefreshState;
pub const formatStatusOverrideAlloc = usage_refresh.formatStatusOverrideAlloc;
pub const refreshForegroundUsageForDisplayWithApiFetcher = usage_refresh.refreshForegroundUsageForDisplayWithApiFetcher;
pub const refreshForegroundUsageForDisplay = usage_refresh.refreshForegroundUsageForDisplay;
pub const refreshForegroundUsageForDisplayWithBatchFetcherUsingApiEnabledAndActiveOnly = usage_refresh.refreshForegroundUsageForDisplayWithBatchFetcherUsingApiEnabledAndActiveOnly;
pub const refreshForegroundUsageForDisplayWithApiFetcherWithPoolInit = usage_refresh.refreshForegroundUsageForDisplayWithApiFetcherWithPoolInit;
pub const refreshForegroundUsageForDisplayWithApiFetchersWithPoolInitUsingApiEnabledAndPersistAndActiveOnly = usage_refresh.refreshForegroundUsageForDisplayWithApiFetchersWithPoolInitUsingApiEnabledAndPersistAndActiveOnly;
pub const initForegroundUsagePool = usage_refresh.initForegroundUsagePool;
pub const maybeRefreshForegroundAccountNames = account_names.maybeRefreshForegroundAccountNames;
pub const refreshAccountNamesAfterLogin = account_names.refreshAccountNamesAfterLogin;
pub const refreshAccountNamesAfterSwitch = account_names.refreshAccountNamesAfterSwitch;
pub const refreshAccountNamesForList = account_names.refreshAccountNamesForList;
pub const refreshAccountNamesAfterImport = account_names.refreshAccountNamesAfterImport;
pub const reconcileActiveAuthAfterRemove = active_auth.reconcileActiveAuthAfterRemove;
pub const resolveSwitchQueryLocally = query_mod.resolveSwitchQueryLocally;
pub const findMatchingAccounts = query_mod.findMatchingAccounts;
pub const isHandledCliError = preflight.isHandledCliError;
pub const shouldPreflightCurlForForegroundTargetWithApiEnabled = preflight.shouldPreflightCurlForForegroundTargetWithApiEnabled;
pub const switch_live_default_refresh_interval_ms = live_flow.switch_live_default_refresh_interval_ms;
pub const SwitchLiveRefreshPolicy = live_flow.SwitchLiveRefreshPolicy;
pub const SwitchLiveRuntime = live_flow.SwitchLiveRuntime;
pub const findAccountIndexByAccountKeyConst = live_flow.findAccountIndexByAccountKeyConst;
pub const replaceOptionalOwnedString = live_flow.replaceOptionalOwnedString;
pub const mapSwitchUsageOverridesToLatest = live_flow.mapSwitchUsageOverridesToLatest;
pub const mergeSwitchLiveRefreshIntoLatest = live_flow.mergeSwitchLiveRefreshIntoLatest;
pub const buildSwitchLiveActionDisplay = live_flow.buildSwitchLiveActionDisplay;
pub const buildRemoveLiveActionDisplay = live_flow.buildRemoveLiveActionDisplay;
pub const loadStoredSwitchSelectionDisplay = live_flow.loadStoredSwitchSelectionDisplay;
pub const loadStoredSwitchSelectionDisplayWithRefreshError = live_flow.loadStoredSwitchSelectionDisplayWithRefreshError;
pub const loadInitialLiveSelectionDisplay = live_flow.loadInitialLiveSelectionDisplay;
pub const switchLiveRuntimeApplySelection = live_flow.switchLiveRuntimeApplySelection;
pub const removeLiveRuntimeApplySelection = live_flow.removeLiveRuntimeApplySelection;

pub fn main(init: std.process.Init) !u8 {
    app_runtime.initRuntime(init);
    defer app_runtime.deinitRuntime();
    runMain(init) catch |err| {
        if (err == error.InvalidCliUsage) return 2;
        if (isHandledCliError(err)) return 1;
        return err;
    };
    return 0;
}

fn runMain(init: std.process.Init) !void {
    const allocator = init.gpa;
    const args = try init.minimal.args.toSlice(init.arena.allocator());

    var parsed = try cli.commands.parseArgs(allocator, args);
    defer cli.commands.freeParseResult(allocator, &parsed);

    const cmd = switch (parsed) {
        .command => |command| command,
        .usage_error => |usage_err| {
            if (usage_err.json) {
                try cli.json_output.printUsageError(usage_err.message);
            } else {
                try cli.output.printUsageError(&usage_err);
            }
            return error.InvalidCliUsage;
        },
    };

    const needs_codex_home = switch (cmd) {
        .version => false,
        .help => false,
        .completion => false,
        .complete_request => false,
        else => true,
    };
    const json_requested = commandWantsJson(&cmd);
    const codex_home = if (needs_codex_home)
        registry.resolveCodexHome(allocator) catch |err| return printJsonStartupError(err, json_requested)
    else if (cmd == .complete_request)
        registry.resolveCodexHome(allocator) catch null
    else
        null;
    defer if (codex_home) |path| allocator.free(path);

    switch (cmd) {
        .version => try cli.output.printVersion(),
        .help => |topic| switch (topic) {
            .top_level => try help_workflow.handleTopLevelHelp(),
            else => try cli.help.printCommandHelp(topic),
        },
        .config => |opts| try config_workflow.handleConfig(allocator, codex_home.?, opts),
        .app => |opts| try app_workflow.handleApp(allocator, codex_home.?, opts),
        .list => |opts| try list_workflow.handleList(allocator, transport.Transport.curl(), codex_home.?, opts),
        .login => |opts| try login_workflow.handleLogin(allocator, codex_home.?, opts),
        .import_auth => |opts| try import_workflow.handleImport(allocator, codex_home.?, opts),
        .export_auth => |opts| try export_workflow.handleExport(allocator, codex_home.?, opts),
        .switch_account => |opts| try switch_workflow.handleSwitch(allocator, codex_home.?, opts),
        .remove_account => |opts| try remove_workflow.handleRemove(allocator, codex_home.?, opts),
        .reset_credits => |opts| try reset_workflow.handleReset(allocator, transport.Transport.curl(), codex_home.?, opts),
        .alias => |opts| try alias_workflow.handleAlias(allocator, codex_home.?, opts),
        .clean => |opts| try clean_workflow.handleClean(allocator, codex_home.?, opts),
        .completion => |opts| try completion_workflow.handleCompletion(opts),
        .complete_request => |opts| try completion_workflow.handleCompleteRequest(allocator, codex_home, opts),
    }
}

fn commandWantsJson(cmd: *const cli.types.Command) bool {
    return switch (cmd.*) {
        .list => |opts| opts.json,
        .switch_account => |opts| opts.json,
        .remove_account => |opts| opts.json,
        else => false,
    };
}

fn printJsonStartupError(err: anyerror, json_requested: bool) anyerror {
    if (!json_requested or err == error.OutOfMemory) return err;
    try cli.json_output.printError("registry_error", @errorName(err), null);
    return error.RegistryError;
}

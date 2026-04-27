const std = @import("std");
const app_runtime = @import("../core/runtime.zig");
const account_api = @import("../api/account.zig");
const account_name_refresh = @import("../auth/account.zig");
const cli = @import("../cli/root.zig");
const chatgpt_http = @import("../api/http.zig");
const display_rows = @import("../tui/display.zig");
const registry = @import("../registry/root.zig");
const auth = @import("../auth/auth.zig");
const auto = @import("../auto/root.zig");
const format = @import("../tui/table.zig");
const usage_api = @import("../api/usage.zig");
const account_names = @import("account_names.zig");
const active_auth = @import("active_auth.zig");
const query_mod = @import("query.zig");
const preflight = @import("preflight.zig");
const live_flow = @import("live.zig");
const help_workflow = @import("help.zig");
const clean_workflow = @import("clean.zig");
const config_workflow = @import("config.zig");
const list_workflow = @import("list.zig");
const login_workflow = @import("login.zig");
const import_workflow = @import("import.zig");
const switch_workflow = @import("switch.zig");
const remove_workflow = @import("remove.zig");
const workflow_env = @import("env.zig");
const targets = @import("targets.zig");
const usage_refresh = @import("usage.zig");

const isAccountNameRefreshOnlyMode = workflow_env.isAccountNameRefreshOnlyMode;
pub const nowMilliseconds = workflow_env.nowMilliseconds;
pub const nowSeconds = workflow_env.nowSeconds;
pub const ForegroundUsageRefreshTarget = targets.ForegroundUsageRefreshTarget;
pub const LiveTtyTarget = targets.LiveTtyTarget;
pub const liveTtyPreflightError = targets.liveTtyPreflightError;
pub const shouldRefreshForegroundUsage = targets.shouldRefreshForegroundUsage;
pub const ForegroundUsageOutcome = usage_refresh.ForegroundUsageOutcome;
pub const ForegroundUsageRefreshState = usage_refresh.ForegroundUsageRefreshState;
pub const max_usage_override_display_width = usage_refresh.max_usage_override_display_width;
pub const formatStatusOverrideAlloc = usage_refresh.formatStatusOverrideAlloc;
pub const refreshForegroundUsageForDisplayWithApiFetcher = usage_refresh.refreshForegroundUsageForDisplayWithApiFetcher;
pub const refreshForegroundUsageForDisplay = usage_refresh.refreshForegroundUsageForDisplay;
pub const refreshForegroundUsageForDisplayWithApiFetcherWithPoolInit = usage_refresh.refreshForegroundUsageForDisplayWithApiFetcherWithPoolInit;
const refreshForegroundUsageForDisplayWithBatchFetcherUsingApiEnabled = usage_refresh.refreshForegroundUsageForDisplayWithBatchFetcherUsingApiEnabled;
const refreshForegroundUsageForDisplayWithApiFetchersWithPoolInitUsingApiEnabledAndPersist = usage_refresh.refreshForegroundUsageForDisplayWithApiFetchersWithPoolInitUsingApiEnabledAndPersist;
pub const initForegroundUsagePool = usage_refresh.initForegroundUsagePool;
pub const maybeRefreshForegroundAccountNames = account_names.maybeRefreshForegroundAccountNames;
const maybeRefreshForegroundAccountNamesWithAccountApiEnabled = account_names.maybeRefreshForegroundAccountNamesWithAccountApiEnabled;
const maybeRefreshForegroundAccountNamesWithAccountApiEnabledAndPersist = account_names.maybeRefreshForegroundAccountNamesWithAccountApiEnabledAndPersist;
const defaultAccountFetcher = account_names.defaultAccountFetcher;
const loadActiveAuthInfoForAccountRefresh = account_names.loadActiveAuthInfoForAccountRefresh;
pub const refreshAccountNamesAfterLogin = account_names.refreshAccountNamesAfterLogin;
pub const refreshAccountNamesAfterSwitch = account_names.refreshAccountNamesAfterSwitch;
pub const refreshAccountNamesForList = account_names.refreshAccountNamesForList;
const shouldRefreshTeamAccountNamesForUserScopeWithAccountApiEnabled = account_names.shouldRefreshTeamAccountNamesForUserScopeWithAccountApiEnabled;
pub const shouldScheduleBackgroundAccountNameRefresh = account_names.shouldScheduleBackgroundAccountNameRefresh;
pub const runBackgroundAccountNameRefresh = account_names.runBackgroundAccountNameRefresh;
pub const runBackgroundAccountNameRefreshWithLockAcquirer = account_names.runBackgroundAccountNameRefreshWithLockAcquirer;
const maybeSpawnBackgroundAccountNameRefresh = account_names.maybeSpawnBackgroundAccountNameRefresh;
pub const refreshAccountNamesAfterImport = account_names.refreshAccountNamesAfterImport;
const loadSingleFileImportAuthInfo = account_names.loadSingleFileImportAuthInfo;
pub const reconcileActiveAuthAfterRemove = active_auth.reconcileActiveAuthAfterRemove;
const trackedActiveAccountKey = active_auth.trackedActiveAccountKey;
const loadCurrentAuthState = active_auth.loadCurrentAuthState;
const selectionContainsAccountKey = active_auth.selectionContainsAccountKey;
const selectionContainsIndex = active_auth.selectionContainsIndex;
const selectBestRemainingAccountKeyByUsageAlloc = active_auth.selectBestRemainingAccountKeyByUsageAlloc;
pub const resolveSwitchQueryLocally = query_mod.resolveSwitchQueryLocally;
pub const findMatchingAccounts = query_mod.findMatchingAccounts;
const findMatchingAccountsForRemove = query_mod.findMatchingAccountsForRemove;
const findAccountIndexByDisplayNumber = query_mod.findAccountIndexByDisplayNumber;
pub const isHandledCliError = preflight.isHandledCliError;
pub const shouldReconcileManagedService = preflight.shouldReconcileManagedService;
const ensureLiveTty = preflight.ensureLiveTty;
const apiModeUsesApi = preflight.apiModeUsesApi;
const ensureForegroundNodeAvailableWithApiEnabled = preflight.ensureForegroundNodeAvailableWithApiEnabled;
pub const switch_live_default_refresh_interval_ms = live_flow.switch_live_default_refresh_interval_ms;
pub const SwitchLiveRefreshPolicy = live_flow.SwitchLiveRefreshPolicy;
pub const SwitchLiveRuntime = live_flow.SwitchLiveRuntime;
const switchLiveRuntimeMaybeStartRefresh = live_flow.switchLiveRuntimeMaybeStartRefresh;
const switchLiveRuntimeMaybeTakeUpdatedDisplay = live_flow.switchLiveRuntimeMaybeTakeUpdatedDisplay;
const switchLiveRuntimeBuildStatusLine = live_flow.switchLiveRuntimeBuildStatusLine;
pub const findAccountIndexByAccountKeyConst = live_flow.findAccountIndexByAccountKeyConst;
pub const replaceOptionalOwnedString = live_flow.replaceOptionalOwnedString;
pub const mapSwitchUsageOverridesToLatest = live_flow.mapSwitchUsageOverridesToLatest;
pub const mergeSwitchLiveRefreshIntoLatest = live_flow.mergeSwitchLiveRefreshIntoLatest;
pub const buildSwitchLiveActionDisplay = live_flow.buildSwitchLiveActionDisplay;
pub const buildRemoveLiveActionDisplay = live_flow.buildRemoveLiveActionDisplay;
pub const loadStoredSwitchSelectionDisplay = live_flow.loadStoredSwitchSelectionDisplay;
pub const loadStoredSwitchSelectionDisplayWithRefreshError = live_flow.loadStoredSwitchSelectionDisplayWithRefreshError;
pub const loadInitialLiveSelectionDisplay = live_flow.loadInitialLiveSelectionDisplay;
const loadSwitchSelectionDisplay = live_flow.loadSwitchSelectionDisplay;
const removeSelectedAccountsAndPersist = live_flow.removeSelectedAccountsAndPersist;
pub const switchLiveRuntimeApplySelection = live_flow.switchLiveRuntimeApplySelection;
pub const removeLiveRuntimeApplySelection = live_flow.removeLiveRuntimeApplySelection;
pub const HelpConfig = help_workflow.HelpConfig;
pub const loadHelpConfig = help_workflow.loadHelpConfig;

pub fn main(init: std.process.Init.Minimal) !void {
    var exit_code: u8 = 0;
    runMain(init) catch |err| {
        if (err == error.InvalidCliUsage) {
            exit_code = 2;
        } else if (isHandledCliError(err)) {
            exit_code = 1;
        } else {
            return err;
        }
    };
    if (exit_code != 0) std.process.exit(exit_code);
}

fn runMain(init: std.process.Init.Minimal) !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer std.debug.assert(gpa.deinit() == .ok);
    const allocator = gpa.allocator();

    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const args = try init.args.toSlice(arena_state.allocator());

    var parsed = try cli.commands.parseArgs(allocator, args);
    defer cli.commands.freeParseResult(allocator, &parsed);

    const cmd = switch (parsed) {
        .command => |command| command,
        .usage_error => |usage_err| {
            try cli.output.printUsageError(&usage_err);
            return error.InvalidCliUsage;
        },
    };

    const needs_codex_home = switch (cmd) {
        .version => false,
        .help => |topic| topic == .top_level,
        else => true,
    };
    const codex_home = if (needs_codex_home) try registry.resolveCodexHome(allocator) else null;
    defer if (codex_home) |path| allocator.free(path);

    switch (cmd) {
        .version => try cli.output.printVersion(),
        .help => |topic| switch (topic) {
            .top_level => try help_workflow.handleTopLevelHelp(allocator, codex_home.?),
            else => try cli.help.printCommandHelp(topic),
        },
        .status => try auto.printStatus(allocator, codex_home.?),
        .daemon => |opts| switch (opts.mode) {
            .watch => try auto.runDaemon(allocator, codex_home.?),
            .once => try auto.runDaemonOnce(allocator, codex_home.?),
        },
        .config => |opts| try config_workflow.handleConfig(allocator, codex_home.?, opts),
        .list => |opts| try list_workflow.handleList(allocator, codex_home.?, opts),
        .login => |opts| try login_workflow.handleLogin(allocator, codex_home.?, opts),
        .import_auth => |opts| try import_workflow.handleImport(allocator, codex_home.?, opts),
        .switch_account => |opts| try switch_workflow.handleSwitch(allocator, codex_home.?, opts),
        .remove_account => |opts| try remove_workflow.handleRemove(allocator, codex_home.?, opts),
        .clean => try clean_workflow.handleClean(allocator, codex_home.?),
    }

    if (shouldReconcileManagedService(cmd)) {
        try auto.reconcileManagedService(allocator, codex_home.?);
    }
}

fn freeOwnedStrings(allocator: std.mem.Allocator, items: []const []const u8) void {
    for (items) |item| allocator.free(@constCast(item));
}

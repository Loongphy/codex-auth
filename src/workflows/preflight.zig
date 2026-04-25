const std = @import("std");
const app_runtime = @import("../core/runtime.zig");
const chatgpt_http = @import("../api/http.zig");
const cli = @import("../cli/root.zig");
const registry = @import("../registry/root.zig");
const account_names = @import("account_names.zig");
const targets = @import("targets.zig");
const workflow_env = @import("env.zig");

const skip_service_reconcile_env = workflow_env.skip_service_reconcile_env;
const hasNonEmptyEnvVar = workflow_env.hasNonEmptyEnvVar;
const ForegroundUsageRefreshTarget = targets.ForegroundUsageRefreshTarget;
const LiveTtyTarget = targets.LiveTtyTarget;
const liveTtyPreflightError = targets.liveTtyPreflightError;
const shouldRefreshForegroundUsage = targets.shouldRefreshForegroundUsage;
const shouldRefreshTeamAccountNamesForUserScopeWithAccountApiEnabled = account_names.shouldRefreshTeamAccountNamesForUserScopeWithAccountApiEnabled;
const loadActiveAuthInfoForAccountRefresh = account_names.loadActiveAuthInfoForAccountRefresh;

pub fn isHandledCliError(err: anyerror) bool {
    return err == error.AccountNotFound or
        err == error.CodexLoginFailed or
        err == error.ListLiveRequiresTty or
        err == error.TuiOutputUnavailable or
        err == error.NodeJsRequired or
        err == error.SwitchSelectionRequiresTty or
        err == error.RemoveConfirmationUnavailable or
        err == error.RemoveSelectionRequiresTty or
        err == error.InvalidRemoveSelectionInput;
}

pub fn shouldReconcileManagedService(cmd: cli.types.Command) bool {
    if (hasNonEmptyEnvVar(skip_service_reconcile_env)) return false;
    return switch (cmd) {
        .help, .version, .status, .daemon => false,
        else => true,
    };
}

pub fn ensureLiveTty(target: LiveTtyTarget) !void {
    const err = liveTtyPreflightError(
        target,
        std.Io.File.stdin().isTty(app_runtime.io()) catch false,
        std.Io.File.stdout().isTty(app_runtime.io()) catch false,
    ) orelse return;

    switch (target) {
        .list => try cli.output.printListRequiresTtyError(),
        .switch_account => try cli.output.printSwitchRequiresTtyError(),
        .remove_account => try cli.output.printRemoveRequiresTtyError(),
    }
    return err;
}

pub fn apiModeUsesApi(default_enabled: bool, api_mode: cli.types.ApiMode) bool {
    return switch (api_mode) {
        .default => default_enabled,
        .force_api => true,
        .skip_api => false,
    };
}

pub fn shouldPreflightNodeForForegroundTargetWithApiEnabled(
    allocator: std.mem.Allocator,
    codex_home: []const u8,
    reg: *registry.Registry,
    target: ForegroundUsageRefreshTarget,
    usage_api_enabled: bool,
    account_api_enabled: bool,
) !bool {
    if (shouldRefreshForegroundUsage(target) and usage_api_enabled and reg.accounts.items.len != 0) {
        return true;
    }

    const active_user_id = registry.activeChatgptUserId(reg) orelse return false;
    if (!shouldRefreshTeamAccountNamesForUserScopeWithAccountApiEnabled(reg, active_user_id, account_api_enabled)) {
        return false;
    }

    var info = (try loadActiveAuthInfoForAccountRefresh(allocator, codex_home)) orelse return false;
    defer info.deinit(allocator);
    return info.access_token != null and info.chatgpt_account_id != null;
}

pub fn ensureForegroundNodeAvailableWithApiEnabled(
    allocator: std.mem.Allocator,
    codex_home: []const u8,
    reg: *registry.Registry,
    target: ForegroundUsageRefreshTarget,
    usage_api_enabled: bool,
    account_api_enabled: bool,
) !void {
    if (!try shouldPreflightNodeForForegroundTargetWithApiEnabled(
        allocator,
        codex_home,
        reg,
        target,
        usage_api_enabled,
        account_api_enabled,
    )) return;

    try chatgpt_http.ensureNodeExecutableAvailable(allocator);
}

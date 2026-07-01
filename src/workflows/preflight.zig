const std = @import("std");
const app_runtime = @import("../core/runtime.zig");
const chatgpt_http = @import("../api/http.zig");
const cli = @import("../cli/root.zig");
const registry = @import("../registry/root.zig");
const account_names = @import("account_names.zig");
const targets = @import("targets.zig");
const usage_refresh = @import("usage.zig");

const ForegroundUsageRefreshTarget = targets.ForegroundUsageRefreshTarget;
const LiveTtyTarget = targets.LiveTtyTarget;
const liveTtyPreflightError = targets.liveTtyPreflightError;
const shouldRefreshForegroundUsage = targets.shouldRefreshForegroundUsage;
const shouldRefreshTeamAccountNamesForUserScopeWithAccountApiEnabled = account_names.shouldRefreshTeamAccountNamesForUserScopeWithAccountApiEnabled;
const loadActiveAuthInfoForAccountRefresh = account_names.loadActiveAuthInfoForAccountRefresh;

pub fn isHandledCliError(err: anyerror) bool {
    return err == error.AccountNotFound or
        err == error.NoPreviousAccount or
        err == error.PreviousAccountUnavailable or
        err == error.CodexLoginFailed or
        err == error.ListLiveRequiresTty or
        err == error.TuiOutputUnavailable or
        err == error.CurlRequired or
        err == error.SwitchSelectionRequiresTty or
        err == error.AliasSelectionRequiresTty or
        err == error.InvalidAlias or
        err == error.DuplicateAlias or
        err == error.RemoveConfirmationUnavailable or
        err == error.RemoveSelectionRequiresTty or
        err == error.InvalidRemoveSelectionInput or
        err == error.ImportFailed or
        err == error.AppLaunchConfigValidationFailed or
        err == error.AppIdRequired or
        err == error.AppIdNotFound or
        err == error.AppExecutableNotFound or
        err == error.CodexCliPathNotFound or
        err == error.CodexCliPathNotAccessible or
        err == error.CodexCliPathNotFile or
        err == error.AppLaunchFailed or
        err == error.PowerShellNotFound or
        err == error.UnsupportedRegistryVersion or
        err == error.WindowsAppLaunchRequiresWindows or
        err == error.WindowsAppPlatformRequiresWindows or
        err == error.MacAppPlatformRequiresMacOS or
        err == error.WindowsPassthroughArgsUnsupported;
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

pub fn shouldPreflightCurlForForegroundTargetWithApiEnabled(
    allocator: std.mem.Allocator,
    codex_home: []const u8,
    reg: *registry.Registry,
    target: ForegroundUsageRefreshTarget,
    usage_api_enabled: bool,
    active_only: bool,
    account_api_enabled: bool,
) !bool {
    if (shouldRefreshForegroundUsage(target) and usage_api_enabled and hasRefreshableChatGptUsageAccount(reg, active_only)) {
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

pub fn ensureForegroundCurlAvailableWithApiEnabled(
    allocator: std.mem.Allocator,
    codex_home: []const u8,
    reg: *registry.Registry,
    target: ForegroundUsageRefreshTarget,
    usage_api_enabled: bool,
    active_only: bool,
    account_api_enabled: bool,
) !void {
    if (!try shouldPreflightCurlForForegroundTargetWithApiEnabled(
        allocator,
        codex_home,
        reg,
        target,
        usage_api_enabled,
        active_only,
        account_api_enabled,
    )) return;

    try chatgpt_http.ensureCurlExecutableAvailable(allocator);
}

fn hasRefreshableChatGptUsageAccount(reg: *registry.Registry, active_only: bool) bool {
    if (active_only) {
        const active_account_key = reg.active_account_key orelse return false;
        const idx = registry.findAccountIndexByAccountKey(reg, active_account_key) orelse return false;
        return usage_refresh.shouldRefreshChatGptUsageForAccount(&reg.accounts.items[idx]);
    }

    for (reg.accounts.items) |*account| {
        if (usage_refresh.shouldRefreshChatGptUsageForAccount(account)) return true;
    }
    return false;
}

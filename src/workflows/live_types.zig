const cli = @import("../cli/root.zig");
const registry = @import("../registry/root.zig");
const preflight = @import("preflight.zig");
const targets = @import("targets.zig");

const ForegroundUsageRefreshTarget = targets.ForegroundUsageRefreshTarget;
const apiModeUsesApi = preflight.apiModeUsesApi;

pub const switch_live_api_refresh_interval_ms: i64 = 30_000;
pub const switch_live_local_refresh_interval_ms: i64 = 10_000;

pub const SwitchLiveRefreshPolicy = struct {
    usage_api_enabled: bool,
    account_api_enabled: bool,
    interval_ms: i64,
    label: []const u8,
};

pub const SwitchLoadedDisplay = struct {
    display: cli.live.OwnedSwitchSelectionDisplay,
    policy: SwitchLiveRefreshPolicy,
    refresh_error_name: ?[]u8 = null,
};

pub fn switchLiveRefreshPolicy(
    reg: *const registry.Registry,
    _: ForegroundUsageRefreshTarget,
    api_mode: cli.types.ApiMode,
) SwitchLiveRefreshPolicy {
    const usage_api_enabled = apiModeUsesApi(reg.api.usage, api_mode);
    const account_api_enabled = apiModeUsesApi(reg.api.account, api_mode);
    if (usage_api_enabled or account_api_enabled) {
        return .{
            .usage_api_enabled = usage_api_enabled,
            .account_api_enabled = account_api_enabled,
            .interval_ms = switch_live_api_refresh_interval_ms,
            .label = "api",
        };
    }

    return .{
        .usage_api_enabled = false,
        .account_api_enabled = false,
        .interval_ms = switch_live_local_refresh_interval_ms,
        .label = "local",
    };
}

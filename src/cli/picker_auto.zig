const std = @import("std");
const app_runtime = @import("../core/runtime.zig");
const registry = @import("../registry/root.zig");
const selection = @import("selection.zig");
const row_data = @import("rows.zig");
const nav = @import("picker_nav.zig");

const SwitchSelectionDisplay = selection.SwitchSelectionDisplay;
const SwitchRows = row_data.SwitchRows;
const resolveRateWindow = row_data.resolveRateWindow;
const usageOverrideForAccount = row_data.usageOverrideForAccount;
const accountKeyForSelectableAlloc = nav.accountKeyForSelectableAlloc;

fn numericUsageOverrideStatus(usage_override: ?[]const u8) ?u16 {
    const value = usage_override orelse return null;
    return std.fmt.parseInt(u16, value, 10) catch null;
}

fn accountCrossesSwitchThreshold(reg: *const registry.Registry, rec: *const registry.AccountRecord, now: i64) bool {
    const rate_5h = resolveRateWindow(rec.last_usage, 300, true);
    const rate_week = resolveRateWindow(rec.last_usage, 10080, false);
    const rem_5h = registry.remainingPercentAt(rate_5h, now);
    const rem_week = registry.remainingPercentAt(rate_week, now);
    return (rem_5h != null and rem_5h.? <= @as(i64, reg.auto_switch.threshold_5h_percent)) or
        (rem_week != null and rem_week.? <= @as(i64, reg.auto_switch.threshold_weekly_percent));
}

fn shouldAutoSwitchActiveAccount(display: SwitchSelectionDisplay, now: i64) bool {
    const active_account_key = display.reg.active_account_key orelse return false;
    const active_idx = registry.findAccountIndexByAccountKey(display.reg, active_account_key) orelse return false;

    if (numericUsageOverrideStatus(usageOverrideForAccount(display.usage_overrides, active_idx))) |status_code| {
        return status_code != 200;
    }

    return accountCrossesSwitchThreshold(display.reg, &display.reg.accounts.items[active_idx], now);
}

fn resetDistanceSeconds(window: ?registry.RateLimitWindow, now: i64) i64 {
    const resets_at = if (window) |value| value.resets_at orelse return std.math.maxInt(i64) else return std.math.maxInt(i64);
    return @max(resets_at - now, 0);
}

fn resetDistanceForMinutes(usage: ?registry.RateLimitSnapshot, minutes: i64, fallback_primary: bool, now: i64) i64 {
    return resetDistanceSeconds(resolveRateWindow(usage, minutes, fallback_primary), now);
}

fn autoSwitchCandidateIsBetter(candidate: *const registry.AccountRecord, best: *const registry.AccountRecord, now: i64) bool {
    const candidate_5h_reset = resetDistanceForMinutes(candidate.last_usage, 300, true, now);
    const best_5h_reset = resetDistanceForMinutes(best.last_usage, 300, true, now);
    if (candidate_5h_reset != best_5h_reset) return candidate_5h_reset < best_5h_reset;

    const candidate_weekly_reset = resetDistanceForMinutes(candidate.last_usage, 10080, false, now);
    const best_weekly_reset = resetDistanceForMinutes(best.last_usage, 10080, false, now);
    return candidate_weekly_reset < best_weekly_reset;
}

fn bestAutoSwitchCandidateSelectableIndex(
    rows: *const SwitchRows,
    reg: *registry.Registry,
    now: i64,
) ?usize {
    const active_account_key = reg.active_account_key orelse return null;

    var best_selectable_idx: ?usize = null;
    var best_account_idx: ?usize = null;

    for (rows.selectable_row_indices, 0..) |row_idx, selectable_idx| {
        const account_idx = rows.items[row_idx].account_index orelse continue;
        const rec = &reg.accounts.items[account_idx];
        if (std.mem.eql(u8, rec.account_key, active_account_key)) continue;
        if (accountCrossesSwitchThreshold(reg, rec, now)) continue;

        if (best_account_idx == null or autoSwitchCandidateIsBetter(rec, &reg.accounts.items[best_account_idx.?], now)) {
            best_selectable_idx = selectable_idx;
            best_account_idx = account_idx;
        }
    }

    return best_selectable_idx;
}

pub fn maybeAutoSwitchTargetKeyAlloc(
    allocator: std.mem.Allocator,
    display: SwitchSelectionDisplay,
    rows: *const SwitchRows,
) !?[]u8 {
    const now = std.Io.Timestamp.now(app_runtime.io(), .real).toSeconds();
    if (!shouldAutoSwitchActiveAccount(display, now)) return null;

    const selectable_idx = bestAutoSwitchCandidateSelectableIndex(rows, display.reg, now) orelse return null;
    return try accountKeyForSelectableAlloc(allocator, rows, display.reg, selectable_idx);
}

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

fn accountHasExhaustedUsage(rec: *const registry.AccountRecord, now: i64) bool {
    const rate_5h = resolveRateWindow(rec.last_usage, 300, true);
    const rate_week = resolveRateWindow(rec.last_usage, 10080, false);
    const rem_5h = registry.remainingPercentAt(rate_5h, now);
    const rem_week = registry.remainingPercentAt(rate_week, now);
    return (rem_5h != null and rem_5h.? == 0) or (rem_week != null and rem_week.? == 0);
}

fn shouldAutoSwitchActiveAccount(display: SwitchSelectionDisplay, now: i64) bool {
    const active_account_key = display.reg.active_account_key orelse return false;
    const active_idx = registry.findAccountIndexByAccountKey(display.reg, active_account_key) orelse return false;

    if (numericUsageOverrideStatus(usageOverrideForAccount(display.usage_overrides, active_idx))) |status_code| {
        return status_code != 200;
    }

    return accountHasExhaustedUsage(&display.reg.accounts.items[active_idx], now);
}

fn autoSwitchCandidateIsBetter(
    candidate_score: ?i64,
    candidate_last_usage_at: ?i64,
    best_score: ?i64,
    best_last_usage_at: i64,
) bool {
    if (candidate_score != null and best_score == null) return true;
    if (candidate_score == null and best_score != null) return false;
    if (candidate_score != null and best_score != null and candidate_score.? != best_score.?) {
        return candidate_score.? > best_score.?;
    }

    return (candidate_last_usage_at orelse -1) > best_last_usage_at;
}

fn bestAutoSwitchCandidateSelectableIndex(
    rows: *const SwitchRows,
    reg: *registry.Registry,
    now: i64,
) ?usize {
    const active_account_key = reg.active_account_key orelse return null;

    var best_selectable_idx: ?usize = null;
    var best_score: ?i64 = null;
    var best_last_usage_at: i64 = -1;

    for (rows.selectable_row_indices, 0..) |row_idx, selectable_idx| {
        const account_idx = rows.items[row_idx].account_index orelse continue;
        const rec = &reg.accounts.items[account_idx];
        if (std.mem.eql(u8, rec.account_key, active_account_key)) continue;
        if (accountHasExhaustedUsage(rec, now)) continue;

        const candidate_score = registry.usageScoreAt(rec.last_usage, now);
        if (best_selectable_idx == null or autoSwitchCandidateIsBetter(
            candidate_score,
            rec.last_usage_at,
            best_score,
            best_last_usage_at,
        )) {
            best_selectable_idx = selectable_idx;
            best_score = candidate_score;
            best_last_usage_at = rec.last_usage_at orelse -1;
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

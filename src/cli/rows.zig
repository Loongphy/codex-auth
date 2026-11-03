const std = @import("std");
const app_runtime = @import("../core/runtime.zig");
const display_rows = @import("../tui/display.zig");
const rate_limit = @import("../tui/rate_limit.zig");
const registry = @import("../registry/root.zig");
const localtime = @import("../time/localtime.zig");
const timefmt = @import("../time/relative.zig");
const timestamp_iso = @import("../time/timestamp.zig");
const text_width = @import("../tui/text_width.zig");

pub const SwitchWidths = struct {
    email: usize,
    plan: usize,
    rate_5h: usize,
    rate_week: usize,
    last: usize,
};

pub const SwitchRow = struct {
    account_index: ?usize,
    account: []u8,
    plan: []const u8,
    rate_5h: []u8,
    rate_week: []u8,
    last: []u8,
    depth: u8,
    is_active: bool,
    has_error: bool,
    is_header: bool,

    fn deinit(self: *SwitchRow, allocator: std.mem.Allocator) void {
        allocator.free(self.account);
        allocator.free(self.rate_5h);
        allocator.free(self.rate_week);
        allocator.free(self.last);
    }
};

pub const SwitchRows = struct {
    items: []SwitchRow,
    selectable_row_indices: []usize,
    widths: SwitchWidths,

    pub fn deinit(self: *SwitchRows, allocator: std.mem.Allocator) void {
        for (self.items) |*row| row.deinit(allocator);
        allocator.free(self.items);
        allocator.free(self.selectable_row_indices);
    }
};

pub fn filterErroredRowsFromSelectableIndices(allocator: std.mem.Allocator, rows: *SwitchRows) !void {
    var selectable_count: usize = 0;
    for (rows.selectable_row_indices) |row_idx| {
        if (!rows.items[row_idx].has_error) selectable_count += 1;
    }

    const filtered = try allocator.alloc(usize, selectable_count);
    var next_idx: usize = 0;
    for (rows.selectable_row_indices) |row_idx| {
        if (rows.items[row_idx].has_error) continue;
        filtered[next_idx] = row_idx;
        next_idx += 1;
    }

    allocator.free(rows.selectable_row_indices);
    rows.selectable_row_indices = filtered;
}

pub fn usageOverrideForAccount(
    usage_overrides: ?[]const ?[]const u8,
    account_idx: usize,
) ?[]const u8 {
    const overrides = usage_overrides orelse return null;
    if (account_idx >= overrides.len) return null;
    return overrides[account_idx];
}

fn usageCellTextAlloc(
    allocator: std.mem.Allocator,
    window: ?registry.RateLimitWindow,
    usage_override: ?[]const u8,
) ![]u8 {
    if (usage_override) |value| return allocator.dupe(u8, value);
    return rate_limit.formatRateLimitFullAlloc(allocator, window);
}

/// An error overlay like `401 unauthorized_unknown` is already loud through
/// the row's red role; it must not also inflate its column to message length
/// and starve every other column. Width measurements cap its contribution.
pub const usage_override_max_width: usize = 16;

pub fn usageOverrideDisplayWidth(text: []const u8) usize {
    return @min(text_width.displayWidth(text), usage_override_max_width);
}

pub fn buildSwitchRows(allocator: std.mem.Allocator, reg: *registry.Registry) !SwitchRows {
    return buildSwitchRowsWithUsageOverrides(allocator, reg, null);
}

pub fn buildSwitchRowsWithUsageOverrides(
    allocator: std.mem.Allocator,
    reg: *registry.Registry,
    usage_overrides: ?[]const ?[]const u8,
) !SwitchRows {
    var display = try display_rows.buildDisplayRows(allocator, reg, null);
    defer display.deinit(allocator);
    var rows = try allocator.alloc(SwitchRow, display.rows.len);
    var widths = SwitchWidths{
        .email = "EMAIL".len,
        .plan = "PLAN".len,
        .rate_5h = "5H".len,
        .rate_week = "WEEKLY".len,
        .last = "LAST".len,
    };
    const now = std.Io.Timestamp.now(app_runtime.io(), .real).toSeconds();
    for (display.rows, 0..) |display_row, i| {
        if (display_row.account_index) |account_idx| {
            const rec = reg.accounts.items[account_idx];
            const plan = display_rows.displayPlan(&rec);
            const rate_5h = registry.resolveRateWindow(rec.last_usage, 300, true);
            const rate_week = registry.resolveRateWindow(rec.last_usage, 10080, false);
            const usage_override = usageOverrideForAccount(usage_overrides, account_idx);
            const rate_5h_str = try usageCellTextAlloc(allocator, rate_5h, usage_override);
            const rate_week_str = try usageCellTextAlloc(allocator, rate_week, usage_override);
            const last = try timefmt.formatRelativeTimeOrDashAlloc(allocator, rec.last_usage_at, now);
            rows[i] = .{
                .account_index = account_idx,
                .account = try allocator.dupe(u8, display_row.account_cell),
                .plan = plan,
                .rate_5h = rate_5h_str,
                .rate_week = rate_week_str,
                .last = last,
                .depth = display_row.depth,
                .is_active = display_row.is_active,
                .has_error = usage_override != null,
                .is_header = false,
            };
            widths.email = @max(widths.email, text_width.displayWidth(display_row.account_cell) + (@as(usize, display_row.depth) * 2));
            widths.plan = @max(widths.plan, plan.len);
            const usage_cell_w: usize = if (usage_override != null) usageOverrideDisplayWidth(rate_5h_str) else rate_5h_str.len;
            widths.rate_5h = @max(widths.rate_5h, usage_cell_w);
            widths.rate_week = @max(widths.rate_week, if (usage_override != null) usageOverrideDisplayWidth(rate_week_str) else rate_week_str.len);
            widths.last = @max(widths.last, last.len);
        } else {
            rows[i] = .{
                .account_index = null,
                .account = try allocator.dupe(u8, display_row.account_cell),
                .plan = "",
                .rate_5h = try allocator.dupe(u8, ""),
                .rate_week = try allocator.dupe(u8, ""),
                .last = try allocator.dupe(u8, ""),
                .depth = display_row.depth,
                .is_active = false,
                .has_error = false,
                .is_header = true,
            };
            widths.email = @max(widths.email, text_width.displayWidth(display_row.account_cell) + (@as(usize, display_row.depth) * 2));
        }
    }
    if (widths.email > 32) widths.email = 32;
    return SwitchRows{
        .items = rows,
        .selectable_row_indices = try allocator.dupe(usize, display.selectable_row_indices),
        .widths = widths,
    };
}

pub fn buildSwitchRowsFromIndicesWithUsageOverrides(
    allocator: std.mem.Allocator,
    reg: *registry.Registry,
    indices: []const usize,
    usage_overrides: ?[]const ?[]const u8,
) !SwitchRows {
    var display = try display_rows.buildDisplayRows(allocator, reg, indices);
    defer display.deinit(allocator);
    var rows = try allocator.alloc(SwitchRow, display.rows.len);
    var widths = SwitchWidths{
        .email = "EMAIL".len,
        .plan = "PLAN".len,
        .rate_5h = "5H".len,
        .rate_week = "WEEKLY".len,
        .last = "LAST".len,
    };
    const now = std.Io.Timestamp.now(app_runtime.io(), .real).toSeconds();
    for (display.rows, 0..) |display_row, i| {
        if (display_row.account_index) |account_idx| {
            const rec = reg.accounts.items[account_idx];
            const plan = display_rows.displayPlan(&rec);
            const rate_5h = registry.resolveRateWindow(rec.last_usage, 300, true);
            const rate_week = registry.resolveRateWindow(rec.last_usage, 10080, false);
            const usage_override = usageOverrideForAccount(usage_overrides, account_idx);
            const rate_5h_str = try usageCellTextAlloc(allocator, rate_5h, usage_override);
            const rate_week_str = try usageCellTextAlloc(allocator, rate_week, usage_override);
            const last = try timefmt.formatRelativeTimeOrDashAlloc(allocator, rec.last_usage_at, now);
            rows[i] = .{
                .account_index = account_idx,
                .account = try allocator.dupe(u8, display_row.account_cell),
                .plan = plan,
                .rate_5h = rate_5h_str,
                .rate_week = rate_week_str,
                .last = last,
                .depth = display_row.depth,
                .is_active = display_row.is_active,
                .has_error = usage_override != null,
                .is_header = false,
            };
            widths.email = @max(widths.email, text_width.displayWidth(display_row.account_cell) + (@as(usize, display_row.depth) * 2));
            widths.plan = @max(widths.plan, plan.len);
            const usage_cell_w: usize = if (usage_override != null) usageOverrideDisplayWidth(rate_5h_str) else rate_5h_str.len;
            widths.rate_5h = @max(widths.rate_5h, usage_cell_w);
            widths.rate_week = @max(widths.rate_week, if (usage_override != null) usageOverrideDisplayWidth(rate_week_str) else rate_week_str.len);
            widths.last = @max(widths.last, last.len);
        } else {
            rows[i] = .{
                .account_index = null,
                .account = try allocator.dupe(u8, display_row.account_cell),
                .plan = "",
                .rate_5h = try allocator.dupe(u8, ""),
                .rate_week = try allocator.dupe(u8, ""),
                .last = try allocator.dupe(u8, ""),
                .depth = display_row.depth,
                .is_active = false,
                .has_error = false,
                .is_header = true,
            };
            widths.email = @max(widths.email, text_width.displayWidth(display_row.account_cell) + (@as(usize, display_row.depth) * 2));
        }
    }
    if (widths.email > 32) widths.email = 32;
    return SwitchRows{
        .items = rows,
        .selectable_row_indices = try allocator.dupe(usize, display.selectable_row_indices),
        .widths = widths,
    };
}



pub fn indexWidth(count: usize) usize {
    var n = count;
    var width: usize = 1;
    while (n >= 10) : (n /= 10) {
        width += 1;
    }
    return width;
}

pub fn formatTimestampAlloc(allocator: std.mem.Allocator, timestamp: ?i64) ![]u8 {
    var tm: localtime.struct_tm = undefined;
    if (timestamp == null or !localtime.compat(timestamp.?, &tm)) return allocator.dupe(u8, "-");
    const year: u32 = @intCast(tm.tm_year + 1900);
    const month: u32 = @intCast(tm.tm_mon + 1);
    const day: u32 = @intCast(tm.tm_mday);
    const hour: u32 = @intCast(tm.tm_hour);
    const minute: u32 = @intCast(tm.tm_min);
    return std.fmt.allocPrint(allocator, "{d:0>4}-{d:0>2}-{d:0>2} {d:0>2}:{d:0>2}", .{
        year, month, day, hour, minute,
    });
}

/// Formats a timestamp as a local `MM-DD HH:MM`: the compact form the live reset
/// credits rail and the `reset` summary share. An unparseable timestamp keeps the
/// `-` missing marker of the full form.
pub fn formatCompactTimestampAlloc(allocator: std.mem.Allocator, timestamp: ?i64) ![]u8 {
    const full = try formatTimestampAlloc(allocator, timestamp);
    if (full.len < 16) return full;
    const compact = try allocator.dupe(u8, full[5..16]);
    allocator.free(full);
    return compact;
}

const available_status = "available";

/// `N` from the persisted `reset_credits` count, plus the earliest expiry among
/// the available cards in local `MM-DD` form (omitted when unknown). The count
/// falls back to the persisted card list so plain and live cells agree.
pub fn resetCreditsCellAlloc(allocator: std.mem.Allocator, usage: ?registry.RateLimitSnapshot) ![]u8 {
    const snapshot = usage orelse return std.fmt.allocPrint(allocator, "-", .{});
    var count: ?i64 = snapshot.reset_credits;
    if (count == null) {
        if (snapshot.reset_credit) |cards| {
            var derived: i64 = 0;
            for (cards) |card| {
                if (std.mem.eql(u8, card.status, available_status)) derived += 1;
            }
            count = derived;
        }
    }
    const value = count orelse return std.fmt.allocPrint(allocator, "-", .{});
    if (value == 0) return std.fmt.allocPrint(allocator, "0", .{});
    var earliest: ?i64 = null;
    if (snapshot.reset_credit) |cards| {
        for (cards) |card| {
            if (!std.mem.eql(u8, card.status, available_status)) continue;
            if (timestamp_iso.parseIso8601(card.expires_at orelse "")) |epoch| {
                if (earliest == null or epoch < earliest.?) earliest = epoch;
            }
        }
    }
    if (earliest) |epoch| {
        const local = try formatTimestampAlloc(allocator, epoch);
        defer allocator.free(local);
        if (local.len >= 10) return std.fmt.allocPrint(allocator, "{d} (exp {s})", .{ value, local[5..10] });
    }
    return std.fmt.allocPrint(allocator, "{d}", .{value});
}

/// Formats a future timestamp as a local `YYYY-MM-DD` date. Missing, invalid,
/// and already-expired timestamps render as `-` so stale snapshots do not look
/// like current entitlements.
pub fn formatFutureDateAlloc(allocator: std.mem.Allocator, timestamp: ?i64, now: i64) ![]u8 {
    const value = timestamp orelse return allocator.dupe(u8, "-");
    if (value <= now) return allocator.dupe(u8, "-");
    var tm: localtime.struct_tm = undefined;
    if (!localtime.compat(value, &tm)) return allocator.dupe(u8, "-");
    const year: u32 = @intCast(tm.tm_year + 1900);
    const month: u32 = @intCast(tm.tm_mon + 1);
    const day: u32 = @intCast(tm.tm_mday);
    return std.fmt.allocPrint(allocator, "{d:0>4}-{d:0>2}-{d:0>2}", .{ year, month, day });
}

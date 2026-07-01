const std = @import("std");
const app_runtime = @import("../core/runtime.zig");
const builtin = @import("builtin");
const display_rows = @import("../tui/display.zig");
const registry = @import("../registry/root.zig");
const timefmt = @import("../time/relative.zig");
const c = @cImport({
    @cInclude("time.h");
});

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
    return formatRateLimitSwitchAlloc(allocator, window);
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
            const plan = if (registry.resolveDisplayPlan(&rec)) |p| registry.planLabel(p) else "-";
            const rate_5h = resolveRateWindow(rec.last_usage, 300, true);
            const rate_week = resolveRateWindow(rec.last_usage, 10080, false);
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
            widths.email = @max(widths.email, display_row.account_cell.len + (@as(usize, display_row.depth) * 2));
            widths.plan = @max(widths.plan, plan.len);
            widths.rate_5h = @max(widths.rate_5h, rate_5h_str.len);
            widths.rate_week = @max(widths.rate_week, rate_week_str.len);
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
            widths.email = @max(widths.email, display_row.account_cell.len + (@as(usize, display_row.depth) * 2));
        }
    }
    if (widths.email > 32) widths.email = 32;
    return SwitchRows{
        .items = rows,
        .selectable_row_indices = try allocator.dupe(usize, display.selectable_row_indices),
        .widths = widths,
    };
}

fn buildSwitchRowsFromIndices(
    allocator: std.mem.Allocator,
    reg: *registry.Registry,
    indices: []const usize,
) !SwitchRows {
    return buildSwitchRowsFromIndicesWithUsageOverrides(allocator, reg, indices, null);
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
            const plan = if (registry.resolveDisplayPlan(&rec)) |p| registry.planLabel(p) else "-";
            const rate_5h = resolveRateWindow(rec.last_usage, 300, true);
            const rate_week = resolveRateWindow(rec.last_usage, 10080, false);
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
            widths.email = @max(widths.email, display_row.account_cell.len + (@as(usize, display_row.depth) * 2));
            widths.plan = @max(widths.plan, plan.len);
            widths.rate_5h = @max(widths.rate_5h, rate_5h_str.len);
            widths.rate_week = @max(widths.rate_week, rate_week_str.len);
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
            widths.email = @max(widths.email, display_row.account_cell.len + (@as(usize, display_row.depth) * 2));
        }
    }
    if (widths.email > 32) widths.email = 32;
    return SwitchRows{
        .items = rows,
        .selectable_row_indices = try allocator.dupe(usize, display.selectable_row_indices),
        .widths = widths,
    };
}

pub fn resolveRateWindow(usage: ?registry.RateLimitSnapshot, minutes: i64, fallback_primary: bool) ?registry.RateLimitWindow {
    if (usage == null) return null;
    if (usage.?.primary) |p| {
        if (p.window_minutes != null and p.window_minutes.? == minutes) return p;
    }
    if (usage.?.secondary) |s| {
        if (s.window_minutes != null and s.window_minutes.? == minutes) return s;
    }
    return if (fallback_primary) usage.?.primary else usage.?.secondary;
}

fn formatRateLimitSwitchAlloc(allocator: std.mem.Allocator, window: ?registry.RateLimitWindow) ![]u8 {
    if (window == null) return try std.fmt.allocPrint(allocator, "-", .{});
    if (window.?.resets_at == null) return try std.fmt.allocPrint(allocator, "-", .{});
    const now = std.Io.Timestamp.now(app_runtime.io(), .real).toSeconds();
    const reset_at = window.?.resets_at.?;
    if (now >= reset_at) {
        return try std.fmt.allocPrint(allocator, "100%", .{});
    }
    const remaining = remainingPercent(window.?.used_percent);
    var parts = try resetPartsAlloc(allocator, reset_at, now);
    defer parts.deinit(allocator);
    if (parts.same_day) {
        return std.fmt.allocPrint(allocator, "{d}% ({s})", .{ remaining, parts.time });
    }
    return std.fmt.allocPrint(allocator, "{d}% ({s} on {s})", .{ remaining, parts.time, parts.date });
}

const ResetParts = struct {
    time: []u8,
    date: []u8,
    same_day: bool,

    fn deinit(self: *ResetParts, allocator: std.mem.Allocator) void {
        allocator.free(self.time);
        allocator.free(self.date);
    }
};

fn localtimeCompat(ts: i64, out_tm: *c.struct_tm) bool {
    if (comptime builtin.os.tag == .windows) {
        // Bind directly to the exported CRT symbol on Windows.
        if (comptime @hasDecl(c, "_localtime64_s") and @hasDecl(c, "__time64_t")) {
            var t64 = std.math.cast(c.__time64_t, ts) orelse return false;
            return c._localtime64_s(out_tm, &t64) == 0;
        }
        return false;
    }

    var t = std.math.cast(c.time_t, ts) orelse return false;
    if (comptime @hasDecl(c, "localtime_r")) {
        return c.localtime_r(&t, out_tm) != null;
    }

    if (comptime @hasDecl(c, "localtime")) {
        const tm_ptr = c.localtime(&t);
        if (tm_ptr == null) return false;
        out_tm.* = tm_ptr.*;
        return true;
    }

    return false;
}

fn resetPartsAlloc(allocator: std.mem.Allocator, reset_at: i64, now: i64) !ResetParts {
    var tm: c.struct_tm = undefined;
    if (!localtimeCompat(reset_at, &tm)) {
        return ResetParts{
            .time = try std.fmt.allocPrint(allocator, "-", .{}),
            .date = try std.fmt.allocPrint(allocator, "-", .{}),
            .same_day = true,
        };
    }
    var now_tm: c.struct_tm = undefined;
    if (!localtimeCompat(now, &now_tm)) {
        return ResetParts{
            .time = try std.fmt.allocPrint(allocator, "-", .{}),
            .date = try std.fmt.allocPrint(allocator, "-", .{}),
            .same_day = true,
        };
    }

    const same_day = tm.tm_year == now_tm.tm_year and tm.tm_mon == now_tm.tm_mon and tm.tm_mday == now_tm.tm_mday;
    const hour = @as(u32, @intCast(tm.tm_hour));
    const min = @as(u32, @intCast(tm.tm_min));
    const day = @as(u32, @intCast(tm.tm_mday));
    const months = [_][]const u8{
        "Jan",
        "Feb",
        "Mar",
        "Apr",
        "May",
        "Jun",
        "Jul",
        "Aug",
        "Sep",
        "Oct",
        "Nov",
        "Dec",
    };
    const month_idx: usize = if (tm.tm_mon < 0) 0 else @min(@as(usize, @intCast(tm.tm_mon)), months.len - 1);
    return ResetParts{
        .time = try std.fmt.allocPrint(allocator, "{d:0>2}:{d:0>2}", .{ hour, min }),
        .date = try std.fmt.allocPrint(allocator, "{d} {s}", .{ day, months[month_idx] }),
        .same_day = same_day,
    };
}

fn remainingPercent(used: f64) i64 {
    const remaining = 100.0 - used;
    if (remaining <= 0.0) return 0;
    if (remaining >= 100.0) return 100;
    return @as(i64, @intFromFloat(remaining));
}

pub fn indexWidth(count: usize) usize {
    var n = count;
    var width: usize = 1;
    while (n >= 10) : (n /= 10) {
        width += 1;
    }
    return width;
}

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

pub const SortField = enum {
    account,
    plan,
    five_hour,
    weekly,
    last_activity,
};

pub const SortDirection = enum {
    asc,
    desc,
};

pub const SortSpec = struct {
    field: SortField,
    direction: SortDirection,
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
            const plan = displayPlan(&rec);
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

pub fn buildListRowsWithUsageOverrides(
    allocator: std.mem.Allocator,
    reg: *registry.Registry,
    usage_overrides: ?[]const ?[]const u8,
    sort_spec: ?SortSpec,
) !SwitchRows {
    return buildSortableRowsWithUsageOverrides(allocator, reg, null, usage_overrides, sort_spec);
}

pub fn buildSortableRowsWithUsageOverrides(
    allocator: std.mem.Allocator,
    reg: *registry.Registry,
    maybe_indices: ?[]const usize,
    usage_overrides: ?[]const ?[]const u8,
    sort_spec: ?SortSpec,
) !SwitchRows {
    const spec = sort_spec orelse {
        if (maybe_indices) |indices| {
            return buildSwitchRowsFromIndicesWithUsageOverrides(allocator, reg, indices, usage_overrides);
        }
        return buildSwitchRowsWithUsageOverrides(allocator, reg, usage_overrides);
    };

    const source_len = if (maybe_indices) |indices| indices.len else reg.accounts.items.len;
    const indices = try allocator.alloc(usize, source_len);
    defer allocator.free(indices);
    if (maybe_indices) |source_indices| {
        @memcpy(indices, source_indices);
    } else {
        for (indices, 0..) |*slot, idx| slot.* = idx;
    }

    const now = std.Io.Timestamp.now(app_runtime.io(), .real).toSeconds();
    std.sort.insertion(usize, indices, SortContext{
        .reg = reg,
        .usage_overrides = usage_overrides,
        .spec = spec,
        .now = now,
    }, sortedAccountLessThan);

    var rows = try allocator.alloc(SwitchRow, indices.len);
    var initialized_rows: usize = 0;
    errdefer {
        for (rows[0..initialized_rows]) |*row| row.deinit(allocator);
        allocator.free(rows);
    }

    var selectable = try allocator.alloc(usize, indices.len);
    errdefer allocator.free(selectable);

    var widths = SwitchWidths{
        .email = "EMAIL".len,
        .plan = "PLAN".len,
        .rate_5h = "5H".len,
        .rate_week = "WEEKLY".len,
        .last = "LAST".len,
    };

    for (indices, 0..) |account_idx, i| {
        const rec = reg.accounts.items[account_idx];
        const plan = displayPlan(&rec);
        const rate_5h = resolveRateWindow(rec.last_usage, 300, true);
        const rate_week = resolveRateWindow(rec.last_usage, 10080, false);
        const usage_override = usageOverrideForAccount(usage_overrides, account_idx);
        const rate_5h_str = try usageCellTextAlloc(allocator, rate_5h, usage_override);
        errdefer allocator.free(rate_5h_str);
        const rate_week_str = try usageCellTextAlloc(allocator, rate_week, usage_override);
        errdefer allocator.free(rate_week_str);
        const last = try timefmt.formatRelativeTimeOrDashAlloc(allocator, rec.last_usage_at, now);
        errdefer allocator.free(last);
        const account = try sortedAccountCellAlloc(allocator, reg, account_idx);
        errdefer allocator.free(account);

        rows[i] = .{
            .account_index = account_idx,
            .account = account,
            .plan = plan,
            .rate_5h = rate_5h_str,
            .rate_week = rate_week_str,
            .last = last,
            .depth = 0,
            .is_active = isActive(reg, account_idx),
            .has_error = usage_override != null,
            .is_header = false,
        };
        initialized_rows += 1;
        selectable[i] = i;
        widths.email = @max(widths.email, account.len);
        widths.plan = @max(widths.plan, plan.len);
        widths.rate_5h = @max(widths.rate_5h, rate_5h_str.len);
        widths.rate_week = @max(widths.rate_week, rate_week_str.len);
        widths.last = @max(widths.last, last.len);
    }

    if (widths.email > 32) widths.email = 32;
    return .{
        .items = rows,
        .selectable_row_indices = selectable,
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
            const plan = displayPlan(&rec);
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

const SortContext = struct {
    reg: *registry.Registry,
    usage_overrides: ?[]const ?[]const u8,
    spec: SortSpec,
    now: i64,
};

fn sortedAccountLessThan(ctx: SortContext, lhs: usize, rhs: usize) bool {
    const order = sortedAccountOrder(ctx, lhs, rhs);
    return order == .lt;
}

fn sortedAccountOrder(ctx: SortContext, lhs: usize, rhs: usize) std.math.Order {
    const order = switch (ctx.spec.field) {
        .account => accountOrder(ctx.reg, lhs, rhs, ctx.spec.direction),
        .plan => planOrder(ctx.reg, lhs, rhs, ctx.spec.direction),
        .five_hour => rateOrder(ctx.reg, ctx.usage_overrides, lhs, rhs, 300, true, ctx.now, ctx.spec.direction),
        .weekly => rateOrder(ctx.reg, ctx.usage_overrides, lhs, rhs, 10080, false, ctx.now, ctx.spec.direction),
        .last_activity => optionalI64Order(
            ctx.reg.accounts.items[lhs].last_usage_at,
            ctx.reg.accounts.items[rhs].last_usage_at,
            ctx.spec.direction,
        ),
    };
    if (order != .eq) return order;
    return accountOrder(ctx.reg, lhs, rhs, .asc);
}

fn accountOrder(reg: *const registry.Registry, lhs: usize, rhs: usize, direction: SortDirection) std.math.Order {
    const a = &reg.accounts.items[lhs];
    const b = &reg.accounts.items[rhs];
    const email_order = maybeReverseOrder(std.mem.order(u8, a.email, b.email), direction);
    if (email_order != .eq) return email_order;

    const a_label = stableAccountLabel(a);
    const b_label = stableAccountLabel(b);
    const label_order = maybeReverseOrder(std.mem.order(u8, a_label, b_label), direction);
    if (label_order != .eq) return label_order;

    return maybeReverseOrder(std.mem.order(u8, a.account_key, b.account_key), direction);
}

fn planOrder(reg: *const registry.Registry, lhs: usize, rhs: usize, direction: SortDirection) std.math.Order {
    const a = &reg.accounts.items[lhs];
    const b = &reg.accounts.items[rhs];
    return maybeReverseOrder(std.mem.order(u8, displayPlan(a), displayPlan(b)), direction);
}

fn rateOrder(
    reg: *const registry.Registry,
    usage_overrides: ?[]const ?[]const u8,
    lhs: usize,
    rhs: usize,
    minutes: i64,
    fallback_primary: bool,
    now: i64,
    direction: SortDirection,
) std.math.Order {
    return optionalI64Order(
        rateSortValue(reg, usage_overrides, lhs, minutes, fallback_primary, now),
        rateSortValue(reg, usage_overrides, rhs, minutes, fallback_primary, now),
        direction,
    );
}

fn rateSortValue(
    reg: *const registry.Registry,
    usage_overrides: ?[]const ?[]const u8,
    account_idx: usize,
    minutes: i64,
    fallback_primary: bool,
    now: i64,
) ?i64 {
    if (usageOverrideForAccount(usage_overrides, account_idx) != null) return null;
    const window = resolveRateWindow(reg.accounts.items[account_idx].last_usage, minutes, fallback_primary) orelse return null;
    const reset_at = window.resets_at orelse return null;
    if (now >= reset_at) return 100;
    return remainingPercent(window.used_percent);
}

fn optionalI64Order(lhs: ?i64, rhs: ?i64, direction: SortDirection) std.math.Order {
    if (lhs == null and rhs == null) return .eq;
    if (lhs == null) return .gt;
    if (rhs == null) return .lt;
    return maybeReverseOrder(intOrder(i64, lhs.?, rhs.?), direction);
}

fn intOrder(comptime T: type, lhs: T, rhs: T) std.math.Order {
    if (lhs < rhs) return .lt;
    if (lhs > rhs) return .gt;
    return .eq;
}

fn maybeReverseOrder(order: std.math.Order, direction: SortDirection) std.math.Order {
    if (direction == .asc) return order;
    return switch (order) {
        .lt => .gt,
        .gt => .lt,
        .eq => .eq,
    };
}

fn sortedAccountCellAlloc(
    allocator: std.mem.Allocator,
    reg: *const registry.Registry,
    account_idx: usize,
) ![]u8 {
    const rec = &reg.accounts.items[account_idx];
    if (sameEmailAccountCount(reg, rec.email) <= 1) return allocator.dupe(u8, rec.email);

    const fallback = displayPlan(rec);
    const label = try display_rows.buildPreferredAccountLabelAlloc(allocator, rec, fallback);
    defer allocator.free(label);
    return std.fmt.allocPrint(allocator, "{s} ({s})", .{ rec.email, label });
}

fn sameEmailAccountCount(reg: *const registry.Registry, email: []const u8) usize {
    var count: usize = 0;
    for (reg.accounts.items) |rec| {
        if (std.mem.eql(u8, rec.email, email)) count += 1;
    }
    return count;
}

fn stableAccountLabel(rec: *const registry.AccountRecord) []const u8 {
    if (rec.alias.len != 0) return rec.alias;
    if (rec.account_name) |account_name| {
        if (account_name.len != 0) return account_name;
    }
    return displayPlan(rec);
}

fn displayPlan(rec: *const registry.AccountRecord) []const u8 {
    if (rec.auth_mode != null and rec.auth_mode.? == .apikey) return "API_KEY";
    return if (registry.resolveDisplayPlan(rec)) |plan| registry.planLabel(plan) else "-";
}

fn isActive(reg: *const registry.Registry, account_idx: usize) bool {
    const active = reg.active_account_key orelse return false;
    return std.mem.eql(u8, active, reg.accounts.items[account_idx].account_key);
}

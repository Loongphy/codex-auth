const std = @import("std");
const app_runtime = @import("runtime.zig");
const builtin = @import("builtin");
const display_rows = @import("display_rows.zig");
const registry = @import("registry.zig");
const io_util = @import("io_util.zig");
const terminal_color = @import("terminal_color.zig");
const timefmt = @import("timefmt.zig");
const c = @cImport({
    @cInclude("time.h");
});

const ansi = struct {
    const reset = "\x1b[0m";
    const dim = "\x1b[2m";
    const red = "\x1b[31m";
    const bold_red = "\x1b[1;31m";
    const green = "\x1b[32m";
};

fn colorEnabled() bool {
    return terminal_color.stdoutColorEnabled();
}

fn planDisplay(rec: *const registry.AccountRecord, missing: []const u8) []const u8 {
    if (registry.resolveDisplayPlan(rec)) |p| return registry.planLabel(p);
    return missing;
}

pub fn printAccounts(reg: *registry.Registry) !void {
    try printAccountsWithUsageOverrides(reg, null);
}

pub fn printAccountsWithUsageOverrides(
    reg: *registry.Registry,
    usage_overrides: ?[]const ?[]const u8,
) !void {
    try printAccountsTable(reg, usage_overrides);
}

fn printAccountsTable(reg: *registry.Registry, usage_overrides: ?[]const ?[]const u8) !void {
    var stdout: io_util.Stdout = undefined;
    stdout.init();
    const out = stdout.out();
    try writeAccountsTableWithUsageOverrides(out, reg, colorEnabled(), usage_overrides);
    try out.flush();
}

fn writeAccountsTable(out: *std.Io.Writer, reg: *registry.Registry, use_color: bool) !void {
    try writeAccountsTableWithUsageOverrides(out, reg, use_color, null);
}

fn usageOverrideForAccount(
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
    max_width: usize,
    usage_override: ?[]const u8,
) ![]u8 {
    if (usage_override) |value| return allocator.dupe(u8, value);
    return formatRateLimitUiAlloc(window, max_width);
}

fn usageCellFullTextAlloc(
    allocator: std.mem.Allocator,
    window: ?registry.RateLimitWindow,
    usage_override: ?[]const u8,
) ![]u8 {
    if (usage_override) |value| return allocator.dupe(u8, value);
    return formatRateLimitFullAlloc(window);
}

fn writeAccountsTableWithUsageOverrides(
    out: *std.Io.Writer,
    reg: *registry.Registry,
    use_color: bool,
    usage_overrides: ?[]const ?[]const u8,
) !void {
    const headers = [_][]const u8{ "ACCOUNT", "PLAN", "5H USAGE", "WEEKLY USAGE", "LAST ACTIVITY" };
    var widths = [_]usize{
        headers[0].len,
        headers[1].len,
        headers[2].len,
        headers[3].len,
        headers[4].len,
    };
    const now = std.Io.Timestamp.now(app_runtime.io(), .real).toSeconds();
    var display = try display_rows.buildDisplayRows(std.heap.page_allocator, reg, null);
    defer display.deinit(std.heap.page_allocator);
    const idx_width = @max(@as(usize, 2), indexWidth(display.selectable_row_indices.len));
    const prefix_len: usize = 2 + idx_width + 1;
    const sep_len: usize = 2;

    for (display.rows) |row| {
        const indent: usize = @as(usize, row.depth) * 2;
        widths[0] = @max(widths[0], row.account_cell.len + indent);
        if (row.account_index) |account_idx| {
            const rec = reg.accounts.items[account_idx];
            const plan = planDisplay(&rec, "-");
            const rate_5h = resolveRateWindow(rec.last_usage, 300, true);
            const rate_week = resolveRateWindow(rec.last_usage, 10080, false);
            const usage_override = usageOverrideForAccount(usage_overrides, account_idx);
            const rate_5h_str = try usageCellFullTextAlloc(std.heap.page_allocator, rate_5h, usage_override);
            defer std.heap.page_allocator.free(rate_5h_str);
            const rate_week_str = try usageCellFullTextAlloc(std.heap.page_allocator, rate_week, usage_override);
            defer std.heap.page_allocator.free(rate_week_str);
            const last_str = try timefmt.formatRelativeTimeOrDashAlloc(std.heap.page_allocator, rec.last_usage_at, now);
            defer std.heap.page_allocator.free(last_str);

            widths[1] = @max(widths[1], plan.len);
            widths[2] = @max(widths[2], rate_5h_str.len);
            widths[3] = @max(widths[3], rate_week_str.len);
            widths[4] = @max(widths[4], last_str.len);
        }
    }

    adjustListWidths(&widths, prefix_len, sep_len);

    const h0 = try truncateAlloc(headers[0], widths[0]);
    defer std.heap.page_allocator.free(h0);
    const h1 = try truncateAlloc(headers[1], widths[1]);
    defer std.heap.page_allocator.free(h1);
    const header_5h = if (widths[2] >= "5H USAGE".len) "5H USAGE" else "5H";
    const h2 = try truncateAlloc(header_5h, widths[2]);
    defer std.heap.page_allocator.free(h2);
    const header_week = if (widths[3] >= "WEEKLY USAGE".len) "WEEKLY USAGE" else if (widths[3] >= "WEEKLY".len) "WEEKLY" else if (widths[3] >= "WEEK".len) "WEEK" else "W";
    const h3 = try truncateAlloc(header_week, widths[3]);
    defer std.heap.page_allocator.free(h3);
    const header_last = if (widths[4] >= "LAST ACTIVITY".len) "LAST ACTIVITY" else "LAST";
    const h4 = try truncateAlloc(header_last, widths[4]);
    defer std.heap.page_allocator.free(h4);

    if (use_color) try out.writeAll(ansi.dim);
    try writeRepeat(out, ' ', prefix_len);
    try writePadded(out, h0, widths[0]);
    try out.writeAll("  ");
    try writePadded(out, h1, widths[1]);
    try out.writeAll("  ");
    try writePadded(out, h2, widths[2]);
    try out.writeAll("  ");
    try writePadded(out, h3, widths[3]);
    try out.writeAll("  ");
    try writePadded(out, h4, widths[4]);
    try out.writeAll("\n");
    if (use_color) try out.writeAll(ansi.dim);
    try writeRepeat(out, '-', listTotalWidth(&widths, prefix_len, sep_len));
    try out.writeAll("\n");
    if (use_color) try out.writeAll(ansi.reset);

    var selectable_counter: usize = 0;
    for (display.rows) |row| {
        if (row.account_index) |account_idx| {
            const rec = reg.accounts.items[account_idx];
            const plan = planDisplay(&rec, "-");
            const rate_5h = resolveRateWindow(rec.last_usage, 300, true);
            const rate_week = resolveRateWindow(rec.last_usage, 10080, false);
            const usage_override = usageOverrideForAccount(usage_overrides, account_idx);
            const rate_5h_str = try usageCellTextAlloc(std.heap.page_allocator, rate_5h, widths[2], usage_override);
            defer std.heap.page_allocator.free(rate_5h_str);
            const rate_week_str = try usageCellTextAlloc(std.heap.page_allocator, rate_week, widths[3], usage_override);
            defer std.heap.page_allocator.free(rate_week_str);
            const last = try timefmt.formatRelativeTimeOrDashAlloc(std.heap.page_allocator, rec.last_usage_at, now);
            defer std.heap.page_allocator.free(last);
            const indent: usize = @as(usize, row.depth) * 2;
            const indent_to_print: usize = @min(indent, widths[0]);
            const account_cell = try truncateAlloc(row.account_cell, widths[0] - indent_to_print);
            defer std.heap.page_allocator.free(account_cell);
            const plan_cell = try truncateAlloc(plan, widths[1]);
            defer std.heap.page_allocator.free(plan_cell);
            const rate_5h_cell = try truncateAlloc(rate_5h_str, widths[2]);
            defer std.heap.page_allocator.free(rate_5h_cell);
            const rate_week_cell = try truncateAlloc(rate_week_str, widths[3]);
            defer std.heap.page_allocator.free(rate_week_cell);
            const last_cell = try truncateAlloc(last, widths[4]);
            defer std.heap.page_allocator.free(last_cell);
            if (use_color) {
                if (usage_override != null) {
                    if (row.is_active) {
                        try out.writeAll(ansi.bold_red);
                    } else {
                        try out.writeAll(ansi.red);
                    }
                } else if (row.is_active) {
                    try out.writeAll(ansi.green);
                } else {
                    try out.writeAll(ansi.dim);
                }
            }
            try out.writeAll(if (row.is_active) "* " else "  ");
            try writeIndexPadded(out, selectable_counter + 1, idx_width);
            try out.writeAll(" ");
            try writeRepeat(out, ' ', indent_to_print);
            try writePadded(out, account_cell, widths[0] - indent_to_print);
            try out.writeAll("  ");
            try writePadded(out, plan_cell, widths[1]);
            try out.writeAll("  ");
            try writePadded(out, rate_5h_cell, widths[2]);
            try out.writeAll("  ");
            try writePadded(out, rate_week_cell, widths[3]);
            try out.writeAll("  ");
            try writePadded(out, last_cell, widths[4]);
            try out.writeAll("\n");
            if (use_color) try out.writeAll(ansi.reset);
            selectable_counter += 1;
        } else {
            const account_cell = try truncateAlloc(row.account_cell, widths[0]);
            defer std.heap.page_allocator.free(account_cell);
            if (use_color) try out.writeAll(ansi.dim);
            try writeRepeat(out, ' ', prefix_len);
            try writePadded(out, account_cell, widths[0]);
            try out.writeAll("\n");
            if (use_color) try out.writeAll(ansi.reset);
        }
    }
}

fn resolveRateWindow(usage: ?registry.RateLimitSnapshot, minutes: i64, fallback_primary: bool) ?registry.RateLimitWindow {
    if (usage == null) return null;
    if (usage.?.primary) |p| {
        if (p.window_minutes != null and p.window_minutes.? == minutes) return p;
    }
    if (usage.?.secondary) |s| {
        if (s.window_minutes != null and s.window_minutes.? == minutes) return s;
    }
    return if (fallback_primary) usage.?.primary else usage.?.secondary;
}

const ResetParts = struct {
    time: []u8,
    date: []u8,
    same_day: bool,

    fn deinit(self: *ResetParts) void {
        std.heap.page_allocator.free(self.time);
        std.heap.page_allocator.free(self.date);
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

fn resetPartsAlloc(reset_at: i64, now: i64) !ResetParts {
    var tm: c.struct_tm = undefined;
    if (!localtimeCompat(reset_at, &tm)) {
        return ResetParts{
            .time = try std.fmt.allocPrint(std.heap.page_allocator, "-", .{}),
            .date = try std.fmt.allocPrint(std.heap.page_allocator, "-", .{}),
            .same_day = true,
        };
    }
    var now_tm: c.struct_tm = undefined;
    if (!localtimeCompat(now, &now_tm)) {
        return ResetParts{
            .time = try std.fmt.allocPrint(std.heap.page_allocator, "-", .{}),
            .date = try std.fmt.allocPrint(std.heap.page_allocator, "-", .{}),
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
        .time = try std.fmt.allocPrint(std.heap.page_allocator, "{d:0>2}:{d:0>2}", .{ hour, min }),
        .date = try std.fmt.allocPrint(std.heap.page_allocator, "{d} {s}", .{ day, months[month_idx] }),
        .same_day = same_day,
    };
}

fn formatRateLimitFullAlloc(window: ?registry.RateLimitWindow) ![]u8 {
    if (window == null) return try std.fmt.allocPrint(std.heap.page_allocator, "-", .{});
    if (window.?.resets_at == null) return try std.fmt.allocPrint(std.heap.page_allocator, "-", .{});
    const now = std.Io.Timestamp.now(app_runtime.io(), .real).toSeconds();
    const reset_at = window.?.resets_at.?;
    if (now >= reset_at) {
        return try std.fmt.allocPrint(std.heap.page_allocator, "100%", .{});
    }
    const remaining = remainingPercent(window.?.used_percent);
    var parts = try resetPartsAlloc(reset_at, now);
    defer parts.deinit();
    if (parts.same_day) {
        return std.fmt.allocPrint(std.heap.page_allocator, "{d}% ({s})", .{ remaining, parts.time });
    }
    return std.fmt.allocPrint(std.heap.page_allocator, "{d}% ({s} on {s})", .{ remaining, parts.time, parts.date });
}

fn formatRateLimitUiAlloc(window: ?registry.RateLimitWindow, width: usize) ![]u8 {
    if (window == null) return try std.fmt.allocPrint(std.heap.page_allocator, "-", .{});
    if (window.?.resets_at == null) return try std.fmt.allocPrint(std.heap.page_allocator, "-", .{});
    const now = std.Io.Timestamp.now(app_runtime.io(), .real).toSeconds();
    const reset_at = window.?.resets_at.?;
    if (now >= reset_at) {
        return try std.fmt.allocPrint(std.heap.page_allocator, "100%", .{});
    }
    const remaining = remainingPercent(window.?.used_percent);
    var parts = try resetPartsAlloc(reset_at, now);
    defer parts.deinit();

    const candidates_same = [_][]const u8{
        try std.fmt.allocPrint(std.heap.page_allocator, "{d}% ({s})", .{ remaining, parts.time }),
        try std.fmt.allocPrint(std.heap.page_allocator, "{d}%", .{remaining}),
    };
    defer std.heap.page_allocator.free(candidates_same[0]);
    defer std.heap.page_allocator.free(candidates_same[1]);

    if (parts.same_day) {
        if (width >= candidates_same[0].len or width == 0) return std.fmt.allocPrint(std.heap.page_allocator, "{s}", .{candidates_same[0]});
        return std.fmt.allocPrint(std.heap.page_allocator, "{s}", .{candidates_same[1]});
    }

    const candidate_full = try std.fmt.allocPrint(std.heap.page_allocator, "{d}% ({s} on {s})", .{ remaining, parts.time, parts.date });
    defer std.heap.page_allocator.free(candidate_full);
    const candidate_date = try std.fmt.allocPrint(std.heap.page_allocator, "{d}% ({s})", .{ remaining, parts.date });
    defer std.heap.page_allocator.free(candidate_date);
    const candidate_time = try std.fmt.allocPrint(std.heap.page_allocator, "{d}% ({s})", .{ remaining, parts.time });
    defer std.heap.page_allocator.free(candidate_time);
    const candidate_percent = try std.fmt.allocPrint(std.heap.page_allocator, "{d}%", .{remaining});
    defer std.heap.page_allocator.free(candidate_percent);

    if (width >= candidate_full.len or width == 0) return std.fmt.allocPrint(std.heap.page_allocator, "{s}", .{candidate_full});
    if (width >= candidate_date.len) return std.fmt.allocPrint(std.heap.page_allocator, "{s}", .{candidate_date});
    if (width >= candidate_time.len) return std.fmt.allocPrint(std.heap.page_allocator, "{s}", .{candidate_time});
    return std.fmt.allocPrint(std.heap.page_allocator, "{s}", .{candidate_percent});
}

fn remainingPercent(used: f64) i64 {
    const remaining = 100.0 - used;
    if (remaining <= 0.0) return 0;
    if (remaining >= 100.0) return 100;
    return @as(i64, @intFromFloat(remaining));
}

fn formatResetTimeAlloc(ts: i64, now: i64) ![]u8 {
    var tm: c.struct_tm = undefined;
    if (!localtimeCompat(ts, &tm)) {
        return try std.fmt.allocPrint(std.heap.page_allocator, "-", .{});
    }
    var now_tm: c.struct_tm = undefined;
    if (!localtimeCompat(now, &now_tm)) {
        return try std.fmt.allocPrint(std.heap.page_allocator, "-", .{});
    }

    const same_day = tm.tm_year == now_tm.tm_year and tm.tm_mon == now_tm.tm_mon and tm.tm_mday == now_tm.tm_mday;
    const hour = @as(u32, @intCast(tm.tm_hour));
    const min = @as(u32, @intCast(tm.tm_min));
    if (same_day) {
        return std.fmt.allocPrint(std.heap.page_allocator, "{d:0>2}:{d:0>2}", .{ hour, min });
    }
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
    return std.fmt.allocPrint(std.heap.page_allocator, "{d:0>2}:{d:0>2} on {d} {s}", .{ hour, min, day, months[month_idx] });
}

fn printTableBorder(out: *std.Io.Writer, widths: []const usize) !void {
    try out.writeAll("+");
    for (widths) |w| {
        var i: usize = 0;
        while (i < w + 2) : (i += 1) {
            try out.writeAll("=");
        }
        try out.writeAll("+");
    }
    try out.writeAll("\n");
}

fn printTableDivider(out: *std.Io.Writer, widths: []const usize) !void {
    try out.writeAll("+");
    for (widths) |w| {
        var i: usize = 0;
        while (i < w + 2) : (i += 1) {
            try out.writeAll("=");
        }
        try out.writeAll("+");
    }
    try out.writeAll("\n");
}

fn printTableEnd(out: *std.Io.Writer, widths: []const usize) !void {
    try out.writeAll("+");
    for (widths) |w| {
        var i: usize = 0;
        while (i < w + 2) : (i += 1) {
            try out.writeAll("=");
        }
        try out.writeAll("+");
    }
    try out.writeAll("\n");
}

fn printTableRow(out: *std.Io.Writer, widths: []const usize, cells: []const []const u8) !void {
    try out.writeAll("|");
    for (cells, 0..) |cell, idx| {
        try out.writeAll(" ");
        try out.print("{s}", .{cell});
        const pad = if (cell.len >= widths[idx]) 0 else (widths[idx] - cell.len);
        var i: usize = 0;
        while (i < pad) : (i += 1) {
            try out.writeAll(" ");
        }
        try out.writeAll(" |");
    }
    try out.writeAll("\n");
}

fn writePadded(out: *std.Io.Writer, value: []const u8, width: usize) !void {
    try out.writeAll(value);
    if (value.len >= width) return;
    var i: usize = 0;
    const pad = width - value.len;
    while (i < pad) : (i += 1) {
        try out.writeAll(" ");
    }
}

fn writeRepeat(out: *std.Io.Writer, ch: u8, count: usize) !void {
    var i: usize = 0;
    while (i < count) : (i += 1) {
        try out.writeByte(ch);
    }
}

fn listTotalWidth(widths: *const [5]usize, prefix_len: usize, sep_len: usize) usize {
    var sum: usize = prefix_len;
    for (widths) |w| sum += w;
    sum += sep_len * (widths.len - 1);
    return sum;
}

fn adjustListWidths(widths: *[5]usize, prefix_len: usize, sep_len: usize) void {
    const term_cols = terminalWidth();
    if (term_cols == 0) return;
    const total = listTotalWidth(widths, prefix_len, sep_len);
    if (total <= term_cols) return;

    const min_email: usize = 10;
    const min_plan: usize = 4;
    const min_rate: usize = 1;
    const min_last: usize = 4;

    var over = total - term_cols;
    if (over == 0) return;

    if (widths[0] > min_email) {
        const reducible = widths[0] - min_email;
        const reduce = @min(reducible, over);
        widths[0] -= reduce;
        over -= reduce;
    }
    if (over == 0) return;

    if (widths[1] > min_plan) {
        const reducible = widths[1] - min_plan;
        const reduce = @min(reducible, over);
        widths[1] -= reduce;
        over -= reduce;
    }
    if (over == 0) return;

    if (widths[2] > min_rate) {
        const reducible = widths[2] - min_rate;
        const reduce = @min(reducible, over);
        widths[2] -= reduce;
        over -= reduce;
    }
    if (over == 0) return;

    if (widths[3] > min_rate) {
        const reducible = widths[3] - min_rate;
        const reduce = @min(reducible, over);
        widths[3] -= reduce;
        over -= reduce;
    }
    if (over == 0) return;

    if (widths[4] > min_last) {
        const reducible = widths[4] - min_last;
        const reduce = @min(reducible, over);
        widths[4] -= reduce;
        over -= reduce;
    }
}

fn adjustTableWidths(widths: []usize) void {
    const term_cols = terminalWidth();
    if (term_cols == 0) return;
    const total = tableTotalWidth(widths);
    if (total <= term_cols) return;

    const min_plan: usize = 4;
    const min_rate: usize = 2;
    const min_last: usize = 19;
    const min_email: usize = 10;

    var over = total - term_cols;
    if (over == 0) return;

    if (widths[0] > min_email) {
        const reducible = widths[0] - min_email;
        const reduce = @min(reducible, over);
        widths[0] -= reduce;
        over -= reduce;
    }
    if (over == 0) return;

    if (widths[1] > min_plan) {
        const reducible = widths[1] - min_plan;
        const reduce = @min(reducible, over);
        widths[1] -= reduce;
        over -= reduce;
    }
    if (over == 0) return;

    if (widths.len > 2 and widths[2] > min_rate) {
        const reducible = widths[2] - min_rate;
        const reduce = @min(reducible, over);
        widths[2] -= reduce;
        over -= reduce;
    }
    if (over == 0) return;

    if (widths.len > 3 and widths[3] > min_rate) {
        const reducible = widths[3] - min_rate;
        const reduce = @min(reducible, over);
        widths[3] -= reduce;
        over -= reduce;
    }
    if (over == 0) return;

    if (widths.len > 4 and widths[4] > min_last) {
        const reducible = widths[4] - min_last;
        const reduce = @min(reducible, over);
        widths[4] -= reduce;
        over -= reduce;
    }
}

fn tableTotalWidth(widths: []const usize) usize {
    var sum: usize = 0;
    for (widths) |w| sum += w;
    return sum + (3 * widths.len) + 1;
}

fn terminalWidth() usize {
    const stdout_file = std.Io.File.stdout();
    if (!(stdout_file.isTty(app_runtime.io()) catch false)) return 0;

    if (comptime builtin.os.tag == .windows) {
        var get_console_info = std.os.windows.CONSOLE.USER_IO.GET_SCREEN_BUFFER_INFO;
        switch (get_console_info.operate(app_runtime.io(), stdout_file) catch return 0) {
            .SUCCESS => {},
            else => return 0,
        }
        const width = @as(i32, get_console_info.Data.dwWindowSize.X);
        if (width <= 0) return 0;
        return @as(usize, @intCast(width));
    } else {
        var wsz: std.posix.winsize = .{
            .row = 0,
            .col = 0,
            .xpixel = 0,
            .ypixel = 0,
        };
        const rc = std.posix.system.ioctl(stdout_file.handle, std.posix.T.IOCGWINSZ, @intFromPtr(&wsz));
        if (std.posix.errno(rc) != .SUCCESS) return 0;
        return @as(usize, wsz.col);
    }
}

fn truncateAlloc(value: []const u8, max_len: usize) ![]u8 {
    if (value.len <= max_len) return try std.fmt.allocPrint(std.heap.page_allocator, "{s}", .{value});
    if (max_len == 0) return try std.fmt.allocPrint(std.heap.page_allocator, "", .{});
    if (max_len == 1) return try std.fmt.allocPrint(std.heap.page_allocator, ".", .{});
    return std.fmt.allocPrint(std.heap.page_allocator, "{s}.", .{value[0 .. max_len - 1]});
}

fn writeIndexPadded(out: *std.Io.Writer, idx: usize, width: usize) !void {
    var buf: [16]u8 = undefined;
    const idx_str = std.fmt.bufPrint(&buf, "{d}", .{idx}) catch "0";
    if (idx_str.len < width) {
        var pad: usize = width - idx_str.len;
        while (pad > 0) : (pad -= 1) {
            try out.writeAll("0");
        }
    }
    try out.writeAll(idx_str);
}

fn indexWidth(count: usize) usize {
    var n = count;
    var width: usize = 1;
    while (n >= 10) : (n /= 10) {
        width += 1;
    }
    return width;
}

fn makeTestRegistry() registry.Registry {
    return .{
        .schema_version = registry.current_schema_version,
        .active_account_key = null,
        .active_account_activated_at_ms = null,
        .auto_switch = registry.defaultAutoSwitchConfig(),
        .api = registry.defaultApiConfig(),
        .accounts = std.ArrayList(registry.AccountRecord).empty,
    };
}

fn appendTestAccount(
    allocator: std.mem.Allocator,
    reg: *registry.Registry,
    record_key: []const u8,
    email: []const u8,
    alias: []const u8,
    plan: registry.PlanType,
) !void {
    const sep = std.mem.lastIndexOf(u8, record_key, "::") orelse return error.InvalidRecordKey;
    const chatgpt_user_id = record_key[0..sep];
    const chatgpt_account_id = record_key[sep + 2 ..];
    try reg.accounts.append(allocator, .{
        .account_key = try allocator.dupe(u8, record_key),
        .chatgpt_account_id = try allocator.dupe(u8, chatgpt_account_id),
        .chatgpt_user_id = try allocator.dupe(u8, chatgpt_user_id),
        .email = try allocator.dupe(u8, email),
        .alias = try allocator.dupe(u8, alias),
        .account_name = null,
        .plan = plan,
        .auth_mode = .chatgpt,
        .created_at = 1,
        .last_used_at = null,
        .last_usage = null,
        .last_usage_at = null,
        .last_local_rollout = null,
    });
}

test "printTableRow handles long cells without underflow" {
    var buffer: [256]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);
    const widths = [_]usize{3};
    const cells = [_][]const u8{"abcdef"};
    try printTableRow(&writer, &widths, &cells);
    try writer.flush();
}

test "truncateAlloc respects max_len" {
    const out1 = try truncateAlloc("abcdef", 3);
    defer std.heap.page_allocator.free(out1);
    try std.testing.expect(out1.len == 3);
    const out2 = try truncateAlloc("abcdef", 1);
    defer std.heap.page_allocator.free(out2);
    try std.testing.expect(out2.len == 1);
}

test "formatRateLimitFullAlloc shows 100% after reset instead of dash-prefixed value" {
    const now = std.Io.Timestamp.now(app_runtime.io(), .real).toSeconds();
    const window = registry.RateLimitWindow{
        .used_percent = 100.0,
        .window_minutes = 300,
        .resets_at = now - 60,
    };

    const formatted = try formatRateLimitFullAlloc(window);
    defer std.heap.page_allocator.free(formatted);

    try std.testing.expectEqualStrings("100%", formatted);
}

test "writeAccountsTable shows zero-padded row numbers for selectable accounts" {
    const gpa = std.testing.allocator;
    var reg = makeTestRegistry();
    defer reg.deinit(gpa);

    try appendTestAccount(gpa, &reg, "user-1::acc-1", "user@example.com", "", .team);
    reg.accounts.items[0].account_name = try gpa.dupe(u8, "Als's Workspace");
    try appendTestAccount(gpa, &reg, "user-1::acc-2", "user@example.com", "", .free);

    var buffer: [2048]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);
    try writeAccountsTable(&writer, &reg, false);

    const output = writer.buffered();
    try std.testing.expect(std.mem.indexOf(u8, output, "01   Als's Workspace") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "02   Free") != null);
}

test "writeAccountsTable shows usage override statuses for failed refreshes" {
    const gpa = std.testing.allocator;
    var reg = makeTestRegistry();
    defer reg.deinit(gpa);

    try appendTestAccount(gpa, &reg, "user-1::acc-1", "user@example.com", "", .team);
    try appendTestAccount(gpa, &reg, "user-1::acc-2", "user@example.com", "", .free);

    const usage_overrides = [_]?[]const u8{ null, "403" };

    var buffer: [2048]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);
    try writeAccountsTableWithUsageOverrides(&writer, &reg, false, &usage_overrides);

    const output = writer.buffered();
    try std.testing.expect(std.mem.count(u8, output, "403") >= 2);
}

test "writeAccountsTable highlights usage override rows in red when color is enabled" {
    const gpa = std.testing.allocator;
    var reg = makeTestRegistry();
    defer reg.deinit(gpa);

    try appendTestAccount(gpa, &reg, "user-1::acc-1", "user@example.com", "", .team);
    try appendTestAccount(gpa, &reg, "user-1::acc-2", "user@example.com", "", .free);

    const usage_overrides = [_]?[]const u8{ null, "403" };

    var buffer: [4096]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);
    try writeAccountsTableWithUsageOverrides(&writer, &reg, true, &usage_overrides);

    const output = writer.buffered();
    try std.testing.expect(std.mem.indexOf(u8, output, ansi.red) != null);
}

test "writeAccountsTable prefers usage snapshot plan labels over stored auth plan" {
    const gpa = std.testing.allocator;
    var reg = makeTestRegistry();
    defer reg.deinit(gpa);

    try appendTestAccount(gpa, &reg, "user-1::acc-1", "user@example.com", "", .plus);
    reg.accounts.items[0].last_usage = .{
        .primary = null,
        .secondary = null,
        .credits = null,
        .plan_type = .team,
    };

    var buffer: [2048]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);
    try writeAccountsTable(&writer, &reg, false);

    const output = writer.buffered();
    try std.testing.expect(std.mem.indexOf(u8, output, "Business") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "Plus") == null);
}

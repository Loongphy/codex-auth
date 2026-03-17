const std = @import("std");
const builtin = @import("builtin");
const display_rows = @import("display_rows.zig");
const registry = @import("registry.zig");
const cli = @import("cli.zig");
const io_util = @import("io_util.zig");
const timefmt = @import("timefmt.zig");
const c = @cImport({
    @cInclude("time.h");
});

const ansi = struct {
    const reset = "\x1b[0m";
    const dim = "\x1b[2m";
    const green = "\x1b[32m";
};

fn colorEnabled() bool {
    return std.fs.File.stdout().isTty();
}

fn planDisplay(rec: *const registry.AccountRecord, missing: []const u8) []const u8 {
    if (registry.resolvePlan(rec)) |p| return @tagName(p);
    return missing;
}

pub fn printAccounts(allocator: std.mem.Allocator, reg: *registry.Registry, fmt: cli.OutputFormat) !void {
    switch (fmt) {
        .table => try printAccountsTable(reg),
        .json => try printAccountsJson(reg),
        .csv => try printAccountsCsv(reg),
        .compact => try printAccountsCompact(reg),
    }
    _ = allocator;
}

fn printAccountsTable(reg: *registry.Registry) !void {
    var stdout: io_util.Stdout = undefined;
    stdout.init();
    const out = stdout.out();
    const headers = [_][]const u8{ "ACCOUNT", "PLAN", "5H USAGE", "WEEKLY USAGE", "LAST ACTIVITY" };
    var widths = [_]usize{
        headers[0].len,
        headers[1].len,
        headers[2].len,
        headers[3].len,
        headers[4].len,
    };
    const now = std.time.timestamp();
    const prefix_len: usize = 2;
    const sep_len: usize = 2;

    var display = try display_rows.buildDisplayRows(std.heap.page_allocator, reg, null);
    defer display.deinit(std.heap.page_allocator);

    for (display.rows) |row| {
        const indent: usize = @as(usize, row.depth) * 2;
        widths[0] = @max(widths[0], row.account_cell.len + indent);
        if (row.account_index) |account_idx| {
            const rec = reg.accounts.items[account_idx];
            const plan = planDisplay(&rec, "-");
            const rate_5h = resolveRateWindow(rec.last_usage, 300, true);
            const rate_week = resolveRateWindow(rec.last_usage, 10080, false);
            const rate_5h_str = try formatRateLimitFullAlloc(rate_5h);
            defer std.heap.page_allocator.free(rate_5h_str);
            const rate_week_str = try formatRateLimitFullAlloc(rate_week);
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

    const use_color = colorEnabled();
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
    try out.writeAll("  ");
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

    for (display.rows) |row| {
        if (row.account_index) |account_idx| {
            const rec = reg.accounts.items[account_idx];
            const plan = planDisplay(&rec, "-");
            const rate_5h = resolveRateWindow(rec.last_usage, 300, true);
            const rate_week = resolveRateWindow(rec.last_usage, 10080, false);
            const rate_5h_str = try formatRateLimitUiAlloc(rate_5h, widths[2]);
            defer std.heap.page_allocator.free(rate_5h_str);
            const rate_week_str = try formatRateLimitUiAlloc(rate_week, widths[3]);
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
                if (row.is_active) {
                    try out.writeAll(ansi.green);
                } else {
                    try out.writeAll(ansi.dim);
                }
            }
            try out.writeAll(if (row.is_active) "* " else "  ");
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
        } else {
            const account_cell = try truncateAlloc(row.account_cell, widths[0]);
            defer std.heap.page_allocator.free(account_cell);
            if (use_color) try out.writeAll(ansi.dim);
            try out.writeAll("  ");
            try writePadded(out, account_cell, widths[0]);
            try out.writeAll("\n");
            if (use_color) try out.writeAll(ansi.reset);
        }
    }

    try out.flush();
}

fn printAccountsJson(reg: *registry.Registry) !void {
    var stdout: io_util.Stdout = undefined;
    stdout.init();
    const out = stdout.out();
    const dump = RegistryOut{
        .schema_version = reg.schema_version,
        .active_account_key = reg.active_account_key,
        .auto_switch = reg.auto_switch,
        .api = reg.api,
        .accounts = reg.accounts.items,
    };
    try std.json.Stringify.value(dump, .{ .whitespace = .indent_2 }, out);
    try out.writeAll("\n");
    try out.flush();
}

fn printAccountsCsv(reg: *registry.Registry) !void {
    var stdout: io_util.Stdout = undefined;
    stdout.init();
    const out = stdout.out();
    try out.writeAll("active,account_key,chatgpt_account_id,chatgpt_user_id,email,plan,limit_5h,limit_weekly,last_used\n");
    for (reg.accounts.items) |rec| {
        const active = if (reg.active_account_key) |k| std.mem.eql(u8, k, rec.account_key) else false;
        const email = rec.email;
        const account_key = rec.account_key;
        const chatgpt_account_id = rec.chatgpt_account_id;
        const chatgpt_user_id = rec.chatgpt_user_id;
        const plan = planDisplay(&rec, "");
        const rate_5h = resolveRateWindow(rec.last_usage, 300, true);
        const rate_week = resolveRateWindow(rec.last_usage, 10080, false);
        const rate_5h_str = try formatRateLimitStatusAlloc(rate_5h);
        defer std.heap.page_allocator.free(rate_5h_str);
        const rate_week_str = try formatRateLimitStatusAlloc(rate_week);
        defer std.heap.page_allocator.free(rate_week_str);
        const last = if (rec.last_used_at) |t| try std.fmt.allocPrint(std.heap.page_allocator, "{d}", .{t}) else "";
        defer if (rec.last_used_at != null) std.heap.page_allocator.free(last) else {};
        try out.print(
            "{s},{s},{s},{s},{s},{s},{s},{s},{s}\n",
            .{ if (active) "1" else "0", account_key, chatgpt_account_id, chatgpt_user_id, email, plan, rate_5h_str, rate_week_str, last },
        );
    }
    try out.flush();
}

fn printAccountsCompact(reg: *registry.Registry) !void {
    var stdout: io_util.Stdout = undefined;
    stdout.init();
    const out = stdout.out();
    for (reg.accounts.items) |rec| {
        const active = if (reg.active_account_key) |k| std.mem.eql(u8, k, rec.account_key) else false;
        const email = rec.email;
        const plan = planDisplay(&rec, "-");
        const rate_5h = resolveRateWindow(rec.last_usage, 300, true);
        const rate_week = resolveRateWindow(rec.last_usage, 10080, false);
        const rate_5h_str = try formatRateLimitStatusAlloc(rate_5h);
        defer std.heap.page_allocator.free(rate_5h_str);
        const rate_week_str = try formatRateLimitStatusAlloc(rate_week);
        defer std.heap.page_allocator.free(rate_week_str);
        const last = if (rec.last_used_at) |t| try formatTimestampAlloc(t) else "-";
        defer if (rec.last_used_at != null) std.heap.page_allocator.free(last) else {};
        try out.print(
            "{s}{s} ({s}) 5h:{s} week:{s} last:{s}\n",
            .{ if (active) "* " else "  ", email, plan, rate_5h_str, rate_week_str, last },
        );
    }
    try out.flush();
}

const RegistryOut = struct {
    schema_version: u32,
    active_account_key: ?[]const u8,
    auto_switch: registry.AutoSwitchConfig,
    api: registry.ApiConfig,
    accounts: []const registry.AccountRecord,
};

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

fn formatRateLimitStatusAlloc(window: ?registry.RateLimitWindow) ![]u8 {
    if (window == null) return try std.fmt.allocPrint(std.heap.page_allocator, "-", .{});
    if (window.?.resets_at == null) return try std.fmt.allocPrint(std.heap.page_allocator, "-", .{});
    const now = std.time.timestamp();
    const reset_at = window.?.resets_at.?;
    if (now >= reset_at) {
        return try std.fmt.allocPrint(std.heap.page_allocator, "100%", .{});
    }
    const remaining = remainingPercent(window.?.used_percent);
    const time_str = try formatResetTimeAlloc(reset_at, now);
    defer std.heap.page_allocator.free(time_str);
    return std.fmt.allocPrint(std.heap.page_allocator, "{d}% {s}", .{ remaining, time_str });
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
    const now = std.time.timestamp();
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
    const now = std.time.timestamp();
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
    const stdout_file = std.fs.File.stdout();
    if (!stdout_file.isTty()) return 0;

    if (comptime builtin.os.tag == .windows) {
        var info: std.os.windows.CONSOLE_SCREEN_BUFFER_INFO = undefined;
        if (std.os.windows.kernel32.GetConsoleScreenBufferInfo(stdout_file.handle, &info) == std.os.windows.FALSE) {
            return 0;
        }
        const width = @as(i32, info.srWindow.Right) - @as(i32, info.srWindow.Left) + 1;
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

fn formatTimestampAlloc(ts: i64) ![]u8 {
    if (ts < 0) return try std.fmt.allocPrint(std.heap.page_allocator, "-", .{});
    var tm: c.struct_tm = undefined;
    if (!localtimeCompat(ts, &tm)) {
        return try std.fmt.allocPrint(std.heap.page_allocator, "-", .{});
    }

    const year = @as(u32, @intCast(tm.tm_year + 1900));
    const month = @as(u32, @intCast(tm.tm_mon + 1));
    const day = @as(u32, @intCast(tm.tm_mday));
    const hour = @as(u32, @intCast(tm.tm_hour));
    const min = @as(u32, @intCast(tm.tm_min));
    const sec = @as(u32, @intCast(tm.tm_sec));

    return std.fmt.allocPrint(
        std.heap.page_allocator,
        "{d:0>4}-{d:0>2}-{d:0>2} {d:0>2}:{d:0>2}:{d:0>2}",
        .{ year, month, day, hour, min, sec },
    );
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
    const now = std.time.timestamp();
    const window = registry.RateLimitWindow{
        .used_percent = 100.0,
        .window_minutes = 300,
        .resets_at = now - 60,
    };

    const formatted = try formatRateLimitFullAlloc(window);
    defer std.heap.page_allocator.free(formatted);

    try std.testing.expectEqualStrings("100%", formatted);
}

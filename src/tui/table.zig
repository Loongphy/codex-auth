const std = @import("std");
const app_runtime = @import("../core/runtime.zig");
const builtin = @import("builtin");
const display_rows = @import("display.zig");
const table_layout = @import("../cli/table_layout.zig");
const cli_rows = @import("../cli/rows.zig");
const registry = @import("../registry/root.zig");
const io_util = @import("../core/io_util.zig");
const rate_limit = @import("rate_limit.zig");
const timefmt = @import("../time/relative.zig");
const text_width = @import("text_width.zig");

const resolveRateWindow = rate_limit.resolveRateWindow;
pub const formatRateLimitFullAlloc = rate_limit.formatRateLimitFullAlloc;

const ansi = struct {
    const reset = "\x1b[0m";
    const dim = "\x1b[2m";
    const red = "\x1b[31m";
    const green = "\x1b[32m";
    const cyan = "\x1b[36m";
};

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
    try writeAccountsTableWithUsageOverrides(out, reg, stdout.color_enabled, usage_overrides);
    try out.flush();
}

pub fn writeAccountsTable(out: *std.Io.Writer, reg: *registry.Registry, use_color: bool) !void {
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
    usage_override: ?[]const u8,
) ![]u8 {
    if (usage_override) |value| return allocator.dupe(u8, value);
    return formatRateLimitFullAlloc(allocator, window);
}

fn creditsCellAlloc(
    allocator: std.mem.Allocator,
    usage: ?registry.RateLimitSnapshot,
    usage_override: ?[]const u8,
) ![]u8 {
    if (usage_override) |value| return allocator.dupe(u8, value);
    if (usage) |snapshot| {
        if (snapshot.credits) |credits| {
            if (credits.balance) |balance| return integerCreditBalanceAlloc(allocator, balance);
            if (credits.unlimited) return allocator.dupe(u8, "unlimited");
        }
    }
    return allocator.dupe(u8, "-");
}

fn resetCreditsCellAlloc(
    allocator: std.mem.Allocator,
    usage: ?registry.RateLimitSnapshot,
    usage_override: ?[]const u8,
) ![]u8 {
    if (usage_override) |value| return allocator.dupe(u8, value);
    return cli_rows.resetCreditsCellAlloc(allocator, usage);
}

fn integerCreditBalanceAlloc(allocator: std.mem.Allocator, balance: []const u8) ![]u8 {
    // Do not round up the displayed balance (for example, 5.99 remains 5).
    const trimmed = std.mem.trim(u8, balance, " \t\r\n");
    const dot = std.mem.findScalar(u8, trimmed, '.') orelse return allocator.dupe(u8, trimmed);
    const integer_part = trimmed[0..dot];
    if (integer_part.len == 0 or
        (integer_part.len == 1 and (integer_part[0] == '+' or integer_part[0] == '-')))
    {
        return allocator.dupe(u8, "0");
    }
    return allocator.dupe(u8, integer_part);
}

pub fn writeAccountsTableWithUsageOverrides(
    out: *std.Io.Writer,
    reg: *registry.Registry,
    use_color: bool,
    usage_overrides: ?[]const ?[]const u8,
) !void {
    const cols = terminalWidth();
    return writeAccountsTableWithUsageOverridesForCols(out, reg, use_color, usage_overrides, if (cols == 0) null else cols);
}

/// Width-injectable variant: `term_cols = null` disables width handling and
/// renders content widths unchanged. Columns receiving zero width are skipped
/// entirely (header, cells, and their separators).
pub fn writeAccountsTableWithUsageOverridesForCols(
    out: *std.Io.Writer,
    reg: *registry.Registry,
    use_color: bool,
    usage_overrides: ?[]const ?[]const u8,
    term_cols: ?usize,
) !void {
    // Cell strings and display rows are render-scoped: one arena turns the
    // per-cell page_allocator mmaps (~3700 syscalls on 200 accounts) into a
    // few buffer growths and a single release. The arena grows out of a
    // stack buffer first — typical registries render without touching mmap.
    var stack_buffer: [256 * 1024]u8 = undefined;
    var sfba = std.heap.BufferFirstAllocator.init(&stack_buffer, app_runtime.scratchAllocator());
    var arena = std.heap.ArenaAllocator.init(sfba.allocator());
    defer arena.deinit();
    const cell_allocator = arena.allocator();

    const now = std.Io.Timestamp.now(app_runtime.io(), .real).toSeconds();
    var display = try display_rows.buildDisplayRows(cell_allocator, reg, null);
    defer display.deinit(cell_allocator);
    const idx_width = cli_rows.indexWidth(display.selectable_row_indices.len);
    const prefix_len: usize = 2 + idx_width + 1;
    const sep_len: usize = 2;

    // Content widths measure cells, not headers: a header outliving its data
    // can no longer starve ACCOUNT (the old 13-column "RESET CREDITS" header
    // over a one-digit count was the worst offender). Compact header ladders
    // take over below the full label.
    var content_widths = [_]usize{
        "ACCOUNT".len,
        "PLAN".len,
        "2000-01-01".len,
        2,
        "RST".len,
        "5H".len,
        "WEEKLY".len,
        "2000-01-01".len,
        "LAST".len,
    };
    for (display.rows) |row| {
        const indent: usize = @as(usize, row.depth) * 2;
        content_widths[0] = @max(content_widths[0], text_width.displayWidth(row.account_cell) + indent);
        if (row.account_index) |account_idx| {
            const rec = reg.accounts.items[account_idx];
            const plan = display_rows.displayPlan(&rec);
            const rate_5h = resolveRateWindow(rec.last_usage, 300, true);
            const rate_week = resolveRateWindow(rec.last_usage, 10080, false);
            const usage_override = usageOverrideForAccount(usage_overrides, account_idx);
            const credits_str = try creditsCellAlloc(cell_allocator, rec.last_usage, usage_override);
            defer cell_allocator.free(credits_str);
            const reset_credits_str = try resetCreditsCellAlloc(cell_allocator, rec.last_usage, usage_override);
            defer cell_allocator.free(reset_credits_str);
            const rate_5h_str = try usageCellTextAlloc(cell_allocator, rate_5h, usage_override);
            defer cell_allocator.free(rate_5h_str);
            const rate_week_str = try usageCellTextAlloc(cell_allocator, rate_week, usage_override);
            defer cell_allocator.free(rate_week_str);
            const last_str = try timefmt.formatRelativeTimeOrDashAlloc(cell_allocator, rec.last_usage_at, now);
            defer cell_allocator.free(last_str);
            const plan_expiry_str = try cli_rows.formatFutureDateAlloc(cell_allocator, rec.plan_expires_at, now);
            defer cell_allocator.free(plan_expiry_str);
            const auth_expiry_str = try cli_rows.formatTimestampAlloc(cell_allocator, rec.access_token_expires_at);
            defer cell_allocator.free(auth_expiry_str);

            const override_w: usize = if (usage_override != null) cli_rows.usage_override_max_width else std.math.maxInt(usize);
            content_widths[1] = @max(content_widths[1], plan.len);
            content_widths[2] = @max(content_widths[2], plan_expiry_str.len);
            content_widths[3] = @max(content_widths[3], @min(credits_str.len, override_w));
            content_widths[4] = @max(content_widths[4], @min(reset_credits_str.len, override_w));
            content_widths[5] = @max(content_widths[5], @min(rate_5h_str.len, override_w));
            content_widths[6] = @max(content_widths[6], @min(rate_week_str.len, override_w));
            content_widths[7] = @max(content_widths[7], auth_expiry_str.len);
            content_widths[8] = @max(content_widths[8], last_str.len);
        }
    }

    var columns: [table_layout.plain_columns.len]table_layout.ColumnSpec = undefined;
    for (table_layout.plain_columns, 0..) |id, index| {
        columns[index] = table_layout.columnSpec(id, content_widths[index]);
    }
    var widths: [table_layout.plain_columns.len]usize = @splat(0);
    table_layout.allocateColumns(.{
        .columns = &columns,
        .first_order = &table_layout.shared_first_order,
        .grow_order = &table_layout.shared_grow_order,
        .deferred_order = &table_layout.shared_deferred_order,
        .prefix_width = prefix_len,
        .separator_width = sep_len,
    }, term_cols, &widths);
    var last_visible: usize = 0;
    var visible: [table_layout.plain_columns.len]bool = undefined;
    for (widths, 0..) |width, index| {
        visible[index] = width > 0;
        if (width > 0) last_visible = index;
    }

    if (use_color) try out.writeAll(ansi.cyan);
    try writeRepeat(out, ' ', prefix_len);
    var first_visible = true;
    for (table_layout.plain_columns, 0..) |id, index| {
        if (!visible[index]) continue;
        if (!first_visible) try out.writeAll("  ");
        first_visible = false;
        const written = try table_layout.writeHeaderCell(out, id, widths[index]);
        if (index != last_visible) try writeRepeat(out, ' ', widths[index] - written);
    }
    try out.writeAll("\n");
    if (use_color) try out.writeAll(ansi.reset);

    var selectable_counter: usize = 0;
    for (display.rows) |row| {
        if (row.account_index) |account_idx| {
            const rec = reg.accounts.items[account_idx];
            const plan = display_rows.displayPlan(&rec);
            const rate_5h = resolveRateWindow(rec.last_usage, 300, true);
            const rate_week = resolveRateWindow(rec.last_usage, 10080, false);
            const usage_override = usageOverrideForAccount(usage_overrides, account_idx);
            const credits_str = try creditsCellAlloc(cell_allocator, rec.last_usage, usage_override);
            defer cell_allocator.free(credits_str);
            const reset_credits_str = try resetCreditsCellAlloc(cell_allocator, rec.last_usage, usage_override);
            defer cell_allocator.free(reset_credits_str);
            const rate_5h_str = try usageCellTextAlloc(cell_allocator, rate_5h, usage_override);
            defer cell_allocator.free(rate_5h_str);
            const rate_week_str = try usageCellTextAlloc(cell_allocator, rate_week, usage_override);
            defer cell_allocator.free(rate_week_str);
            const last = try timefmt.formatRelativeTimeOrDashAlloc(cell_allocator, rec.last_usage_at, now);
            defer cell_allocator.free(last);
            const plan_expiry = try cli_rows.formatFutureDateAlloc(cell_allocator, rec.plan_expires_at, now);
            defer cell_allocator.free(plan_expiry);
            const auth_expiry = try cli_rows.formatTimestampAlloc(cell_allocator, rec.access_token_expires_at);
            defer cell_allocator.free(auth_expiry);
            const indent: usize = @as(usize, row.depth) * 2;
            if (use_color) {
                if (row.is_active) {
                    try out.writeAll(ansi.green);
                } else if (usage_override != null) {
                    try out.writeAll(ansi.red);
                }
            }
            try out.writeAll(if (row.is_active) "* " else "  ");
            try table_layout.writeIndexAligned(out, selectable_counter + 1, idx_width);
            try out.writeAll(" ");
            const row_cells = [_][]const u8{ row.account_cell, plan, plan_expiry, credits_str, reset_credits_str, rate_5h_str, rate_week_str, auth_expiry, last };
            var row_first_visible = true;
            for (table_layout.plain_columns, 0..) |id, index| {
                if (!visible[index]) continue;
                if (!row_first_visible) try out.writeAll("  ");
                row_first_visible = false;
                const indent_to_print: usize = if (index == 0) @min(indent, widths[0]) else 0;
                if (indent_to_print != 0) try writeRepeat(out, ' ', indent_to_print);
                const written = try table_layout.writeCellFor(id, out, row_cells[index], widths[index] - indent_to_print);
                if (index != last_visible) try writeRepeat(out, ' ', widths[index] - indent_to_print - written);
            }
            try out.writeAll("\n");
            if (use_color) try out.writeAll(ansi.reset);
            selectable_counter += 1;
        } else {
            // A group header is one context line for the rows under it, not an
            // ACCOUNT cell: like the live list it indents under the marker
            // column and may use the full line width.
            if (!visible[0]) continue;
            if (use_color) try out.writeAll(ansi.dim);
            try table_layout.writeBoundedCell(out, row.account_cell, prefix_len, term_cols);
            try out.writeAll("\n");
            if (use_color) try out.writeAll(ansi.reset);
        }
    }
}
fn writeRepeat(out: *std.Io.Writer, ch: u8, count: usize) !void {
    var i: usize = 0;
    while (i < count) : (i += 1) {
        try out.writeByte(ch);
    }
}

fn terminalWidth() usize {
    const stdout_file = std.Io.File.stdout();
    if (!(stdout_file.isTty(app_runtime.io()) catch false)) return 0;

    if (comptime builtin.target.os.tag == .windows) {
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

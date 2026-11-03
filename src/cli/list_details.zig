const std = @import("std");
const registry = @import("../registry/root.zig");
const rows = @import("rows.zig");
const style = @import("style.zig");
const table_layout = @import("table_layout.zig");
const app_runtime = @import("../core/runtime.zig");

/// The borderless live list separates columns with whitespace only.
const separator_width: usize = 2;
const column_count = table_layout.list_detail_columns.len;

pub fn computeWidths(
    number_width: usize,
    widths: rows.SwitchWidths,
    max_cols: ?usize,
) [column_count]usize {
    const columns = [_]table_layout.ColumnSpec{
        .{
            .id = .number,
            .content_width = number_width,
            .target_width = number_width,
            .min_width = number_width,
        },
        table_layout.columnSpec(.account, @max(widths.email, "ACCOUNT".len)),
        table_layout.columnSpec(.plan, @max(widths.plan, "PLAN".len)),
        // Content widths come from cells, not headers: a header that
        // outlives its data no longer starves ACCOUNT (the old 13-column
        // "RESET CREDITS" header over a one-digit count was the worst
        // offender).
        table_layout.columnSpec(.plan_expire, "2000-01-01".len),
        table_layout.columnSpec(.reset_credits, "0 (exp 00-00)".len),
        table_layout.columnSpec(.rate_5h, @max(widths.rate_5h, "5H".len)),
        table_layout.columnSpec(.rate_week, @max(widths.rate_week, "WEEKLY".len)),
        table_layout.columnSpec(.auth_expire, "2000-01-01 00:00".len),
        table_layout.columnSpec(.last, @max(widths.last, "LAST".len)),
    };
    var bounded = [_]usize{0} ** column_count;
    table_layout.allocateColumns(.{
        .columns = &columns,
        .first_order = &table_layout.shared_first_order,
        .grow_order = &table_layout.shared_grow_order,
        .deferred_order = &table_layout.shared_deferred_order,
        .prefix_width = 0,
        .separator_width = separator_width,
    }, max_cols, &bounded);
    return bounded;
}

pub fn writeHeader(writer: *style.StyledWriter, widths: [column_count]usize) !void {
    try writer.writeStyle(style.role.heading);
    const last_visible = lastVisibleIndex(widths);
    var wrote_any = false;
    for (table_layout.list_detail_columns, 0..) |id, index| {
        if (widths[index] == 0) continue;
        if (wrote_any) try writer.out.writeAll("  ");
        wrote_any = true;
        const written = try table_layout.writeHeaderCell(writer.out, id, widths[index]);
        if (index != last_visible) try writer.out.splatByteAll(' ', widths[index] - written);
    }
    try writer.reset();
    try writer.out.writeByte('\n');
}

fn lastVisibleIndex(widths: [column_count]usize) usize {
    var last: usize = 0;
    for (widths, 0..) |width, index| {
        if (width > 0) last = index;
    }
    return last;
}

/// Group header line for the live body: the shared email in the dim role the
/// pickers give group rows, indented under the ACCOUNT column. It is not a
/// data row — no number, no marker — but it is one body line for viewport and
/// rail-splice bookkeeping, so `render.liveLineIndexForDataIndex` counts it.
/// The line always exists once the caller decides to emit it, even when the
/// terminal is too narrow for the text: a skipped line would desync the
/// rendered-line index basis.
pub fn writeGroupHeader(
    writer: *style.StyledWriter,
    email: []const u8,
    indent: usize,
    max_cols: ?usize,
) !void {
    try writer.writeStyle(style.role.secondary);
    try table_layout.writeBoundedCell(writer.out, email, indent, max_cols);
    try writer.reset();
    try writer.out.writeByte('\n');
}

/// `row_style` comes from the caller: deriving it from the marker glyph here
/// would leave the `>` cursor row unstyled, which is exactly the ambiguity
/// the picker row styles already avoid.
pub fn write(
    allocator: std.mem.Allocator,
    writer: *style.StyledWriter,
    account: registry.AccountRecord,
    row: anytype,
    widths: [column_count]usize,
    row_style: []const u8,
) !void {
    const now = std.Io.Timestamp.now(app_runtime.io(), .real).toSeconds();
    const token_expiry = try rows.formatTimestampAlloc(allocator, account.access_token_expires_at);
    defer allocator.free(token_expiry);
    const plan_expiry = try rows.formatFutureDateAlloc(allocator, account.plan_expires_at, now);
    defer allocator.free(plan_expiry);
    const reset_full = try rows.resetCreditsCellAlloc(allocator, account.last_usage);
    defer allocator.free(reset_full);

    const values = [_][]const u8{
        row.number,
        row.account,
        row.plan,
        plan_expiry,
        reset_full,
        row.rate_5h,
        row.rate_week,
        token_expiry,
        row.last,
    };
    const last_visible = lastVisibleIndex(widths);
    try writer.writeStyle(row_style);
    var wrote_any = false;
    for (table_layout.list_detail_columns, 0..) |id, index| {
        if (widths[index] == 0) continue;
        if (wrote_any) try writer.out.writeAll("  ");
        wrote_any = true;
        // Group members indent inside the account column — the same depth*2
        // the pickers and the plain table give them; the column width already
        // reserves it (rows.zig counts depth*2 into widths.email), so every
        // later column keeps its alignment and only the label text shrinks.
        const indent: usize = if (id == .account) @min(@as(usize, row.depth) * 2, widths[index]) else 0;
        try writer.out.splatByteAll(' ', indent);
        const written = indent + try table_layout.writeCellFor(id, writer.out, values[index], widths[index] - indent);
        if (index != last_visible) try writer.out.splatByteAll(' ', widths[index] - written);
    }
    try writer.reset();
    try writer.out.writeByte('\n');
}


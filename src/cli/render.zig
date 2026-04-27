const std = @import("std");
const registry = @import("../registry/root.zig");
const row_data = @import("rows.zig");
const style = @import("style.zig");
const table_layout = @import("table_layout.zig");
const tui_mod = @import("tui.zig");

pub const SwitchWidths = row_data.SwitchWidths;
pub const indexWidth = row_data.indexWidth;
pub const LiveListViewport = table_layout.LiveListViewport;
const SwitchRow = row_data.SwitchRow;
const writeTuiPromptLine = tui_mod.writeTuiPromptLine;
const writeSwitchTuiFooterBounded = tui_mod.writeSwitchTuiFooterBounded;
const writeListTuiFooterBounded = tui_mod.writeListTuiFooterBounded;
const writeRemoveTuiFooterBounded = tui_mod.writeRemoveTuiFooterBounded;
const writeTuiLineBounded = tui_mod.writeTuiLineBounded;
const writeStyledTuiLineBounded = tui_mod.writeStyledTuiLineBounded;

fn activeRowMarker(is_cursor: bool, is_active: bool) []const u8 {
    return if (is_cursor) "> " else if (is_active) "* " else "  ";
}

pub fn renderSwitchScreen(
    out: *std.Io.Writer,
    reg: *registry.Registry,
    rows: []const SwitchRow,
    idx_width: usize,
    widths: SwitchWidths,
    selected: ?usize,
    use_color: bool,
    status_line: []const u8,
    action_line: []const u8,
    number_input: []const u8,
) !void {
    try renderSwitchScreenViewport(
        out,
        reg,
        rows,
        idx_width,
        widths,
        selected,
        use_color,
        status_line,
        action_line,
        number_input,
        .{},
    );
}

pub fn renderSwitchScreenViewport(
    out: *std.Io.Writer,
    reg: *registry.Registry,
    rows: []const SwitchRow,
    idx_width: usize,
    widths: SwitchWidths,
    selected: ?usize,
    use_color: bool,
    status_line: []const u8,
    action_line: []const u8,
    number_input: []const u8,
    viewport: LiveListViewport,
) !void {
    try writeTuiPromptLine(out, "Select account to activate:", number_input);
    try renderSwitchListViewport(out, reg, rows, idx_width, widths, selected, use_color, viewport);
    if (status_line.len != 0) {
        try writeLiveStatusLine(out, status_line, use_color, viewport.max_cols);
    }
    try writeSwitchTuiFooterBounded(out, use_color, viewport.max_cols);
    if (action_line.len != 0) {
        try writeStyledTuiLineBounded(out, if (use_color) actionLineStyle(action_line) else "", action_line, viewport.max_cols);
    }
}

pub fn renderListScreen(
    out: *std.Io.Writer,
    reg: *registry.Registry,
    rows: []const SwitchRow,
    idx_width: usize,
    widths: SwitchWidths,
    use_color: bool,
    status_line: []const u8,
) !void {
    try renderListScreenViewport(
        out,
        reg,
        rows,
        idx_width,
        widths,
        use_color,
        status_line,
        .{},
    );
}

pub fn renderListScreenViewport(
    out: *std.Io.Writer,
    reg: *registry.Registry,
    rows: []const SwitchRow,
    idx_width: usize,
    widths: SwitchWidths,
    use_color: bool,
    status_line: []const u8,
    viewport: LiveListViewport,
) !void {
    try renderSwitchListViewport(out, reg, rows, idx_width, widths, null, use_color, viewport);
    if (status_line.len != 0) {
        try writeLiveStatusLine(out, status_line, use_color, viewport.max_cols);
    }
    try writeListTuiFooterBounded(out, use_color, viewport.max_cols);
}

pub fn renderRemoveScreen(
    out: *std.Io.Writer,
    reg: *registry.Registry,
    rows: []const SwitchRow,
    idx_width: usize,
    widths: SwitchWidths,
    cursor: ?usize,
    checked: []const bool,
    use_color: bool,
    status_line: []const u8,
    action_line: []const u8,
    number_input: []const u8,
) !void {
    try renderRemoveScreenViewport(
        out,
        reg,
        rows,
        idx_width,
        widths,
        cursor,
        checked,
        use_color,
        status_line,
        action_line,
        number_input,
        .{},
    );
}

pub fn renderRemoveScreenViewport(
    out: *std.Io.Writer,
    reg: *registry.Registry,
    rows: []const SwitchRow,
    idx_width: usize,
    widths: SwitchWidths,
    cursor: ?usize,
    checked: []const bool,
    use_color: bool,
    status_line: []const u8,
    action_line: []const u8,
    number_input: []const u8,
    viewport: LiveListViewport,
) !void {
    try writeTuiPromptLine(out, "Select accounts to delete:", number_input);
    try renderRemoveListViewport(out, reg, rows, idx_width, widths, cursor, checked, use_color, viewport);
    if (status_line.len != 0) {
        try writeLiveStatusLine(out, status_line, use_color, viewport.max_cols);
    }
    try writeRemoveTuiFooterBounded(out, use_color, viewport.max_cols);
    if (action_line.len != 0) {
        try writeStyledTuiLineBounded(out, if (use_color) actionLineStyle(action_line) else "", action_line, viewport.max_cols);
    }
}

pub fn renderSwitchList(
    out: *std.Io.Writer,
    reg: *registry.Registry,
    rows: []const SwitchRow,
    idx_width: usize,
    widths: SwitchWidths,
    cursor: ?usize,
    use_color: bool,
) !void {
    try renderSwitchListViewport(out, reg, rows, idx_width, widths, cursor, use_color, .{});
}

pub fn renderSwitchListViewport(
    out: *std.Io.Writer,
    reg: *registry.Registry,
    rows: []const SwitchRow,
    idx_width: usize,
    widths: SwitchWidths,
    cursor: ?usize,
    use_color: bool,
    viewport: LiveListViewport,
) !void {
    _ = reg;
    const prefix_width = 2 + idx_width + 1;
    const table = table_layout.accountTable(table_layout.boundWidths(widths, prefix_width, viewport.max_cols), prefix_width);
    try table.writeHeader(out, use_color);

    const visible = visibleRowRange(rows.len, viewport);
    var displayed_counter = dataRowCount(rows[0..visible.start]);
    for (rows[visible.start..visible.end]) |row| {
        if (row.is_header) {
            try table.writeGroupRow(out, row.account, use_color);
            continue;
        }

        const is_cursor = cursor != null and cursor.? == displayed_counter;
        const is_active = row.is_active;
        var prefix_buf: [64]u8 = undefined;
        const prefix = liveTableIndexPrefix(
            &prefix_buf,
            activeRowMarker(is_cursor, is_active),
            displayed_counter + 1,
            idx_width,
        );
        try table.writeDataRow(
            out,
            prefix,
            liveAccountCells(row),
            if (use_color) switchRowStyle(row, is_cursor, is_active) else "",
        );
        displayed_counter += 1;
    }
}

pub fn renderRemoveList(
    out: *std.Io.Writer,
    reg: *registry.Registry,
    rows: []const SwitchRow,
    idx_width: usize,
    widths: SwitchWidths,
    cursor: ?usize,
    checked: []const bool,
    use_color: bool,
) !void {
    try renderRemoveListViewport(out, reg, rows, idx_width, widths, cursor, checked, use_color, .{});
}

pub fn renderRemoveListViewport(
    out: *std.Io.Writer,
    reg: *registry.Registry,
    rows: []const SwitchRow,
    idx_width: usize,
    widths: SwitchWidths,
    cursor: ?usize,
    checked: []const bool,
    use_color: bool,
    viewport: LiveListViewport,
) !void {
    _ = reg;
    const checkbox_width: usize = 3;
    const prefix_width = 2 + checkbox_width + 1 + idx_width + 1;
    const table = table_layout.accountTable(table_layout.boundWidths(widths, prefix_width, viewport.max_cols), prefix_width);
    try table.writeHeader(out, use_color);

    const visible = visibleRowRange(rows.len, viewport);
    var selectable_counter = dataRowCount(rows[0..visible.start]);
    for (rows[visible.start..visible.end]) |row| {
        if (row.is_header) {
            try table.writeGroupRow(out, row.account, use_color);
            continue;
        }

        const is_cursor = cursor != null and cursor.? == selectable_counter;
        const is_checked = checked[selectable_counter];
        const is_active = row.is_active;
        var prefix_buf: [64]u8 = undefined;
        const prefix = liveTableRemovePrefix(
            &prefix_buf,
            activeRowMarker(is_cursor, is_active),
            is_checked,
            selectable_counter + 1,
            idx_width,
        );
        try table.writeDataRow(
            out,
            prefix,
            liveAccountCells(row),
            if (use_color) removeRowStyle(row, is_cursor, is_checked, is_active) else "",
        );
        selectable_counter += 1;
    }
}

pub fn clampLiveViewportStart(row_count: usize, max_rows: usize, current_start: usize) usize {
    if (max_rows == 0 or row_count <= max_rows) return 0;
    return @min(current_start, row_count - max_rows);
}

pub fn liveViewportStartForDisplayIndex(
    rows: []const SwitchRow,
    selected_display_idx: ?usize,
    max_rows: usize,
    current_start: usize,
) usize {
    var start = clampLiveViewportStart(rows.len, max_rows, current_start);
    if (max_rows == 0 or rows.len <= max_rows) return start;

    const selected_row_idx = if (selected_display_idx) |display_idx|
        rowIndexForDisplayIndex(rows, display_idx) orelse return start
    else
        return start;

    if (selected_row_idx < start) {
        start = selected_row_idx;
    } else if (selected_row_idx >= start + max_rows) {
        start = selected_row_idx - max_rows + 1;
    }
    return clampLiveViewportStart(rows.len, max_rows, start);
}

const VisibleRowRange = struct {
    start: usize,
    end: usize,
};

fn visibleRowRange(row_count: usize, viewport: LiveListViewport) VisibleRowRange {
    const max_rows = viewport.max_rows orelse row_count;
    const start = clampLiveViewportStart(row_count, max_rows, viewport.start_row);
    return .{
        .start = start,
        .end = if (max_rows == 0) start else @min(row_count, start + max_rows),
    };
}

fn rowIndexForDisplayIndex(rows: []const SwitchRow, selected_display_idx: usize) ?usize {
    var display_idx: usize = 0;
    for (rows, 0..) |row, row_idx| {
        if (row.is_header) continue;
        if (display_idx == selected_display_idx) return row_idx;
        display_idx += 1;
    }
    return null;
}

fn dataRowCount(rows: []const SwitchRow) usize {
    var count: usize = 0;
    for (rows) |row| {
        if (!row.is_header) count += 1;
    }
    return count;
}

fn liveAccountCells(row: SwitchRow) [table_layout.column_count]table_layout.Cell {
    return .{
        .{ .text = row.account, .indent = @as(usize, row.depth) * 2 },
        .{ .text = row.plan },
        .{ .text = row.rate_5h },
        .{ .text = row.rate_week },
        .{ .text = row.last },
    };
}

fn switchRowStyle(row: SwitchRow, is_cursor: bool, is_active: bool) []const u8 {
    if (is_active) return style.ansi.green;
    if (is_cursor) return style.ansi.green;
    if (row.has_error) return style.ansi.red;
    return "";
}

fn removeRowStyle(row: SwitchRow, is_cursor: bool, is_checked: bool, is_active: bool) []const u8 {
    if (is_active) return style.ansi.green;
    if (is_cursor) return style.ansi.green;
    if (row.has_error) return style.ansi.red;
    if (is_checked) return style.ansi.green;
    return "";
}

fn actionLineStyle(action_line: []const u8) []const u8 {
    if (std.mem.startsWith(u8, action_line, "Switch failed:") or
        std.mem.startsWith(u8, action_line, "Auto-switch failed:") or
        std.mem.startsWith(u8, action_line, "Delete failed:"))
    {
        return style.ansi.red;
    }
    return style.ansi.green;
}

fn writeLiveStatusLine(out: *std.Io.Writer, status_line: []const u8, use_color: bool, max_cols: ?usize) !void {
    try writeStyledTuiLineBounded(out, if (use_color) style.ansi.cyan else "", status_line, max_cols);
}

fn liveTableIndexPrefix(buf: []u8, marker: []const u8, idx: usize, idx_width: usize) []const u8 {
    var writer: std.Io.Writer = .fixed(buf);
    writer.writeAll(marker) catch unreachable;
    writeIndexPadded(&writer, idx, idx_width) catch unreachable;
    writer.writeAll(" ") catch unreachable;
    return writer.buffered();
}

fn liveTableRemovePrefix(
    buf: []u8,
    marker: []const u8,
    is_checked: bool,
    idx: usize,
    idx_width: usize,
) []const u8 {
    var writer: std.Io.Writer = .fixed(buf);
    writer.writeAll(marker) catch unreachable;
    writer.writeAll(if (is_checked) "[x]" else "[ ]") catch unreachable;
    writer.writeAll(" ") catch unreachable;
    writeIndexPadded(&writer, idx, idx_width) catch unreachable;
    writer.writeAll(" ") catch unreachable;
    return writer.buffered();
}

fn writeIndexPadded(out: *std.Io.Writer, idx: usize, width: usize) !void {
    var buf: [16]u8 = undefined;
    const idx_str = std.fmt.bufPrint(&buf, "{d}", .{idx}) catch "0";
    if (idx_str.len < width) {
        try out.splatByteAll('0', width - idx_str.len);
    }
    try out.writeAll(idx_str);
}

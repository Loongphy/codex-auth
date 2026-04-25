const std = @import("std");
const registry = @import("../registry/root.zig");
const row_data = @import("rows.zig");
const style = @import("style.zig");
const tui_mod = @import("tui.zig");

pub const SwitchWidths = row_data.SwitchWidths;
pub const indexWidth = row_data.indexWidth;
const SwitchRow = row_data.SwitchRow;
const writeTuiPromptLine = tui_mod.writeTuiPromptLine;
const writeSwitchTuiFooter = tui_mod.writeSwitchTuiFooter;
const writeListTuiFooter = tui_mod.writeListTuiFooter;
const writeRemoveTuiFooter = tui_mod.writeRemoveTuiFooter;

pub const LiveListViewport = struct {
    start_row: usize = 0,
    max_rows: ?usize = null,
};

const live_table_column_count = 5;
const LiveTableColumn = struct {
    header: []const u8,
    width: usize,
};
const LiveTableCell = struct {
    text: []const u8,
    indent: usize = 0,
};
const LiveTable = struct {
    columns: [live_table_column_count]LiveTableColumn,
    prefix_width: usize,

    fn writeHeader(self: *const LiveTable, out: *std.Io.Writer) !void {
        try writeRepeat(out, ' ', self.prefix_width);
        try self.writeCells(out, &.{
            .{ .text = self.columns[0].header },
            .{ .text = self.columns[1].header },
            .{ .text = self.columns[2].header },
            .{ .text = self.columns[3].header },
            .{ .text = self.columns[4].header },
        });
        try out.writeAll("\n");
    }

    fn writeGroupRow(self: *const LiveTable, out: *std.Io.Writer, account: []const u8, use_color: bool) !void {
        if (use_color) try out.writeAll(style.ansi.dim);
        try writeRepeat(out, ' ', self.prefix_width);
        try writeTruncatedPadded(out, account, self.columns[0].width);
        try out.writeAll("\n");
        if (use_color) try out.writeAll(style.ansi.reset);
    }

    fn writeDataRow(
        self: *const LiveTable,
        out: *std.Io.Writer,
        prefix: []const u8,
        cells: [live_table_column_count]LiveTableCell,
        ansi_style: []const u8,
    ) !void {
        if (ansi_style.len != 0) try out.writeAll(ansi_style);
        try out.writeAll(prefix);
        if (prefix.len < self.prefix_width) {
            try writeRepeat(out, ' ', self.prefix_width - prefix.len);
        }
        try self.writeCells(out, &cells);
        try out.writeAll("\n");
        if (ansi_style.len != 0) try out.writeAll(style.ansi.reset);
    }

    fn writeCells(
        self: *const LiveTable,
        out: *std.Io.Writer,
        cells: *const [live_table_column_count]LiveTableCell,
    ) !void {
        for (self.columns, 0..) |column, i| {
            if (i > 0) try out.writeAll("  ");
            const indent = @min(cells[i].indent, column.width);
            try writeRepeat(out, ' ', indent);
            try writeTruncatedPadded(out, cells[i].text, column.width - indent);
        }
    }
};

fn activeRowMarker(is_cursor_or_selected: bool, is_active: bool) []const u8 {
    return if (is_cursor_or_selected) "> " else if (is_active) "* " else "  ";
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
    try out.writeAll("\n");
    try renderSwitchListViewport(out, reg, rows, idx_width, widths, selected, use_color, viewport);
    try out.writeAll("\n");
    if (status_line.len != 0) {
        if (use_color) try out.writeAll(style.ansi.dim);
        try out.writeAll(status_line);
        try out.writeAll("\n");
        if (use_color) try out.writeAll(style.ansi.reset);
    }
    try writeSwitchTuiFooter(out, use_color);
    if (action_line.len != 0) {
        if (use_color) try out.writeAll(style.ansi.bold_green);
        try out.writeAll(action_line);
        try out.writeAll("\n");
        if (use_color) try out.writeAll(style.ansi.reset);
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
    try out.writeAll("Live account list:\n\n");
    try renderSwitchListViewport(out, reg, rows, idx_width, widths, null, use_color, viewport);
    try out.writeAll("\n");
    if (status_line.len != 0) {
        if (use_color) try out.writeAll(style.ansi.dim);
        try out.writeAll(status_line);
        try out.writeAll("\n");
        if (use_color) try out.writeAll(style.ansi.reset);
    }
    try writeListTuiFooter(out, use_color);
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
    try out.writeAll("\n");
    try renderRemoveListViewport(out, reg, rows, idx_width, widths, cursor, checked, use_color, viewport);
    try out.writeAll("\n");
    if (status_line.len != 0) {
        if (use_color) try out.writeAll(style.ansi.dim);
        try out.writeAll(status_line);
        try out.writeAll("\n");
        if (use_color) try out.writeAll(style.ansi.reset);
    }
    try writeRemoveTuiFooter(out, use_color);
    if (action_line.len != 0) {
        if (use_color) try out.writeAll(style.ansi.bold_green);
        try out.writeAll(action_line);
        try out.writeAll("\n");
        if (use_color) try out.writeAll(style.ansi.reset);
    }
}

pub fn renderSwitchList(
    out: *std.Io.Writer,
    reg: *registry.Registry,
    rows: []const SwitchRow,
    idx_width: usize,
    widths: SwitchWidths,
    selected: ?usize,
    use_color: bool,
) !void {
    try renderSwitchListViewport(out, reg, rows, idx_width, widths, selected, use_color, .{});
}

pub fn renderSwitchListViewport(
    out: *std.Io.Writer,
    reg: *registry.Registry,
    rows: []const SwitchRow,
    idx_width: usize,
    widths: SwitchWidths,
    selected: ?usize,
    use_color: bool,
    viewport: LiveListViewport,
) !void {
    _ = reg;
    const table = liveAccountsTable(widths, 2 + idx_width + 1);
    try table.writeHeader(out);

    const visible = visibleRowRange(rows.len, viewport);
    var displayed_counter = dataRowCount(rows[0..visible.start]);
    for (rows[visible.start..visible.end]) |row| {
        if (row.is_header) {
            try table.writeGroupRow(out, row.account, use_color);
            continue;
        }

        const is_selected = selected != null and selected.? == displayed_counter;
        const is_active = row.is_active;
        var prefix_buf: [64]u8 = undefined;
        const prefix = liveTableIndexPrefix(
            &prefix_buf,
            activeRowMarker(is_selected, is_active),
            displayed_counter + 1,
            idx_width,
        );
        try table.writeDataRow(
            out,
            prefix,
            liveAccountCells(row),
            if (use_color) switchRowStyle(row, is_selected, is_active) else "",
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
    const table = liveAccountsTable(widths, 2 + checkbox_width + 1 + idx_width + 1);
    try table.writeHeader(out);

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

fn liveAccountsTable(widths: SwitchWidths, prefix_width: usize) LiveTable {
    return .{
        .columns = .{
            .{ .header = "ACCOUNT", .width = widths.email },
            .{ .header = "PLAN", .width = widths.plan },
            .{ .header = "5H", .width = widths.rate_5h },
            .{ .header = "WEEKLY", .width = widths.rate_week },
            .{ .header = "LAST", .width = widths.last },
        },
        .prefix_width = prefix_width,
    };
}

fn liveAccountCells(row: SwitchRow) [live_table_column_count]LiveTableCell {
    return .{
        .{ .text = row.account, .indent = @as(usize, row.depth) * 2 },
        .{ .text = row.plan },
        .{ .text = row.rate_5h },
        .{ .text = row.rate_week },
        .{ .text = row.last },
    };
}

fn switchRowStyle(row: SwitchRow, is_selected: bool, is_active: bool) []const u8 {
    if (row.has_error) {
        return if (is_selected or is_active) style.ansi.bold_red else style.ansi.red;
    }
    if (is_selected) return style.ansi.bold_green;
    if (is_active) return style.ansi.green;
    return style.ansi.dim;
}

fn removeRowStyle(row: SwitchRow, is_cursor: bool, is_checked: bool, is_active: bool) []const u8 {
    if (row.has_error) {
        return if (is_cursor or is_checked or is_active) style.ansi.bold_red else style.ansi.red;
    }
    if (is_cursor) return style.ansi.bold_green;
    if (is_checked or is_active) return style.ansi.green;
    return style.ansi.dim;
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

fn writePadded(out: *std.Io.Writer, value: []const u8, width: usize) !void {
    try out.writeAll(value);
    if (value.len >= width) return;
    try out.splatByteAll(' ', width - value.len);
}

fn writeTruncatedPadded(out: *std.Io.Writer, value: []const u8, width: usize) !void {
    if (width == 0) return;
    if (value.len <= width) {
        try writePadded(out, value, width);
        return;
    }
    if (width == 1) {
        try out.writeAll(".");
        return;
    }
    try out.writeAll(value[0 .. width - 1]);
    try out.writeAll(".");
}

fn writeRepeat(out: *std.Io.Writer, ch: u8, count: usize) !void {
    try out.splatByteAll(ch, count);
}

const std = @import("std");
const registry = @import("../registry/root.zig");
const row_data = @import("rows.zig");
const style = @import("style.zig");
const table_layout = @import("table_layout.zig");
const tui_mod = @import("tui.zig");

pub const SwitchWidths = row_data.SwitchWidths;
pub const indexWidth = row_data.indexWidth;
pub const LiveListViewport = table_layout.LiveListViewport;
pub const StyledWriter = style.StyledWriter;
const SwitchRow = row_data.SwitchRow;
const writeTuiPromptLineBounded = tui_mod.writeTuiPromptLineBounded;
const writeSwitchTuiFooterBounded = tui_mod.writeSwitchTuiFooterBounded;
const writeListTuiFooterBounded = tui_mod.writeListTuiFooterBounded;
const writeRemoveTuiFooterBounded = tui_mod.writeRemoveTuiFooterBounded;
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
    var writer = style.StyledWriter.init(out, use_color);
    try renderSwitchScreenViewport(
        &writer,
        reg,
        rows,
        idx_width,
        widths,
        selected,
        status_line,
        action_line,
        number_input,
        .{},
    );
}

pub fn renderSwitchScreenViewport(
    writer: *style.StyledWriter,
    reg: *registry.Registry,
    rows: []const SwitchRow,
    idx_width: usize,
    widths: SwitchWidths,
    selected: ?usize,
    status_line: []const u8,
    action_line: []const u8,
    number_input: []const u8,
    viewport: LiveListViewport,
) !void {
    try writeTuiPromptLineBounded(writer.out, "Select account to activate:", number_input, viewport.max_cols);
    try renderSwitchListViewport(writer, reg, rows, idx_width, widths, selected, viewport);
    if (status_line.len != 0) {
        try writeLiveStatusLine(writer.out, status_line, writer.color_enabled, viewport.max_cols);
    }
    try writeSwitchTuiFooterBounded(writer.out, writer.color_enabled, viewport.max_cols);
    if (action_line.len != 0) {
        try writeStyledTuiLineBounded(writer.out, if (writer.color_enabled) actionLineStyle(action_line) else "", action_line, viewport.max_cols);
    }
}

pub fn renderListScreenViewport(
    writer: *style.StyledWriter,
    reg: *registry.Registry,
    rows: []const SwitchRow,
    idx_width: usize,
    widths: SwitchWidths,
    status_line: []const u8,
    viewport: LiveListViewport,
) !void {
    try renderSwitchListViewport(writer, reg, rows, idx_width, widths, null, viewport);
    if (status_line.len != 0) {
        try writeLiveStatusLine(writer.out, status_line, writer.color_enabled, viewport.max_cols);
    }
    try writeListTuiFooterBounded(writer.out, writer.color_enabled, viewport.max_cols);
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
    var writer = style.StyledWriter.init(out, use_color);
    try renderRemoveScreenViewport(
        &writer,
        reg,
        rows,
        idx_width,
        widths,
        cursor,
        checked,
        status_line,
        action_line,
        number_input,
        .{},
    );
}

pub fn renderRemoveScreenViewport(
    writer: *style.StyledWriter,
    reg: *registry.Registry,
    rows: []const SwitchRow,
    idx_width: usize,
    widths: SwitchWidths,
    cursor: ?usize,
    checked: []const bool,
    status_line: []const u8,
    action_line: []const u8,
    number_input: []const u8,
    viewport: LiveListViewport,
) !void {
    try writeTuiPromptLineBounded(writer.out, "Select accounts to delete:", number_input, viewport.max_cols);
    try renderRemoveListViewport(writer, reg, rows, idx_width, widths, cursor, checked, viewport);
    if (status_line.len != 0) {
        try writeLiveStatusLine(writer.out, status_line, writer.color_enabled, viewport.max_cols);
    }
    try writeRemoveTuiFooterBounded(writer.out, writer.color_enabled, viewport.max_cols);
    if (action_line.len != 0) {
        try writeStyledTuiLineBounded(writer.out, if (writer.color_enabled) actionLineStyle(action_line) else "", action_line, viewport.max_cols);
    }
}

pub fn renderSwitchList(
    writer: *style.StyledWriter,
    reg: *registry.Registry,
    rows: []const SwitchRow,
    idx_width: usize,
    widths: SwitchWidths,
    cursor: ?usize,
) !void {
    try renderSwitchListViewport(writer, reg, rows, idx_width, widths, cursor, .{});
}

pub fn renderSwitchListViewport(
    writer: *style.StyledWriter,
    reg: *registry.Registry,
    rows: []const SwitchRow,
    idx_width: usize,
    widths: SwitchWidths,
    cursor: ?usize,
    viewport: LiveListViewport,
) !void {
    _ = reg;
    const prefix_width = 2 + idx_width + 1;
    const table = table_layout.accountTableForSwitch(widths, prefix_width, viewport.max_cols);
    try table.writeHeader(writer);

    const visible = visibleRowRange(rows.len, viewport);
    var displayed_counter = dataRowCount(rows[0..visible.start]);
    for (rows[visible.start..visible.end]) |row| {
        try writeSwitchRow(writer, &table, row, idx_width, cursor, &displayed_counter);
    }
}

pub fn renderRemoveList(
    writer: *style.StyledWriter,
    reg: *registry.Registry,
    rows: []const SwitchRow,
    idx_width: usize,
    widths: SwitchWidths,
    cursor: ?usize,
    checked: []const bool,
) !void {
    try renderRemoveListViewport(writer, reg, rows, idx_width, widths, cursor, checked, .{});
}

pub fn renderRemoveListViewport(
    writer: *style.StyledWriter,
    reg: *registry.Registry,
    rows: []const SwitchRow,
    idx_width: usize,
    widths: SwitchWidths,
    cursor: ?usize,
    checked: []const bool,
    viewport: LiveListViewport,
) !void {
    _ = reg;
    const checkbox_width: usize = 3;
    const prefix_width = 2 + checkbox_width + 1 + idx_width + 1;
    const table = table_layout.accountTableForSwitch(widths, prefix_width, viewport.max_cols);
    try table.writeHeader(writer);

    const visible = visibleRowRange(rows.len, viewport);
    var selectable_counter = dataRowCount(rows[0..visible.start]);
    for (rows[visible.start..visible.end]) |row| {
        if (row.is_header) {
            try table.writeGroupRow(writer, row.account);
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
            writer,
            prefix,
            liveAccountCells(row),
            removeRowStyle(row, is_cursor, is_checked, is_active),
        );
        selectable_counter += 1;
    }
}

pub fn clampLiveViewportStart(row_count: usize, max_rows: usize, current_start: usize) usize {
    if (max_rows == 0 or row_count <= max_rows) return 0;
    return @min(current_start, row_count - max_rows);
}

/// Viewport start that keeps the selected display index visible on the screens
/// that render group header rows (switch, remove).
///
/// Both the clamp and the resolved row index use the `rows.items` basis, which
/// matches those screens one line per row. Do not feed it the live list rail
/// cursor: that one counts body lines without header rows, and is followed with
/// `live_tui.followViewportStart` instead.
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

/// Maps a selectable display index to its index in `rows`.
///
/// Index basis: `rows.items`, for the views that treat rows one-to-one with
/// screen lines (`renderSwitchScreen`, `renderRemoveScreen`). The live list
/// numbers only its data rows while also drawing unnumbered group header
/// lines, so its rail cursor must use `liveRowIndexForDataIndex` instead.
fn rowIndexForDisplayIndex(rows: []const SwitchRow, selected_display_idx: usize) ?usize {
    var display_idx: usize = 0;
    for (rows, 0..) |row, row_idx| {
        if (row.is_header) continue;
        if (display_idx == selected_display_idx) return row_idx;
        display_idx += 1;
    }
    return null;
}

/// Number of selectable rows in a `rows` prefix, on the same `rows.items` basis
/// as `rowIndexForDisplayIndex`. Not the live list body line count, which is
/// `liveDataRowCount`.
fn dataRowCount(rows: []const SwitchRow) usize {
    var count: usize = 0;
    for (rows) |row| {
        if (!row.is_header) count += 1;
    }
    return count;
}

fn liveAccountCells(row: SwitchRow) [table_layout.live_column_count]table_layout.Cell {
    return .{
        .{ .text = row.account, .indent = @as(usize, row.depth) * 2 },
        .{ .text = row.plan },
        .{ .text = row.rate_5h },
        .{ .text = row.rate_week },
        .{ .text = row.last },
    };
}

// Error stays red under the cursor, same as the live list: the `>` glyph
// alone marks focus, and hiding the alarm would invite acting on a broken row.
fn switchRowStyle(row: SwitchRow, is_cursor: bool, is_active: bool) []const u8 {
    if (row.has_error) return style.ansi.red;
    if (is_active or is_cursor) return style.ansi.green;
    return "";
}

fn removeRowStyle(row: SwitchRow, is_cursor: bool, is_checked: bool, is_active: bool) []const u8 {
    if (row.has_error) return style.ansi.red;
    if (is_active or is_cursor or is_checked) return style.ansi.green;
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
    try table_layout.writeIndexAligned(out, idx, width);
}

fn writeSwitchRow(
    writer: *style.StyledWriter,
    table: *const table_layout.LiveTable,
    row: SwitchRow,
    idx_width: usize,
    cursor: ?usize,
    displayed_counter: *usize,
) !void {
    if (row.is_header) {
        try table.writeGroupRow(writer, row.account);
        return;
    }

    const is_cursor = cursor != null and cursor.? == displayed_counter.*;
    const is_active = row.is_active;
    var prefix_buf: [64]u8 = undefined;
    const prefix = liveTableIndexPrefix(
        &prefix_buf,
        activeRowMarker(is_cursor, is_active),
        displayed_counter.* + 1,
        idx_width,
    );
    try table.writeDataRow(
        writer,
        prefix,
        liveAccountCells(row),
        switchRowStyle(row, is_cursor, is_active),
    );
    displayed_counter.* += 1;
}

/// Single source of truth for which rows the live list body renders as
/// numbered data rows. Selection and the rail cursor index those data rows,
/// so mapping and rendering share one predicate. Views that draw group header
/// rows as selectable-style rows (switch, remove) use the `rows.items`-based
/// helpers above instead; the two bases are not interchangeable.
pub fn isRenderedLiveRow(row: SwitchRow, account_count: usize) bool {
    if (row.is_header) return false;
    const account_idx = row.account_index orelse return false;
    return account_idx < account_count;
}

/// Number of data rows `renderListBody` emits for these rows. Group header
/// lines are extra body lines on top of this count; see
/// `liveLineIndexForDataIndex` for the rendered-line basis.
pub fn liveDataRowCount(rows: []const SwitchRow, account_count: usize) usize {
    var count: usize = 0;
    for (rows) |row| {
        if (isRenderedLiveRow(row, account_count)) count += 1;
    }
    return count;
}

/// Maps a rendered data-row index back to its index in `rows`, skipping the
/// rows `renderListBody` does not number (group headers and stale indices).
pub fn liveRowIndexForDataIndex(rows: []const SwitchRow, account_count: usize, data_index: usize) ?usize {
    var rendered: usize = 0;
    for (rows, 0..) |row, row_idx| {
        if (!isRenderedLiveRow(row, account_count)) continue;
        if (rendered == data_index) return row_idx;
        rendered += 1;
    }
    return null;
}

/// Reverse of `liveRowIndexForDataIndex`, on the same rendered basis: the
/// data-row index of `account_key`. The rail cursor uses it to open on the
/// active account's row, the same starting point the pickers' initial
/// selection takes.
pub fn liveDataIndexForAccountKey(rows: []const SwitchRow, reg: *const registry.Registry, account_key: []const u8) ?usize {
    var data_index: usize = 0;
    for (rows) |row| {
        if (!isRenderedLiveRow(row, reg.accounts.items.len)) continue;
        const account_idx = row.account_index.?;
        if (std.mem.eql(u8, reg.accounts.items[account_idx].account_key, account_key)) return data_index;
        data_index += 1;
    }
    return null;
}

/// Rendered body-line index (0-based, column header excluded) of a data-row
/// index: the group header lines `renderListBody` emits ahead of a group's
/// first rendered child shift everything below them. The rail's splice point
/// and viewport-follow span are body lines, so they go through this mapping;
/// the selection state itself stays on the `liveDataRowCount` basis.
pub fn liveLineIndexForDataIndex(
    rows: []const SwitchRow,
    account_count: usize,
    data_index: usize,
) ?usize {
    var data: usize = 0;
    var line: usize = 0;
    var pending_header = false;
    for (rows) |row| {
        if (row.is_header) {
            pending_header = true;
            continue;
        }
        if (!isRenderedLiveRow(row, account_count)) continue;
        // The header only counts once a rendered child actually follows it,
        // matching renderListBody's emission rule; a group whose rows all went
        // stale leaves no orphan line behind.
        if (pending_header) {
            line += 1;
            pending_header = false;
        }
        if (data == data_index) return line;
        data += 1;
        line += 1;
    }
    return null;
}

/// Render the compact live account table.
/// `cursor` is an optional data-row index on the `liveDataRowCount` basis
/// (0-based, group header lines excluded); the matching row draws `>` instead
/// of the `*`/space marker, so the row `Enter` acts on is always visible.
/// `cursor_anchored` keeps that row's green but yields the `>` glyph to a
/// nested cursor: while the reset-credit rail is open the card highlight owns
/// `>`, so two cursor glyphs never compete on screen.
/// A group header draws one unnumbered dim line ahead of its first rendered
/// child so grouped rows keep their shared email in view.
pub fn renderListBody(
    allocator: std.mem.Allocator,
    writer: *style.StyledWriter,
    reg: *const registry.Registry,
    rows: []const SwitchRow,
    idx_width: usize,
    widths: SwitchWidths,
    max_cols: ?usize,
    cursor: ?usize,
    cursor_anchored: bool,
) !void {
    const details = @import("list_details.zig");

    const number_width = idx_width + 2;
    const column_widths = details.computeWidths(number_width, widths, max_cols);
    try details.writeHeader(writer, column_widths);
    var displayed_counter: usize = 0;
    var pending_header: ?[]const u8 = null;
    for (rows) |row| {
        if (row.is_header) {
            pending_header = row.account;
            continue;
        }
        if (!isRenderedLiveRow(row, reg.accounts.items.len)) continue;
        if (pending_header) |email| {
            pending_header = null;
            try details.writeGroupHeader(writer, email, column_widths[0] + 2, max_cols);
        }
        const idx = row.account_index.?;
        const is_cursor = cursor != null and cursor.? == displayed_counter;
        displayed_counter += 1;
        const account = reg.accounts.items[idx];
        var number_buf: [32]u8 = undefined;
        const marker: u8 = if (is_cursor)
            (if (cursor_anchored) ' ' else '>')
        else if (row.is_active) '*' else ' ';
        var number_len: usize = 0;
        number_buf[number_len] = marker;
        number_len += 1;
        number_buf[number_len] = ' ';
        number_len += 1;
        var digit_buf: [16]u8 = undefined;
        const digits = std.fmt.bufPrint(&digit_buf, "{d}", .{displayed_counter}) catch "0";
        var pad = idx_width - @min(idx_width, digits.len);
        while (pad > 0) : (pad -= 1) {
            number_buf[number_len] = ' ';
            number_len += 1;
        }
        @memcpy(number_buf[number_len .. number_len + digits.len], digits);
        number_len += digits.len;
        const number = number_buf[0..number_len];
        // Style precedence deliberately differs from the marker's: an error row
        // stays red under the cursor (the glyph already marks the focus, the
        // alarm must not be hidden), while cursor and active share the green the
        // switch/remove pickers give both — the glyph, not the color, says which.
        const row_style: []const u8 = if (row.has_error)
            style.role.error_text
        else if (is_cursor or row.is_active)
            style.role.success
        else
            "";
        try details.write(allocator, writer, account, .{
            .number = number,
            .account = row.account,
            .plan = row.plan,
            .rate_5h = row.rate_5h,
            .rate_week = row.rate_week,
            .last = row.last,
        }, column_widths, row_style);
    }
}

pub fn renderListBodyViewport(
    writer: *style.StyledWriter,
    body: []const u8,
    status_line: []const u8,
    viewport: LiveListViewport,
) !void {
    try renderListBodyViewportWithFooter(writer, body, status_line, viewport, null);
}

/// Like `renderListBodyViewport`, but `footer_text` replaces the default list
/// footer when the caller has a context-specific key legend (for example while
/// the reset credits rail owns `j`/`k`).
pub fn renderListBodyViewportWithFooter(
    writer: *style.StyledWriter,
    body: []const u8,
    status_line: []const u8,
    viewport: LiveListViewport,
    footer_text: ?[]const u8,
) !void {
    var lines = std.mem.splitScalar(u8, body, '\n');
    if (lines.next()) |header| {
        try writer.print("{s}\n", .{header});
    }
    var index: usize = 0;
    while (lines.next()) |line| : (index += 1) {
        if (index < viewport.start_row) continue;
        if (viewport.max_rows) |limit| {
            if (index - viewport.start_row >= limit) break;
        }
        if (line.len != 0) try writer.print("{s}\n", .{line});
    }
    if (status_line.len != 0) {
        try writeLiveStatusLine(writer.out, status_line, writer.color_enabled, viewport.max_cols);
    }
    if (footer_text) |text| {
        // The rail's own key legend is secondary: the credit rows and the
        // status line stay the focus while the user is consuming a credit.
        try writeStyledTuiLineBounded(writer.out, if (writer.color_enabled) style.role.secondary else "", text, viewport.max_cols);
    } else {
        try writeListTuiFooterBounded(writer.out, writer.color_enabled, viewport.max_cols);
    }
}

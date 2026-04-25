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
    try writeTuiPromptLine(out, "Select account to activate:", number_input);
    try out.writeAll("\n");
    try renderSwitchList(out, reg, rows, idx_width, widths, selected, use_color);
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
    try out.writeAll("Live account list:\n\n");
    try renderSwitchList(out, reg, rows, idx_width, widths, null, use_color);
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
    try writeTuiPromptLine(out, "Select accounts to delete:", number_input);
    try out.writeAll("\n");
    try renderRemoveList(out, reg, rows, idx_width, widths, cursor, checked, use_color);
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
    _ = reg;
    const prefix = 2 + idx_width + 1;
    var pad: usize = 0;
    while (pad < prefix) : (pad += 1) {
        try out.writeAll(" ");
    }
    try writePadded(out, "ACCOUNT", widths.email);
    try out.writeAll("  ");
    try writePadded(out, "PLAN", widths.plan);
    try out.writeAll("  ");
    try writePadded(out, "5H", widths.rate_5h);
    try out.writeAll("  ");
    try writePadded(out, "WEEKLY", widths.rate_week);
    try out.writeAll("  ");
    try writePadded(out, "LAST", widths.last);
    try out.writeAll("\n");

    var displayed_counter: usize = 0;
    for (rows) |row| {
        if (row.is_header) {
            if (use_color) try out.writeAll(style.ansi.dim);
            try out.writeAll("  ");
            var pad_header: usize = 0;
            while (pad_header < idx_width + 1) : (pad_header += 1) {
                try out.writeAll(" ");
            }
            try writeTruncatedPadded(out, row.account, widths.email);
            try out.writeAll("\n");
            if (use_color) try out.writeAll(style.ansi.reset);
            continue;
        }

        const is_selected = selected != null and selected.? == displayed_counter;
        const is_active = row.is_active;
        if (use_color) {
            if (row.has_error) {
                if (is_selected or is_active) {
                    try out.writeAll(style.ansi.bold_red);
                } else {
                    try out.writeAll(style.ansi.red);
                }
            } else if (is_selected) {
                try out.writeAll(style.ansi.bold_green);
            } else if (is_active) {
                try out.writeAll(style.ansi.green);
            } else {
                try out.writeAll(style.ansi.dim);
            }
        }
        try out.writeAll(activeRowMarker(is_selected, is_active));
        try writeIndexPadded(out, displayed_counter + 1, idx_width);
        try out.writeAll(" ");
        const indent: usize = @as(usize, row.depth) * 2;
        const indent_to_print: usize = @min(indent, widths.email);
        try writeRepeat(out, ' ', indent_to_print);
        try writeTruncatedPadded(out, row.account, widths.email - indent_to_print);
        try out.writeAll("  ");
        try writeTruncatedPadded(out, row.plan, widths.plan);
        try out.writeAll("  ");
        try writeTruncatedPadded(out, row.rate_5h, widths.rate_5h);
        try out.writeAll("  ");
        try writeTruncatedPadded(out, row.rate_week, widths.rate_week);
        try out.writeAll("  ");
        try writeTruncatedPadded(out, row.last, widths.last);
        try out.writeAll("\n");
        if (use_color) try out.writeAll(style.ansi.reset);
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
    _ = reg;
    const checkbox_width: usize = 3;
    const prefix = 2 + checkbox_width + 1 + idx_width + 1;
    var pad: usize = 0;
    while (pad < prefix) : (pad += 1) {
        try out.writeAll(" ");
    }
    try writePadded(out, "ACCOUNT", widths.email);
    try out.writeAll("  ");
    try writePadded(out, "PLAN", widths.plan);
    try out.writeAll("  ");
    try writePadded(out, "5H", widths.rate_5h);
    try out.writeAll("  ");
    try writePadded(out, "WEEKLY", widths.rate_week);
    try out.writeAll("  ");
    try writePadded(out, "LAST", widths.last);
    try out.writeAll("\n");

    var selectable_counter: usize = 0;
    for (rows) |row| {
        if (row.is_header) {
            if (use_color) try out.writeAll(style.ansi.dim);
            try out.writeAll("  ");
            var pad_header: usize = 0;
            while (pad_header < checkbox_width + 1 + idx_width + 1) : (pad_header += 1) {
                try out.writeAll(" ");
            }
            try writeTruncatedPadded(out, row.account, widths.email);
            try out.writeAll("\n");
            if (use_color) try out.writeAll(style.ansi.reset);
            continue;
        }

        const is_cursor = cursor != null and cursor.? == selectable_counter;
        const is_checked = checked[selectable_counter];
        const is_active = row.is_active;
        if (use_color) {
            if (row.has_error) {
                if (is_cursor or is_checked or is_active) {
                    try out.writeAll(style.ansi.bold_red);
                } else {
                    try out.writeAll(style.ansi.red);
                }
            } else if (is_cursor) {
                try out.writeAll(style.ansi.bold_green);
            } else if (is_checked or is_active) {
                try out.writeAll(style.ansi.green);
            } else {
                try out.writeAll(style.ansi.dim);
            }
        }
        try out.writeAll(activeRowMarker(is_cursor, is_active));
        try out.writeAll(if (is_checked) "[x]" else "[ ]");
        try out.writeAll(" ");
        try writeIndexPadded(out, selectable_counter + 1, idx_width);
        try out.writeAll(" ");
        const indent: usize = @as(usize, row.depth) * 2;
        const indent_to_print: usize = @min(indent, widths.email);
        try writeRepeat(out, ' ', indent_to_print);
        try writeTruncatedPadded(out, row.account, widths.email - indent_to_print);
        try out.writeAll("  ");
        try writeTruncatedPadded(out, row.plan, widths.plan);
        try out.writeAll("  ");
        try writeTruncatedPadded(out, row.rate_5h, widths.rate_5h);
        try out.writeAll("  ");
        try writeTruncatedPadded(out, row.rate_week, widths.rate_week);
        try out.writeAll("  ");
        try writeTruncatedPadded(out, row.last, widths.last);
        try out.writeAll("\n");
        if (use_color) try out.writeAll(style.ansi.reset);
        selectable_counter += 1;
    }
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

fn writePadded(out: *std.Io.Writer, value: []const u8, width: usize) !void {
    try out.writeAll(value);
    if (value.len >= width) return;
    var i: usize = 0;
    const pad = width - value.len;
    while (i < pad) : (i += 1) {
        try out.writeAll(" ");
    }
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
    var i: usize = 0;
    while (i < count) : (i += 1) {
        try out.writeByte(ch);
    }
}

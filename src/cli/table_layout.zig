const std = @import("std");
const row_data = @import("rows.zig");
const style = @import("style.zig");
const text_width = @import("../tui/text_width.zig");

pub const SwitchWidths = row_data.SwitchWidths;

pub const LiveListViewport = struct {
    start_row: usize = 0,
    max_rows: ?usize = null,
    max_cols: ?usize = null,
};

pub const live_column_count = 5;
const live_account_ident_width: usize = 10;
const account_min_width: usize = 2;
const live_account_suffix_min_width: usize = 10;
const live_account_suffix_min_len: usize = 3;
const live_account_prefix_min_len: usize = 6;

const LiveTableColumn = struct {
    id: ColumnId,
    width: usize,
};

pub const Cell = struct {
    text: []const u8,
    indent: usize = 0,
};

/// Semantic identity of a responsive table column. Visual order is supplied
/// separately, so views such as `list` and `list --live` can keep their own
/// column order while sharing one allocation strategy.
pub const ColumnId = enum {
    number,
    account,
    plan,
    credits,
    reset_credits,
    rate_5h,
    rate_week,
    last,
    auth_expire,
    plan_expire,
};

pub const ColumnSpec = struct {
    id: ColumnId,
    content_width: usize,
    target_width: usize,
    min_width: usize,
    allow_partial: bool = false,
};

pub const ColumnLayout = struct {
    columns: []const ColumnSpec,
    first_order: []const ColumnId,
    grow_order: []const ColumnId,
    deferred_order: []const ColumnId,
    prefix_width: usize,
    separator_width: usize,
};

pub const LiveTable = struct {
    columns: [live_column_count]LiveTableColumn,
    prefix_width: usize,
    /// Terminal width the table renders into; group rows may span the full
    /// line even though their text stays left-aligned under ACCOUNT.
    max_cols: ?usize = null,

    pub fn writeHeader(self: *const LiveTable, writer: *style.StyledWriter) !void {
        try writer.writeStyle(style.role.status);
        try writeRepeat(writer.out, ' ', self.prefix_width);
        var wrote_any = false;
        for (self.columns, 0..) |column, i| {
            if (column.width == 0) continue;
            if (wrote_any) try writer.out.writeAll("  ");
            wrote_any = true;
            const written = try writeHeaderCell(writer.out, column.id, column.width);
            if (i != lastVisibleIndex(&self.columns)) {
                try writeRepeat(writer.out, ' ', column.width - written);
            }
        }
        try writer.reset();
        try writer.writeAll("\n");
    }

    pub fn writeGroupRow(self: *const LiveTable, writer: *style.StyledWriter, account: []const u8) !void {
        if (self.columns[0].width == 0) return;
        try writer.writeStyle(style.role.secondary);
        // A group row is a context line, not an ACCOUNT cell: it may use the
        // full line width like the plain list, and never pads to the column.
        try writeBoundedCell(writer.out, account, self.prefix_width, self.max_cols);
        try writer.reset();
        try writer.writeAll("\n");
    }

    pub fn writeDataRow(
        self: *const LiveTable,
        writer: *style.StyledWriter,
        prefix: []const u8,
        cells: [live_column_count]Cell,
        ansi_style: []const u8,
    ) !void {
        try writer.writeStyle(ansi_style);
        try writer.writeAll(prefix);
        if (prefix.len < self.prefix_width) {
            try writeRepeat(writer.out, ' ', self.prefix_width - prefix.len);
        }
        try self.writeCells(writer.out, &cells);
        if (ansi_style.len != 0) try writer.reset();
        try writer.writeAll("\n");
    }

    fn writeCells(
        self: *const LiveTable,
        out: *std.Io.Writer,
        cells: *const [live_column_count]Cell,
    ) !void {
        const last_visible = lastVisibleIndex(&self.columns);
        var wrote_any = false;
        for (self.columns, 0..) |column, i| {
            if (column.width == 0) continue;
            if (wrote_any) try out.writeAll("  ");
            wrote_any = true;
            const indent = @min(cells[i].indent, column.width);
            try writeRepeat(out, ' ', indent);
            const width = column.width - indent;
            const written = try writeCellFor(column.id, out, cells[i].text, width);
            if (i != last_visible) try writeRepeat(out, ' ', width - written);
        }
    }
};

fn lastVisibleIndex(columns: []const LiveTableColumn) usize {
    var last: usize = 0;
    for (columns, 0..) |column, i| {
        if (column.width > 0) last = i;
    }
    return last;
}

pub fn accountTable(widths: [live_column_count]usize, prefix_width: usize, max_cols: ?usize) LiveTable {
    var columns: [live_column_count]LiveTableColumn = undefined;
    for (switch_columns, 0..) |id, i| {
        columns[i] = .{ .id = id, .width = widths[i] };
    }
    return .{
        .columns = columns,
        .prefix_width = prefix_width,
        .max_cols = max_cols,
    };
}

pub const switch_columns = [_]ColumnId{ .account, .plan, .rate_5h, .rate_week, .last };

/// Shared priority for every view. A view simply skips columns it does not
/// support (content width 0). Keep this single list as the source of truth so
/// `list` and `list --live` cannot drift apart.
pub const shared_first_order = [_]ColumnId{
    .number,
    .account,
    .rate_5h,
    .rate_week,
    .plan,
    .reset_credits,
    .credits,
};
pub const shared_grow_order = [_]ColumnId{
    .rate_5h,
    .rate_week,
    .plan,
    .reset_credits,
    .credits,
};
/// Deferred columns are admitted left to right once core columns have grown:
/// the subscription expiry first (the only forward-looking business date),
/// then recency, then the auto-refreshing access-token expiry — the
/// lowest-value and widest detail, so it is also the first detail hidden.
pub const shared_deferred_order = [_]ColumnId{ .plan_expire, .last, .auth_expire };

pub fn accountTableForSwitch(widths: SwitchWidths, prefix_width: usize, max_cols: ?usize) LiveTable {
    const source_widths = [_]usize{ widths.email, widths.plan, widths.rate_5h, widths.rate_week, widths.last };
    var columns: [switch_columns.len]ColumnSpec = undefined;
    for (switch_columns, 0..) |id, index| {
        columns[index] = columnSpec(id, source_widths[index]);
    }
    var bounded: [live_column_count]usize = @splat(0);
    allocateColumns(.{
        .columns = &columns,
        .first_order = &shared_first_order,
        .grow_order = &shared_grow_order,
        .deferred_order = &shared_deferred_order,
        .prefix_width = prefix_width,
        .separator_width = 2,
    }, max_cols, &bounded);
    return accountTable(bounded, prefix_width, max_cols);
}

pub const plain_columns = [_]ColumnId{ .account, .plan, .plan_expire, .credits, .reset_credits, .rate_5h, .rate_week, .auth_expire, .last };

pub const list_detail_columns = [_]ColumnId{ .number, .account, .plan, .plan_expire, .reset_credits, .rate_5h, .rate_week, .auth_expire, .last };

/// Header text for a column at `width` display columns. Each header falls
/// back through a compact ladder so a narrow column still names itself:
/// `TOKEN EXPIRE` → `TOKEN EXP` → `TOKEN` → `TK`, `RESETS` → `RESET` → `RST`
/// → `R`. Widths below a rung truncate through `writeHeaderCell`.
pub fn headerFor(id: ColumnId, width: usize) []const u8 {
    return switch (id) {
        .number => "",
        .account => "ACCOUNT",
        .plan => "PLAN",
        .plan_expire => if (width >= 11)
            "PLAN EXPIRE"
        else if (width >= 8)
            "PLAN EXP"
        else if (width >= 4)
            "PLAN"
        else if (width >= 2)
            "PE"
        else
            "P",
        .credits => if (width >= 7) "CREDITS" else if (width >= 2) "CR" else "C",
        .reset_credits => if (width >= 6)
            "RESETS"
        else if (width >= 5)
            "RESET"
        else if (width >= 3)
            "RST"
        else
            "R",
        .rate_5h => "5H",
        .rate_week => "WEEKLY",
        .auth_expire => if (width >= 12)
            "TOKEN EXPIRE"
        else if (width >= 9)
            "TOKEN EXP"
        else if (width >= 5)
            "TOKEN"
        else if (width >= 2)
            "TK"
        else
            "T",
        .last => if (width >= 13) "LAST ACTIVITY" else "LAST",
    };
}

/// Header cell writer: headers only ever shrink by prefix truncation — the
/// account suffix split and the tiered data-cell forms would be unreadable.
/// Returns the written display width; callers pad between columns.
pub fn writeHeaderCell(out: *std.Io.Writer, id: ColumnId, width: usize) !usize {
    if (width == 0) return 0;
    return writeTruncated(out, headerFor(id, width), width);
}

/// Data cell writer, width-aware: each column id picks a compact variant of
/// `text` that still fits `width` display columns before falling back to a
/// `.`-terminated prefix. Returns the written display width; callers pad
/// between columns and leave the last visible column unpadded.
pub fn writeCellFor(id: ColumnId, out: *std.Io.Writer, text: []const u8, width: usize) !usize {
    if (width == 0) return 0;
    return switch (id) {
        .account => writeAccountCell(out, text, width),
        .rate_5h, .rate_week => writeUsageCell(out, text, width),
        .plan_expire, .auth_expire => writeDateCell(out, text, width),
        .last => writeLastCell(out, text, width),
        .credits => writeCreditsCell(out, text, width),
        .reset_credits => writeResetCell(out, text, width),
        else => writeTruncated(out, text, width),
    };
}

/// Writes the row number right-aligned inside `width` columns: ` 7` / `10`.
/// Plain and live numbered rows share this so their prefixes line up.
pub fn writeIndexAligned(out: *std.Io.Writer, index: usize, width: usize) !void {
    var buf: [16]u8 = undefined;
    const digits = std.fmt.bufPrint(&buf, "{d}", .{index}) catch "0";
    if (digits.len < width) try out.splatByteAll(' ', width - digits.len);
    try out.writeAll(digits);
}

/// Writes `text` truncated to `width` display columns (prefix plus `.` when
/// it does not fit) and returns the written width — `width` when truncating,
/// the display width of `text` otherwise.
fn writeTruncated(out: *std.Io.Writer, text: []const u8, width: usize) !usize {
    const measured = text_width.displayWidth(text);
    if (measured <= width) {
        try out.writeAll(text);
        return measured;
    }
    if (width == 1) {
        try out.writeAll(".");
        return 1;
    }
    try out.writeAll(text[0..text_width.prefixByteLength(text, width - 1)]);
    try out.writeAll(".");
    return width;
}

/// Usage cells read `N% (HH:MM on D Mon)`, `N% (HH:MM)` or a bare label such
/// as `FileNotFound`. Narrow widths first drop the clock part
/// (`N% (D Mon)`), then the parenthetical entirely (`N%`).
fn writeUsageCell(out: *std.Io.Writer, text: []const u8, width: usize) !usize {
    const measured = text_width.displayWidth(text);
    if (measured <= width) {
        try out.writeAll(text);
        return measured;
    }
    if (std.mem.find(u8, text, " (")) |paren| {
        if (std.mem.find(u8, text[paren..], " on ")) |on| {
            // After " on " the date keeps the closing `)`, so
            // `N% (HH:MM on D Mon)` reassembles as `N% (` + `D Mon)`.
            const head = text[0..paren];
            const date = text[paren + on + 4 ..];
            const head_w = text_width.displayWidth(head);
            const date_w = text_width.displayWidth(date);
            if (head_w + 2 + date_w <= width) {
                try out.writeAll(head);
                try out.writeAll(" (");
                try out.writeAll(date);
                return head_w + 2 + date_w;
            }
        }
        const head_w = text_width.displayWidth(text[0..paren]);
        if (head_w <= width) {
            try out.writeAll(text[0..paren]);
            return head_w;
        }
    }
    return writeTruncated(out, text, width);
}

/// Datetime cells read `YYYY-MM-DD HH:MM`; a width that cannot fit the time
/// shows the date alone rather than a mid-date cut like `2027-01-1`.
fn writeDateCell(out: *std.Io.Writer, text: []const u8, width: usize) !usize {
    const measured = text_width.displayWidth(text);
    if (measured <= width) {
        try out.writeAll(text);
        return measured;
    }
    if (std.mem.findScalar(u8, text, ' ')) |space| {
        const date = text[0..space];
        if (date.len == 10 and std.ascii.isDigit(date[0]) and width >= 10) {
            try out.writeAll(date);
            return 10;
        }
    }
    return writeTruncated(out, text, width);
}

/// `Nd ago`/`Nh ago`/`Nm ago` drop the ` ago` suffix rather than cutting it
/// mid-word (`30d .`); `Now` and `-` always fit.
fn writeLastCell(out: *std.Io.Writer, text: []const u8, width: usize) !usize {
    const measured = text_width.displayWidth(text);
    if (measured <= width) {
        try out.writeAll(text);
        return measured;
    }
    if (std.mem.endsWith(u8, text, " ago")) {
        const short = text[0 .. text.len - 4];
        const short_w = text_width.displayWidth(short);
        if (short_w <= width) {
            try out.writeAll(short);
            return short_w;
        }
    }
    return writeTruncated(out, text, width);
}

/// `unlimited` compacts to `inf` below its natural width; counts and `-`
/// fit as they are.
fn writeCreditsCell(out: *std.Io.Writer, text: []const u8, width: usize) !usize {
    if (std.mem.eql(u8, text, "unlimited") and text_width.displayWidth(text) > width) {
        return writeTruncated(out, "inf", width);
    }
    return writeTruncated(out, text, width);
}

/// `N (exp MM-DD)` degrades to the bare count, keeping the reset balance.
fn writeResetCell(out: *std.Io.Writer, text: []const u8, width: usize) !usize {
    const measured = text_width.displayWidth(text);
    if (measured <= width) {
        try out.writeAll(text);
        return measured;
    }
    if (std.mem.find(u8, text, " (")) |paren| {
        const head_w = text_width.displayWidth(text[0..paren]);
        if (head_w <= width) {
            try out.writeAll(text[0..paren]);
            return head_w;
        }
    }
    return writeTruncated(out, text, width);
}

fn writeAccountCell(out: *std.Io.Writer, text: []const u8, width: usize) !usize {
    const measured = text_width.displayWidth(text);
    if (measured <= width) {
        try out.writeAll(text);
        return measured;
    }
    if (width < live_account_suffix_min_width) {
        return writeTruncated(out, text, width);
    }
    const max_suffix = width - live_account_prefix_min_len - 1;
    if (max_suffix < live_account_suffix_min_len) {
        return writeTruncated(out, text, width);
    }
    const suffix_len = @min(max_suffix, @max(live_account_suffix_min_len, measured - 1 - live_account_prefix_min_len));
    const suffix_start = text_width.suffixStart(text, suffix_len);
    // A suffix that opens with the truncation dot (`acct01` + `.com)`) stands
    // in for the separator itself; the freed column goes to the prefix.
    const suffix_has_dot = text[suffix_start] == '.';
    const prefix_len = width - suffix_len - @intFromBool(!suffix_has_dot);
    try out.writeAll(text[0..text_width.prefixByteLength(text, prefix_len)]);
    if (!suffix_has_dot) try out.writeAll(".");
    try out.writeAll(text[suffix_start..]);
    return width;
}

pub fn defaultTargetWidth(id: ColumnId) usize {
    return switch (id) {
        .number => 4,
        .account => live_account_ident_width,
        .plan => "PLAN".len,
        .credits => 2,
        .reset_credits => 2,
        .rate_5h => @max(4, "5H".len),
        .rate_week => "WEEKLY".len,
        .last => 4,
        .auth_expire => 10,
        .plan_expire => 10,
    };
}

pub fn columnSpec(id: ColumnId, content_width: usize) ColumnSpec {
    const target = defaultTargetWidth(id);
    return .{
        .id = id,
        .content_width = content_width,
        .target_width = target,
        .min_width = if (id == .account) account_min_width else target,
        .allow_partial = id == .account,
    };
}

pub fn allocateColumns(layout: ColumnLayout, max_cols: ?usize, widths: []usize) void {
    @memset(widths, 0);
    if (widths.len != layout.columns.len) return;

    if (max_cols == null) {
        for (layout.columns, 0..) |column, index| widths[index] = column.content_width;
        return;
    }

    const cols = max_cols.?;
    if (cols <= layout.prefix_width) return;

    var remaining = cols - layout.prefix_width;
    var visible_count: usize = 0;

    for (layout.first_order) |id| {
        const index = columnIndex(layout.columns, id) orelse continue;
        const column = layout.columns[index];
        if (column.content_width == 0) continue;

        const target = @min(column.content_width, column.target_width);
        if (target == 0) continue;

        const separator = if (visible_count == 0) 0 else layout.separator_width;

        if (column.allow_partial) {
            if (remaining < column.min_width + separator) break;
            const width = @min(target, remaining - separator);
            if (width < column.min_width) break;
            widths[index] = width;
            remaining -= width + separator;
            visible_count += 1;
            continue;
        }

        if (remaining < target + separator) break;
        widths[index] = target;
        remaining -= target + separator;
        visible_count += 1;
    }

    for (layout.grow_order) |id| {
        const index = columnIndex(layout.columns, id) orelse continue;
        if (widths[index] == 0) continue;
        growBoundedWidth(&remaining, &widths[index], layout.columns[index].content_width);
    }

    // Deferred columns are admitted only after all normal columns have grown.
    // They still require their target width, so they never become dot-only
    // cells; if the target does not fit, the column stays hidden.
    for (layout.deferred_order) |id| {
        const index = columnIndex(layout.columns, id) orelse continue;
        if (widths[index] != 0) continue;
        const column = layout.columns[index];
        if (column.content_width == 0) continue;
        const target = @min(column.content_width, column.target_width);
        if (target == 0) continue;
        const separator = if (visible_count == 0) 0 else layout.separator_width;
        if (remaining < target + separator) break;
        widths[index] = target;
        remaining -= target + separator;
        visible_count += 1;
        growBoundedWidth(&remaining, &widths[index], column.content_width);
    }

    // ACCOUNT identity is useful but approximate: give every other column,
    // including deferred columns, a chance before expanding it. A long account
    // label therefore cannot squeeze AUTH/PLAN expiry or LAST out of the table.
    if (columnIndex(layout.columns, .account)) |index| {
        if (widths[index] != 0) {
            growBoundedWidth(&remaining, &widths[index], layout.columns[index].content_width);
        }
    }
}

fn columnIndex(columns: []const ColumnSpec, id: ColumnId) ?usize {
    for (columns, 0..) |column, index| {
        if (column.id == id) return index;
    }
    return null;
}

fn growBoundedWidth(remaining: *usize, current: *usize, target: usize) void {
    if (current.* >= target) return;
    const amount = @min(remaining.*, target - current.*);
    current.* += amount;
    remaining.* -= amount;
}

pub fn writeTruncatedPadded(out: *std.Io.Writer, value: []const u8, width: usize) !void {
    if (width == 0) return;
    const written = try writeTruncated(out, value, width);
    try writeRepeat(out, ' ', width - written);
}

/// Writes `indent` spaces then `text`, bounded to `max_cols` display columns
/// with a `...` tail. Group header rows use this so a long shared email may
/// span the line instead of fighting the ACCOUNT column for width.
pub fn writeBoundedCell(out: *std.Io.Writer, text: []const u8, indent: usize, max_cols: ?usize) !void {
    try writeRepeat(out, ' ', indent);
    if (max_cols) |cols| {
        const budget = cols -| indent;
        if (text_width.displayWidth(text) <= budget) {
            try out.writeAll(text);
        } else if (budget > 3) {
            try out.writeAll(text[0..text_width.prefixByteLength(text, budget - 3)]);
            try out.writeAll("...");
        }
        return;
    }
    try out.writeAll(text);
}

fn writeRepeat(out: *std.Io.Writer, ch: u8, count: usize) !void {
    try out.splatByteAll(ch, count);
}

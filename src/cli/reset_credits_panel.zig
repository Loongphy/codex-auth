const std = @import("std");
const registry = @import("../registry/root.zig");
const rows = @import("rows.zig");

const available_status = "available";

pub const AvailableCard = struct {
    id: []const u8,
    title: ?[]const u8,
    expires_at: ?[]const u8,
    epoch: ?i64,
};

/// Available (unconsumed) cards for one account, sorted by expiry ascending
/// (no-expiry last). `consumed_ids` filters cards already used in this session.
pub fn collectAvailable(
    allocator: std.mem.Allocator,
    account: *const registry.AccountRecord,
    consumed_ids: []const []const u8,
) ![]AvailableCard {
    var cards: std.ArrayList(AvailableCard) = .empty;
    errdefer cards.deinit(allocator);

    const usage = account.last_usage orelse return cards.toOwnedSlice(allocator);
    const details = usage.reset_credit orelse return cards.toOwnedSlice(allocator);

    for (details) |credit| {
        if (!std.mem.eql(u8, credit.status, available_status)) continue;
        var consumed = false;
        for (consumed_ids) |used| {
            if (std.mem.eql(u8, used, credit.id)) {
                consumed = true;
                break;
            }
        }
        if (consumed) continue;
        try cards.append(allocator, .{
            .id = credit.id,
            .title = credit.title,
            .expires_at = credit.expires_at,
            .epoch = parseIsoEpoch(credit.expires_at orelse ""),
        });
    }
    std.mem.sort(AvailableCard, cards.items, {}, cardLessThan);
    return cards.toOwnedSlice(allocator);
}

/// Renders the RESET CREDITS rail block. Lines are bounded to `max_cols`
/// and '\n'-terminated. `card_cursor` marks the selected credit; the
/// selected line appends the two-step confirm hint when `confirm_pending`.
/// `status_line` surfaces the result of the last action.
pub fn render(
    allocator: std.mem.Allocator,
    writer: *std.Io.Writer,
    cards: []const AvailableCard,
    max_cols: usize,
    now: i64,
    card_cursor: usize,
    confirm_pending: bool,
    status_line: ?[]const u8,
) !usize {
    var lines: usize = 0;
    const budget = if (max_cols > 2) max_cols - 2 else max_cols;
    var header_buf: [128]u8 = undefined;
    const header = std.fmt.bufPrint(&header_buf, "Remaining {d} · ⏎ select · esc close", .{cards.len}) catch "Remaining";
    try writer.writeAll("┌ ");
    try writeBounded(writer, header, budget);
    try writer.writeByte('\n');
    lines += 1;

    if (cards.len == 0) {
        try writer.writeAll("│ ");
        try writeBounded(writer, "no available reset credits · run `codex-auth list --api` to refresh", budget);
        try writer.writeByte('\n');
        lines += 1;
    } else {
        for (cards, 0..) |card, index| {
            const selected = index == card_cursor;
            var line: std.Io.Writer.Allocating = .init(allocator);
            defer line.deinit();
            try line.writer.writeAll(if (selected) "▸ " else "  ");
            try line.writer.writeAll(card.title orelse "(untitled)");
            if (card.epoch) |epoch| {
                const local = try rows.formatTimestampAlloc(allocator, epoch);
                defer allocator.free(local);
                const rel = try relativeIn(allocator, epoch, now);
                defer allocator.free(rel);
                const compact = if (local.len >= 16) local[5..16] else local;
                try line.writer.print(" · {s} · {s}", .{ compact, rel });
            } else {
                try line.writer.writeAll(" · -");
            }
            if (selected and confirm_pending) try line.writer.writeAll(" · ⏎ again to use");
            try writer.writeAll("│ ");
            try writeBounded(writer, line.written(), budget);
            try writer.writeByte('\n');
            lines += 1;
        }
    }

    if (status_line) |message| {
        try writer.writeAll("│ ");
        try writeBounded(writer, message, budget);
        try writer.writeByte('\n');
        lines += 1;
    }

    try writer.writeAll("└\n");
    lines += 1;
    return lines;
}

/// Splices `panel` into `body` (a '\n'-separated table render: line 0 is the
/// header, data lines follow) immediately after the given 0-based data line.
pub fn spliceAfterDataLine(allocator: std.mem.Allocator, body: []const u8, data_line: usize, panel: []const u8) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    var iter = std.mem.splitScalar(u8, body, '\n');
    var index: usize = 0;
    while (iter.next()) |line| : (index += 1) {
        try out.writer.writeAll(line);
        try out.writer.writeByte('\n');
        if (index == data_line + 1) {
            try out.writer.writeAll(panel);
            if (panel.len == 0 or panel[panel.len - 1] != '\n') try out.writer.writeByte('\n');
        }
    }
    return allocator.dupe(u8, out.written());
}

fn cardLessThan(_: void, a: AvailableCard, b: AvailableCard) bool {
    const a_epoch = a.epoch orelse std.math.maxInt(i64);
    const b_epoch = b.epoch orelse std.math.maxInt(i64);
    return a_epoch < b_epoch;
}

/// Minimal ISO-8601 parser for the backend shape `YYYY-MM-DDTHH:MM:SS` with an
/// optional trailing zone (`Z` or `±HH:MM`). Returns epoch seconds, or null.
fn parseIsoEpoch(value: []const u8) ?i64 {
    if (value.len < 19 or value[4] != '-' or value[7] != '-' or value[10] != 'T' or
        value[13] != ':' or value[16] != ':') return null;
    const year = std.fmt.parseInt(i64, value[0..4], 10) catch return null;
    const month = std.fmt.parseInt(i64, value[5..7], 10) catch return null;
    const day = std.fmt.parseInt(i64, value[8..10], 10) catch return null;
    const hour = std.fmt.parseInt(i64, value[11..13], 10) catch return null;
    const minute = std.fmt.parseInt(i64, value[14..16], 10) catch return null;
    const second = std.fmt.parseInt(i64, value[17..19], 10) catch return null;
    if (month < 1 or month > 12 or day < 1 or day > 31) return null;

    var epoch = daysFromCivil(year, month, day) * 86400 + hour * 3600 + minute * 60 + second;
    if (value.len > 19) {
        const zone_marker = value[19];
        if (zone_marker == '+' or zone_marker == '-') {
            if (value.len >= 25 and value[22] == ':') {
                const zone_hour = std.fmt.parseInt(i64, value[20..22], 10) catch 0;
                const zone_minute = std.fmt.parseInt(i64, value[23..25], 10) catch 0;
                const offset = zone_hour * 3600 + zone_minute * 60;
                epoch += if (zone_marker == '+') -offset else offset;
            }
        }
    }
    return epoch;
}

/// Howard Hinnant's days_from_civil algorithm.
fn daysFromCivil(year: i64, month: i64, day: i64) i64 {
    var y = year;
    if (month <= 2) y -= 1;
    const era = @divFloor(y, 400);
    const yoe = y - era * 400;
    const mp = @mod(month + 9, 12);
    const doy = @divFloor(153 * mp + 2, 5) + day - 1;
    const doe = yoe * 365 + @divFloor(yoe, 4) - @divFloor(yoe, 100) + doy;
    return era * 146097 + doe - 719468;
}

fn relativeIn(allocator: std.mem.Allocator, target: i64, now: i64) ![]u8 {
    const delta = target - now;
    if (delta <= 0) return std.fmt.allocPrint(allocator, "expired", .{});
    if (delta < 60) return std.fmt.allocPrint(allocator, "in {d}s", .{delta});
    if (delta < 3600) return std.fmt.allocPrint(allocator, "in {d}m", .{@divTrunc(delta, 60)});
    if (delta < 86400) return std.fmt.allocPrint(allocator, "in {d}h", .{@divTrunc(delta, 3600)});
    return std.fmt.allocPrint(allocator, "in {d}d", .{@divTrunc(delta, 86400)});
}

fn writeBounded(writer: *std.Io.Writer, text: []const u8, max_cols: usize) !void {
    if (text.len <= max_cols) {
        try writer.writeAll(text);
        return;
    }
    if (max_cols <= 3) {
        try writer.writeAll("...");
        return;
    }
    try writer.writeAll(text[0 .. max_cols - 3]);
    try writer.writeAll("...");
}

test "parseIsoEpoch handles backend strings" {
    const epoch = parseIsoEpoch("2026-11-01T00:00:00Z");
    try std.testing.expect(epoch != null);
    try std.testing.expectEqual(@as(i64, 1793491200), epoch.?);
    try std.testing.expect(parseIsoEpoch("nonsense") == null);
}

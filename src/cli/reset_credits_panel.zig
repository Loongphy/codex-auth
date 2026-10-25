const std = @import("std");
const registry = @import("../registry/root.zig");
const rows = @import("rows.zig");
const timestamp = @import("../time/timestamp.zig");
const text_width = @import("../tui/text_width.zig");

const available_status = "available";

pub const AvailableCard = struct {
    id: []const u8,
    title: ?[]const u8,
    expires_at: ?[]const u8,
    epoch: ?i64,
};

/// Direction of a cursor move inside the reset credits panel.
pub const Direction = enum { up, down };

/// The exact credit a confirmation refers to. Redemption is irreversible, so
/// the pending state is bound to this pair instead of a bare flag.
pub const Identity = struct {
    account_key: []const u8,
    credit_id: []const u8,
};

/// Result of pressing `⏎` while the panel is open.
pub const ConfirmStep = enum {
    /// The credit is now armed; the caller must render the re-confirm hint.
    armed,
    /// The already armed credit was confirmed again; the caller may redeem it
    /// after `approve` accepts the same identity.
    consume,
    /// Nothing is consumable: the panel is closed or the cursor row has no
    /// available credit.
    ignored,
    /// The armed identity could not be recorded; nothing was armed.
    out_of_memory,
};

/// Selection state of the live reset credits panel.
///
/// Every cursor change goes through these methods so a pending confirmation
/// can never outlive the credit it was armed for: moving the credit cursor,
/// moving to another account row, collapsing the panel, or losing the credit
/// list under the cursor all disarm it, and the armed identity is compared
/// again before any redeem is sent.
pub const Selection = struct {
    pub const Armed = struct {
        account_key: []u8,
        credit_id: []u8,
    };

    expanded: bool = false,
    row_cursor: usize = 0,
    card_cursor: usize = 0,
    card_count: usize = 0,
    valid: bool = false,
    /// The credit a confirmation is pending for; `null` means nothing is
    /// pending. Owning the copies keeps the invariant local to this struct.
    armed: ?Armed = null,
    /// Status line rendered inside the rail, owned by the selection so it
    /// cannot describe a credit from another account row.
    status: ?[]u8 = null,

    pub fn deinit(self: *Selection, allocator: std.mem.Allocator) void {
        self.clearArmed(allocator);
        self.clearStatus(allocator);
    }

    pub fn isPending(self: *Selection) bool {
        return self.armed != null;
    }

    pub fn toggleExpanded(self: *Selection, allocator: std.mem.Allocator) void {
        self.expanded = !self.expanded;
        if (!self.expanded) self.close(allocator);
    }

    /// Closes the rail: `esc` and `q` both stop at the rail while it is open,
    /// so neither can leave a confirmation armed or quit the session.
    pub fn close(self: *Selection, allocator: std.mem.Allocator) void {
        self.expanded = false;
        self.clearArmed(allocator);
        self.clearStatus(allocator);
    }

    pub fn moveRow(self: *Selection, allocator: std.mem.Allocator, direction: Direction, row_count: usize) void {
        const next = movedIndex(self.row_cursor, direction, row_count) orelse return;
        self.row_cursor = next;
        self.clearSelection(allocator);
        self.clearStatus(allocator);
    }

    pub fn moveCard(self: *Selection, allocator: std.mem.Allocator, direction: Direction) void {
        const next = movedIndex(self.card_cursor, direction, self.card_count) orelse return;
        self.card_cursor = next;
        self.clearArmed(allocator);
    }

    /// Keeps the row cursor inside the rendered table after a refresh.
    pub fn clampRow(self: *Selection, allocator: std.mem.Allocator, row_count: usize) void {
        if (self.row_cursor < row_count) return;
        self.row_cursor = if (row_count == 0) 0 else row_count - 1;
        self.clearSelection(allocator);
    }

    /// Publishes the credit list rendered for the cursor row. The highlight
    /// stays on the same card when it still exists; when the list shrinks the
    /// confirmation is dropped because the highlighted card changed.
    pub fn updateCards(self: *Selection, allocator: std.mem.Allocator, count: usize) void {
        self.card_count = count;
        if (self.card_cursor >= count) {
            self.card_cursor = if (count == 0) 0 else count - 1;
            self.clearArmed(allocator);
        }
        self.valid = count > 0;
        if (!self.valid) self.clearArmed(allocator);
    }

    /// The cursor row has no consumable credit: keep the row cursor, drop the
    /// card highlight, the armed confirmation, and any status line.
    pub fn clearSelection(self: *Selection, allocator: std.mem.Allocator) void {
        self.card_cursor = 0;
        self.card_count = 0;
        self.valid = false;
        self.clearArmed(allocator);
        self.clearStatus(allocator);
    }

    /// Two-step confirmation for the highlighted credit.
    pub fn confirm(self: *Selection, allocator: std.mem.Allocator, identity: Identity) ConfirmStep {
        if (!self.expanded or !self.valid) return .ignored;
        if (self.armed) |entry| {
            if (std.mem.eql(u8, entry.account_key, identity.account_key) and
                std.mem.eql(u8, entry.credit_id, identity.credit_id))
            {
                return .consume;
            }
            self.clearArmed(allocator);
        }
        const account_key = allocator.dupe(u8, identity.account_key) catch return .out_of_memory;
        const credit_id = allocator.dupe(u8, identity.credit_id) catch {
            allocator.free(account_key);
            return .out_of_memory;
        };
        self.armed = .{ .account_key = account_key, .credit_id = credit_id };
        return .armed;
    }

    /// Accepts the redeem for `identity` exactly once: returns true only when
    /// the armed confirmation matches it, and always drops the armed state so
    /// a second redeem needs a fresh confirmation.
    pub fn approve(self: *Selection, allocator: std.mem.Allocator, identity: Identity) bool {
        const entry = self.armed orelse return false;
        const matches = std.mem.eql(u8, entry.account_key, identity.account_key) and
            std.mem.eql(u8, entry.credit_id, identity.credit_id);
        self.clearArmed(allocator);
        return matches;
    }

    pub fn setStatus(self: *Selection, allocator: std.mem.Allocator, text: []const u8) !void {
        const copy = try allocator.dupe(u8, text);
        if (self.status) |old| allocator.free(old);
        self.status = copy;
    }

    pub fn clearStatus(self: *Selection, allocator: std.mem.Allocator) void {
        if (self.status) |old| {
            allocator.free(old);
            self.status = null;
        }
    }

    fn clearArmed(self: *Selection, allocator: std.mem.Allocator) void {
        if (self.armed) |entry| {
            allocator.free(entry.account_key);
            allocator.free(entry.credit_id);
            self.armed = null;
        }
    }
};

fn movedIndex(cursor: usize, direction: Direction, count: usize) ?usize {
    switch (direction) {
        .up => return if (cursor > 0) cursor - 1 else null,
        .down => return if (count == 0 or cursor + 1 >= count) null else cursor + 1,
    }
}

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
            .epoch = timestamp.parseIso8601(credit.expires_at orelse ""),
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
    indent: usize,
) !usize {
    var lines: usize = 0;
    const budget = if (max_cols > indent + 2) max_cols - indent - 2 else 0;
    var header_buf: [128]u8 = undefined;
    const header = std.fmt.bufPrint(&header_buf, "Available {d} · ⏎ select · esc close", .{cards.len}) catch "Available";
    try writeIndent(writer, indent);
    try writer.writeAll("┌ ");
    try writeBounded(writer, header, budget);
    try writer.writeByte('\n');
    lines += 1;

    if (cards.len == 0) {
        try writeIndent(writer, indent);
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
            try writeIndent(writer, indent);
            try writer.writeAll("│ ");
            try writeBounded(writer, line.written(), budget);
            try writer.writeByte('\n');
            lines += 1;
        }
    }

    if (status_line) |message| {
        try writeIndent(writer, indent);
        try writer.writeAll("│ ");
        try writeBounded(writer, message, budget);
        try writer.writeByte('\n');
        lines += 1;
    }

    try writeIndent(writer, indent);
    try writer.writeAll("└\n");
    lines += 1;
    return lines;
}

fn writeIndent(writer: *std.Io.Writer, indent: usize) !void {
    var index: usize = 0;
    while (index < indent) : (index += 1) {
        try writer.writeByte(' ');
    }
}

/// Splices `panel` into `body` (a '\n'-separated table render: line 0 is the
/// header, data lines follow) immediately after the given 0-based data line.
/// The terminating newline of `body` must not become a phantom data row.
pub fn spliceAfterDataLine(allocator: std.mem.Allocator, body: []const u8, data_line: usize, panel: []const u8) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    var iter = std.mem.splitScalar(u8, body, '\n');
    var index: usize = 0;
    while (iter.next()) |line| : (index += 1) {
        const is_terminator = line.len == 0 and iter.rest().len == 0 and index > 0;
        if (!is_terminator) {
            try out.writer.writeAll(line);
            try out.writer.writeByte('\n');
        }
        if (index == data_line + 1) {
            try out.writer.writeAll(panel);
            if (panel.len == 0 or panel[panel.len - 1] != '\n') try out.writer.writeByte('\n');
        }
    }
    const copy = try allocator.dupe(u8, out.written());
    out.deinit();
    return copy;
}

fn cardLessThan(_: void, a: AvailableCard, b: AvailableCard) bool {
    const a_epoch = a.epoch orelse std.math.maxInt(i64);
    const b_epoch = b.epoch orelse std.math.maxInt(i64);
    return a_epoch < b_epoch;
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
    if (text_width.displayWidth(text) <= max_cols) {
        try writer.writeAll(text);
        return;
    }
    if (max_cols <= 3) {
        try writer.writeAll("...");
        return;
    }
    try writer.writeAll(text[0..text_width.prefixByteLength(text, max_cols - 3)]);
    try writer.writeAll("...");
}

const std = @import("std");
const registry = @import("../registry/root.zig");
const reset_credits_api = @import("../api/reset_credits.zig");
const rows = @import("rows.zig");
const style = @import("style.zig");
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

/// Identity cached from the last rendered frame.
///
/// Keys are processed in batches before the next frame is drawn, so a move can
/// make this cached identity describe a credit that is no longer highlighted.
/// The batch code clears it through `Selection.moveCardAndInvalidate`; `get`
/// then returns null and the same batch cannot arm or redeem the stale credit.
pub const RenderedIdentity = struct {
    account_key: ?[]u8 = null,
    credit_id: ?[]u8 = null,

    pub fn deinit(self: *RenderedIdentity, allocator: std.mem.Allocator) void {
        self.clear(allocator);
    }

    pub fn clear(self: *RenderedIdentity, allocator: std.mem.Allocator) void {
        if (self.credit_id) |id| allocator.free(id);
        self.credit_id = null;
        if (self.account_key) |key| allocator.free(key);
        self.account_key = null;
    }

    /// Replaces the cached pair. Both copies are allocated before the old pair
    /// is freed, so an allocation failure leaves the previous frame's identity
    /// intact instead of dangling.
    pub fn set(self: *RenderedIdentity, allocator: std.mem.Allocator, identity: ?Identity) !void {
        var credit_copy: ?[]u8 = null;
        errdefer if (credit_copy) |copy| allocator.free(copy);
        var account_copy: ?[]u8 = null;
        errdefer if (account_copy) |copy| allocator.free(copy);
        if (identity) |current| {
            credit_copy = try allocator.dupe(u8, current.credit_id);
            account_copy = try allocator.dupe(u8, current.account_key);
        }
        self.clear(allocator);
        self.credit_id = credit_copy;
        self.account_key = account_copy;
    }

    pub fn get(self: *const RenderedIdentity) ?Identity {
        const account_key = self.account_key orelse return null;
        const credit_id = self.credit_id orelse return null;
        return .{ .account_key = account_key, .credit_id = credit_id };
    }
};

/// Result of pressing `Enter` while the panel is open.
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

/// Role of a rail status line, mapped to the shared color roles.
pub const StatusKind = enum { ok, fail, info };

/// The report a consume outcome leaves on the rail's bottom line. `text` is
/// owned by the caller.
pub const ConsumeStatus = struct {
    text: []u8,
    kind: StatusKind,
};

/// The status line an outcome draws under the card list, or `null` when the
/// outcome reports itself in place: a fresh redeem keeps the consumed card as
/// a struck ghost tagged `redeemed`, and that row is the success report.
/// `already_redeemed` still gets a line because this attempt consumed
/// nothing — the card was already spent — so a ghost's tag alone would read
/// as our own success. Every other outcome reports on the last line; failures
/// are `.fail`, spent-state answers are `.info`.
pub fn consumeStatus(
    allocator: std.mem.Allocator,
    result: *const reset_credits_api.ConsumeResult,
) !?ConsumeStatus {
    const text: []u8 = switch (result.outcome) {
        .reset => return null,
        .already_redeemed => try allocator.dupe(u8, "reset credit already redeemed"),
        .nothing_to_reset => try allocator.dupe(u8, "usage does not need a reset right now"),
        .no_credit => try allocator.dupe(u8, "reset credit is no longer available; refresh to see current resets"),
        .unexpected_response => if (result.status_code) |code|
            try allocator.print("redeem failed (HTTP {d}, unexpected response)", .{code})
        else
            try allocator.dupe(u8, "redeem failed (unexpected response)"),
        .http_error => if (result.status_code) |code|
            try allocator.print("redeem failed (HTTP {d})", .{code})
        else
            try allocator.dupe(u8, "redeem failed"),
        .request_error => try allocator.dupe(u8, if (result.error_name) |name|
            reset_credits_api.describeRequestError(name)
        else
            "redeem failed"),
    };
    return .{
        .text = text,
        .kind = switch (result.outcome) {
            .already_redeemed, .nothing_to_reset => .info,
            else => .fail,
        },
    };
}

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

    /// The parts of a redeemed card needed to draw its ghost line after the
    /// card list no longer contains it.
    pub const SpentCard = struct {
        title: ?[]const u8,
        epoch: ?i64,
    };

    expanded: bool = false,
    row_cursor: usize = 0,
    card_cursor: usize = 0,
    card_count: usize = 0,
    valid: bool = false,
    /// The credit a confirmation is pending for; `null` means nothing is
    /// pending. Owning the copies keeps the invariant local to this struct.
    armed: ?Armed = null,
    /// Status line rendered inside the rail, owned by the selection and bound
    /// to the account it reports on. A refresh may re-sort the rows, so the
    /// text alone cannot be trusted to still sit under the same account.
    status: ?[]u8 = null,
    status_account: ?[]u8 = null,
    status_kind: StatusKind = .info,
    /// Credits redeemed this session, kept as struck-through ghost lines at
    /// their sorted slots so each consume reads as an action on a card, not
    /// a silent disappearance. They accumulate while the rail stays on its
    /// account: a card move only re-anchors the highlight, so the ghosts of
    /// earlier consumes keep their slots. Cleared with the selection and by
    /// the refresh path, which reloads the true card list.
    spent_cards: std.ArrayList(SpentCard) = .empty,
    /// Data-row index probed with `Enter` that has no available credits: a
    /// passive `no reset credits` note renders under it. Cleared when the row
    /// cursor moves so the note never floats under a different row.
    note_row: ?usize = null,

    pub fn deinit(self: *Selection, allocator: std.mem.Allocator) void {
        self.clearArmed(allocator);
        self.clearStatus(allocator);
        self.clearSpentCards(allocator);
    }

    /// True only when `identity` is the exact credit the confirmation is armed
    /// for. The rail draws its re-confirm hint from this, so the hint and the
    /// credit a second Enter would redeem can never disagree.
    pub fn isPendingFor(self: *Selection, identity: ?Identity) bool {
        const armed = self.armed orelse return false;
        const current = identity orelse return false;
        return std.mem.eql(u8, armed.account_key, current.account_key) and
            std.mem.eql(u8, armed.credit_id, current.credit_id);
    }

    pub fn toggleExpanded(self: *Selection, allocator: std.mem.Allocator) void {
        self.expanded = !self.expanded;
        self.note_row = null;
        if (!self.expanded) self.close(allocator);
    }

    /// Closes the rail: `esc` and `q` both stop at the rail while it is open,
    /// so neither can leave a confirmation armed or quit the session.
    pub fn close(self: *Selection, allocator: std.mem.Allocator) void {
        self.expanded = false;
        self.clearArmed(allocator);
        self.clearStatus(allocator);
        self.clearSpentCards(allocator);
    }

    pub fn moveRow(self: *Selection, allocator: std.mem.Allocator, direction: Direction, row_count: usize) void {
        const next = movedIndex(self.row_cursor, direction, row_count) orelse return;
        self.row_cursor = next;
        self.note_row = null;
        self.clearSelection(allocator);
    }

    pub fn moveCard(self: *Selection, allocator: std.mem.Allocator, direction: Direction) void {
        const next = movedIndex(self.card_cursor, direction, self.card_count) orelse return;
        self.card_cursor = next;
        self.clearArmed(allocator);
        self.clearStatus(allocator);
    }

    /// `moveCard` for one input batch. If the cursor actually moved, the
    /// identity cached from the previous frame is dropped before a following
    /// `Enter` in the same batch can use it. At a boundary the cursor and the
    /// cached identity both stay, so a repeated move key does not make the
    /// visible credit unusable.
    pub fn moveCardAndInvalidate(
        self: *Selection,
        allocator: std.mem.Allocator,
        rendered: *RenderedIdentity,
        direction: Direction,
    ) void {
        const before = self.card_cursor;
        self.moveCard(allocator, direction);
        if (self.card_cursor != before) rendered.clear(allocator);
    }

    /// Jumps the card highlight to `index` for the digit keys: a moved cursor
    /// drops the armed confirmation and the batch-cached identity, exactly
    /// like `moveCardAndInvalidate` does for an actual move.
    pub fn moveCardTo(
        self: *Selection,
        allocator: std.mem.Allocator,
        index: usize,
        rendered: *RenderedIdentity,
    ) void {
        if (index >= self.card_count or index == self.card_cursor) return;
        self.card_cursor = index;
        self.clearArmed(allocator);
        self.clearStatus(allocator);
        rendered.clear(allocator);
    }

    /// Keeps the row cursor inside the rendered table after a refresh.
    pub fn clampRow(self: *Selection, allocator: std.mem.Allocator, row_count: usize) void {
        if (self.row_cursor < row_count) return;
        self.row_cursor = if (row_count == 0) 0 else row_count - 1;
        self.note_row = null;
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

    /// Drops the card highlight and the armed confirmation but keeps the status
    /// line, so a background refresh cannot erase the report of a redeem that
    /// already happened on this row.
    pub fn clearCards(self: *Selection, allocator: std.mem.Allocator) void {
        self.card_cursor = 0;
        self.card_count = 0;
        self.valid = false;
        self.clearArmed(allocator);
    }

    /// The cursor row has no consumable credit: keep the row cursor, drop the
    /// card highlight, the armed confirmation, any status line, and the
    /// session's spent ghosts — they belong to the account this selection
    /// was anchored to, not to whatever row the cursor lands on next.
    pub fn clearSelection(self: *Selection, allocator: std.mem.Allocator) void {
        self.clearCards(allocator);
        self.clearStatus(allocator);
        self.clearSpentCards(allocator);
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

    /// Records a report for `account_key`: the rail draws it only while the
    /// cursor row still resolves to that account, so a post-redeem refresh
    /// cannot leave the message floating under a different account row.
    pub fn setStatusFor(
        self: *Selection,
        allocator: std.mem.Allocator,
        account_key: []const u8,
        text: []const u8,
        kind: StatusKind,
    ) !void {
        const copy = try allocator.dupe(u8, text);
        errdefer allocator.free(copy);
        const key_copy = try allocator.dupe(u8, account_key);
        if (self.status) |old| allocator.free(old);
        if (self.status_account) |old| allocator.free(old);
        self.status = copy;
        self.status_account = key_copy;
        self.status_kind = kind;
    }

    /// Appends the just-redeemed card's ghost line. Earlier ghosts stay:
    /// each one still marks the card it was consumed from, so a following
    /// consume must not erase the record of the previous one.
    pub fn addSpentCard(
        self: *Selection,
        allocator: std.mem.Allocator,
        title: ?[]const u8,
        epoch: ?i64,
    ) !void {
        const title_copy: ?[]const u8 = if (title) |value| try allocator.dupe(u8, value) else null;
        errdefer if (title_copy) |value| allocator.free(value);
        try self.spent_cards.append(allocator, .{ .title = title_copy, .epoch = epoch });
    }

    pub fn clearSpentCards(self: *Selection, allocator: std.mem.Allocator) void {
        for (self.spent_cards.items) |card| {
            if (card.title) |title| allocator.free(title);
        }
        self.spent_cards.deinit(allocator);
        self.spent_cards = .empty;
    }

    /// The status text only for the account the rail is attached to; any
    /// other account row sees no message.
    pub fn statusFor(self: *const Selection, account_key: []const u8) ?[]const u8 {
        const saved = self.status_account orelse return null;
        if (!std.mem.eql(u8, saved, account_key)) return null;
        return self.status;
    }

    pub fn clearStatus(self: *Selection, allocator: std.mem.Allocator) void {
        if (self.status) |old| {
            allocator.free(old);
            self.status = null;
        }
        if (self.status_account) |old| {
            allocator.free(old);
            self.status_account = null;
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

/// True when the account currently has a credit the rail can show. The live
/// list uses this before opening the rail, so a zero-credit row stays a plain
/// account row instead of flashing an empty panel.
pub fn hasAvailable(
    allocator: std.mem.Allocator,
    account: *const registry.AccountRecord,
    consumed_ids: []const []const u8,
) !bool {
    const cards = try collectAvailable(allocator, account, consumed_ids);
    defer allocator.free(cards);
    return cards.len > 0;
}

/// Inputs of one rail render. `is_windows` selects the ASCII glyph set that
/// docs/windows.md requires for Windows default output.
pub const RenderOptions = struct {
    max_cols: usize,
    now: i64,
    card_cursor: usize = 0,
    /// Draws the re-confirm hint on the highlighted card.
    confirm_pending: bool = false,
    status: ?[]const u8 = null,
    status_kind: StatusKind = .info,
    /// Just-redeemed cards drawn struck-through where their expiry sorted
    /// them, so each consume reads as an action on a card instead of a
    /// disappearance. Unsorted; render merges them by epoch like the cards.
    spent_cards: []const Selection.SpentCard = &.{},
    indent: usize = 0,
    is_windows: bool = false,
    use_color: bool = false,
};

/// Renders the borderless RESETS block and returns its line count,
/// which the caller needs to keep the whole block inside the viewport. Lines
/// are bounded to `max_cols` and '\n'-terminated. `card_cursor` marks the
/// selected credit; the selected line appends the two-step confirm hint when
/// `confirm_pending`. The block uses indentation, an uppercase heading, and
/// color roles instead of a box border.
pub fn render(
    allocator: std.mem.Allocator,
    writer: *std.Io.Writer,
    cards: []const AvailableCard,
    opts: RenderOptions,
) !usize {
    const g = style.Glyphs.forPlatform(opts.is_windows);
    // Below this the heading would have no room at all, which reads as stray
    // whitespace instead of a rail.
    if (opts.max_cols <= opts.indent) return 0;
    const budget = opts.max_cols - opts.indent;

    var lines: usize = 0;
    var header_buf: [128]u8 = undefined;
    const header = std.fmt.bufPrint(
        &header_buf,
        "RESETS{s}{d} available",
        .{ g.separator, cards.len },
    ) catch "RESETS";
    try writeRailLine(writer, opts.indent, header, budget, if (opts.use_color) style.role.heading else "");
    lines += 1;

    // Spent ghosts keep the slots their expiry sorted into, so the lines the
    // user confirmed still sit where they were while the cursor has moved on.
    // Cards arrive sorted; ghosts merge by epoch through a sorted index list
    // so the caller's slice stays untouched.
    const spent_order = try allocator.alloc(usize, opts.spent_cards.len);
    defer allocator.free(spent_order);
    for (spent_order, 0..) |*slot, i| slot.* = i;
    std.mem.sort(usize, spent_order, opts.spent_cards, spentIndexLessThan);

    var spent_index: usize = 0;
    var card_index: usize = 0;
    const total_rows = cards.len + spent_order.len;
    for (0..total_rows) |_| {
        const card_epoch: ?i64 = if (card_index < cards.len) cards[card_index].epoch else null;
        const next_card_epoch = card_epoch orelse std.math.maxInt(i64);
        const next_spent_epoch = if (spent_index < spent_order.len) opts.spent_cards[spent_order[spent_index]].epoch orelse std.math.maxInt(i64) else std.math.maxInt(i64);
        if (spent_index < spent_order.len and next_spent_epoch <= next_card_epoch) {
            const spent = opts.spent_cards[spent_order[spent_index]];
            spent_index += 1;
            var line: std.Io.Writer.Allocating = .init(allocator);
            defer line.deinit();
            try line.writer.writeAll("  ");
            try line.writer.writeAll(spent.title orelse "untitled");
            if (spent.epoch) |epoch| {
                const compact = try rows.formatCompactTimestampAlloc(allocator, epoch);
                defer allocator.free(compact);
                const rel = try relativeIn(allocator, epoch, opts.now);
                defer allocator.free(rel);
                try line.writer.print("{s}{s}{s}{s}", .{ g.separator, compact, g.separator, rel });
            }
            // The tag is the success report, drawn outside the strike in the
            // success role: the row itself says what happened, so a bottom
            // status line is only needed for outcomes that left no card.
            try writeSpentLine(writer, opts.indent, line.written(), " redeemed", budget, opts.use_color);
            lines += 1;
            continue;
        }
        const card = cards[card_index];
        const index = card_index;
        card_index += 1;
        const selected = index == opts.card_cursor;
        var line: std.Io.Writer.Allocating = .init(allocator);
        defer line.deinit();
        // `>` is the cursor mark style.md already establishes for the switch
        // and remove tables, so the rail uses it on every platform.
        try line.writer.writeAll(if (selected) "> " else "  ");
        try line.writer.writeAll(card.title orelse "untitled");
        if (card.epoch) |epoch| {
            const compact = try rows.formatCompactTimestampAlloc(allocator, epoch);
            defer allocator.free(compact);
            const rel = try relativeIn(allocator, epoch, opts.now);
            defer allocator.free(rel);
            try line.writer.print("{s}{s}{s}{s}", .{ g.separator, compact, g.separator, rel });
        }
        const line_style = if (selected and opts.use_color) style.role.success else "";
        if (selected and opts.confirm_pending) {
            // The re-confirm hint is drawn after the card text, outside the
            // bounded span: it is the only thing that tells the user the
            // second Enter is armed, so truncating it away would turn the
            // two-step confirm into a blind one.
            var hint_buf: [48]u8 = undefined;
            const hint = std.fmt.bufPrint(&hint_buf, "{s}Enter again to redeem", .{g.separator}) catch "Enter again to redeem";
            try writeRailLineWithHint(writer, opts.indent, line.written(), hint, budget, line_style);
        } else {
            try writeRailLine(writer, opts.indent, line.written(), budget, line_style);
        }
        lines += 1;
    }

    if (opts.status) |message| {
        // The marker joins the message before bounding, so a narrow terminal
        // truncates the pair instead of overflowing by the marker's width.
        const marked = try allocator.print("{s}{s}", .{ statusMarker(g, opts.status_kind), message });
        defer allocator.free(marked);
        try writeRailLine(
            writer,
            opts.indent,
            marked,
            budget,
            if (opts.use_color) statusRole(opts.status_kind) else "",
        );
        lines += 1;
    }
    return lines;
}

/// One dim line for an `Enter` probe on a credit-less row: it answers the
/// probe in the same spot a rail would open, but is not interactive — every
/// key keeps its account-list meaning while the note is on screen.
pub fn renderEmptyNote(writer: *std.Io.Writer, indent: usize, max_cols: usize, use_color: bool) !usize {
    if (max_cols <= indent) return 0;
    try writeRailLine(writer, indent, "no reset credits", max_cols - indent, if (use_color) style.role.secondary else "");
    return 1;
}

fn writeRailLine(
    writer: *std.Io.Writer,
    indent: usize,
    text: []const u8,
    budget: usize,
    ansi_style: []const u8,
) !void {
    try writeIndent(writer, indent);
    if (ansi_style.len != 0) try writer.writeAll(ansi_style);
    try writeBounded(writer, text, budget);
    if (ansi_style.len != 0) try writer.writeAll(style.ansi.reset);
    try writer.writeByte('\n');
}

/// The spent-card line is two styled spans: the card text stays struck+dim
/// while `tag` — the success report the struck row carries — is drawn in the
/// success role after a plain space, outside the strike. Like the armed hint
/// it keeps its own width: a tight line gives up card text, never the tag.
fn writeSpentLine(
    writer: *std.Io.Writer,
    indent: usize,
    text: []const u8,
    tag: []const u8,
    budget: usize,
    use_color: bool,
) !void {
    try writeIndent(writer, indent);
    const tag_width = text_width.displayWidth(tag);
    if (tag_width >= budget) {
        // Too narrow for card text — the tag is the whole line.
        if (use_color) try writer.writeAll(style.role.success);
        try writeBounded(writer, tag, budget);
        if (use_color) try writer.writeAll(style.ansi.reset);
    } else {
        if (use_color) try writer.writeAll(style.role.spent);
        try writeBounded(writer, text, budget - tag_width);
        if (use_color) {
            try writer.writeAll(style.ansi.reset);
            try writer.writeAll(style.role.success);
        }
        try writer.writeAll(tag);
        if (use_color) try writer.writeAll(style.ansi.reset);
    }
    try writer.writeByte('\n');
}

/// Like `writeRailLine` but `hint` is appended after the bounded `text` and
/// always survives: the card text is what gives way when the line is tight.
fn writeRailLineWithHint(
    writer: *std.Io.Writer,
    indent: usize,
    text: []const u8,
    hint: []const u8,
    budget: usize,
    ansi_style: []const u8,
) !void {
    try writeIndent(writer, indent);
    if (ansi_style.len != 0) try writer.writeAll(ansi_style);
    const hint_width = text_width.displayWidth(hint);
    if (hint_width >= budget) {
        // Too narrow for any card text — the hint is the whole line.
        try writeBounded(writer, hint, budget);
    } else {
        try writeBounded(writer, text, budget - hint_width);
        try writer.writeAll(hint);
    }
    if (ansi_style.len != 0) try writer.writeAll(style.ansi.reset);
    try writer.writeByte('\n');
}

fn statusMarker(g: style.Glyphs, kind: StatusKind) []const u8 {
    return switch (kind) {
        .ok => g.success,
        .fail => g.failure,
        .info => "",
    };
}

fn statusRole(kind: StatusKind) []const u8 {
    return switch (kind) {
        .ok => style.role.success,
        .fail => style.role.error_text,
        .info => style.role.status,
    };
}

fn writeIndent(writer: *std.Io.Writer, indent: usize) !void {
    var index: usize = 0;
    while (index < indent) : (index += 1) {
        try writer.writeByte(' ');
    }
}

/// Splices `panel` into `body` (a '\n'-separated table render: line 0 is the
/// column header, body lines follow) immediately after the given 0-based body
/// line. The index is on the rendered-line basis: group header lines count,
/// so callers map a data-row index through `liveLineIndexForDataIndex` first.
/// The terminating newline of `body` must not become a phantom data row.
pub fn spliceAfterBodyLine(allocator: std.mem.Allocator, body: []const u8, data_line: usize, panel: []const u8) ![]u8 {
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

fn spentIndexLessThan(spent_cards: []const Selection.SpentCard, a: usize, b: usize) bool {
    const a_epoch = spent_cards[a].epoch orelse std.math.maxInt(i64);
    const b_epoch = spent_cards[b].epoch orelse std.math.maxInt(i64);
    return a_epoch < b_epoch;
}

/// 0-based line index of `card_index` inside the rendered block: line 0 is the
/// RESETS heading and every ghost whose expiry sorts at or before the card
/// lands ahead of it — the same `<=` rule the merge loop above applies. The
/// live view maps this through the rail's splice point to keep the armed
/// card's confirm hint inside the viewport.
pub fn mergedCardLine(cards: []const AvailableCard, spent_cards: []const Selection.SpentCard, card_index: usize) usize {
    const epoch = cards[card_index].epoch orelse std.math.maxInt(i64);
    var ghosts_before: usize = 0;
    for (spent_cards) |spent| {
        if ((spent.epoch orelse std.math.maxInt(i64)) <= epoch) ghosts_before += 1;
    }
    return 1 + card_index + ghosts_before;
}

fn relativeIn(allocator: std.mem.Allocator, target: i64, now: i64) ![]u8 {
    const delta = target - now;
    if (delta <= 0) return allocator.print("expired", .{});
    if (delta < 60) return allocator.print("in {d}s", .{delta});
    if (delta < 3600) return allocator.print("in {d}m", .{@divTrunc(delta, 60)});
    if (delta < 86400) return allocator.print("in {d}h", .{@divTrunc(delta, 3600)});
    return allocator.print("in {d}d", .{@divTrunc(delta, 86400)});
}

fn writeBounded(writer: *std.Io.Writer, text: []const u8, max_cols: usize) !void {
    if (text_width.displayWidth(text) <= max_cols) {
        try writer.writeAll(text);
        return;
    }
    if (max_cols == 0) return;
    if (max_cols <= 3) {
        // A budget below the ellipsis width still must not widen the line.
        try writer.writeAll("..."[0..max_cols]);
        return;
    }
    try writer.writeAll(text[0..text_width.prefixByteLength(text, max_cols - 3)]);
    try writer.writeAll("...");
}

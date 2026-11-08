const std = @import("std");
const app_runtime = @import("../core/runtime.zig");
const builtin = @import("builtin");
const terminal_color = @import("../terminal/color.zig");
const selection = @import("selection.zig");
const row_data = @import("rows.zig");
const render = @import("render.zig");
const style = @import("style.zig");
const picker = @import("picker.zig");
const tui_mod = @import("tui.zig");
const live_tui = @import("live_tui.zig");
const reset_credits_panel = @import("reset_credits_panel.zig");
const reset_credits_api = @import("../api/reset_credits.zig");
const transport_mod = @import("../api/transport.zig");
const registry = @import("../registry/root.zig");
const api_usage = @import("../api/usage.zig");
const timestamp = @import("../time/timestamp.zig");

const is_windows = builtin.target.os.tag == .windows;

/// Refreshes one account's usage snapshot after a successful consume so the
/// 5H/WEEKLY cells and the remaining card list reflect the reset immediately.
/// The fetcher is injected for the same reason the foreground refresh takes
/// one: tests drive it with a scripted backend instead of real curl.
fn refreshAccountUsageAfterReset(
    allocator: std.mem.Allocator,
    usage_fetcher: api_usage.FetchForAuthPathDetailedFn,
    reg: *registry.Registry,
    codex_home: []const u8,
    account_key: []const u8,
) void {
    const account_idx = registry.findAccountIndexByAccountKey(reg, account_key) orelse return;
    const auth_path = registry.accountAuthPath(allocator, codex_home, account_key) catch return;
    defer allocator.free(auth_path);
    const fetched = usage_fetcher(allocator, auth_path) catch return;
    const snapshot = fetched.snapshot orelse return;
    const rec = &reg.accounts.items[account_idx];
    if (rec.last_usage) |*old| registry.freeRateLimitSnapshot(allocator, old);
    rec.last_usage = snapshot;
    rec.last_usage_at = std.Io.Timestamp.now(app_runtime.io(), .real).toSeconds();
    if (fetched.access_token_expires_at) |expires_at| rec.access_token_expires_at = expires_at;
}

fn alreadyConsumed(consumed_ids: []const []u8, credit_id: []const u8) bool {
    for (consumed_ids) |id| {
        if (std.mem.eql(u8, id, credit_id)) return true;
    }
    return false;
}

/// True when the rendered data row under the rail cursor still has a credit
/// the rail could show. `Enter` opens the rail only for these rows, so a row
/// with zero credits stays a plain account row.
fn rowHasAvailableCredits(
    allocator: std.mem.Allocator,
    reg: *const registry.Registry,
    rows: []const row_data.SwitchRow,
    data_index: usize,
    consumed_ids: []const []const u8,
) bool {
    const row_idx = render.liveRowIndexForDataIndex(rows, reg.accounts.items.len, data_index) orelse return false;
    const account_idx = rows[row_idx].account_index orelse return false;
    if (account_idx >= reg.accounts.items.len) return false;
    return reset_credits_panel.hasAvailable(allocator, &reg.accounts.items[account_idx], consumed_ids) catch false;
}

/// Approves the redeem queued by a second `Enter`. `approve` drops the armed
/// confirmation whether or not the identity matches, so every attempt —
/// including a retry after a failed request — needs a fresh confirmation on the
/// credit that is actually rendered under the cursor.
fn consumeApproved(
    allocator: std.mem.Allocator,
    panel: *reset_credits_panel.Selection,
    identity: ?reset_credits_panel.Identity,
) bool {
    if (!panel.valid) return false;
    const current = identity orelse return false;
    return panel.approve(allocator, current);
}

pub const SwitchSelectionDisplay = selection.SwitchSelectionDisplay;
pub const OwnedSwitchSelectionDisplay = selection.OwnedSwitchSelectionDisplay;
pub const SwitchLiveController = selection.SwitchLiveController;
pub const LiveActionOutcome = selection.LiveActionOutcome;
pub const SwitchLiveActionController = selection.SwitchLiveActionController;
pub const RemoveLiveActionController = selection.RemoveLiveActionController;

const TuiSession = tui_mod.TuiSession;
const mapTuiOutputError = tui_mod.mapTuiOutputError;
const indexWidth = row_data.indexWidth;
const renderSwitchScreenViewport = render.renderSwitchScreenViewport;
const shouldUseNumberedSwitchSelector = picker.shouldUseNumberedSwitchSelector;
const selectWithNumbers = picker.selectWithNumbers;
const dupeOptionalAccountKey = picker.dupeOptionalAccountKey;
const selectedDisplayIndexForRender = picker.selectedDisplayIndexForRender;
const parsedDisplayedIndex = picker.parsedDisplayedIndex;
const dupSelectedAccountKeyForDisplayedAccount = picker.dupSelectedAccountKeyForDisplayedAccount;
const dupSelectedAccountKey = picker.dupSelectedAccountKey;
const isQuitKey = picker.isQuitKey;
const accountRowCount = picker.accountRowCount;

pub fn selectAccountWithLiveUpdates(
    allocator: std.mem.Allocator,
    initial_display: OwnedSwitchSelectionDisplay,
    controller: SwitchLiveController,
) !?[]const u8 {
    var current_display = initial_display;
    defer current_display.deinit(allocator);
    if (current_display.reg.accounts.items.len == 0) return null;

    if (shouldUseNumberedSwitchSelector(
        comptime builtin.target.os.tag == .windows,
        std.Io.File.stdin().isTty(app_runtime.io()) catch false,
        std.Io.File.stdout().isTty(app_runtime.io()) catch false,
    )) {
        const selected_account_key = try selectWithNumbers(allocator, &current_display.reg, current_display.usage_overrides);
        return try dupeOptionalAccountKey(allocator, selected_account_key);
    }

    var tui: TuiSession = undefined;
    try tui.init();
    defer tui.deinit();

    const use_color = terminal_color.fileColorEnabled(tui.output);

    var selected_account_key = if (current_display.reg.active_account_key) |key|
        try allocator.dupe(u8, key)
    else
        null;
    defer if (selected_account_key) |key| allocator.free(key);

    var number_buf: [8]u8 = undefined;
    var number_len: usize = 0;
    var viewport_start: usize = 0;
    var scroll_stream: live_tui.ScrollStream = .{};
    var needs_render = true;
    var last_render_second: i64 = -1;
    var last_rows_minute: i64 = -1;
    var rows_cache: live_tui.RowsCache = .{};
    defer rows_cache.deinit(allocator);
    var frame: std.Io.Writer.Allocating = .init(allocator);
    defer frame.deinit();

    while (true) {
        if (try controller.maybe_take_updated_display(controller.context)) |updated| {
            current_display.deinit(allocator);
            current_display = updated;
            needs_render = true;
            rows_cache.invalidate(allocator);
        }

        const now_second = live_tui.nowSecond();
        const now_minute = @divTrunc(now_second, 60);
        if (now_minute != last_rows_minute) {
            rows_cache.invalidate(allocator);
            last_rows_minute = now_minute;
        }
        if (needs_render or now_second != last_render_second) {
            const borrowed = current_display.borrowed();
            const rows = try rows_cache.ensureSelectable(allocator, borrowed);
            const total_accounts = accountRowCount(rows.items);
            if (total_accounts == 0) return null;

            const selected_idx = try live_tui.resolveSelectedIndex(allocator, &selected_account_key, rows, borrowed.reg);
            const status_line = try controller.build_status_line(controller.context, allocator, borrowed, tui.terminalCols());
            defer allocator.free(status_line);
            const selected_display_idx = selectedDisplayIndexForRender(rows, selected_idx, number_buf[0..number_len]);
            const viewport = live_tui.selectedViewport(
                tui.terminalRows(),
                rows.items,
                selected_display_idx,
                live_tui.switchFixedLines(status_line, ""),
                &viewport_start,
            );
            var bounded_viewport = viewport;
            bounded_viewport.max_cols = tui.terminalCols();

            frame.clearRetainingCapacity();
            var styled_frame = style.StyledWriter.init(&frame.writer, use_color);
            renderSwitchScreenViewport(
                &styled_frame,
                borrowed.reg,
                rows.items,
                indexWidth(total_accounts),
                rows.widths,
                selected_display_idx,
                status_line,
                "",
                number_buf[0..number_len],
                bounded_viewport,
            ) catch |err| return mapTuiOutputError(err);
            try tui.drawFrame(frame.written());
            last_render_second = now_second;
            needs_render = false;
        }

        var key_buf: [live_tui.key_buffer_len]tui_mod.TuiInputKey = undefined;
        switch (try tui.readInputKeys(live_tui.tick_ms, &key_buf)) {
            .timeout => {
                try controller.maybe_start_refresh(controller.context);
                continue;
            },
            .closed => return null,
            .ready => |key_count| {
                if (key_count != 0) {
                    const borrowed = current_display.borrowed();
                    const rows = try rows_cache.ensureSelectable(allocator, borrowed);
                    const total_accounts = accountRowCount(rows.items);
                    if (total_accounts == 0) return null;
                    const page_rows = live_tui.maxTableRows(
                        tui.terminalRows(),
                        live_tui.switchFixedLines("status", ""),
                    );

                    for (key_buf[0..key_count]) |key| {
                        const selected_idx = try live_tui.resolveSelectedIndex(allocator, &selected_account_key, rows, borrowed.reg);
                        switch (key) {
                            .move_up, .keyboard_up => {
                                if (try live_tui.moveSelectedIndex(allocator, &selected_account_key, rows, borrowed.reg, .up)) number_len = 0;
                                needs_render = true;
                            },
                            .move_down, .keyboard_down => {
                                if (try live_tui.moveSelectedIndex(allocator, &selected_account_key, rows, borrowed.reg, .down)) number_len = 0;
                                needs_render = true;
                            },
                            .scroll_up => {
                                if (try live_tui.moveSelectedIndexBy(allocator, &selected_account_key, rows, borrowed.reg, .up, scroll_stream.step(live_tui.nowMs()))) number_len = 0;
                                needs_render = true;
                            },
                            .scroll_down => {
                                if (try live_tui.moveSelectedIndexBy(allocator, &selected_account_key, rows, borrowed.reg, .down, scroll_stream.step(live_tui.nowMs()))) number_len = 0;
                                needs_render = true;
                            },
                            .page_up => {
                                if (try live_tui.moveSelectedIndexBy(allocator, &selected_account_key, rows, borrowed.reg, .up, page_rows)) number_len = 0;
                                needs_render = true;
                            },
                            .home => {
                                if (try live_tui.moveSelectedIndexToEdge(allocator, &selected_account_key, rows, borrowed.reg, .up)) number_len = 0;
                                needs_render = true;
                            },
                            .page_down => {
                                if (try live_tui.moveSelectedIndexBy(allocator, &selected_account_key, rows, borrowed.reg, .down, page_rows)) number_len = 0;
                                needs_render = true;
                            },
                            .end => {
                                if (try live_tui.moveSelectedIndexToEdge(allocator, &selected_account_key, rows, borrowed.reg, .down)) number_len = 0;
                                needs_render = true;
                            },
                            .enter => {
                                if (parsedDisplayedIndex(number_buf[0..number_len], total_accounts)) |displayed_idx| {
                                    if (try dupSelectedAccountKeyForDisplayedAccount(allocator, rows, borrowed.reg, displayed_idx)) |account_key| return account_key;
                                    // The numbered row is not selectable (for
                                    // example an errored account): keep the
                                    // view open instead of treating it as quit.
                                    continue;
                                }
                                if (selected_idx) |idx| return try dupSelectedAccountKey(allocator, rows, borrowed.reg, idx);
                                // Nothing selected to confirm; ignore.
                                continue;
                            },
                            .quit => return null,
                            .backspace => {
                                if (number_len > 0) {
                                    number_len -= 1;
                                    _ = try live_tui.updateSelectedFromDisplayedDigits(
                                        allocator,
                                        &selected_account_key,
                                        rows,
                                        borrowed.reg,
                                        number_buf[0..number_len],
                                    );
                                    needs_render = true;
                                }
                            },
                            .redraw => needs_render = true,
                            .byte => |ch| {
                                if (isQuitKey(ch)) return null;
                                if (ch == 'k') {
                                    if (try live_tui.moveSelectedIndex(allocator, &selected_account_key, rows, borrowed.reg, .up)) number_len = 0;
                                    needs_render = true;
                                    continue;
                                }
                                if (ch == 'j') {
                                    if (try live_tui.moveSelectedIndex(allocator, &selected_account_key, rows, borrowed.reg, .down)) number_len = 0;
                                    needs_render = true;
                                    continue;
                                }
                                if (ch >= '0' and ch <= '9' and number_len < number_buf.len) {
                                    number_buf[number_len] = ch;
                                    number_len += 1;
                                    _ = try live_tui.updateSelectedFromDisplayedDigits(
                                        allocator,
                                        &selected_account_key,
                                        rows,
                                        borrowed.reg,
                                        number_buf[0..number_len],
                                    );
                                    needs_render = true;
                                }
                            },
                        }
                    }
                }
            },
        }
    }
}

pub fn viewAccountsWithLiveUpdates(
    allocator: std.mem.Allocator,
    transport: transport_mod.Transport,
    usage_fetcher: api_usage.FetchForAuthPathDetailedFn,
    initial_display: OwnedSwitchSelectionDisplay,
    controller: SwitchLiveController,
) !void {
    var current_display = initial_display;
    defer current_display.deinit(allocator);

    var tui: TuiSession = undefined;
    try tui.init();
    defer tui.deinit();

    const use_color = terminal_color.fileColorEnabled(tui.output);
    var viewport_start: usize = 0;
    var scroll_stream: live_tui.ScrollStream = .{};
    var rendered_row_count: usize = current_display.reg.accounts.items.len;
    var needs_render = true;
    var last_render_second: i64 = -1;
    var last_rows_minute: i64 = -1;
    var rows_cache: live_tui.RowsCache = .{};
    defer rows_cache.deinit(allocator);
    var frame: std.Io.Writer.Allocating = .init(allocator);
    defer frame.deinit();

    var body: std.Io.Writer.Allocating = .init(allocator);
    defer body.deinit();
    var credits_panel: std.Io.Writer.Allocating = .init(allocator);
    defer credits_panel.deinit();
    var credit_selection: reset_credits_panel.Selection = .{};
    var data_row_count: usize = 0;
    var pending_consume: bool = false;
    // Set by the rail-closed j/k handlers so the next frame keeps the row
    // cursor inside the viewport; scroll keys leave it unset, so ↑/↓ and the
    // wheel still roam freely without the cursor snapping the window back.
    var follow_row_cursor: bool = false;
    var note_needs_follow: bool = false;
    // True only when the frame on screen shows the re-confirm hint for the
    // armed credit, so a redeem always follows a visible confirmation.
    var armed_hint_rendered: bool = false;
    var rendered_identity: reset_credits_panel.RenderedIdentity = .{};
    var redeem_key: ?[]u8 = null;
    var redeem_credit_id: ?[]u8 = null;
    var consumed_ids: std.ArrayList([]u8) = .empty;
    defer {
        credit_selection.deinit(allocator);
        for (consumed_ids.items) |id| allocator.free(id);
        consumed_ids.deinit(allocator);
        rendered_identity.deinit(allocator);
        if (redeem_key) |key| allocator.free(key);
        if (redeem_credit_id) |id| allocator.free(id);
    }

    // The rail cursor opens on the active account's row — the same starting
    // point the switch/remove pickers take — so on the first frame the `>`
    // cursor, the green highlight and the `*` marker all agree. Falls back to
    // the first data row when there is no active account or it went stale.
    if (current_display.reg.active_account_key) |key| {
        const initial_rows = try rows_cache.ensure(allocator, current_display.borrowed());
        if (render.liveDataIndexForAccountKey(initial_rows.items, &current_display.reg, key)) |idx| {
            credit_selection.row_cursor = idx;
        }
    }

    while (true) {
        if (try controller.maybe_take_updated_display(controller.context)) |updated| {
            current_display.deinit(allocator);
            current_display = updated;
            needs_render = true;
            rows_cache.invalidate(allocator);
            // A display update reloads the true card list, so everything
            // anchored to the previous render is rebuilt: the armed
            // confirmation, the outcome line, and the spent ghosts all go.
            // A leftover report under a fresh list would read as a new event
            // instead of the stale report it is. The probe note is a bare
            // row-index anchor and goes too.
            credit_selection.clearCards(allocator);
            credit_selection.clearStatus(allocator);
            credit_selection.clearSpentCards(allocator);
            credit_selection.note_row = null;
        }

        const now_second = live_tui.nowSecond();
        const now_minute = @divTrunc(now_second, 60);
        if (now_minute != last_rows_minute) {
            rows_cache.invalidate(allocator);
            last_rows_minute = now_minute;
        }
        if (needs_render or now_second != last_render_second) {
            const rows = try rows_cache.ensure(allocator, current_display.borrowed());
            const list_index_width = indexWidth(rows.selectable_row_indices.len);
            body.clearRetainingCapacity();
            var styled_body = style.StyledWriter.init(&body.writer, use_color);
            try render.renderListBody(allocator, &styled_body, &current_display.reg, rows.items, list_index_width, rows.widths, tui.terminalCols(), credit_selection.row_cursor, credit_selection.expanded);
            var body_text: []const u8 = body.written();
            var spliced_panel: ?[]u8 = null;
            defer if (spliced_panel) |panel_buf| allocator.free(panel_buf);
            var available_cards: []reset_credits_panel.AvailableCard = &.{};
            defer if (available_cards.len > 0) allocator.free(available_cards);
            const account_count = current_display.reg.accounts.items.len;
            const data_rows = render.liveDataRowCount(rows.items, account_count);
            data_row_count = data_rows;
            credit_selection.clampRow(allocator, data_rows);
            // The rail's splice point and the viewport-follow span are on the
            // rendered body-line basis: group header lines sit above the
            // cursor's data row, so the data index maps through
            // liveLineIndexForDataIndex first.
            const cursor_line = render.liveLineIndexForDataIndex(
                rows.items,
                account_count,
                credit_selection.row_cursor,
            ) orelse credit_selection.row_cursor;
            // The rail and the probe note hang under the cursor row's label:
            // a grouped member indents two columns deeper, matching the
            // account cell, so the block still reads as belonging to that
            // account rather than to the group header above it.
            const cursor_row_depth: u8 = if (render.liveRowIndexForDataIndex(rows.items, account_count, credit_selection.row_cursor)) |row_idx|
                rows.items[row_idx].depth
            else
                0;
            const rail_indent = list_index_width + 4 + @as(usize, cursor_row_depth) * 2;
            if (credit_selection.expanded and data_rows == 0) {
                // Without a row to attach to the rail draws nothing, yet staying
                // expanded would keep swallowing `esc` and `q`.
                credit_selection.close(allocator);
            }
            var panel_lines: usize = 0;
            var panel_account: ?*registry.AccountRecord = null;
            // Body line of the armed card's confirm hint, when one is pending:
            // the viewport follows it and the redeem gate reads it, so a card
            // that scrolled off (or a rail too narrow to draw) can never be
            // spent by an `Enter` the user could not see confirmed.
            var armed_hint_line: ?usize = null;
            if (credit_selection.expanded and data_rows > 0) {
                // The cursor counts data rows; group header lines are rendered
                // but unnumbered, so map it back before touching rows.items.
                if (render.liveRowIndexForDataIndex(rows.items, account_count, credit_selection.row_cursor)) |row_idx| {
                    if (rows.items[row_idx].account_index) |account_idx| {
                        panel_account = &current_display.reg.accounts.items[account_idx];
                    }
                }
            }
            if (panel_account) |account| {
                available_cards = try reset_credits_panel.collectAvailable(
                    allocator,
                    account,
                    consumed_ids.items,
                );
                credit_selection.updateCards(allocator, available_cards.len);
                // Derive the shown identity once and use it for the hint, the
                // armed check, and the owned copies, so the re-confirm hint can
                // only ever appear on the credit a second Enter would redeem.
                const shown_identity: ?reset_credits_panel.Identity = if (available_cards.len > 0)
                    .{
                        .account_key = account.account_key,
                        .credit_id = available_cards[credit_selection.card_cursor].id,
                    }
                else
                    null;
                credits_panel.clearRetainingCapacity();
                const confirm_pending = credit_selection.isPendingFor(shown_identity);
                panel_lines = try reset_credits_panel.render(
                    allocator,
                    &credits_panel.writer,
                    available_cards,
                    .{
                        .max_cols = tui.terminalCols(),
                        .now = now_second,
                        .card_cursor = credit_selection.card_cursor,
                        .confirm_pending = confirm_pending,
                        .status = credit_selection.statusFor(account.account_key),
                        .status_kind = credit_selection.status_kind,
                        .spent_cards = credit_selection.spent_cards.items,
                        .indent = rail_indent,
                        .is_windows = is_windows,
                        .use_color = use_color,
                    },
                );
                if (confirm_pending and panel_lines > 0) {
                    armed_hint_line = cursor_line + 1 + reset_credits_panel.mergedCardLine(
                        available_cards,
                        credit_selection.spent_cards.items,
                        credit_selection.card_cursor,
                    );
                }
                spliced_panel = try reset_credits_panel.spliceAfterBodyLine(
                    allocator,
                    body_text,
                    cursor_line,
                    credits_panel.written(),
                );
                body_text = spliced_panel.?;
                try rendered_identity.set(allocator, shown_identity);
            } else {
                credit_selection.clearSelection(allocator);
                armed_hint_rendered = false;
                rendered_identity.clear(allocator);
                // An `Enter` probe on a credit-less row gets a passive note in
                // the rail's spot instead of silence. It is not a mode: the
                // footer and every key keep their account-list meanings, and
                // moving the row cursor drops the note.
                if (!credit_selection.expanded and credit_selection.note_row != null and
                    credit_selection.note_row.? == credit_selection.row_cursor)
                {
                    credits_panel.clearRetainingCapacity();
                    panel_lines = try reset_credits_panel.renderEmptyNote(
                        &credits_panel.writer,
                        rail_indent,
                        tui.terminalCols(),
                        use_color,
                    );
                    if (panel_lines > 0) {
                        spliced_panel = try reset_credits_panel.spliceAfterBodyLine(
                            allocator,
                            body_text,
                            cursor_line,
                            credits_panel.written(),
                        );
                        body_text = spliced_panel.?;
                    }
                }
            }
            rendered_row_count = std.mem.count(u8, body_text, "\n") -| 1;
            const status_line = try controller.build_status_line(controller.context, allocator, current_display.borrowed(), tui.terminalCols());
            defer allocator.free(status_line);
            const viewport = live_tui.listViewportFollowing(
                tui.terminalRows(),
                rendered_row_count,
                live_tui.listFixedLines(status_line),
                &viewport_start,
                // Follow the rail's last line, not just its anchor row: the
                // redeem result is drawn below the row. While a confirmation
                // is pending the armed card's own line is followed instead —
                // a rail taller than the frame must not leave its hint above
                // the window. The credit-less row's passive note is not a
                // mode either: it follows only on the frame that opens it
                // (otherwise a probe at the viewport bottom would look dead),
                // then releases so the wheel stays free to scroll instead of
                // snapping back every frame.
                if (credit_selection.expanded and panel_lines > 0)
                    .{ .first = cursor_line, .last = armed_hint_line orelse cursor_line + panel_lines }
                else if (note_needs_follow and panel_lines > 0)
                    // The probe note is spliced below its anchor row, so an
                    // Enter near the viewport bottom would open it entirely
                    // off-screen — the keypress would look dead. Follow it
                    // once at open, then release so the wheel stays free.
                    .{ .first = cursor_line, .last = cursor_line + panel_lines }
                else if (follow_row_cursor)
                    // A j/k move must stay visible: with the rail closed the
                    // cursor's own line is its span.
                    .{ .first = cursor_line, .last = cursor_line }
                else
                    null,
            );
            follow_row_cursor = false;
            note_needs_follow = false;
            var bounded_viewport = viewport;
            bounded_viewport.max_cols = tui.terminalCols();
            // A second `Enter` only redeems once the hint it confirms is
            // actually on screen: keys arrive in batches that are processed
            // before the next frame, so a fast double tap must not skip it,
            // and a hint clipped or never drawn must not arm it either.
            armed_hint_rendered = if (armed_hint_line) |hint_line|
                hint_line >= viewport.start_row and
                    hint_line < viewport.start_row + (viewport.max_rows orelse rendered_row_count)
            else
                false;

            frame.clearRetainingCapacity();
            var styled_frame = style.StyledWriter.init(&frame.writer, use_color);
            const footer_text = if (credit_selection.expanded)
                tui_mod.listCreditsTuiFooterTextFor(is_windows, tui.terminalCols())
            else
                tui_mod.listTuiFooterTextFor(is_windows, tui.terminalCols());
            render.renderListBodyViewportWithFooter(
                &styled_frame,
                body_text,
                status_line,
                bounded_viewport,
                footer_text,
            ) catch |err| return mapTuiOutputError(err);
            try tui.drawFrame(frame.written());
            last_render_second = now_second;
            needs_render = false;
        }

        var key_buf: [live_tui.key_buffer_len]tui_mod.TuiInputKey = undefined;
        switch (try tui.readInputKeys(live_tui.tick_ms, &key_buf)) {
            .timeout => {
                try controller.maybe_start_refresh(controller.context);
                continue;
            },
            .closed => return,
            .ready => |key_count| {
                if (key_count != 0) {
                    const max_rows = live_tui.maxTableRows(tui.terminalRows(), live_tui.listFixedLines("status"));
                    const wheel_rows = live_tui.mouseWheelRows(max_rows);

                    for (key_buf[0..key_count]) |key| {
                        // A queued redeem is a committed action: stop consuming
                        // this key batch, otherwise a `j` burst behind `Enter` `Enter` would
                        // move the credit highlight and silently cancel the approval.
                        if (pending_consume) break;
                        if (credit_selection.expanded) {
                            switch (key) {
                                // Inside the reset-credit TUI, Up/Down and j/k are
                                // one operator on the credit list. The account
                                // row is chosen before opening it with `Enter`.
                                .move_up, .keyboard_up, .scroll_up => {
                                    credit_selection.moveCardAndInvalidate(allocator, &rendered_identity, .up);
                                    needs_render = true;
                                    continue;
                                },
                                .move_down, .keyboard_down, .scroll_down => {
                                    credit_selection.moveCardAndInvalidate(allocator, &rendered_identity, .down);
                                    needs_render = true;
                                    continue;
                                },
                                .enter => {
                                    if (rendered_identity.get()) |identity| {
                                        switch (credit_selection.confirm(allocator, identity)) {
                                            .consume => {
                                                if (armed_hint_rendered) {
                                                    pending_consume = true;
                                                }
                                                // Otherwise the credit stays
                                                // armed and the hint is drawn
                                                // by the next frame, so the
                                                // redeem needs a deliberate
                                                // third `Enter`.
                                                needs_render = true;
                                            },
                                            .armed => {
                                                // The hint for this credit has
                                                // not been drawn yet, so a
                                                // second `Enter` in the same input
                                                // batch must wait for a frame.
                                                armed_hint_rendered = false;
                                                needs_render = true;
                                            },
                                            .ignored => {},
                                            .out_of_memory => {
                                                try credit_selection.setStatusFor(
                                                    allocator,
                                                    identity.account_key,
                                                    "credit selection unavailable (out of memory)",
                                                    .fail,
                                                );
                                                needs_render = true;
                                            },
                                        }
                                    }
                                    continue;
                                },
                                .byte => |ch| switch (ch) {
                                    'j' => {
                                        credit_selection.moveCardAndInvalidate(allocator, &rendered_identity, .down);
                                        needs_render = true;
                                        continue;
                                    },
                                    'k' => {
                                        credit_selection.moveCardAndInvalidate(allocator, &rendered_identity, .up);
                                        needs_render = true;
                                        continue;
                                    },
                                    '1'...'9' => {
                                        // Digit jump: the Nth card, 1-based like
                                        // the numbered account rows.
                                        credit_selection.moveCardTo(allocator, ch - '1', &rendered_identity);
                                        needs_render = true;
                                        continue;
                                    },
                                    else => {},
                                },
                                else => {},
                            }
                        }
                        const scroll_lines: usize = switch (key) {
                            .scroll_up, .scroll_down => scroll_stream.step(live_tui.nowMs()),
                            else => live_tui.mouse_wheel_lines,
                        };
                        if (live_tui.applyListViewportKey(rendered_row_count, max_rows, &viewport_start, wheel_rows, scroll_lines, key)) {
                            needs_render = true;
                            continue;
                        }
                        switch (key) {
                            .quit => {
                                if (credit_selection.expanded) {
                                    credit_selection.close(allocator);
                                    needs_render = true;
                                    continue;
                                }
                                return;
                            },
                            .redraw => needs_render = true,
                            .enter => {
                                // Opening the rail is the account-row selection:
                                // only rows with a consumable credit get one.
                                const borrowed = current_display.borrowed();
                                const rows = try rows_cache.ensure(allocator, borrowed);
                                if (rowHasAvailableCredits(
                                    allocator,
                                    borrowed.reg,
                                    rows.items,
                                    credit_selection.row_cursor,
                                    consumed_ids.items,
                                )) {
                                    credit_selection.toggleExpanded(allocator);
                                } else if (data_row_count > 0) {
                                    // No rail to open: leave a `no reset
                                    // credits` note under the probed row so
                                    // the keypress visibly did something. On
                                    // an empty list there is no row to anchor
                                    // the note to.
                                    credit_selection.note_row = credit_selection.row_cursor;
                                    note_needs_follow = true;
                                }
                                needs_render = true;
                                continue;
                            },
                            .byte => |ch| {
                                if (isQuitKey(ch)) {
                                    // `q` and `esc` are advertised as equivalent
                                    // quit keys, so while the rail is open both
                                    // only close it instead of dropping a
                                    // confirmation and ending the session.
                                    if (credit_selection.expanded) {
                                        credit_selection.close(allocator);
                                        needs_render = true;
                                        continue;
                                    }
                                    return;
                                }
                                if (ch == 'j') {
                                    credit_selection.moveRow(allocator, .down, data_row_count);
                                    rendered_identity.clear(allocator);
                                    follow_row_cursor = true;
                                    needs_render = true;
                                    continue;
                                }
                                if (ch == 'k') {
                                    credit_selection.moveRow(allocator, .up, data_row_count);
                                    rendered_identity.clear(allocator);
                                    follow_row_cursor = true;
                                    needs_render = true;
                                    continue;
                                }
                            },
                            else => {},
                        }
                    }
                    if (pending_consume) {
                        pending_consume = false;
                        const identity = rendered_identity.get();
                        if (consumeApproved(allocator, &credit_selection, identity)) {
                            const current = identity.?;
                            // Reuse the idempotency key while retrying the same
                            // credit: the backend deduplicates repeated redeems.
                            // A missing key counts as a different credit so a
                            // failed generation is retried instead of sticking.
                            if (redeem_key == null or redeem_credit_id == null or
                                !std.mem.eql(u8, redeem_credit_id.?, current.credit_id))
                            {
                                if (redeem_key) |key| allocator.free(key);
                                if (redeem_credit_id) |id| allocator.free(id);
                                redeem_key = reset_credits_api.generateIdempotencyKeyAlloc(allocator) catch null;
                                redeem_credit_id = allocator.dupe(u8, current.credit_id) catch null;
                            }
                            if (redeem_key) |key| {
                                const codex_home = registry.resolveCodexHome(allocator) catch |err| {
                                    try credit_selection.setStatusFor(allocator, current.account_key, reset_credits_api.describeRequestError(@errorName(err)), .fail);
                                    needs_render = true;
                                    continue;
                                };
                                defer allocator.free(codex_home);
                                var result = reset_credits_api.consumeCreditForAccount(
                                    allocator,
                                    transport,
                                    codex_home,
                                    current.account_key,
                                    key,
                                    current.credit_id,
                                ) catch |err| reset_credits_api.ConsumeResult{ .outcome = .request_error, .error_name = try allocator.dupe(u8, @errorName(err)) };
                                defer result.deinit(allocator);
                                switch (result.outcome) {
                                    .reset, .already_redeemed => {
                                        if (!alreadyConsumed(consumed_ids.items, current.credit_id)) {
                                            const id_copy = try allocator.dupe(u8, current.credit_id);
                                            try consumed_ids.append(allocator, id_copy);
                                        }
                                        if (redeem_key) |k| allocator.free(k);
                                        redeem_key = null;
                                        if (redeem_credit_id) |c| allocator.free(c);
                                        redeem_credit_id = null;
                                        // A fresh redeem leaves the consumed
                                        // card as a struck ghost tagged
                                        // `redeemed` where it sorted — the row
                                        // itself is the success report — and
                                        // the cursor lands on the next
                                        // available card.
                                        if (registry.findAccountIndexByAccountKey(&current_display.reg, current.account_key)) |spent_idx| {
                                            const spent_rec = &current_display.reg.accounts.items[spent_idx];
                                            if (spent_rec.last_usage) |usage| {
                                                if (usage.reset_credit) |credits| {
                                                    for (credits) |credit| {
                                                        if (!std.mem.eql(u8, credit.id, current.credit_id)) continue;
                                                        try credit_selection.addSpentCard(allocator, credit.title, timestamp.parseIso8601(credit.expires_at orelse ""));
                                                        break;
                                                    }
                                                }
                                            }
                                        }
                                        // Refresh the row in place for this frame
                                        // only. The registry is left to the next
                                        // refresh round, which reloads it from
                                        // disk before saving, so this cannot roll
                                        // back another account's newer snapshot.
                                        refreshAccountUsageAfterReset(allocator, usage_fetcher, &current_display.reg, codex_home, current.account_key);
                                        rows_cache.invalidate(allocator);
                                    },
                                    .no_credit => {
                                        if (!alreadyConsumed(consumed_ids.items, current.credit_id)) {
                                            const id_copy = try allocator.dupe(u8, current.credit_id);
                                            try consumed_ids.append(allocator, id_copy);
                                        }
                                        if (redeem_key) |k| allocator.free(k);
                                        redeem_key = null;
                                        if (redeem_credit_id) |c| allocator.free(c);
                                        redeem_credit_id = null;
                                    },
                                    else => {},
                                }
                                if (try reset_credits_panel.consumeStatus(allocator, &result)) |report| {
                                    defer allocator.free(report.text);
                                    try credit_selection.setStatusFor(allocator, current.account_key, report.text, report.kind);
                                }
                            } else {
                                try credit_selection.setStatusFor(allocator, current.account_key, "redeem failed (idempotency key unavailable)", .fail);
                            }
                            needs_render = true;
                        }
                    }
                }
            },
        }
    }
}

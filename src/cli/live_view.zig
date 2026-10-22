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
const registry = @import("../registry/root.zig");

fn setPanelStatus(allocator: std.mem.Allocator, slot: *?[]u8, text: []const u8) !void {
    if (slot.*) |old| allocator.free(old);
    slot.* = try allocator.dupe(u8, text);
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
        comptime builtin.os.tag == .windows,
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
            const status_line = try controller.build_status_line(controller.context, allocator, borrowed);
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
                @max(@as(usize, 2), indexWidth(total_accounts)),
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
                    const wheel_rows = live_tui.mouseWheelRows(page_rows);

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
                                if (try live_tui.moveSelectedIndexBy(allocator, &selected_account_key, rows, borrowed.reg, .up, wheel_rows)) number_len = 0;
                                needs_render = true;
                            },
                            .scroll_down => {
                                if (try live_tui.moveSelectedIndexBy(allocator, &selected_account_key, rows, borrowed.reg, .down, wheel_rows)) number_len = 0;
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
                                    return try dupSelectedAccountKeyForDisplayedAccount(allocator, rows, borrowed.reg, displayed_idx);
                                }
                                if (selected_idx) |idx| return try dupSelectedAccountKey(allocator, rows, borrowed.reg, idx);
                                return null;
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
    var credits_cursor: usize = 0;
    var credits_expanded: bool = false;
    var card_cursor: usize = 0;
    var confirm_pending: bool = false;
    var pending_consume: bool = false;
    var panel_status: ?[]u8 = null;
    var selected_credit_id: ?[]u8 = null;
    var selected_account_key: ?[]u8 = null;
    var redeem_key: ?[]u8 = null;
    var redeem_credit_id: ?[]u8 = null;
    var available_count_cache: usize = 0;
    var consumed_ids: std.ArrayList([]u8) = .empty;
    defer {
        for (consumed_ids.items) |id| allocator.free(id);
        consumed_ids.deinit(allocator);
        if (panel_status) |status| allocator.free(status);
        if (selected_credit_id) |id| allocator.free(id);
        if (selected_account_key) |key| allocator.free(key);
        if (redeem_key) |key| allocator.free(key);
        if (redeem_credit_id) |id| allocator.free(id);
    }

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
            const rows = try rows_cache.ensure(allocator, current_display.borrowed());
            body.clearRetainingCapacity();
            var styled_body = style.StyledWriter.init(&body.writer, use_color);
            try render.renderListBody(allocator, &styled_body, &current_display.reg, rows.items, @max(@as(usize, 2), indexWidth(rows.selectable_row_indices.len)), rows.widths, tui.terminalCols());
            var body_text: []const u8 = body.written();
            var spliced_panel: ?[]u8 = null;
            defer if (spliced_panel) |panel_buf| allocator.free(panel_buf);
            var available_cards: []reset_credits_panel.AvailableCard = &.{};
            defer if (available_cards.len > 0) allocator.free(available_cards);
            const data_rows = std.mem.count(u8, body_text, "\n") -| 1;
            if (credits_cursor >= data_rows) credits_cursor = if (data_rows == 0) 0 else data_rows - 1;
            if (credits_expanded and data_rows > 0) {
                const cursor_row = rows.items[credits_cursor];
                if (cursor_row.account_index) |account_idx| {
                    if (account_idx < current_display.reg.accounts.items.len) {
                        const account = &current_display.reg.accounts.items[account_idx];
                        available_cards = try reset_credits_panel.collectAvailable(
                            allocator,
                            account,
                            consumed_ids.items,
                        );
                        available_count_cache = available_cards.len;
                        if (card_cursor >= available_cards.len) card_cursor = if (available_cards.len == 0) 0 else available_cards.len - 1;
                        credits_panel.clearRetainingCapacity();
                        _ = try reset_credits_panel.render(
                            allocator,
                            &credits_panel.writer,
                            available_cards,
                            tui.terminalCols(),
                            now_second,
                            card_cursor,
                            confirm_pending,
                            panel_status,
                        );
                        spliced_panel = try reset_credits_panel.spliceAfterDataLine(
                            allocator,
                            body_text,
                            credits_cursor,
                            credits_panel.written(),
                        );
                        body_text = spliced_panel.?;
                        if (selected_credit_id) |id| allocator.free(id);
                        selected_credit_id = if (available_cards.len > 0)
                            try allocator.dupe(u8, available_cards[card_cursor].id)
                        else
                            null;
                        if (selected_account_key) |key| allocator.free(key);
                        selected_account_key = try allocator.dupe(u8, account.account_key);
                    }
                }
            }
            rendered_row_count = std.mem.count(u8, body_text, "\n") -| 1;
            const status_line = try controller.build_status_line(controller.context, allocator, current_display.borrowed());
            defer allocator.free(status_line);
            const viewport = live_tui.listViewport(
                tui.terminalRows(),
                rendered_row_count,
                live_tui.listFixedLines(status_line),
                &viewport_start,
            );
            var bounded_viewport = viewport;
            bounded_viewport.max_cols = tui.terminalCols();

            frame.clearRetainingCapacity();
            var styled_frame = style.StyledWriter.init(&frame.writer, use_color);
            render.renderListBodyViewport(
                &styled_frame,
                body_text,
                status_line,
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
            .closed => return,
            .ready => |key_count| {
                if (key_count != 0) {
                    const max_rows = live_tui.maxTableRows(tui.terminalRows(), live_tui.listFixedLines("status"));
                    const wheel_rows = live_tui.mouseWheelRows(max_rows);

                    for (key_buf[0..key_count]) |key| {
                        if (credits_expanded) {
                            switch (key) {
                                .move_up, .keyboard_up => {
                                    if (card_cursor > 0) card_cursor -= 1;
                                    needs_render = true;
                                    continue;
                                },
                                .move_down, .keyboard_down => {
                                    card_cursor += 1;
                                    needs_render = true;
                                    continue;
                                },
                                .enter => {
                                    if (available_count_cache > 0 and selected_credit_id != null) {
                                        if (!confirm_pending) {
                                            confirm_pending = true;
                                            needs_render = true;
                                        } else {
                                            confirm_pending = false;
                                            pending_consume = true;
                                            needs_render = true;
                                        }
                                    }
                                    continue;
                                },
                                else => {},
                            }
                        }
                        if (live_tui.applyListViewportKey(rendered_row_count, max_rows, &viewport_start, wheel_rows, key)) {
                            needs_render = true;
                            continue;
                        }
                        switch (key) {
                            .quit => {
                                if (credits_expanded) {
                                    credits_expanded = false;
                                    confirm_pending = false;
                                    needs_render = true;
                                    continue;
                                }
                                return;
                            },
                            .redraw => needs_render = true,
                            .byte => |ch| {
                                if (isQuitKey(ch)) return;
                                if (ch == 'c') {
                                    credits_expanded = !credits_expanded;
                                    if (!credits_expanded) confirm_pending = false;
                                    needs_render = true;
                                    continue;
                                }
                                if (ch == 'j') {
                                    if (credits_cursor + 1 < rendered_row_count) credits_cursor += 1;
                                    needs_render = true;
                                    continue;
                                }
                                if (ch == 'k') {
                                    if (credits_cursor > 0) credits_cursor -= 1;
                                    needs_render = true;
                                    continue;
                                }
                            },
                            else => {},
                        }
                    }
                    if (pending_consume) {
                        pending_consume = false;
                        if (selected_credit_id != null and selected_account_key != null) {
                            // Reuse the idempotency key while retrying the same
                            // credit: the backend deduplicates repeated redeems.
                            if (redeem_credit_id == null or !std.mem.eql(u8, redeem_credit_id.?, selected_credit_id.?)) {
                                if (redeem_key) |key| allocator.free(key);
                                if (redeem_credit_id) |id| allocator.free(id);
                                redeem_key = reset_credits_api.generateIdempotencyKeyAlloc(allocator) catch null;
                                redeem_credit_id = allocator.dupe(u8, selected_credit_id.?) catch null;
                            }
                            if (redeem_key) |key| {
                                var result: reset_credits_api.ConsumeResult = blk: {
                                    const codex_home = registry.resolveCodexHome(allocator) catch |err| {
                                        break :blk reset_credits_api.ConsumeResult{ .outcome = .request_error, .error_name = try allocator.dupe(u8, @errorName(err)) };
                                    };
                                    defer allocator.free(codex_home);
                                    break :blk reset_credits_api.consumeCreditForAccount(
                                        allocator,
                                        codex_home,
                                        selected_account_key.?,
                                        key,
                                        selected_credit_id.?,
                                    ) catch |err| reset_credits_api.ConsumeResult{ .outcome = .request_error, .error_name = try allocator.dupe(u8, @errorName(err)) };
                                };
                                defer result.deinit(allocator);
                                switch (result.outcome) {
                                    .reset, .already_redeemed, .no_credit => {
                                        var already_consumed = false;
                                        for (consumed_ids.items) |id| {
                                            if (std.mem.eql(u8, id, selected_credit_id.?)) {
                                                already_consumed = true;
                                                break;
                                            }
                                        }
                                        if (!already_consumed) {
                                            const id_copy = try allocator.dupe(u8, selected_credit_id.?);
                                            try consumed_ids.append(allocator, id_copy);
                                        }
                                        if (redeem_key) |k| allocator.free(k);
                                        redeem_key = null;
                                        if (redeem_credit_id) |c| allocator.free(c);
                                        redeem_credit_id = null;
                                        const message = switch (result.outcome) {
                                            .reset => "✓ reset credit used · windows reset on next refresh",
                                            .already_redeemed => "✓ reset credit was already used · windows reset on next refresh",
                                            .no_credit => "✗ reset credit is no longer available · refresh to see current resets",
                                            else => unreachable,
                                        };
                                        try setPanelStatus(allocator, &panel_status, message);
                                    },
                                    .nothing_to_reset => {
                                        try setPanelStatus(allocator, &panel_status, "reset not needed — usage does not need a reset right now");
                                    },
                                    .unexpected_response => {
                                        if (result.status_code) |code| {
                                            const text = try std.fmt.allocPrint(allocator, "✗ use failed (HTTP {d}, unexpected response)", .{code});
                                            defer allocator.free(text);
                                            try setPanelStatus(allocator, &panel_status, text);
                                        } else {
                                            try setPanelStatus(allocator, &panel_status, "✗ use failed (unexpected response)");
                                        }
                                    },
                                    .http_error => {
                                        if (result.status_code) |code| {
                                            const text = try std.fmt.allocPrint(allocator, "✗ use failed (HTTP {d})", .{code});
                                            defer allocator.free(text);
                                            try setPanelStatus(allocator, &panel_status, text);
                                        } else {
                                            try setPanelStatus(allocator, &panel_status, "use failed");
                                        }
                                    },
                                    .request_error => {
                                        try setPanelStatus(allocator, &panel_status, result.error_name orelse "use failed");
                                    },
                                }
                            } else {
                                try setPanelStatus(allocator, &panel_status, "✗ use failed (idempotency key unavailable)");
                            }
                            needs_render = true;
                        }
                    }
                }
            },
        }
    }
}

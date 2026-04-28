const std = @import("std");
const app_runtime = @import("../core/runtime.zig");
const builtin = @import("builtin");
const terminal_color = @import("../terminal/color.zig");
const selection = @import("selection.zig");
const row_data = @import("rows.zig");
const render = @import("render.zig");
const picker = @import("picker.zig");
const tui_mod = @import("tui.zig");
const live_tui = @import("live_tui.zig");

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
const renderListScreenViewport = render.renderListScreenViewport;
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
            renderSwitchScreenViewport(
                &frame.writer,
                borrowed.reg,
                rows.items,
                @max(@as(usize, 2), indexWidth(total_accounts)),
                rows.widths,
                selected_display_idx,
                use_color,
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
            rendered_row_count = rows.items.len;
            const status_line = try controller.build_status_line(controller.context, allocator, current_display.borrowed());
            defer allocator.free(status_line);
            const viewport = live_tui.listViewport(
                tui.terminalRows(),
                rows.items.len,
                live_tui.listFixedLines(status_line),
                &viewport_start,
            );
            var bounded_viewport = viewport;
            bounded_viewport.max_cols = tui.terminalCols();

            frame.clearRetainingCapacity();
            renderListScreenViewport(
                &frame.writer,
                &current_display.reg,
                rows.items,
                @max(@as(usize, 2), indexWidth(rows.selectable_row_indices.len)),
                rows.widths,
                use_color,
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
                    const rows = try rows_cache.ensure(allocator, current_display.borrowed());
                    rendered_row_count = rows.items.len;

                    for (key_buf[0..key_count]) |key| {
                        if (live_tui.applyListViewportKey(rendered_row_count, max_rows, &viewport_start, wheel_rows, key)) {
                            needs_render = true;
                            continue;
                        }
                        switch (key) {
                            .quit => return,
                            .redraw => needs_render = true,
                            .byte => |ch| {
                                if (isQuitKey(ch)) return;
                            },
                            else => {},
                        }
                    }
                }
            },
        }
    }
}

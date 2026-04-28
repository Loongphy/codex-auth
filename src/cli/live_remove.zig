const std = @import("std");
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
const renderRemoveScreenViewport = render.renderRemoveScreenViewport;
const selectedDisplayIndexForRender = picker.selectedDisplayIndexForRender;
const isQuitKey = picker.isQuitKey;
const replaceOptionalOwnedString = picker.replaceOptionalOwnedString;
const accountIdForSelectable = picker.accountIdForSelectable;
const clearOwnedAccountKeys = picker.clearOwnedAccountKeys;
const containsOwnedAccountKey = picker.containsOwnedAccountKey;
const toggleOwnedAccountKey = picker.toggleOwnedAccountKey;

pub fn runRemoveLiveActions(
    allocator: std.mem.Allocator,
    initial_display: OwnedSwitchSelectionDisplay,
    controller: RemoveLiveActionController,
) !void {
    var current_display = initial_display;
    defer current_display.deinit(allocator);

    var tui: TuiSession = undefined;
    try tui.init();
    defer tui.deinit();

    const use_color = terminal_color.fileColorEnabled(tui.output);

    var cursor_account_key: ?[]u8 = null;
    defer if (cursor_account_key) |key| allocator.free(key);

    var checked_account_keys = std.ArrayList([]u8).empty;
    defer {
        clearOwnedAccountKeys(allocator, &checked_account_keys);
        checked_account_keys.deinit(allocator);
    }

    var action_message: ?[]u8 = null;
    defer if (action_message) |message| allocator.free(message);

    var number_buf: [8]u8 = undefined;
    var number_len: usize = 0;
    var viewport_start: usize = 0;
    var follow_selection = true;
    var needs_render = true;
    var last_render_second: i64 = -1;
    var last_rows_minute: i64 = -1;
    var rows_cache: live_tui.RowsCache = .{};
    defer rows_cache.deinit(allocator);
    var frame: std.Io.Writer.Allocating = .init(allocator);
    defer frame.deinit();
    var checked_flags_buf = std.ArrayList(bool).empty;
    defer checked_flags_buf.deinit(allocator);

    while (true) {
        if (try controller.refresh.maybe_take_updated_display(controller.refresh.context)) |updated| {
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
            const rows = try rows_cache.ensure(allocator, borrowed);

            const cursor_idx = try live_tui.resolveSelectedIndex(allocator, &cursor_account_key, rows, borrowed.reg);
            try checked_flags_buf.resize(allocator, rows.selectable_row_indices.len);
            const checked_flags = checked_flags_buf.items;
            for (checked_flags, 0..) |*flag, selectable_idx| {
                flag.* = containsOwnedAccountKey(&checked_account_keys, accountIdForSelectable(rows, borrowed.reg, selectable_idx));
            }

            const status_line = try controller.refresh.build_status_line(controller.refresh.context, allocator, borrowed);
            defer allocator.free(status_line);
            const cursor_display_idx = selectedDisplayIndexForRender(rows, cursor_idx, number_buf[0..number_len]);
            const viewport = live_tui.selectableViewport(
                tui.terminalRows(),
                rows.items,
                cursor_display_idx,
                live_tui.switchFixedLines(status_line, action_message orelse ""),
                &viewport_start,
                follow_selection,
            );
            var bounded_viewport = viewport;
            bounded_viewport.max_cols = tui.terminalCols();

            frame.clearRetainingCapacity();
            renderRemoveScreenViewport(
                &frame.writer,
                borrowed.reg,
                rows.items,
                @max(@as(usize, 2), indexWidth(rows.selectable_row_indices.len)),
                rows.widths,
                cursor_idx,
                checked_flags,
                use_color,
                status_line,
                action_message orelse "",
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
                try controller.refresh.maybe_start_refresh(controller.refresh.context);
                continue;
            },
            .closed => return,
            .ready => |key_count| {
                if (key_count != 0) {
                    const borrowed = current_display.borrowed();
                    const rows = try rows_cache.ensure(allocator, borrowed);
                    const page_rows = live_tui.maxTableRows(
                        tui.terminalRows(),
                        live_tui.switchFixedLines("status", action_message orelse ""),
                    );
                    const wheel_rows = live_tui.mouseWheelRows(page_rows);

                    for (key_buf[0..key_count]) |key| {
                        const cursor_idx = try live_tui.resolveSelectedIndex(allocator, &cursor_account_key, rows, borrowed.reg);
                        switch (key) {
                            .move_up => {
                                if (try live_tui.moveSelectedIndex(allocator, &cursor_account_key, rows, borrowed.reg, .up)) {
                                    number_len = 0;
                                    follow_selection = true;
                                } else {
                                    live_tui.scrollListViewportBy(rows.items.len, page_rows, &viewport_start, .up, wheel_rows);
                                    follow_selection = false;
                                }
                                needs_render = true;
                            },
                            .move_down => {
                                if (try live_tui.moveSelectedIndex(allocator, &cursor_account_key, rows, borrowed.reg, .down)) {
                                    number_len = 0;
                                    follow_selection = true;
                                } else {
                                    live_tui.scrollListViewportBy(rows.items.len, page_rows, &viewport_start, .down, wheel_rows);
                                    follow_selection = false;
                                }
                                needs_render = true;
                            },
                            .keyboard_up => {
                                if (try live_tui.moveSelectedIndex(allocator, &cursor_account_key, rows, borrowed.reg, .up)) number_len = 0;
                                follow_selection = true;
                                needs_render = true;
                            },
                            .keyboard_down => {
                                if (try live_tui.moveSelectedIndex(allocator, &cursor_account_key, rows, borrowed.reg, .down)) number_len = 0;
                                follow_selection = true;
                                needs_render = true;
                            },
                            .scroll_up => {
                                live_tui.scrollListViewportBy(rows.items.len, page_rows, &viewport_start, .up, wheel_rows);
                                follow_selection = false;
                                needs_render = true;
                            },
                            .scroll_down => {
                                live_tui.scrollListViewportBy(rows.items.len, page_rows, &viewport_start, .down, wheel_rows);
                                follow_selection = false;
                                needs_render = true;
                            },
                            .page_up => {
                                if (try live_tui.moveSelectedIndexBy(allocator, &cursor_account_key, rows, borrowed.reg, .up, page_rows)) number_len = 0;
                                follow_selection = true;
                                needs_render = true;
                            },
                            .page_down => {
                                if (try live_tui.moveSelectedIndexBy(allocator, &cursor_account_key, rows, borrowed.reg, .down, page_rows)) number_len = 0;
                                follow_selection = true;
                                needs_render = true;
                            },
                            .home => {
                                if (try live_tui.moveSelectedIndexToEdge(allocator, &cursor_account_key, rows, borrowed.reg, .up)) number_len = 0;
                                follow_selection = true;
                                needs_render = true;
                            },
                            .end => {
                                if (try live_tui.moveSelectedIndexToEdge(allocator, &cursor_account_key, rows, borrowed.reg, .down)) number_len = 0;
                                follow_selection = true;
                                needs_render = true;
                            },
                            .enter => {
                                if (checked_account_keys.items.len == 0) {
                                    replaceOptionalOwnedString(allocator, &action_message, try allocator.dupe(u8, "No accounts selected"));
                                    needs_render = true;
                                    break;
                                }
                                const selected_keys = try allocator.alloc([]const u8, checked_account_keys.items.len);
                                defer allocator.free(selected_keys);
                                for (checked_account_keys.items, 0..) |checked_key, idx| selected_keys[idx] = checked_key;
                                const outcome = controller.apply_selection(controller.refresh.context, allocator, borrowed, selected_keys) catch |err| {
                                    replaceOptionalOwnedString(
                                        allocator,
                                        &action_message,
                                        try std.fmt.allocPrint(allocator, "Delete failed: {s}", .{@errorName(err)}),
                                    );
                                    needs_render = true;
                                    break;
                                };
                                clearOwnedAccountKeys(allocator, &checked_account_keys);
                                current_display.deinit(allocator);
                                current_display = outcome.updated_display;
                                rows_cache.invalidate(allocator);
                                replaceOptionalOwnedString(allocator, &action_message, outcome.action_message);
                                number_len = 0;
                                needs_render = true;
                                break;
                            },
                            .quit => return,
                            .backspace => {
                                if (number_len > 0) {
                                    number_len -= 1;
                                    _ = try live_tui.updateSelectedFromSelectableDigits(
                                        allocator,
                                        &cursor_account_key,
                                        rows,
                                        borrowed.reg,
                                        number_buf[0..number_len],
                                    );
                                    follow_selection = true;
                                    needs_render = true;
                                }
                            },
                            .redraw => needs_render = true,
                            .byte => |ch| {
                                if (isQuitKey(ch)) return;
                                if (ch == 'k') {
                                    if (try live_tui.moveSelectedIndex(allocator, &cursor_account_key, rows, borrowed.reg, .up)) number_len = 0;
                                    follow_selection = true;
                                    needs_render = true;
                                    continue;
                                }
                                if (ch == 'j') {
                                    if (try live_tui.moveSelectedIndex(allocator, &cursor_account_key, rows, borrowed.reg, .down)) number_len = 0;
                                    follow_selection = true;
                                    needs_render = true;
                                    continue;
                                }
                                if (ch == ' ') {
                                    if (cursor_idx) |idx| {
                                        try toggleOwnedAccountKey(allocator, &checked_account_keys, accountIdForSelectable(rows, borrowed.reg, idx));
                                        number_len = 0;
                                        needs_render = true;
                                    }
                                    continue;
                                }
                                if (ch >= '0' and ch <= '9' and number_len < number_buf.len) {
                                    number_buf[number_len] = ch;
                                    number_len += 1;
                                    _ = try live_tui.updateSelectedFromSelectableDigits(
                                        allocator,
                                        &cursor_account_key,
                                        rows,
                                        borrowed.reg,
                                        number_buf[0..number_len],
                                    );
                                    follow_selection = true;
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

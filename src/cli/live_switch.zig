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
const renderSwitchScreenViewport = render.renderSwitchScreenViewport;
const selectedDisplayIndexForRender = picker.selectedDisplayIndexForRender;
const parsedDisplayedIndex = picker.parsedDisplayedIndex;
const isQuitKey = picker.isQuitKey;
const accountIdForDisplayedAccount = picker.accountIdForDisplayedAccount;
const maybeAutoSwitchTargetKeyAlloc = picker.maybeAutoSwitchTargetKeyAlloc;
const replaceOptionalOwnedString = picker.replaceOptionalOwnedString;
const accountKeyForSelectableAlloc = picker.accountKeyForSelectableAlloc;
const accountRowCount = picker.accountRowCount;

pub fn runSwitchLiveActions(
    allocator: std.mem.Allocator,
    initial_display: OwnedSwitchSelectionDisplay,
    controller: SwitchLiveActionController,
) !void {
    var current_display = initial_display;
    defer current_display.deinit(allocator);

    var tui: TuiSession = undefined;
    try tui.init();
    defer tui.deinit();

    const use_color = terminal_color.fileColorEnabled(tui.output);

    var selected_account_key = if (current_display.reg.active_account_key) |key|
        try allocator.dupe(u8, key)
    else
        null;
    defer if (selected_account_key) |key| allocator.free(key);

    var action_message: ?[]u8 = null;
    defer if (action_message) |message| allocator.free(message);

    var number_buf: [8]u8 = undefined;
    var number_len: usize = 0;
    var auto_switch_state = live_tui.LiveAutoSwitchState.init(controller.auto_switch);
    var viewport_start: usize = 0;
    var follow_selection = true;
    var needs_render = true;
    var last_render_second: i64 = -1;
    var last_rows_minute: i64 = -1;
    var rows_cache: live_tui.RowsCache = .{};
    defer rows_cache.deinit(allocator);
    var frame: std.Io.Writer.Allocating = .init(allocator);
    defer frame.deinit();

    while (true) {
        if (try controller.refresh.maybe_take_updated_display(controller.refresh.context)) |updated| {
            const previous_active_account_key = if (current_display.reg.active_account_key) |key|
                try allocator.dupe(u8, key)
            else
                null;
            defer if (previous_active_account_key) |key| allocator.free(key);

            current_display.deinit(allocator);
            current_display = updated;
            if (current_display.reg.active_account_key) |active_account_key| {
                if (previous_active_account_key == null or !std.mem.eql(u8, previous_active_account_key.?, active_account_key)) {
                    replaceOptionalOwnedString(allocator, &selected_account_key, try allocator.dupe(u8, active_account_key));
                    follow_selection = true;
                }
            }
            auto_switch_state.noteRefreshedDisplay();
            needs_render = true;
            rows_cache.invalidate(allocator);
        }

        const now_second = live_tui.nowSecond();
        const now_minute = @divTrunc(now_second, 60);
        if (now_minute != last_rows_minute) {
            rows_cache.invalidate(allocator);
            last_rows_minute = now_minute;
        }

        if (auto_switch_state.takePending()) {
            const borrowed = current_display.borrowed();
            const rows = try rows_cache.ensureSelectable(allocator, borrowed);
            if (try maybeAutoSwitchTargetKeyAlloc(allocator, borrowed, rows)) |target_key| {
                defer allocator.free(target_key);
                const outcome = controller.apply_selection(controller.refresh.context, allocator, borrowed, target_key) catch |err| {
                    replaceOptionalOwnedString(
                        allocator,
                        &action_message,
                        try std.fmt.allocPrint(allocator, "Auto-switch failed: {s}", .{@errorName(err)}),
                    );
                    replaceOptionalOwnedString(allocator, &selected_account_key, try allocator.dupe(u8, target_key));
                    number_len = 0;
                    auto_switch_state.noteActionDisplay();
                    needs_render = true;
                    continue;
                };
                current_display.deinit(allocator);
                current_display = outcome.updated_display;
                rows_cache.invalidate(allocator);
                replaceOptionalOwnedString(allocator, &action_message, outcome.action_message);
                replaceOptionalOwnedString(allocator, &selected_account_key, try allocator.dupe(u8, target_key));
                number_len = 0;
                auto_switch_state.noteActionDisplay();
                needs_render = true;
                continue;
            }
        }

        if (needs_render or now_second != last_render_second) {
            const borrowed = current_display.borrowed();
            const rows = try rows_cache.ensureSelectable(allocator, borrowed);
            const total_accounts = accountRowCount(rows.items);
            const selected_idx = try live_tui.resolveSelectedIndex(allocator, &selected_account_key, rows, borrowed.reg);
            const status_line = try controller.refresh.build_status_line(controller.refresh.context, allocator, borrowed);
            defer allocator.free(status_line);
            const selected_display_idx = selectedDisplayIndexForRender(rows, selected_idx, number_buf[0..number_len]);
            const viewport = live_tui.selectableViewport(
                tui.terminalRows(),
                rows.items,
                selected_display_idx,
                live_tui.switchFixedLines(status_line, action_message orelse ""),
                &viewport_start,
                follow_selection,
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
                    const rows = try rows_cache.ensureSelectable(allocator, borrowed);
                    const total_accounts = accountRowCount(rows.items);
                    const page_rows = live_tui.maxTableRows(
                        tui.terminalRows(),
                        live_tui.switchFixedLines("status", action_message orelse ""),
                    );
                    const wheel_rows = live_tui.mouseWheelRows(page_rows);

                    for (key_buf[0..key_count]) |key| {
                        const selected_idx = try live_tui.resolveSelectedIndex(allocator, &selected_account_key, rows, borrowed.reg);
                        switch (key) {
                            .move_up => {
                                if (try live_tui.moveSelectedIndex(allocator, &selected_account_key, rows, borrowed.reg, .up)) {
                                    number_len = 0;
                                    follow_selection = true;
                                } else {
                                    live_tui.scrollListViewportBy(rows.items.len, page_rows, &viewport_start, .up, wheel_rows);
                                    follow_selection = false;
                                }
                                needs_render = true;
                            },
                            .move_down => {
                                if (try live_tui.moveSelectedIndex(allocator, &selected_account_key, rows, borrowed.reg, .down)) {
                                    number_len = 0;
                                    follow_selection = true;
                                } else {
                                    live_tui.scrollListViewportBy(rows.items.len, page_rows, &viewport_start, .down, wheel_rows);
                                    follow_selection = false;
                                }
                                needs_render = true;
                            },
                            .keyboard_up => {
                                if (try live_tui.moveSelectedIndex(allocator, &selected_account_key, rows, borrowed.reg, .up)) number_len = 0;
                                follow_selection = true;
                                needs_render = true;
                            },
                            .keyboard_down => {
                                if (try live_tui.moveSelectedIndex(allocator, &selected_account_key, rows, borrowed.reg, .down)) number_len = 0;
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
                                if (try live_tui.moveSelectedIndexBy(allocator, &selected_account_key, rows, borrowed.reg, .up, page_rows)) number_len = 0;
                                follow_selection = true;
                                needs_render = true;
                            },
                            .page_down => {
                                if (try live_tui.moveSelectedIndexBy(allocator, &selected_account_key, rows, borrowed.reg, .down, page_rows)) number_len = 0;
                                follow_selection = true;
                                needs_render = true;
                            },
                            .home => {
                                if (try live_tui.moveSelectedIndexToEdge(allocator, &selected_account_key, rows, borrowed.reg, .up)) number_len = 0;
                                follow_selection = true;
                                needs_render = true;
                            },
                            .end => {
                                if (try live_tui.moveSelectedIndexToEdge(allocator, &selected_account_key, rows, borrowed.reg, .down)) number_len = 0;
                                follow_selection = true;
                                needs_render = true;
                            },
                            .enter => {
                                const target_key = if (parsedDisplayedIndex(number_buf[0..number_len], total_accounts)) |displayed_idx|
                                    try allocator.dupe(u8, accountIdForDisplayedAccount(rows, borrowed.reg, displayed_idx) orelse continue)
                                else if (selected_idx) |idx|
                                    try accountKeyForSelectableAlloc(allocator, rows, borrowed.reg, idx)
                                else
                                    continue;
                                defer allocator.free(target_key);
                                const outcome = controller.apply_selection(controller.refresh.context, allocator, borrowed, target_key) catch |err| {
                                    replaceOptionalOwnedString(
                                        allocator,
                                        &action_message,
                                        try std.fmt.allocPrint(allocator, "Switch failed: {s}", .{@errorName(err)}),
                                    );
                                    replaceOptionalOwnedString(allocator, &selected_account_key, try allocator.dupe(u8, target_key));
                                    number_len = 0;
                                    needs_render = true;
                                    break;
                                };
                                current_display.deinit(allocator);
                                current_display = outcome.updated_display;
                                rows_cache.invalidate(allocator);
                                replaceOptionalOwnedString(allocator, &action_message, outcome.action_message);
                                replaceOptionalOwnedString(allocator, &selected_account_key, try allocator.dupe(u8, target_key));
                                number_len = 0;
                                auto_switch_state.noteActionDisplay();
                                needs_render = true;
                                break;
                            },
                            .quit => return,
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
                                    follow_selection = true;
                                    needs_render = true;
                                }
                            },
                            .redraw => needs_render = true,
                            .byte => |ch| {
                                if (isQuitKey(ch)) return;
                                if (ch == 'k') {
                                    if (try live_tui.moveSelectedIndex(allocator, &selected_account_key, rows, borrowed.reg, .up)) number_len = 0;
                                    follow_selection = true;
                                    needs_render = true;
                                    continue;
                                }
                                if (ch == 'j') {
                                    if (try live_tui.moveSelectedIndex(allocator, &selected_account_key, rows, borrowed.reg, .down)) number_len = 0;
                                    follow_selection = true;
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

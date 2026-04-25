const std = @import("std");
const app_runtime = @import("../core/runtime.zig");
const builtin = @import("builtin");
const registry = @import("../registry/root.zig");
const terminal_color = @import("../terminal/color.zig");
const selection = @import("selection.zig");
const row_data = @import("rows.zig");
const render = @import("render.zig");
const picker = @import("picker.zig");
const tui_mod = @import("tui.zig");

pub const SwitchSelectionDisplay = selection.SwitchSelectionDisplay;
pub const OwnedSwitchSelectionDisplay = selection.OwnedSwitchSelectionDisplay;
pub const SwitchLiveController = selection.SwitchLiveController;
pub const LiveActionOutcome = selection.LiveActionOutcome;
pub const SwitchLiveActionController = selection.SwitchLiveActionController;
pub const RemoveLiveActionController = selection.RemoveLiveActionController;

const TuiSession = tui_mod.TuiSession;
const pollTuiInput = tui_mod.pollTuiInput;
const readTuiEscapeAction = tui_mod.readTuiEscapeAction;
const tui_poll_error_mask = tui_mod.tui_poll_error_mask;
const tui_escape_sequence_timeout_ms = tui_mod.tui_escape_sequence_timeout_ms;
const mapTuiOutputError = tui_mod.mapTuiOutputError;
const buildSwitchRowsWithUsageOverrides = row_data.buildSwitchRowsWithUsageOverrides;
const filterErroredRowsFromSelectableIndices = row_data.filterErroredRowsFromSelectableIndices;
const indexWidth = row_data.indexWidth;
const renderSwitchScreen = render.renderSwitchScreen;
const renderListScreen = render.renderListScreen;
const renderRemoveScreen = render.renderRemoveScreen;
const shouldUseNumberedSwitchSelector = picker.shouldUseNumberedSwitchSelector;
const selectWithNumbers = picker.selectWithNumbers;
const dupeOptionalAccountKey = picker.dupeOptionalAccountKey;
const activeSelectableIndex = picker.activeSelectableIndex;
const selectableIndexForAccountKey = picker.selectableIndexForAccountKey;
const replaceSelectedAccountKeyForSelectable = picker.replaceSelectedAccountKeyForSelectable;
const selectedDisplayIndexForRender = picker.selectedDisplayIndexForRender;
const parsedDisplayedIndex = picker.parsedDisplayedIndex;
const dupSelectedAccountKeyForDisplayedAccount = picker.dupSelectedAccountKeyForDisplayedAccount;
const dupSelectedAccountKey = picker.dupSelectedAccountKey;
const isQuitKey = picker.isQuitKey;
const selectableIndexForDisplayedAccount = picker.selectableIndexForDisplayedAccount;
const accountIdForDisplayedAccount = picker.accountIdForDisplayedAccount;
const maybeAutoSwitchTargetKeyAlloc = picker.maybeAutoSwitchTargetKeyAlloc;
const replaceOptionalOwnedString = picker.replaceOptionalOwnedString;
const accountKeyForSelectableAlloc = picker.accountKeyForSelectableAlloc;
const accountRowCount = picker.accountRowCount;
const firstSelectableAccountKeyAlloc = picker.firstSelectableAccountKeyAlloc;
const accountIdForSelectable = picker.accountIdForSelectable;
const clearOwnedAccountKeys = picker.clearOwnedAccountKeys;
const containsOwnedAccountKey = picker.containsOwnedAccountKey;
const toggleOwnedAccountKey = picker.toggleOwnedAccountKey;

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

    const out = tui.out();
    const use_color = terminal_color.fileColorEnabled(tui.output);
    const ui_tick_ms: i32 = 1000;

    var selected_account_key = if (current_display.reg.active_account_key) |key|
        try allocator.dupe(u8, key)
    else
        null;
    defer if (selected_account_key) |key| allocator.free(key);

    var action_message: ?[]u8 = null;
    defer if (action_message) |message| allocator.free(message);

    var number_buf: [8]u8 = undefined;
    var number_len: usize = 0;
    var auto_check_pending = controller.auto_switch;

    while (true) {
        if (try controller.refresh.maybe_take_updated_display(controller.refresh.context)) |updated| {
            current_display.deinit(allocator);
            current_display = updated;
            auto_check_pending = controller.auto_switch;
        }

        const borrowed = current_display.borrowed();
        var rows = try buildSwitchRowsWithUsageOverrides(allocator, borrowed.reg, borrowed.usage_overrides);
        defer rows.deinit(allocator);
        try filterErroredRowsFromSelectableIndices(allocator, &rows);
        const total_accounts = accountRowCount(rows.items);

        var selected_idx: ?usize = null;
        if (rows.selectable_row_indices.len != 0) {
            selected_idx = if (selected_account_key) |key|
                selectableIndexForAccountKey(&rows, borrowed.reg, key) orelse activeSelectableIndex(&rows) orelse 0
            else
                activeSelectableIndex(&rows) orelse 0;
            try replaceSelectedAccountKeyForSelectable(allocator, &selected_account_key, &rows, borrowed.reg, selected_idx.?);
        }

        if (auto_check_pending) {
            if (try maybeAutoSwitchTargetKeyAlloc(allocator, borrowed, &rows)) |target_key| {
                defer allocator.free(target_key);
                const outcome = controller.apply_selection(controller.refresh.context, allocator, borrowed, target_key) catch |err| {
                    replaceOptionalOwnedString(
                        allocator,
                        &action_message,
                        try std.fmt.allocPrint(allocator, "Auto-switch failed: {s}", .{@errorName(err)}),
                    );
                    replaceOptionalOwnedString(allocator, &selected_account_key, try allocator.dupe(u8, target_key));
                    number_len = 0;
                    auto_check_pending = false;
                    continue;
                };
                current_display.deinit(allocator);
                current_display = outcome.updated_display;
                replaceOptionalOwnedString(allocator, &action_message, outcome.action_message);
                replaceOptionalOwnedString(allocator, &selected_account_key, try allocator.dupe(u8, target_key));
                number_len = 0;
                auto_check_pending = controller.auto_switch;
                continue;
            }
            auto_check_pending = false;
        }

        const status_line = try controller.refresh.build_status_line(controller.refresh.context, allocator, borrowed);
        defer allocator.free(status_line);
        const selected_display_idx = selectedDisplayIndexForRender(&rows, selected_idx, number_buf[0..number_len]);

        try tui.resetFrame();
        renderSwitchScreen(
            out,
            borrowed.reg,
            rows.items,
            @max(@as(usize, 2), indexWidth(total_accounts)),
            rows.widths,
            selected_display_idx,
            use_color,
            status_line,
            action_message orelse "",
            number_buf[0..number_len],
        ) catch |err| return mapTuiOutputError(err);
        try tui.flushOutput();

        switch (try pollTuiInput(tui.input, ui_tick_ms, tui_poll_error_mask)) {
            .timeout => {
                try controller.refresh.maybe_start_refresh(controller.refresh.context);
                continue;
            },
            .closed => return,
            .ready => {},
        }

        if (comptime builtin.os.tag == .windows) {
            switch (try tui.readWindowsKey()) {
                .move_up => {
                    if (selected_idx) |idx| {
                        if (idx > 0) {
                            try replaceSelectedAccountKeyForSelectable(allocator, &selected_account_key, &rows, borrowed.reg, idx - 1);
                            number_len = 0;
                        }
                    }
                },
                .move_down => {
                    if (selected_idx) |idx| {
                        if (idx + 1 < rows.selectable_row_indices.len) {
                            try replaceSelectedAccountKeyForSelectable(allocator, &selected_account_key, &rows, borrowed.reg, idx + 1);
                            number_len = 0;
                        }
                    }
                },
                .enter => {
                    const target_key = if (parsedDisplayedIndex(number_buf[0..number_len], total_accounts)) |displayed_idx|
                        try allocator.dupe(u8, accountIdForDisplayedAccount(&rows, borrowed.reg, displayed_idx) orelse continue)
                    else if (selected_idx) |idx|
                        try accountKeyForSelectableAlloc(allocator, &rows, borrowed.reg, idx)
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
                        continue;
                    };
                    current_display.deinit(allocator);
                    current_display = outcome.updated_display;
                    replaceOptionalOwnedString(allocator, &action_message, outcome.action_message);
                    replaceOptionalOwnedString(allocator, &selected_account_key, try allocator.dupe(u8, target_key));
                    number_len = 0;
                    auto_check_pending = controller.auto_switch;
                },
                .quit => return,
                .backspace => {
                    if (number_len > 0) {
                        number_len -= 1;
                        if (parsedDisplayedIndex(number_buf[0..number_len], total_accounts)) |displayed_idx| {
                            if (selectableIndexForDisplayedAccount(&rows, displayed_idx)) |selectable_idx| {
                                try replaceSelectedAccountKeyForSelectable(allocator, &selected_account_key, &rows, borrowed.reg, selectable_idx);
                            }
                        }
                    }
                },
                .redraw => continue,
                .byte => |ch| {
                    if (isQuitKey(ch)) return;
                    if (ch == 'k') {
                        if (selected_idx) |idx| {
                            if (idx > 0) {
                                try replaceSelectedAccountKeyForSelectable(allocator, &selected_account_key, &rows, borrowed.reg, idx - 1);
                                number_len = 0;
                            }
                        }
                        continue;
                    }
                    if (ch == 'j') {
                        if (selected_idx) |idx| {
                            if (idx + 1 < rows.selectable_row_indices.len) {
                                try replaceSelectedAccountKeyForSelectable(allocator, &selected_account_key, &rows, borrowed.reg, idx + 1);
                                number_len = 0;
                            }
                        }
                        continue;
                    }
                    if (ch >= '0' and ch <= '9' and number_len < number_buf.len) {
                        number_buf[number_len] = ch;
                        number_len += 1;
                        if (parsedDisplayedIndex(number_buf[0..number_len], total_accounts)) |displayed_idx| {
                            if (selectableIndexForDisplayedAccount(&rows, displayed_idx)) |selectable_idx| {
                                try replaceSelectedAccountKeyForSelectable(allocator, &selected_account_key, &rows, borrowed.reg, selectable_idx);
                            }
                        }
                    }
                },
            }
            continue;
        }

        var b: [8]u8 = undefined;
        const n = try tui.read(&b);
        if (n == 0) return;

        var i: usize = 0;
        while (i < n) : (i += 1) {
            if (b[i] == 0x1b) {
                const escape = try readTuiEscapeAction(
                    tui.input,
                    b[i + 1 .. n],
                    tui_poll_error_mask,
                    tui_escape_sequence_timeout_ms,
                );
                switch (escape.action) {
                    .move_up => {
                        if (selected_idx) |idx| {
                            if (idx > 0) {
                                try replaceSelectedAccountKeyForSelectable(allocator, &selected_account_key, &rows, borrowed.reg, idx - 1);
                                number_len = 0;
                            }
                        }
                    },
                    .move_down => {
                        if (selected_idx) |idx| {
                            if (idx + 1 < rows.selectable_row_indices.len) {
                                try replaceSelectedAccountKeyForSelectable(allocator, &selected_account_key, &rows, borrowed.reg, idx + 1);
                                number_len = 0;
                            }
                        }
                    },
                    .quit => return,
                    .ignore => {},
                }
                i += escape.buffered_bytes_consumed;
                continue;
            }

            if (b[i] == '\r' or b[i] == '\n') {
                const target_key = if (parsedDisplayedIndex(number_buf[0..number_len], total_accounts)) |displayed_idx|
                    try allocator.dupe(u8, accountIdForDisplayedAccount(&rows, borrowed.reg, displayed_idx) orelse continue)
                else if (selected_idx) |idx|
                    try accountKeyForSelectableAlloc(allocator, &rows, borrowed.reg, idx)
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
                    continue;
                };
                current_display.deinit(allocator);
                current_display = outcome.updated_display;
                replaceOptionalOwnedString(allocator, &action_message, outcome.action_message);
                replaceOptionalOwnedString(allocator, &selected_account_key, try allocator.dupe(u8, target_key));
                number_len = 0;
                auto_check_pending = controller.auto_switch;
                continue;
            }
            if (isQuitKey(b[i])) return;

            if (b[i] == 'k') {
                if (selected_idx) |idx| {
                    if (idx > 0) {
                        try replaceSelectedAccountKeyForSelectable(allocator, &selected_account_key, &rows, borrowed.reg, idx - 1);
                        number_len = 0;
                    }
                }
                continue;
            }
            if (b[i] == 'j') {
                if (selected_idx) |idx| {
                    if (idx + 1 < rows.selectable_row_indices.len) {
                        try replaceSelectedAccountKeyForSelectable(allocator, &selected_account_key, &rows, borrowed.reg, idx + 1);
                        number_len = 0;
                    }
                }
                continue;
            }
            if (b[i] == 0x7f or b[i] == 0x08) {
                if (number_len > 0) {
                    number_len -= 1;
                    if (parsedDisplayedIndex(number_buf[0..number_len], total_accounts)) |displayed_idx| {
                        if (selectableIndexForDisplayedAccount(&rows, displayed_idx)) |selectable_idx| {
                            try replaceSelectedAccountKeyForSelectable(allocator, &selected_account_key, &rows, borrowed.reg, selectable_idx);
                        }
                    }
                }
                continue;
            }
            if (b[i] >= '0' and b[i] <= '9') {
                if (number_len < number_buf.len) {
                    number_buf[number_len] = b[i];
                    number_len += 1;
                    if (parsedDisplayedIndex(number_buf[0..number_len], total_accounts)) |displayed_idx| {
                        if (selectableIndexForDisplayedAccount(&rows, displayed_idx)) |selectable_idx| {
                            try replaceSelectedAccountKeyForSelectable(allocator, &selected_account_key, &rows, borrowed.reg, selectable_idx);
                        }
                    }
                }
                continue;
            }
        }
    }
}

const std = @import("std");
const app_runtime = @import("../core/runtime.zig");
const builtin = @import("builtin");
const io_util = @import("../core/io_util.zig");
const registry = @import("../registry/root.zig");
const terminal_color = @import("../terminal/color.zig");
const row_data = @import("rows.zig");
const render = @import("render.zig");
const tui_mod = @import("tui.zig");
const style = @import("style.zig");
const io = @import("io.zig");
const nav = @import("picker_nav.zig");

const buildSwitchRowsWithUsageOverrides = row_data.buildSwitchRowsWithUsageOverrides;
const buildSwitchRowsFromIndicesWithUsageOverrides = row_data.buildSwitchRowsFromIndicesWithUsageOverrides;
const filterErroredRowsFromSelectableIndices = row_data.filterErroredRowsFromSelectableIndices;
const indexWidth = row_data.indexWidth;
const renderSwitchScreen = render.renderSwitchScreen;
const renderSwitchList = render.renderSwitchList;
const TuiSession = tui_mod.TuiSession;
const readTuiEscapeAction = tui_mod.readTuiEscapeAction;
const tui_poll_error_mask = tui_mod.tui_poll_error_mask;
const tui_escape_sequence_timeout_ms = tui_mod.tui_escape_sequence_timeout_ms;
const mapTuiOutputError = tui_mod.mapTuiOutputError;
const readFileOnce = io.readFileOnce;
const activeSelectableIndex = nav.activeSelectableIndex;
const accountIdForSelectable = nav.accountIdForSelectable;
const accountRowCount = nav.accountRowCount;
const displayedIndexForSelectable = nav.displayedIndexForSelectable;
const selectableIndexForDisplayedAccount = nav.selectableIndexForDisplayedAccount;
const accountIdForDisplayedAccount = nav.accountIdForDisplayedAccount;
const parsedDisplayedIndex = nav.parsedDisplayedIndex;
const selectedDisplayIndexForRender = nav.selectedDisplayIndexForRender;
const isQuitInput = nav.isQuitInput;
const isQuitKey = nav.isQuitKey;

pub fn shouldUseNumberedSwitchSelector(is_windows: bool, stdin_is_tty: bool, stdout_is_tty: bool) bool {
    _ = is_windows;
    return !stdin_is_tty or !stdout_is_tty;
}

pub fn selectAccount(allocator: std.mem.Allocator, reg: *registry.Registry) !?[]const u8 {
    return selectAccountWithUsageOverrides(allocator, reg, null);
}

pub fn selectAccountWithUsageOverrides(
    allocator: std.mem.Allocator,
    reg: *registry.Registry,
    usage_overrides: ?[]const ?[]const u8,
) !?[]const u8 {
    if (shouldUseNumberedSwitchSelector(
        comptime builtin.os.tag == .windows,
        std.Io.File.stdin().isTty(app_runtime.io()) catch false,
        std.Io.File.stdout().isTty(app_runtime.io()) catch false,
    )) {
        return selectWithNumbers(allocator, reg, usage_overrides);
    }
    return selectInteractive(allocator, reg, usage_overrides) catch |err| switch (err) {
        error.TuiRequiresTty => selectWithNumbers(allocator, reg, usage_overrides),
        else => return err,
    };
}

pub fn selectAccountFromIndices(allocator: std.mem.Allocator, reg: *registry.Registry, indices: []const usize) !?[]const u8 {
    return selectAccountFromIndicesWithUsageOverrides(allocator, reg, indices, null);
}

pub fn selectAccountFromIndicesWithUsageOverrides(
    allocator: std.mem.Allocator,
    reg: *registry.Registry,
    indices: []const usize,
    usage_overrides: ?[]const ?[]const u8,
) !?[]const u8 {
    if (indices.len == 0) return null;
    if (indices.len == 1) return reg.accounts.items[indices[0]].account_key;
    if (shouldUseNumberedSwitchSelector(
        comptime builtin.os.tag == .windows,
        std.Io.File.stdin().isTty(app_runtime.io()) catch false,
        std.Io.File.stdout().isTty(app_runtime.io()) catch false,
    )) {
        return selectWithNumbersFromIndices(allocator, reg, indices, usage_overrides);
    }
    return selectInteractiveFromIndices(allocator, reg, indices, usage_overrides) catch |err| switch (err) {
        error.TuiRequiresTty => selectWithNumbersFromIndices(allocator, reg, indices, usage_overrides),
        else => return err,
    };
}

pub fn selectWithNumbers(
    allocator: std.mem.Allocator,
    reg: *registry.Registry,
    usage_overrides: ?[]const ?[]const u8,
) !?[]const u8 {
    var stdout: io_util.Stdout = undefined;
    stdout.init();
    const out = stdout.out();
    if (reg.accounts.items.len == 0) return null;
    var rows = try buildSwitchRowsWithUsageOverrides(allocator, reg, usage_overrides);
    defer rows.deinit(allocator);
    try filterErroredRowsFromSelectableIndices(allocator, &rows);
    const total_accounts = accountRowCount(rows.items);
    if (total_accounts == 0) return null;
    const use_color = style.stdoutColorEnabled();
    const active_idx = activeSelectableIndex(&rows);
    const idx_width = @max(@as(usize, 2), indexWidth(total_accounts));
    const widths = rows.widths;
    const active_display_idx = if (active_idx) |idx| displayedIndexForSelectable(&rows, idx) else null;

    try out.writeAll("Select account to activate:\n\n");
    try renderSwitchList(out, reg, rows.items, idx_width, widths, active_display_idx, use_color);
    try out.writeAll("Select account number (or q to quit): ");
    try out.flush();

    var buf: [64]u8 = undefined;
    const n = try readFileOnce(std.Io.File.stdin(), &buf);
    const line = std.mem.trim(u8, buf[0..n], " \n\r\t");
    if (line.len == 0) {
        if (active_idx) |i| return accountIdForSelectable(&rows, reg, i);
        return null;
    }
    if (isQuitInput(line)) return null;
    const displayed_idx = parsedDisplayedIndex(line, total_accounts) orelse return null;
    return accountIdForDisplayedAccount(&rows, reg, displayed_idx);
}

pub fn selectWithNumbersFromIndices(
    allocator: std.mem.Allocator,
    reg: *registry.Registry,
    indices: []const usize,
    usage_overrides: ?[]const ?[]const u8,
) !?[]const u8 {
    var stdout: io_util.Stdout = undefined;
    stdout.init();
    const out = stdout.out();
    if (indices.len == 0) return null;

    var rows = try buildSwitchRowsFromIndicesWithUsageOverrides(allocator, reg, indices, usage_overrides);
    defer rows.deinit(allocator);
    try filterErroredRowsFromSelectableIndices(allocator, &rows);
    const total_accounts = accountRowCount(rows.items);
    if (total_accounts == 0) return null;
    const use_color = style.stdoutColorEnabled();
    const active_idx = activeSelectableIndex(&rows);
    const idx_width = @max(@as(usize, 2), indexWidth(total_accounts));
    const widths = rows.widths;
    const active_display_idx = if (active_idx) |idx| displayedIndexForSelectable(&rows, idx) else null;

    try out.writeAll("Select account to activate:\n\n");
    try renderSwitchList(out, reg, rows.items, idx_width, widths, active_display_idx, use_color);
    try out.writeAll("Select account number (or q to quit): ");
    try out.flush();

    var buf: [64]u8 = undefined;
    const n = try readFileOnce(std.Io.File.stdin(), &buf);
    const line = std.mem.trim(u8, buf[0..n], " \n\r\t");
    if (line.len == 0) {
        if (active_idx) |i| return accountIdForSelectable(&rows, reg, i);
        return null;
    }
    if (isQuitInput(line)) return null;
    const displayed_idx = parsedDisplayedIndex(line, total_accounts) orelse return null;
    return accountIdForDisplayedAccount(&rows, reg, displayed_idx);
}

fn selectInteractiveFromIndices(
    allocator: std.mem.Allocator,
    reg: *registry.Registry,
    indices: []const usize,
    usage_overrides: ?[]const ?[]const u8,
) !?[]const u8 {
    if (indices.len == 0) return null;
    var rows = try buildSwitchRowsFromIndicesWithUsageOverrides(allocator, reg, indices, usage_overrides);
    defer rows.deinit(allocator);
    try filterErroredRowsFromSelectableIndices(allocator, &rows);
    const total_accounts = accountRowCount(rows.items);
    if (total_accounts == 0) return null;

    var tui: TuiSession = undefined;
    try tui.init();
    defer tui.deinit();
    const out = tui.out();
    const active_idx = activeSelectableIndex(&rows);
    var idx: usize = active_idx orelse 0;
    var number_buf: [8]u8 = undefined;
    var number_len: usize = 0;
    const use_color = terminal_color.fileColorEnabled(tui.output);
    const idx_width = @max(@as(usize, 2), indexWidth(total_accounts));
    const widths = rows.widths;

    while (true) {
        const selected_display_idx = selectedDisplayIndexForRender(
            &rows,
            if (rows.selectable_row_indices.len != 0) idx else null,
            number_buf[0..number_len],
        );
        try tui.resetFrame();
        renderSwitchScreen(
            out,
            reg,
            rows.items,
            idx_width,
            widths,
            selected_display_idx,
            use_color,
            "",
            "",
            number_buf[0..number_len],
        ) catch |err| return mapTuiOutputError(err);
        try tui.flushOutput();

        if (comptime builtin.os.tag == .windows) {
            switch (try tui.readWindowsKey()) {
                .move_up, .keyboard_up, .scroll_up, .page_up => {
                    if (rows.selectable_row_indices.len != 0 and idx > 0) {
                        idx -= 1;
                        number_len = 0;
                    }
                },
                .home => {
                    if (rows.selectable_row_indices.len != 0) {
                        idx = 0;
                        number_len = 0;
                    }
                },
                .move_down, .keyboard_down, .scroll_down, .page_down => {
                    if (rows.selectable_row_indices.len != 0 and idx + 1 < rows.selectable_row_indices.len) {
                        idx += 1;
                        number_len = 0;
                    }
                },
                .end => {
                    if (rows.selectable_row_indices.len != 0) {
                        idx = rows.selectable_row_indices.len - 1;
                        number_len = 0;
                    }
                },
                .enter => {
                    if (parsedDisplayedIndex(number_buf[0..number_len], total_accounts)) |displayed_idx| {
                        return accountIdForDisplayedAccount(&rows, reg, displayed_idx);
                    }
                    if (rows.selectable_row_indices.len == 0) return null;
                    return accountIdForSelectable(&rows, reg, idx);
                },
                .quit => return null,
                .backspace => {
                    if (number_len > 0) {
                        number_len -= 1;
                        if (parsedDisplayedIndex(number_buf[0..number_len], total_accounts)) |displayed_idx| {
                            if (selectableIndexForDisplayedAccount(&rows, displayed_idx)) |selectable_idx| {
                                idx = selectable_idx;
                            }
                        }
                    }
                },
                .redraw => continue,
                .byte => |ch| {
                    if (isQuitKey(ch)) return null;
                    if (ch == 'k' and rows.selectable_row_indices.len != 0 and idx > 0) {
                        idx -= 1;
                        number_len = 0;
                        continue;
                    }
                    if (ch == 'j' and rows.selectable_row_indices.len != 0 and idx + 1 < rows.selectable_row_indices.len) {
                        idx += 1;
                        number_len = 0;
                        continue;
                    }
                    if (ch >= '0' and ch <= '9' and number_len < number_buf.len) {
                        number_buf[number_len] = ch;
                        number_len += 1;
                        if (parsedDisplayedIndex(number_buf[0..number_len], total_accounts)) |displayed_idx| {
                            if (selectableIndexForDisplayedAccount(&rows, displayed_idx)) |selectable_idx| {
                                idx = selectable_idx;
                            }
                        }
                    }
                },
            }
            continue;
        }

        var b: [8]u8 = undefined;
        const n = try tui.read(&b);
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
                    .move_up, .keyboard_up, .scroll_up, .page_up => {
                        if (rows.selectable_row_indices.len != 0 and idx > 0) {
                            idx -= 1;
                            number_len = 0;
                        }
                    },
                    .home => {
                        if (rows.selectable_row_indices.len != 0) {
                            idx = 0;
                            number_len = 0;
                        }
                    },
                    .move_down, .keyboard_down, .scroll_down, .page_down => {
                        if (rows.selectable_row_indices.len != 0 and idx + 1 < rows.selectable_row_indices.len) {
                            idx += 1;
                            number_len = 0;
                        }
                    },
                    .end => {
                        if (rows.selectable_row_indices.len != 0) {
                            idx = rows.selectable_row_indices.len - 1;
                            number_len = 0;
                        }
                    },
                    .quit => return null,
                    .keyboard_enhancement_supported, .ignore => {},
                }
                i += escape.buffered_bytes_consumed;
                continue;
            }

            if (b[i] == '\r' or b[i] == '\n') {
                if (parsedDisplayedIndex(number_buf[0..number_len], total_accounts)) |displayed_idx| {
                    return accountIdForDisplayedAccount(&rows, reg, displayed_idx);
                }
                if (rows.selectable_row_indices.len == 0) return null;
                return accountIdForSelectable(&rows, reg, idx);
            }
            if (isQuitKey(b[i])) return null;

            if (b[i] == 'k' and rows.selectable_row_indices.len != 0 and idx > 0) {
                idx -= 1;
                number_len = 0;
                continue;
            }
            if (b[i] == 'j' and rows.selectable_row_indices.len != 0 and idx + 1 < rows.selectable_row_indices.len) {
                idx += 1;
                number_len = 0;
                continue;
            }
            if (b[i] == 0x7f or b[i] == 0x08) {
                if (number_len > 0) {
                    number_len -= 1;
                    if (parsedDisplayedIndex(number_buf[0..number_len], total_accounts)) |displayed_idx| {
                        if (selectableIndexForDisplayedAccount(&rows, displayed_idx)) |selectable_idx| {
                            idx = selectable_idx;
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
                            idx = selectable_idx;
                        }
                    }
                }
                continue;
            }
        }
    }
}

fn selectInteractive(
    allocator: std.mem.Allocator,
    reg: *registry.Registry,
    usage_overrides: ?[]const ?[]const u8,
) !?[]const u8 {
    if (reg.accounts.items.len == 0) return null;
    var rows = try buildSwitchRowsWithUsageOverrides(allocator, reg, usage_overrides);
    defer rows.deinit(allocator);
    try filterErroredRowsFromSelectableIndices(allocator, &rows);
    const total_accounts = accountRowCount(rows.items);
    if (total_accounts == 0) return null;

    var tui: TuiSession = undefined;
    try tui.init();
    defer tui.deinit();
    const out = tui.out();
    const active_idx = activeSelectableIndex(&rows);
    var idx: usize = active_idx orelse 0;
    var number_buf: [8]u8 = undefined;
    var number_len: usize = 0;
    const use_color = terminal_color.fileColorEnabled(tui.output);
    const idx_width = @max(@as(usize, 2), indexWidth(total_accounts));
    const widths = rows.widths;

    while (true) {
        const selected_display_idx = selectedDisplayIndexForRender(
            &rows,
            if (rows.selectable_row_indices.len != 0) idx else null,
            number_buf[0..number_len],
        );
        try tui.resetFrame();
        renderSwitchScreen(
            out,
            reg,
            rows.items,
            idx_width,
            widths,
            selected_display_idx,
            use_color,
            "",
            "",
            number_buf[0..number_len],
        ) catch |err| return mapTuiOutputError(err);
        try tui.flushOutput();

        if (comptime builtin.os.tag == .windows) {
            switch (try tui.readWindowsKey()) {
                .move_up, .keyboard_up, .scroll_up, .page_up => {
                    if (rows.selectable_row_indices.len != 0 and idx > 0) {
                        idx -= 1;
                        number_len = 0;
                    }
                },
                .home => {
                    if (rows.selectable_row_indices.len != 0) {
                        idx = 0;
                        number_len = 0;
                    }
                },
                .move_down, .keyboard_down, .scroll_down, .page_down => {
                    if (rows.selectable_row_indices.len != 0 and idx + 1 < rows.selectable_row_indices.len) {
                        idx += 1;
                        number_len = 0;
                    }
                },
                .end => {
                    if (rows.selectable_row_indices.len != 0) {
                        idx = rows.selectable_row_indices.len - 1;
                        number_len = 0;
                    }
                },
                .enter => {
                    if (parsedDisplayedIndex(number_buf[0..number_len], total_accounts)) |displayed_idx| {
                        return accountIdForDisplayedAccount(&rows, reg, displayed_idx);
                    }
                    if (rows.selectable_row_indices.len == 0) return null;
                    return accountIdForSelectable(&rows, reg, idx);
                },
                .quit => return null,
                .backspace => {
                    if (number_len > 0) {
                        number_len -= 1;
                        if (parsedDisplayedIndex(number_buf[0..number_len], total_accounts)) |displayed_idx| {
                            if (selectableIndexForDisplayedAccount(&rows, displayed_idx)) |selectable_idx| {
                                idx = selectable_idx;
                            }
                        }
                    }
                },
                .redraw => continue,
                .byte => |ch| {
                    if (isQuitKey(ch)) return null;
                    if (ch == 'k' and rows.selectable_row_indices.len != 0 and idx > 0) {
                        idx -= 1;
                        number_len = 0;
                        continue;
                    }
                    if (ch == 'j' and rows.selectable_row_indices.len != 0 and idx + 1 < rows.selectable_row_indices.len) {
                        idx += 1;
                        number_len = 0;
                        continue;
                    }
                    if (ch >= '0' and ch <= '9' and number_len < number_buf.len) {
                        number_buf[number_len] = ch;
                        number_len += 1;
                        if (parsedDisplayedIndex(number_buf[0..number_len], total_accounts)) |displayed_idx| {
                            if (selectableIndexForDisplayedAccount(&rows, displayed_idx)) |selectable_idx| {
                                idx = selectable_idx;
                            }
                        }
                    }
                },
            }
            continue;
        }

        var b: [8]u8 = undefined;
        const n = try tui.read(&b);
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
                    .move_up, .keyboard_up, .scroll_up, .page_up => {
                        if (rows.selectable_row_indices.len != 0 and idx > 0) {
                            idx -= 1;
                            number_len = 0;
                        }
                    },
                    .home => {
                        if (rows.selectable_row_indices.len != 0) {
                            idx = 0;
                            number_len = 0;
                        }
                    },
                    .move_down, .keyboard_down, .scroll_down, .page_down => {
                        if (rows.selectable_row_indices.len != 0 and idx + 1 < rows.selectable_row_indices.len) {
                            idx += 1;
                            number_len = 0;
                        }
                    },
                    .end => {
                        if (rows.selectable_row_indices.len != 0) {
                            idx = rows.selectable_row_indices.len - 1;
                            number_len = 0;
                        }
                    },
                    .quit => return null,
                    .keyboard_enhancement_supported, .ignore => {},
                }
                i += escape.buffered_bytes_consumed;
                continue;
            }

            if (b[i] == '\r' or b[i] == '\n') {
                if (parsedDisplayedIndex(number_buf[0..number_len], total_accounts)) |displayed_idx| {
                    return accountIdForDisplayedAccount(&rows, reg, displayed_idx);
                }
                if (rows.selectable_row_indices.len == 0) return null;
                return accountIdForSelectable(&rows, reg, idx);
            }
            if (isQuitKey(b[i])) return null;
            if (b[i] == 'k' and rows.selectable_row_indices.len != 0 and idx > 0) {
                idx -= 1;
                number_len = 0;
                continue;
            }
            if (b[i] == 'j' and rows.selectable_row_indices.len != 0 and idx + 1 < rows.selectable_row_indices.len) {
                idx += 1;
                number_len = 0;
                continue;
            }
            if (b[i] == 0x7f or b[i] == 0x08) {
                if (number_len > 0) {
                    number_len -= 1;
                    if (parsedDisplayedIndex(number_buf[0..number_len], total_accounts)) |displayed_idx| {
                        if (selectableIndexForDisplayedAccount(&rows, displayed_idx)) |selectable_idx| {
                            idx = selectable_idx;
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
                            idx = selectable_idx;
                        }
                    }
                }
                continue;
            }
        }
    }
}

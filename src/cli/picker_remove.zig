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
const indexWidth = row_data.indexWidth;
const renderRemoveList = render.renderRemoveList;
const TuiSession = tui_mod.TuiSession;
const readTuiEscapeAction = tui_mod.readTuiEscapeAction;
const tui_poll_error_mask = tui_mod.tui_poll_error_mask;
const tui_escape_sequence_timeout_ms = tui_mod.tui_escape_sequence_timeout_ms;
const writeTuiPromptLine = tui_mod.writeTuiPromptLine;
const writeRemoveTuiFooter = tui_mod.writeRemoveTuiFooter;
const mapTuiOutputError = tui_mod.mapTuiOutputError;
const readFileOnce = io.readFileOnce;
const accountIndexForSelectable = nav.accountIndexForSelectable;
const isQuitKey = nav.isQuitKey;

pub fn shouldUseNumberedRemoveSelector(is_windows: bool, stdin_is_tty: bool, stdout_is_tty: bool) bool {
    _ = is_windows;
    return !stdin_is_tty or !stdout_is_tty;
}

pub fn selectAccountsToRemove(allocator: std.mem.Allocator, reg: *registry.Registry) !?[]usize {
    return selectAccountsToRemoveWithUsageOverrides(allocator, reg, null);
}

pub fn selectAccountsToRemoveWithUsageOverrides(
    allocator: std.mem.Allocator,
    reg: *registry.Registry,
    usage_overrides: ?[]const ?[]const u8,
) !?[]usize {
    if (shouldUseNumberedRemoveSelector(
        comptime builtin.os.tag == .windows,
        std.Io.File.stdin().isTty(app_runtime.io()) catch false,
        std.Io.File.stdout().isTty(app_runtime.io()) catch false,
    )) {
        return selectRemoveWithNumbers(allocator, reg, usage_overrides);
    }
    return selectRemoveInteractive(allocator, reg, usage_overrides) catch |err| switch (err) {
        error.TuiRequiresTty => selectRemoveWithNumbers(allocator, reg, usage_overrides),
        else => return err,
    };
}

fn selectRemoveWithNumbers(
    allocator: std.mem.Allocator,
    reg: *registry.Registry,
    usage_overrides: ?[]const ?[]const u8,
) !?[]usize {
    var stdout: io_util.Stdout = undefined;
    stdout.init();
    const out = stdout.out();
    if (reg.accounts.items.len == 0) return null;
    var rows = try buildSwitchRowsWithUsageOverrides(allocator, reg, usage_overrides);
    defer rows.deinit(allocator);
    const use_color = style.stdoutColorEnabled();
    const idx_width = @max(@as(usize, 2), indexWidth(rows.selectable_row_indices.len));
    const widths = rows.widths;

    var checked = try allocator.alloc(bool, rows.selectable_row_indices.len);
    defer allocator.free(checked);
    @memset(checked, false);

    try out.writeAll("Select accounts to delete:\n\n");
    try renderRemoveList(out, reg, rows.items, idx_width, widths, null, checked, use_color);
    try out.writeAll("Enter account numbers (comma/space separated, empty to cancel): ");
    try out.flush();

    var buf: [256]u8 = undefined;
    const n = try readFileOnce(std.Io.File.stdin(), &buf);
    const line = std.mem.trim(u8, buf[0..n], " \n\r\t");
    if (line.len == 0) return null;
    if (!isStrictRemoveSelectionLine(line)) return error.InvalidRemoveSelectionInput;

    var current: usize = 0;
    var in_number = false;
    for (line) |ch| {
        if (ch >= '0' and ch <= '9') {
            current = current * 10 + @as(usize, ch - '0');
            in_number = true;
            continue;
        }
        if (in_number) {
            if (current >= 1 and current <= rows.selectable_row_indices.len) {
                checked[current - 1] = true;
            }
            current = 0;
            in_number = false;
        }
    }
    if (in_number and current >= 1 and current <= rows.selectable_row_indices.len) {
        checked[current - 1] = true;
    }

    var count: usize = 0;
    for (checked) |flag| {
        if (flag) count += 1;
    }
    if (count == 0) return null;
    var selected = try allocator.alloc(usize, count);
    var idx: usize = 0;
    for (checked, 0..) |flag, i| {
        if (!flag) continue;
        selected[idx] = accountIndexForSelectable(&rows, i);
        idx += 1;
    }
    return selected;
}

fn isStrictRemoveSelectionLine(line: []const u8) bool {
    for (line) |ch| {
        if ((ch >= '0' and ch <= '9') or ch == ',' or ch == ' ' or ch == '\t') continue;
        return false;
    }
    return true;
}

fn selectRemoveInteractive(
    allocator: std.mem.Allocator,
    reg: *registry.Registry,
    usage_overrides: ?[]const ?[]const u8,
) !?[]usize {
    if (reg.accounts.items.len == 0) return null;
    var rows = try buildSwitchRowsWithUsageOverrides(allocator, reg, usage_overrides);
    defer rows.deinit(allocator);

    var checked = try allocator.alloc(bool, rows.selectable_row_indices.len);
    defer allocator.free(checked);
    @memset(checked, false);

    var tui: TuiSession = undefined;
    try tui.init();
    defer tui.deinit();
    const out = tui.out();
    var idx: usize = 0;
    var number_buf: [8]u8 = undefined;
    var number_len: usize = 0;
    const use_color = terminal_color.fileColorEnabled(tui.output);
    const idx_width = @max(@as(usize, 2), indexWidth(rows.selectable_row_indices.len));
    const widths = rows.widths;

    while (true) {
        try tui.resetFrame();
        writeTuiPromptLine(out, "Select accounts to delete:", number_buf[0..number_len]) catch |err| return mapTuiOutputError(err);
        out.writeAll("\n") catch |err| return mapTuiOutputError(err);
        renderRemoveList(out, reg, rows.items, idx_width, widths, idx, checked, use_color) catch |err| return mapTuiOutputError(err);
        out.writeAll("\n") catch |err| return mapTuiOutputError(err);
        writeRemoveTuiFooter(out, use_color) catch |err| return mapTuiOutputError(err);
        try tui.flushOutput();

        if (comptime builtin.os.tag == .windows) {
            switch (try tui.readWindowsKey()) {
                .move_up, .keyboard_up, .scroll_up, .page_up => {
                    if (idx > 0) {
                        idx -= 1;
                        number_len = 0;
                    }
                },
                .home => {
                    idx = 0;
                    number_len = 0;
                },
                .move_down, .keyboard_down, .scroll_down, .page_down => {
                    if (idx + 1 < rows.selectable_row_indices.len) {
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
                    var count: usize = 0;
                    for (checked) |flag| {
                        if (flag) count += 1;
                    }
                    if (count == 0) return null;
                    var selected = try allocator.alloc(usize, count);
                    var out_idx: usize = 0;
                    for (checked, 0..) |flag, sel_idx| {
                        if (!flag) continue;
                        selected[out_idx] = accountIndexForSelectable(&rows, sel_idx);
                        out_idx += 1;
                    }
                    return selected;
                },
                .quit => return null,
                .backspace => {
                    if (number_len > 0) {
                        number_len -= 1;
                        if (number_len > 0) {
                            const parsed = std.fmt.parseInt(usize, number_buf[0..number_len], 10) catch 0;
                            if (parsed >= 1 and parsed <= rows.selectable_row_indices.len) {
                                idx = parsed - 1;
                            }
                        }
                    }
                },
                .redraw => continue,
                .byte => |ch| {
                    if (isQuitKey(ch)) return null;
                    if (ch == 'k' and idx > 0) {
                        idx -= 1;
                        number_len = 0;
                        continue;
                    }
                    if (ch == 'j' and idx + 1 < rows.selectable_row_indices.len) {
                        idx += 1;
                        number_len = 0;
                        continue;
                    }
                    if (ch == ' ') {
                        checked[idx] = !checked[idx];
                        number_len = 0;
                        continue;
                    }
                    if (ch >= '0' and ch <= '9' and number_len < number_buf.len) {
                        number_buf[number_len] = ch;
                        number_len += 1;
                        const parsed = std.fmt.parseInt(usize, number_buf[0..number_len], 10) catch 0;
                        if (parsed >= 1 and parsed <= rows.selectable_row_indices.len) {
                            idx = parsed - 1;
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
                    .move_up, .keyboard_up, .scroll_up, .page_up, .home => {
                        if (idx > 0) {
                            idx = if (escape.action == .home) 0 else idx - 1;
                            number_len = 0;
                        }
                    },
                    .move_down, .keyboard_down, .scroll_down, .page_down, .end => {
                        if (idx + 1 < rows.selectable_row_indices.len) {
                            idx = if (escape.action == .end) rows.selectable_row_indices.len - 1 else idx + 1;
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
                var count: usize = 0;
                for (checked) |flag| {
                    if (flag) count += 1;
                }
                if (count == 0) return null;
                var selected = try allocator.alloc(usize, count);
                var out_idx: usize = 0;
                for (checked, 0..) |flag, sel_idx| {
                    if (!flag) continue;
                    selected[out_idx] = accountIndexForSelectable(&rows, sel_idx);
                    out_idx += 1;
                }
                return selected;
            }
            if (isQuitKey(b[i])) return null;
            if (b[i] == 'k' and idx > 0) {
                idx -= 1;
                number_len = 0;
                continue;
            }
            if (b[i] == 'j' and idx + 1 < rows.selectable_row_indices.len) {
                idx += 1;
                number_len = 0;
                continue;
            }
            if (b[i] == ' ') {
                checked[idx] = !checked[idx];
                number_len = 0;
                continue;
            }
            if (b[i] == 0x7f or b[i] == 0x08) {
                if (number_len > 0) {
                    number_len -= 1;
                    if (number_len > 0) {
                        const parsed = std.fmt.parseInt(usize, number_buf[0..number_len], 10) catch 0;
                        if (parsed >= 1 and parsed <= rows.selectable_row_indices.len) {
                            idx = parsed - 1;
                        }
                    }
                }
                continue;
            }
            if (b[i] >= '0' and b[i] <= '9') {
                if (number_len < number_buf.len) {
                    number_buf[number_len] = b[i];
                    number_len += 1;
                    const parsed = std.fmt.parseInt(usize, number_buf[0..number_len], 10) catch 0;
                    if (parsed >= 1 and parsed <= rows.selectable_row_indices.len) {
                        idx = parsed - 1;
                    }
                }
                continue;
            }
        }
    }
}

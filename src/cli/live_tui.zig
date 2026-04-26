const std = @import("std");
const app_runtime = @import("../core/runtime.zig");
const registry = @import("../registry/root.zig");
const picker = @import("picker.zig");
const render = @import("render.zig");
const row_data = @import("rows.zig");
const selection = @import("selection.zig");
const tui_mod = @import("tui.zig");

pub const tick_ms = tui_mod.live_ui_tick_ms;
pub const key_buffer_len = 64;
pub const mouse_wheel_rows = 3;
pub const ScrollDirection = enum { up, down };

pub const LiveAutoSwitchState = struct {
    enabled: bool,
    pending: bool = false,

    pub fn init(enabled: bool) @This() {
        return .{ .enabled = enabled };
    }

    pub fn noteRefreshedDisplay(self: *@This()) void {
        self.pending = self.enabled;
    }

    pub fn noteActionDisplay(self: *@This()) void {
        self.pending = false;
    }

    pub fn takePending(self: *@This()) bool {
        if (!self.pending) return false;
        self.pending = false;
        return true;
    }
};

pub fn nowSecond() i64 {
    return std.Io.Timestamp.now(app_runtime.io(), .real).toSeconds();
}

pub fn switchFixedLines(status_line: []const u8, action_line: []const u8) usize {
    var lines: usize = 5;
    if (status_line.len != 0) lines += 1;
    if (action_line.len != 0) lines += 1;
    return lines;
}

pub fn listFixedLines(status_line: []const u8) usize {
    var lines: usize = 5;
    if (status_line.len != 0) lines += 1;
    return lines;
}

pub fn maxTableRows(terminal_rows: usize, fixed_lines: usize) usize {
    return if (terminal_rows <= fixed_lines) 1 else terminal_rows - fixed_lines;
}

pub fn selectedViewport(
    terminal_rows: usize,
    rows: []const row_data.SwitchRow,
    selected_display_idx: ?usize,
    fixed_lines: usize,
    viewport_start: *usize,
) render.LiveListViewport {
    const max_rows = maxTableRows(terminal_rows, fixed_lines);
    viewport_start.* = render.liveViewportStartForDisplayIndex(
        rows,
        selected_display_idx,
        max_rows,
        viewport_start.*,
    );
    return .{
        .start_row = viewport_start.*,
        .max_rows = max_rows,
    };
}

pub fn listViewport(
    terminal_rows: usize,
    row_count: usize,
    fixed_lines: usize,
    viewport_start: *usize,
) render.LiveListViewport {
    const max_rows = maxTableRows(terminal_rows, fixed_lines);
    viewport_start.* = render.clampLiveViewportStart(row_count, max_rows, viewport_start.*);
    return .{
        .start_row = viewport_start.*,
        .max_rows = max_rows,
    };
}

pub fn scrollListViewport(
    row_count: usize,
    max_rows: usize,
    viewport_start: *usize,
    direction: ScrollDirection,
) void {
    scrollListViewportBy(row_count, max_rows, viewport_start, direction, 1);
}

pub fn scrollForward(offset: *usize, amount: usize) void {
    offset.* = std.math.add(usize, offset.*, amount) catch std.math.maxInt(usize);
}

pub fn scrollListViewportBy(
    row_count: usize,
    max_rows: usize,
    viewport_start: *usize,
    direction: ScrollDirection,
    amount: usize,
) void {
    switch (direction) {
        .up => {
            viewport_start.* -|= amount;
        },
        .down => {
            scrollForward(viewport_start, amount);
            viewport_start.* = render.clampLiveViewportStart(row_count, max_rows, viewport_start.*);
        },
    }
}

pub fn buildSelectableRows(
    allocator: std.mem.Allocator,
    display: selection.SwitchSelectionDisplay,
) !row_data.SwitchRows {
    var rows = try row_data.buildSwitchRowsWithUsageOverrides(allocator, display.reg, display.usage_overrides);
    errdefer rows.deinit(allocator);
    try row_data.filterErroredRowsFromSelectableIndices(allocator, &rows);
    return rows;
}

pub const RowsCache = struct {
    rows: ?row_data.SwitchRows = null,

    pub fn deinit(self: *RowsCache, allocator: std.mem.Allocator) void {
        if (self.rows) |*rows| {
            rows.deinit(allocator);
            self.rows = null;
        }
    }

    pub fn invalidate(self: *RowsCache, allocator: std.mem.Allocator) void {
        self.deinit(allocator);
    }

    pub fn ensure(
        self: *RowsCache,
        allocator: std.mem.Allocator,
        display: selection.SwitchSelectionDisplay,
    ) !*row_data.SwitchRows {
        if (self.rows) |*rows| return rows;
        self.rows = try row_data.buildSwitchRowsWithUsageOverrides(allocator, display.reg, display.usage_overrides);
        return &self.rows.?;
    }

    pub fn ensureSelectable(
        self: *RowsCache,
        allocator: std.mem.Allocator,
        display: selection.SwitchSelectionDisplay,
    ) !*row_data.SwitchRows {
        if (self.rows) |*rows| return rows;
        var rows = try buildSelectableRows(allocator, display);
        errdefer rows.deinit(allocator);
        self.rows = rows;
        return &self.rows.?;
    }
};

pub fn resolveSelectedIndex(
    allocator: std.mem.Allocator,
    selected_account_key: *?[]u8,
    rows: *const row_data.SwitchRows,
    reg: *registry.Registry,
) !?usize {
    if (rows.selectable_row_indices.len == 0) return null;
    const selected_idx = if (selected_account_key.*) |key|
        picker.selectableIndexForAccountKey(rows, reg, key) orelse picker.activeSelectableIndex(rows) orelse 0
    else
        picker.activeSelectableIndex(rows) orelse 0;
    try picker.replaceSelectedAccountKeyForSelectable(allocator, selected_account_key, rows, reg, selected_idx);
    return selected_idx;
}

pub fn moveSelectedIndex(
    allocator: std.mem.Allocator,
    selected_account_key: *?[]u8,
    rows: *const row_data.SwitchRows,
    reg: *registry.Registry,
    direction: ScrollDirection,
) !bool {
    const selected_idx = (try resolveSelectedIndex(allocator, selected_account_key, rows, reg)) orelse return false;
    const next_idx = switch (direction) {
        .up => if (selected_idx > 0) selected_idx - 1 else return false,
        .down => if (selected_idx + 1 < rows.selectable_row_indices.len) selected_idx + 1 else return false,
    };
    try picker.replaceSelectedAccountKeyForSelectable(allocator, selected_account_key, rows, reg, next_idx);
    return true;
}

pub fn moveSelectedIndexForKey(
    allocator: std.mem.Allocator,
    selected_account_key: *?[]u8,
    rows: *const row_data.SwitchRows,
    reg: *registry.Registry,
    key: tui_mod.TuiInputKey,
) !bool {
    const direction: ScrollDirection = switch (key) {
        .move_up => .up,
        .move_down => .down,
        .byte => |ch| switch (ch) {
            'k' => .up,
            'j' => .down,
            else => return false,
        },
        else => return false,
    };
    return try moveSelectedIndex(allocator, selected_account_key, rows, reg, direction);
}

pub fn moveSelectedIndexBy(
    allocator: std.mem.Allocator,
    selected_account_key: *?[]u8,
    rows: *const row_data.SwitchRows,
    reg: *registry.Registry,
    direction: ScrollDirection,
    amount: usize,
) !bool {
    if (amount == 0) return false;
    const selected_idx = (try resolveSelectedIndex(allocator, selected_account_key, rows, reg)) orelse return false;
    const last_idx = rows.selectable_row_indices.len - 1;
    const next_idx = switch (direction) {
        .up => selected_idx -| amount,
        .down => @min(last_idx, std.math.add(usize, selected_idx, amount) catch last_idx),
    };
    if (next_idx == selected_idx) return false;
    try picker.replaceSelectedAccountKeyForSelectable(allocator, selected_account_key, rows, reg, next_idx);
    return true;
}

pub fn moveSelectedIndexToEdge(
    allocator: std.mem.Allocator,
    selected_account_key: *?[]u8,
    rows: *const row_data.SwitchRows,
    reg: *registry.Registry,
    direction: ScrollDirection,
) !bool {
    const selected_idx = (try resolveSelectedIndex(allocator, selected_account_key, rows, reg)) orelse return false;
    const next_idx = switch (direction) {
        .up => 0,
        .down => rows.selectable_row_indices.len - 1,
    };
    if (next_idx == selected_idx) return false;
    try picker.replaceSelectedAccountKeyForSelectable(allocator, selected_account_key, rows, reg, next_idx);
    return true;
}

pub fn updateSelectedFromDisplayedDigits(
    allocator: std.mem.Allocator,
    selected_account_key: *?[]u8,
    rows: *const row_data.SwitchRows,
    reg: *registry.Registry,
    digits: []const u8,
) !bool {
    const displayed_idx = picker.parsedDisplayedIndex(digits, picker.accountRowCount(rows.items)) orelse return false;
    const selectable_idx = picker.selectableIndexForDisplayedAccount(rows, displayed_idx) orelse return false;
    try picker.replaceSelectedAccountKeyForSelectable(allocator, selected_account_key, rows, reg, selectable_idx);
    return true;
}

pub fn updateSelectedFromSelectableDigits(
    allocator: std.mem.Allocator,
    selected_account_key: *?[]u8,
    rows: *const row_data.SwitchRows,
    reg: *registry.Registry,
    digits: []const u8,
) !bool {
    if (digits.len == 0 or rows.selectable_row_indices.len == 0) return false;
    const parsed = std.fmt.parseInt(usize, digits, 10) catch return false;
    if (parsed == 0 or parsed > rows.selectable_row_indices.len) return false;
    try picker.replaceSelectedAccountKeyForSelectable(allocator, selected_account_key, rows, reg, parsed - 1);
    return true;
}

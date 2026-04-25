const std = @import("std");
const registry = @import("../registry/root.zig");
const row_data = @import("rows.zig");

const SwitchRow = row_data.SwitchRow;
const SwitchRows = row_data.SwitchRows;

pub fn isQuitInput(input: []const u8) bool {
    return input.len == 1 and (input[0] == 'q' or input[0] == 'Q');
}

pub fn isQuitKey(key: u8) bool {
    return key == 'q' or key == 'Q';
}

pub fn activeSelectableIndex(rows: *const SwitchRows) ?usize {
    for (rows.selectable_row_indices, 0..) |row_idx, pos| {
        if (rows.items[row_idx].is_active) return pos;
    }
    return null;
}

pub fn accountIdForSelectable(rows: *const SwitchRows, reg: *registry.Registry, selectable_idx: usize) []const u8 {
    const row_idx = rows.selectable_row_indices[selectable_idx];
    const account_idx = rows.items[row_idx].account_index.?;
    return reg.accounts.items[account_idx].account_key;
}

pub fn accountRowCount(rows: []const SwitchRow) usize {
    var count: usize = 0;
    for (rows) |row| {
        if (!row.is_header) count += 1;
    }
    return count;
}

fn rowIndexForDisplayedAccount(rows: []const SwitchRow, displayed_idx: usize) ?usize {
    var current: usize = 0;
    for (rows, 0..) |row, row_idx| {
        if (row.is_header) continue;
        if (current == displayed_idx) return row_idx;
        current += 1;
    }
    return null;
}

fn displayedIndexForRowIndex(rows: []const SwitchRow, row_idx: usize) ?usize {
    if (row_idx >= rows.len or rows[row_idx].is_header) return null;
    var current: usize = 0;
    for (rows, 0..) |row, idx| {
        if (row.is_header) continue;
        if (idx == row_idx) return current;
        current += 1;
    }
    return null;
}

pub fn displayedIndexForSelectable(rows: *const SwitchRows, selectable_idx: usize) ?usize {
    if (selectable_idx >= rows.selectable_row_indices.len) return null;
    return displayedIndexForRowIndex(rows.items, rows.selectable_row_indices[selectable_idx]);
}

pub fn selectableIndexForDisplayedAccount(rows: *const SwitchRows, displayed_idx: usize) ?usize {
    const row_idx = rowIndexForDisplayedAccount(rows.items, displayed_idx) orelse return null;
    for (rows.selectable_row_indices, 0..) |selectable_row_idx, selectable_idx| {
        if (selectable_row_idx == row_idx) return selectable_idx;
    }
    return null;
}

pub fn accountIdForDisplayedAccount(
    rows: *const SwitchRows,
    reg: *registry.Registry,
    displayed_idx: usize,
) ?[]const u8 {
    const row_idx = rowIndexForDisplayedAccount(rows.items, displayed_idx) orelse return null;
    const account_idx = rows.items[row_idx].account_index orelse return null;
    return reg.accounts.items[account_idx].account_key;
}

pub fn dupSelectedAccountKeyForDisplayedAccount(
    allocator: std.mem.Allocator,
    rows: *const SwitchRows,
    reg: *registry.Registry,
    displayed_idx: usize,
) !?[]const u8 {
    const account_key = accountIdForDisplayedAccount(rows, reg, displayed_idx) orelse return null;
    return try allocator.dupe(u8, account_key);
}

pub fn parsedDisplayedIndex(number_input: []const u8, total_accounts: usize) ?usize {
    if (number_input.len == 0) return null;
    const parsed = std.fmt.parseInt(usize, number_input, 10) catch return null;
    if (parsed == 0 or parsed > total_accounts) return null;
    return parsed - 1;
}

pub fn selectedDisplayIndexForRender(
    rows: *const SwitchRows,
    selected_selectable_idx: ?usize,
    number_input: []const u8,
) ?usize {
    if (parsedDisplayedIndex(number_input, accountRowCount(rows.items))) |displayed_idx| {
        return displayed_idx;
    }
    if (selected_selectable_idx) |selectable_idx| {
        return displayedIndexForSelectable(rows, selectable_idx);
    }
    return null;
}

pub fn dupSelectedAccountKey(
    allocator: std.mem.Allocator,
    rows: *const SwitchRows,
    reg: *registry.Registry,
    selectable_idx: usize,
) ![]const u8 {
    return try allocator.dupe(u8, accountIdForSelectable(rows, reg, selectable_idx));
}

pub fn dupeOptionalAccountKey(allocator: std.mem.Allocator, account_key: ?[]const u8) !?[]const u8 {
    return if (account_key) |value| try allocator.dupe(u8, value) else null;
}

pub fn accountIndexForSelectable(rows: *const SwitchRows, selectable_idx: usize) usize {
    const row_idx = rows.selectable_row_indices[selectable_idx];
    return rows.items[row_idx].account_index.?;
}

pub fn selectableIndexForAccountKey(
    rows: *const SwitchRows,
    reg: *registry.Registry,
    account_key: []const u8,
) ?usize {
    for (rows.selectable_row_indices, 0..) |row_idx, selectable_idx| {
        const account_idx = rows.items[row_idx].account_index orelse continue;
        if (std.mem.eql(u8, reg.accounts.items[account_idx].account_key, account_key)) return selectable_idx;
    }
    return null;
}

pub fn replaceSelectedAccountKeyForSelectable(
    allocator: std.mem.Allocator,
    selected_account_key: *?[]u8,
    rows: *const SwitchRows,
    reg: *registry.Registry,
    selectable_idx: usize,
) !void {
    const next_key = try allocator.dupe(u8, accountIdForSelectable(rows, reg, selectable_idx));
    if (selected_account_key.*) |current_key| allocator.free(current_key);
    selected_account_key.* = next_key;
}

pub fn replaceOptionalOwnedString(
    allocator: std.mem.Allocator,
    target: *?[]u8,
    next: ?[]u8,
) void {
    if (target.*) |current| allocator.free(current);
    target.* = next;
}

pub fn accountKeyForSelectableAlloc(
    allocator: std.mem.Allocator,
    rows: *const SwitchRows,
    reg: *registry.Registry,
    selectable_idx: usize,
) ![]u8 {
    return try allocator.dupe(u8, accountIdForSelectable(rows, reg, selectable_idx));
}

pub fn firstSelectableAccountKeyAlloc(
    allocator: std.mem.Allocator,
    rows: *const SwitchRows,
    reg: *registry.Registry,
) !?[]u8 {
    if (rows.selectable_row_indices.len == 0) return null;
    return try accountKeyForSelectableAlloc(allocator, rows, reg, 0);
}

pub fn removeOwnedAccountKey(
    allocator: std.mem.Allocator,
    keys: *std.ArrayList([]u8),
    account_key: []const u8,
) bool {
    for (keys.items, 0..) |key, idx| {
        if (!std.mem.eql(u8, key, account_key)) continue;
        allocator.free(key);
        _ = keys.orderedRemove(idx);
        return true;
    }
    return false;
}

pub fn containsOwnedAccountKey(keys: *const std.ArrayList([]u8), account_key: []const u8) bool {
    for (keys.items) |key| {
        if (std.mem.eql(u8, key, account_key)) return true;
    }
    return false;
}

pub fn toggleOwnedAccountKey(
    allocator: std.mem.Allocator,
    keys: *std.ArrayList([]u8),
    account_key: []const u8,
) !void {
    if (removeOwnedAccountKey(allocator, keys, account_key)) return;
    try keys.append(allocator, try allocator.dupe(u8, account_key));
}

pub fn clearOwnedAccountKeys(allocator: std.mem.Allocator, keys: *std.ArrayList([]u8)) void {
    for (keys.items) |key| allocator.free(key);
    keys.clearRetainingCapacity();
}

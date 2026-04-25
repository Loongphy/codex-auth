const std = @import("std");
const display_rows = @import("../tui/display.zig");
const registry = @import("../registry/root.zig");

pub const SwitchQueryResolution = union(enum) {
    not_found,
    direct: []const u8,
    multiple: std.ArrayList(usize),

    pub fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
        switch (self.*) {
            .multiple => |*matches| matches.deinit(allocator),
            else => {},
        }
        self.* = undefined;
    }
};

pub fn resolveSwitchQueryLocally(
    allocator: std.mem.Allocator,
    reg: *registry.Registry,
    query: []const u8,
) !SwitchQueryResolution {
    if (try findAccountIndexByDisplayNumber(allocator, reg, query)) |account_idx| {
        return .{ .direct = reg.accounts.items[account_idx].account_key };
    }

    var matches = try findMatchingAccounts(allocator, reg, query);
    if (matches.items.len == 0) {
        matches.deinit(allocator);
        return .not_found;
    }
    if (matches.items.len == 1) {
        defer matches.deinit(allocator);
        return .{ .direct = reg.accounts.items[matches.items[0]].account_key };
    }
    return .{ .multiple = matches };
}

pub fn findMatchingAccounts(
    allocator: std.mem.Allocator,
    reg: *registry.Registry,
    query: []const u8,
) !std.ArrayList(usize) {
    var matches = std.ArrayList(usize).empty;
    for (reg.accounts.items, 0..) |*rec, idx| {
        const matches_email = std.ascii.indexOfIgnoreCase(rec.email, query) != null;
        const matches_alias = rec.alias.len != 0 and std.ascii.indexOfIgnoreCase(rec.alias, query) != null;
        const matches_name = if (rec.account_name) |name|
            name.len != 0 and std.ascii.indexOfIgnoreCase(name, query) != null
        else
            false;
        if (matches_email or matches_alias or matches_name) {
            try matches.append(allocator, idx);
        }
    }
    return matches;
}

pub fn findMatchingAccountsForRemove(
    allocator: std.mem.Allocator,
    reg: *registry.Registry,
    query: []const u8,
) !std.ArrayList(usize) {
    var matches = std.ArrayList(usize).empty;
    for (reg.accounts.items, 0..) |*rec, idx| {
        const matches_email = std.ascii.indexOfIgnoreCase(rec.email, query) != null;
        const matches_alias = rec.alias.len != 0 and std.ascii.indexOfIgnoreCase(rec.alias, query) != null;
        const matches_name = if (rec.account_name) |name|
            name.len != 0 and std.ascii.indexOfIgnoreCase(name, query) != null
        else
            false;
        const matches_key = std.ascii.indexOfIgnoreCase(rec.account_key, query) != null;
        if (matches_email or matches_alias or matches_name or matches_key) {
            try matches.append(allocator, idx);
        }
    }
    return matches;
}

pub fn parseDisplayNumber(selector: []const u8) ?usize {
    if (selector.len == 0) return null;
    for (selector) |ch| {
        if (ch < '0' or ch > '9') return null;
    }

    const parsed = std.fmt.parseInt(usize, selector, 10) catch return null;
    if (parsed == 0) return null;
    return parsed;
}

pub fn findAccountIndexByDisplayNumber(
    allocator: std.mem.Allocator,
    reg: *registry.Registry,
    selector: []const u8,
) !?usize {
    const display_number = parseDisplayNumber(selector) orelse return null;

    var display = try display_rows.buildDisplayRows(allocator, reg, null);
    defer display.deinit(allocator);

    if (display_number > display.selectable_row_indices.len) return null;
    const row_idx = display.selectable_row_indices[display_number - 1];
    return display.rows[row_idx].account_index;
}

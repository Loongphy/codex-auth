const std = @import("std");
const registry = @import("registry.zig");

pub const DisplayRow = struct {
    account_index: ?usize,
    account_cell: []u8,
    depth: u8,
    is_active: bool,

    fn deinit(self: *DisplayRow, allocator: std.mem.Allocator) void {
        allocator.free(self.account_cell);
    }
};

pub const DisplayRows = struct {
    rows: []DisplayRow,
    selectable_row_indices: []usize,

    pub fn deinit(self: *DisplayRows, allocator: std.mem.Allocator) void {
        for (self.rows) |*row| row.deinit(allocator);
        allocator.free(self.rows);
        allocator.free(self.selectable_row_indices);
    }
};

pub fn buildDisplayRows(
    allocator: std.mem.Allocator,
    reg: *const registry.Registry,
    account_indices: ?[]const usize,
) !DisplayRows {
    const source_len = if (account_indices) |indices| indices.len else reg.accounts.items.len;
    var ordered = try allocator.alloc(usize, source_len);
    defer allocator.free(ordered);

    if (account_indices) |indices| {
        @memcpy(ordered, indices);
    } else {
        for (ordered, 0..) |*slot, idx| slot.* = idx;
    }

    std.sort.insertion(usize, ordered, SortContext{ .reg = reg }, lessThanByDisplayOrder);

    var row_list = std.ArrayList(DisplayRow).empty;
    errdefer for (row_list.items) |*row| row.deinit(allocator);
    defer row_list.deinit(allocator);
    var selectable = std.ArrayList(usize).empty;
    defer selectable.deinit(allocator);

    var i: usize = 0;
    while (i < ordered.len) {
        const group_start = i;
        const email = reg.accounts.items[ordered[i]].email;
        while (i < ordered.len and std.mem.eql(u8, reg.accounts.items[ordered[i]].email, email)) : (i += 1) {}
        const group_indices = ordered[group_start..i];

        if (group_indices.len == 1) {
            const account_idx = group_indices[0];
            const rec = &reg.accounts.items[account_idx];
            const cell = try singletonAccountCellAlloc(allocator, rec);
            row_list.append(allocator, .{
                .account_index = account_idx,
                .account_cell = cell,
                .depth = 0,
                .is_active = isActive(reg, account_idx),
            }) catch |err| {
                allocator.free(cell);
                return err;
            };
            try selectable.append(allocator, row_list.items.len - 1);
            continue;
        }

        const header_cell = try allocator.dupe(u8, email);
        row_list.append(allocator, .{
            .account_index = null,
            .account_cell = header_cell,
            .depth = 0,
            .is_active = false,
        }) catch |err| {
            allocator.free(header_cell);
            return err;
        };

        for (group_indices) |account_idx| {
            const cell = try groupedAccountCellAlloc(allocator, reg, group_indices, account_idx);
            row_list.append(allocator, .{
                .account_index = account_idx,
                .account_cell = cell,
                .depth = 1,
                .is_active = isActive(reg, account_idx),
            }) catch |err| {
                allocator.free(cell);
                return err;
            };
            try selectable.append(allocator, row_list.items.len - 1);
        }
    }

    const rows = try row_list.toOwnedSlice(allocator);
    errdefer {
        for (rows) |*row| row.deinit(allocator);
        allocator.free(rows);
    }

    return .{
        .rows = rows,
        .selectable_row_indices = try selectable.toOwnedSlice(allocator),
    };
}

const SortContext = struct {
    reg: *const registry.Registry,
};

fn lessThanByDisplayOrder(ctx: SortContext, lhs: usize, rhs: usize) bool {
    const reg = ctx.reg;
    const a = &reg.accounts.items[lhs];
    const b = &reg.accounts.items[rhs];

    const email_cmp = std.mem.order(u8, a.email, b.email);
    if (email_cmp != .eq) return email_cmp == .lt;

    const a_active = isActive(reg, lhs);
    const b_active = isActive(reg, rhs);
    if (a_active != b_active) return a_active;

    const a_rank = planSortRank(registry.resolveDisplayPlan(a));
    const b_rank = planSortRank(registry.resolveDisplayPlan(b));
    if (a_rank != b_rank) return a_rank < b_rank;

    const a_plan = displayPlan(a);
    const b_plan = displayPlan(b);
    const plan_cmp = std.mem.order(u8, a_plan, b_plan);
    if (plan_cmp != .eq) return plan_cmp == .lt;

    return std.mem.lessThan(u8, a.account_key, b.account_key);
}

fn planSortRank(plan: ?registry.PlanType) u8 {
    return switch (plan orelse .unknown) {
        .team, .business, .enterprise, .edu => 0,
        .free, .plus, .prolite, .pro => 1,
        else => 2,
    };
}

fn displayPlan(rec: *const registry.AccountRecord) []const u8 {
    return if (registry.resolveDisplayPlan(rec)) |plan| registry.planLabel(plan) else "-";
}

fn isActive(reg: *const registry.Registry, account_idx: usize) bool {
    const active = reg.active_account_key orelse return false;
    return std.mem.eql(u8, active, reg.accounts.items[account_idx].account_key);
}

fn singletonAccountCellAlloc(allocator: std.mem.Allocator, rec: *const registry.AccountRecord) ![]u8 {
    return allocator.dupe(u8, rec.email);
}

fn groupedAccountCellAlloc(
    allocator: std.mem.Allocator,
    reg: *const registry.Registry,
    group_indices: []const usize,
    account_idx: usize,
) ![]u8 {
    const rec = &reg.accounts.items[account_idx];
    const base = displayPlan(rec);
    var total_same: usize = 0;
    var ordinal: usize = 1;
    for (group_indices) |candidate_idx| {
        const candidate = &reg.accounts.items[candidate_idx];
        if (candidate.alias.len != 0) continue;
        if (!std.mem.eql(u8, displayPlan(candidate), base)) continue;
        total_same += 1;
        if (candidate_idx == account_idx) continue;
        if (std.mem.lessThan(u8, candidate.account_key, rec.account_key)) {
            ordinal += 1;
        }
    }

    const fallback = if (total_same <= 1)
        try allocator.dupe(u8, base)
    else
        try std.fmt.allocPrint(allocator, "{s} #{d}", .{ base, ordinal });
    defer allocator.free(fallback);

    return buildPreferredAccountLabelAlloc(allocator, rec, fallback);
}

pub fn buildPreferredAccountLabelAlloc(
    allocator: std.mem.Allocator,
    rec: *const registry.AccountRecord,
    fallback: []const u8,
) ![]u8 {
    const alias = if (rec.alias.len != 0) rec.alias else null;
    const account_name = normalizedAccountName(rec);

    if (alias != null and account_name != null) {
        return std.fmt.allocPrint(allocator, "{s} ({s})", .{ alias.?, account_name.? });
    }
    if (alias != null) return allocator.dupe(u8, alias.?);
    if (account_name != null) return allocator.dupe(u8, account_name.?);
    return allocator.dupe(u8, fallback);
}

fn normalizedAccountName(rec: *const registry.AccountRecord) ?[]const u8 {
    const account_name = rec.account_name orelse return null;
    if (account_name.len == 0) return null;
    return account_name;
}

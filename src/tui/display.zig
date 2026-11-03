const std = @import("std");
const registry = @import("../registry/root.zig");

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
        // A singleton is a group of one: the same label resolution applies,
        // only the email placement differs — a group header row carries it,
        // a singleton row carries it in its own cell.
        const grouped = group_indices.len > 1;

        if (grouped) {
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
        }

        for (group_indices) |account_idx| {
            const cell = try accountCellAlloc(allocator, reg, group_indices, account_idx);
            row_list.append(allocator, .{
                .account_index = account_idx,
                .account_cell = cell,
                .depth = if (grouped) 1 else 0,
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

    // Within one email group, rows order alphabetically by the label they
    // display, so the order the user reads is the order the user sees.
    // account_key keeps it stable (and matches the "#N" fallback ordinals).
    var a_buf: [apikey_label_len]u8 = undefined;
    var b_buf: [apikey_label_len]u8 = undefined;
    const label_cmp = std.mem.order(u8, groupSortLabel(a, &a_buf), groupSortLabel(b, &b_buf));
    if (label_cmp != .eq) return label_cmp == .lt;

    return std.mem.lessThan(u8, a.account_key, b.account_key);
}

/// "sk-" + 5 fingerprint chars + "***" + 4 fingerprint chars.
const apikey_label_len = 15;

/// The label a grouped row displays, as a sort key: alias, else the apikey
/// fingerprint (grouped apikey rows show it ahead of the account name), else
/// account name, else the plan fallback that groupFallbackLabelAlloc produces.
/// `buf` backs the formatted fingerprint label so sorting stays
/// allocation-free; the returned slice borrows either `buf` or the record.
fn groupSortLabel(rec: *const registry.AccountRecord, buf: *[apikey_label_len]u8) []const u8 {
    if (rec.alias.len != 0) return rec.alias;
    if (rec.auth_mode != null and rec.auth_mode.? == .apikey) {
        if (apiKeyFingerprintSlice(rec.account_key)) |fingerprint| {
            return std.fmt.bufPrint(buf, "sk-{s}***{s}", .{
                fingerprint[0..5],
                fingerprint[fingerprint.len - 4 ..],
            }) catch displayPlan(rec);
        }
    }
    if (normalizedAccountName(rec)) |name| return name;
    return displayPlan(rec);
}

pub fn displayPlan(rec: *const registry.AccountRecord) []const u8 {
    if (rec.auth_mode != null and rec.auth_mode.? == .apikey) return "API_KEY";
    return if (registry.resolveDisplayPlan(rec)) |plan| registry.planLabel(plan) else "-";
}

fn isActive(reg: *const registry.Registry, account_idx: usize) bool {
    const active = reg.active_account_key orelse return false;
    return std.mem.eql(u8, active, reg.accounts.items[account_idx].account_key);
}

/// One precedence chain for what identifies an account row: alias, then
/// account name, then — only inside a group, where the header row already
/// shows the email — the masked apikey fingerprint. The two cell shapes are
/// thin formatters over this shared resolution.
const AccountLabel = struct {
    alias: ?[]const u8,
    account_name: ?[]const u8,
    fingerprint: ?[]u8,

    fn deinit(self: AccountLabel, allocator: std.mem.Allocator) void {
        if (self.fingerprint) |value| allocator.free(value);
    }
};

fn resolveAccountLabel(allocator: std.mem.Allocator, rec: *const registry.AccountRecord, grouped: bool) !AccountLabel {
    return .{
        .alias = if (rec.alias.len != 0) rec.alias else null,
        .account_name = normalizedAccountName(rec),
        .fingerprint = if (grouped and rec.auth_mode != null and rec.auth_mode.? == .apikey)
            try apiKeyLabelFromAccountKeyAlloc(allocator, rec.account_key)
        else
            null,
    };
}

/// The cell for one account row in a group of `group_indices` (a singleton
/// is a group of one). Label resolution is shared; only the email placement
/// differs — a grouped child leaves the email to the header row, a singleton
/// carries it in its own cell via buildAccountIdentityLabelAlloc.
fn accountCellAlloc(
    allocator: std.mem.Allocator,
    reg: *const registry.Registry,
    group_indices: []const usize,
    account_idx: usize,
) ![]u8 {
    const rec = &reg.accounts.items[account_idx];
    if (group_indices.len == 1) return buildAccountIdentityLabelAlloc(allocator, rec);

    const label = try resolveAccountLabel(allocator, rec, true);
    defer label.deinit(allocator);
    if (label.alias) |alias| {
        if (label.fingerprint orelse label.account_name) |detail|
            return allocator.print("{s}({s})", .{ alias, detail });
        return allocator.dupe(u8, alias);
    }
    if (label.fingerprint) |fingerprint| return allocator.dupe(u8, fingerprint);
    if (label.account_name) |name| return allocator.dupe(u8, name);
    return groupFallbackLabelAlloc(allocator, reg, group_indices, account_idx);
}

/// The label for a grouped row whose account has neither alias nor account
/// name: the plan, disambiguated with a 1-based ordinal when several
/// alias-less accounts of the same plan share the email.
fn groupFallbackLabelAlloc(
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
    if (total_same <= 1) return allocator.dupe(u8, base);
    return allocator.print("{s} #{d}", .{ base, ordinal });
}

/// Singleton shape over the shared label resolution: the row must carry the
/// email itself (no group header shows it), and never the apikey fingerprint.
pub fn buildAccountIdentityLabelAlloc(
    allocator: std.mem.Allocator,
    rec: *const registry.AccountRecord,
) ![]u8 {
    const label = try resolveAccountLabel(allocator, rec, false);
    if (label.alias != null and label.account_name != null) {
        return allocator.print("{s}({s}, {s})", .{ label.alias.?, label.account_name.?, rec.email });
    }
    if (label.alias) |alias| {
        return allocator.print("{s}({s})", .{ alias, rec.email });
    }
    if (label.account_name) |name| {
        return allocator.print("{s}({s})", .{ name, rec.email });
    }
    return allocator.dupe(u8, rec.email);
}

fn normalizedAccountName(rec: *const registry.AccountRecord) ?[]const u8 {
    const account_name = rec.account_name orelse return null;
    if (account_name.len == 0) return null;
    return account_name;
}

/// The raw fingerprint an apikey account_key carries (`apikey::<…>::<fp>`);
/// shared by the displayed `sk-…***…` label and the group sort key.
fn apiKeyFingerprintSlice(account_key: []const u8) ?[]const u8 {
    if (!std.mem.startsWith(u8, account_key, "apikey::")) return null;
    const sep = std.mem.findLast(u8, account_key, "::") orelse return null;
    const fingerprint = account_key[sep + 2 ..];
    if (fingerprint.len < 9) return null;
    return fingerprint;
}

fn apiKeyLabelFromAccountKeyAlloc(allocator: std.mem.Allocator, account_key: []const u8) !?[]u8 {
    const fingerprint = apiKeyFingerprintSlice(account_key) orelse return null;
    const label = try allocator.print("sk-{s}***{s}", .{
        fingerprint[0..5],
        fingerprint[fingerprint.len - 4 ..],
    });
    return label;
}

const std = @import("std");
const cli = @import("../cli/root.zig");
const registry = @import("../registry/root.zig");
const query_mod = @import("query.zig");

pub fn handleAlias(allocator: std.mem.Allocator, codex_home: []const u8, opts: cli.types.AliasOptions) !void {
    var reg = try registry.loadRegistry(allocator, codex_home);
    defer reg.deinit(allocator);

    switch (opts) {
        .set => |set_opts| {
            const idx = (try resolveAliasTargetIndex(allocator, &reg, set_opts.selector)) orelse return;
            try validateAlias(&reg, set_opts.alias, idx);
            const old_alias = try allocator.dupe(u8, reg.accounts.items[idx].alias);
            defer allocator.free(old_alias);
            try replaceAlias(allocator, &reg.accounts.items[idx], set_opts.alias);
            try registry.saveRegistry(allocator, codex_home, &reg);
            try cli.output.printAliasSet(&reg.accounts.items[idx], old_alias);
        },
        .clear => |clear_opts| {
            const idx = (try resolveAliasTargetIndex(allocator, &reg, clear_opts.selector)) orelse return;
            const old_alias = try allocator.dupe(u8, reg.accounts.items[idx].alias);
            defer allocator.free(old_alias);
            try replaceAlias(allocator, &reg.accounts.items[idx], "");
            try registry.saveRegistry(allocator, codex_home, &reg);
            try cli.output.printAliasCleared(&reg.accounts.items[idx], old_alias);
        },
    }
}

fn resolveAliasTargetIndex(
    allocator: std.mem.Allocator,
    reg: *registry.Registry,
    selector: []const u8,
) !?usize {
    var resolution = try query_mod.resolveSwitchQueryLocally(allocator, reg, selector);
    defer resolution.deinit(allocator);

    const account_key = switch (resolution) {
        .not_found => {
            try cli.output.printAliasAccountNotFoundError(selector);
            return error.AccountNotFound;
        },
        .direct => |key| key,
        .multiple => |matches| blk: {
            const selected_account_key = cli.picker.selectAccountFromIndicesWithUsageOverrides(
                allocator,
                reg,
                matches.items,
                null,
            ) catch |err| {
                if (err == error.TuiRequiresTty) {
                    try cli.output.printAliasRequiresTtyError();
                    return error.AliasSelectionRequiresTty;
                }
                return err;
            };
            if (selected_account_key == null) return null;
            break :blk selected_account_key.?;
        },
    };
    return registry.findAccountIndexByAccountKey(reg, account_key) orelse error.AccountNotFound;
}

fn replaceAlias(allocator: std.mem.Allocator, rec: *registry.AccountRecord, alias_value: []const u8) !void {
    const owned_alias = try allocator.dupe(u8, alias_value);
    allocator.free(rec.alias);
    rec.alias = owned_alias;
}

fn validateAlias(reg: *registry.Registry, alias_value: []const u8, selected_idx: usize) !void {
    if (alias_value.len == 0) {
        try cli.output.printInvalidAliasError("alias cannot be empty; use `codex-auth alias clear <selector>` to remove one.");
        return error.InvalidAlias;
    }
    if (query_mod.parseDisplayNumber(alias_value) != null) {
        try cli.output.printInvalidAliasError("alias cannot be only digits because numbers select displayed rows.");
        return error.InvalidAlias;
    }
    for (alias_value) |ch| {
        if (ch < 0x20 or ch == 0x7f) {
            try cli.output.printInvalidAliasError("alias cannot contain control characters.");
            return error.InvalidAlias;
        }
    }
    for (reg.accounts.items, 0..) |rec, idx| {
        if (idx == selected_idx) continue;
        if (rec.alias.len != 0 and std.ascii.eqlIgnoreCase(rec.alias, alias_value)) {
            try cli.output.printDuplicateAliasError(alias_value, rec.email);
            return error.DuplicateAlias;
        }
    }
}

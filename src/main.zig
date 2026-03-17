const std = @import("std");
const cli = @import("cli.zig");
const registry = @import("registry.zig");
const auth = @import("auth.zig");
const sessions = @import("sessions.zig");
const format = @import("format.zig");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    var cmd = try cli.parseArgs(allocator, args);
    defer cli.freeCommand(allocator, &cmd);

    const codex_home = try registry.resolveCodexHome(allocator);
    defer allocator.free(codex_home);

    switch (cmd) {
        .list => |opts| try handleList(allocator, codex_home, opts),
        .login => |opts| try handleLogin(allocator, codex_home, opts),
        .import_auth => |opts| try handleImport(allocator, codex_home, opts),
        .switch_account => |opts| try handleSwitch(allocator, codex_home, opts),
        .remove_account => |_| try handleRemove(allocator, codex_home),
        .version => try cli.printVersion(),
        .help => try cli.printHelp(),
    }
}

fn handleList(allocator: std.mem.Allocator, codex_home: []const u8, opts: cli.ListOptions) !void {
    _ = opts;
    var reg = try registry.loadRegistry(allocator, codex_home);
    defer reg.deinit(allocator);
    if (try registry.syncActiveAccountFromAuth(allocator, codex_home, &reg)) {
        try registry.saveRegistry(allocator, codex_home, &reg);
    }
    var needs_refresh = false;
    for (reg.accounts.items) |rec| {
        if (rec.plan == null or rec.auth_mode == null) {
            needs_refresh = true;
            break;
        }
    }
    if (needs_refresh) {
        try registry.refreshAccountsFromAuth(allocator, codex_home, &reg);
        try registry.saveRegistry(allocator, codex_home, &reg);
    }
    if (try refreshActiveUsageFromSessions(allocator, codex_home, &reg)) {
        try registry.saveRegistry(allocator, codex_home, &reg);
    }
    try format.printAccounts(allocator, &reg, .table);
}

fn handleLogin(allocator: std.mem.Allocator, codex_home: []const u8, opts: cli.LoginOptions) !void {
    cli.warnDeprecatedLoginAlias(opts);
    if (opts.launch_codex_login) {
        try cli.runCodexLogin(allocator);
    }
    const auth_path = try registry.activeAuthPath(allocator, codex_home);
    defer allocator.free(auth_path);

    const info = try auth.parseAuthInfo(allocator, auth_path);
    defer info.deinit(allocator);

    var reg = try registry.loadRegistry(allocator, codex_home);
    defer reg.deinit(allocator);

    const record = try registry.accountFromAuth(allocator, "", &info);
    const dest = try registry.accountAuthPath(allocator, codex_home, record.account_id);
    defer allocator.free(dest);

    try registry.ensureAccountsDir(allocator, codex_home);
    try registry.copyFile(auth_path, dest);

    registry.upsertAccount(allocator, &reg, record);
    try registry.saveRegistry(allocator, codex_home, &reg);
}

fn handleImport(allocator: std.mem.Allocator, codex_home: []const u8, opts: cli.ImportOptions) !void {
    var reg = try registry.loadRegistry(allocator, codex_home);
    defer reg.deinit(allocator);
    const summary = try registry.importAuthPath(allocator, codex_home, &reg, opts.auth_path, opts.alias);
    if (summary.imported > 0) {
        try registry.saveRegistry(allocator, codex_home, &reg);
    }
}

fn handleSwitch(allocator: std.mem.Allocator, codex_home: []const u8, opts: cli.SwitchOptions) !void {
    var reg = try registry.loadRegistry(allocator, codex_home);
    defer reg.deinit(allocator);
    if (try registry.syncActiveAccountFromAuth(allocator, codex_home, &reg)) {
        try registry.saveRegistry(allocator, codex_home, &reg);
    }
    if (try refreshActiveUsageFromSessions(allocator, codex_home, &reg)) {
        try registry.saveRegistry(allocator, codex_home, &reg);
    }

    var selected_account_id: ?[]const u8 = null;
    if (opts.email) |target| {
        var matches = try findMatchingAccounts(allocator, &reg, target);
        defer matches.deinit(allocator);

        if (matches.items.len == 0) {
            std.log.err("account not found: {s}", .{target});
            return error.AccountNotFound;
        }

        if (matches.items.len == 1) {
            selected_account_id = reg.accounts.items[matches.items[0]].account_id;
        } else {
            selected_account_id = try cli.selectAccountFromIndices(allocator, &reg, matches.items);
        }
        if (selected_account_id == null) return;
    } else {
        const selected = try cli.selectAccount(allocator, &reg);
        if (selected == null) return;
        selected_account_id = selected.?;
    }
    const account_id = selected_account_id.?;

    const src = try registry.accountAuthPath(allocator, codex_home, account_id);
    defer allocator.free(src);

    const dest = try registry.activeAuthPath(allocator, codex_home);
    defer allocator.free(dest);

    try registry.backupAuthIfChanged(allocator, codex_home, dest, src);
    try registry.copyFile(src, dest);

    try registry.setActiveAccount(allocator, &reg, account_id);
    try registry.saveRegistry(allocator, codex_home, &reg);
}

fn findMatchingAccounts(allocator: std.mem.Allocator, reg: *registry.Registry, query: []const u8) !std.ArrayList(usize) {
    var matches = std.ArrayList(usize).empty;
    const normalized = try allocator.dupe(u8, query);
    defer allocator.free(normalized);
    for (normalized) |*ch| ch.* = std.ascii.toLower(ch.*);

    for (reg.accounts.items, 0..) |*rec, idx| {
        if (std.ascii.indexOfIgnoreCase(rec.account_id, normalized) != null) {
            try matches.append(allocator, idx);
            continue;
        }
        if (rec.alias.len != 0 and std.ascii.indexOfIgnoreCase(rec.alias, normalized) != null) {
            try matches.append(allocator, idx);
            continue;
        }
        if (rec.email.len != 0 and std.ascii.indexOfIgnoreCase(rec.email, normalized) != null) {
            try matches.append(allocator, idx);
            continue;
        }
        if (rec.plan) |plan| {
            const full = try std.fmt.allocPrint(allocator, "{s}#{s}", .{ rec.email, @tagName(plan) });
            defer allocator.free(full);
            if (std.ascii.indexOfIgnoreCase(full, normalized) != null) {
                try matches.append(allocator, idx);
                continue;
            }
        }
        if (rec.api_key_fingerprint) |fp| {
            const label = try std.fmt.allocPrint(allocator, "apikey:{s}", .{fp});
            defer allocator.free(label);
            if (std.ascii.indexOfIgnoreCase(label, normalized) != null) {
                try matches.append(allocator, idx);
            }
        } else if (std.mem.eql(u8, rec.account_id, normalized)) {
            try matches.append(allocator, idx);
        }
    }
    return matches;
}

fn handleRemove(allocator: std.mem.Allocator, codex_home: []const u8) !void {
    var reg = try registry.loadRegistry(allocator, codex_home);
    defer reg.deinit(allocator);
    if (try registry.syncActiveAccountFromAuth(allocator, codex_home, &reg)) {
        try registry.saveRegistry(allocator, codex_home, &reg);
    }

    const selected = try cli.selectAccountsToRemove(allocator, &reg);
    if (selected == null) return;
    defer allocator.free(selected.?);
    if (selected.?.len == 0) return;

    try registry.removeAccounts(allocator, codex_home, &reg, selected.?);
    if (reg.active_account_id == null and reg.accounts.items.len > 0) {
        const best_idx = registry.selectBestAccountIndexByUsage(&reg) orelse 0;
        const account_id = reg.accounts.items[best_idx].account_id;

        const src = try registry.accountAuthPath(allocator, codex_home, account_id);
        defer allocator.free(src);

        const dest = try registry.activeAuthPath(allocator, codex_home);
        defer allocator.free(dest);

        try registry.backupAuthIfChanged(allocator, codex_home, dest, src);
        try registry.copyFile(src, dest);
        try registry.setActiveAccount(allocator, &reg, account_id);
    }
    try registry.saveRegistry(allocator, codex_home, &reg);
}

fn refreshActiveUsageFromSessions(allocator: std.mem.Allocator, codex_home: []const u8, reg: *registry.Registry) !bool {
    const snapshot = sessions.scanLatestUsage(allocator, codex_home) catch return false;
    if (snapshot == null) return false;
    const account_id = reg.active_account_id orelse return false;
    registry.updateUsage(allocator, reg, account_id, snapshot.?);
    return true;
}

// Tests live in separate files but are pulled in by main.zig for zig test.
test {
    _ = @import("tests/auth_test.zig");
    _ = @import("tests/sessions_test.zig");
    _ = @import("tests/registry_test.zig");
    _ = @import("tests/registry_bdd_test.zig");
    _ = @import("tests/cli_bdd_test.zig");
}

test "Scenario: Given switch selector matches alias when searching then target account is returned once" {
    const gpa = std.testing.allocator;
    var reg = @import("tests/bdd_helpers.zig").makeEmptyRegistry();
    defer reg.deinit(gpa);

    try @import("tests/bdd_helpers.zig").appendChatgptAccount(gpa, &reg, "user@example.com", "gmail_plus", .plus);

    var matches = try findMatchingAccounts(gpa, &reg, "gmail_plus");
    defer matches.deinit(gpa);

    try std.testing.expectEqual(@as(usize, 1), matches.items.len);
    try std.testing.expectEqual(@as(usize, 0), matches.items[0]);
}

test "Scenario: Given switch selector matches alias case-insensitively when searching then target account is returned" {
    const gpa = std.testing.allocator;
    var reg = @import("tests/bdd_helpers.zig").makeEmptyRegistry();
    defer reg.deinit(gpa);

    try @import("tests/bdd_helpers.zig").appendChatgptAccount(gpa, &reg, "user@example.com", "gmail_plus", .plus);

    var matches = try findMatchingAccounts(gpa, &reg, "GMAIL_PLUS");
    defer matches.deinit(gpa);

    try std.testing.expectEqual(@as(usize, 1), matches.items.len);
    try std.testing.expectEqual(@as(usize, 0), matches.items[0]);
}

test "Scenario: Given switch selector matches alias fragment when searching then multiple candidates are preserved" {
    const gpa = std.testing.allocator;
    var reg = @import("tests/bdd_helpers.zig").makeEmptyRegistry();
    defer reg.deinit(gpa);

    try @import("tests/bdd_helpers.zig").appendChatgptAccount(gpa, &reg, "one@example.com", "gmail_plus", .plus);
    try @import("tests/bdd_helpers.zig").appendChatgptAccount(gpa, &reg, "two@example.com", "gmail_team", .team);

    var matches = try findMatchingAccounts(gpa, &reg, "gmail");
    defer matches.deinit(gpa);

    try std.testing.expectEqual(@as(usize, 2), matches.items.len);
    try std.testing.expectEqual(@as(usize, 0), matches.items[0]);
    try std.testing.expectEqual(@as(usize, 1), matches.items[1]);
}

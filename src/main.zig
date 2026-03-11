const std = @import("std");
const cli = @import("cli.zig");
const registry = @import("registry.zig");
const auth = @import("auth.zig");
const auto = @import("auto.zig");
const format = @import("format.zig");
const migration = @import("migration.zig");

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
        .version => try cli.printVersion(),
        .help => try handleHelp(allocator, codex_home),
        .migrate => {
            _ = try migration.ensureMigrated(allocator, codex_home, .explicit);
            try auto.reconcileManagedService(allocator, codex_home);
        },
        .daemon => |opts| if (opts.watch) try auto.runDaemon(allocator, codex_home),
        else => {
            _ = try migration.ensureMigrated(allocator, codex_home, .automatic);
            switch (cmd) {
                .list => |opts| try handleList(allocator, codex_home, opts),
                .login => |opts| try handleLogin(allocator, codex_home, opts),
                .import_auth => |opts| try handleImport(allocator, codex_home, opts),
                .switch_account => |opts| try handleSwitch(allocator, codex_home, opts),
                .remove_account => |_| try handleRemove(allocator, codex_home),
                .clean => |_| try handleClean(allocator, codex_home),
                .auto_switch => |opts| try auto.handleCommand(allocator, codex_home, switch (opts.action) {
                    .enable => .enable,
                    .disable => .disable,
                    .status => .status,
                }),
                else => unreachable,
            }
            try auto.reconcileManagedService(allocator, codex_home);
        },
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
    if (try auto.refreshTrackedActiveUsage(allocator, codex_home, &reg)) {
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

    const email = info.email orelse return error.MissingEmail;
    _ = email;
    const account_id = info.account_id orelse return error.MissingAccountId;
    const dest = try registry.accountAuthPath(allocator, codex_home, account_id);
    defer allocator.free(dest);

    try registry.ensureAccountsDir(allocator, codex_home);
    try registry.copyFile(auth_path, dest);

    const record = try registry.accountFromAuth(allocator, "", &info);
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
    if (try auto.refreshTrackedActiveUsage(allocator, codex_home, &reg)) {
        try registry.saveRegistry(allocator, codex_home, &reg);
    }

    var selected_account_id: ?[]const u8 = null;
    if (opts.query) |query| {
        var matches = try findMatchingAccounts(allocator, &reg, query);
        defer matches.deinit(allocator);

        if (matches.items.len == 0) {
            std.log.err("account not found: {s}", .{query});
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

    try registry.activateAccountById(allocator, codex_home, &reg, account_id);
    try registry.saveRegistry(allocator, codex_home, &reg);
}

pub fn findMatchingAccounts(
    allocator: std.mem.Allocator,
    reg: *registry.Registry,
    query: []const u8,
) !std.ArrayList(usize) {
    var matches = std.ArrayList(usize).empty;
    for (reg.accounts.items, 0..) |*rec, idx| {
        if (std.mem.eql(u8, rec.account_id, query) or std.mem.startsWith(u8, rec.account_id, query) or
            std.ascii.indexOfIgnoreCase(rec.email, query) != null or
            (rec.alias.len != 0 and std.ascii.indexOfIgnoreCase(rec.alias, query) != null))
        {
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

        try registry.activateAccountById(allocator, codex_home, &reg, account_id);
    }
    try registry.saveRegistry(allocator, codex_home, &reg);
}

fn handleHelp(allocator: std.mem.Allocator, codex_home: []const u8) !void {
    var auto_enabled = false;
    var reg = registry.loadRegistry(allocator, codex_home) catch |err| switch (err) {
        error.RegistryMigrationRequired, error.UnsupportedSchemaVersion => {
            try cli.printHelp(false);
            return;
        },
        else => return err,
    };
    defer reg.deinit(allocator);
    auto_enabled = reg.auto_switch.enabled;
    try cli.printHelp(auto_enabled);
}

fn handleClean(allocator: std.mem.Allocator, codex_home: []const u8) !void {
    const summary = try registry.cleanAccountsBackups(allocator, codex_home);
    var stdout: [256]u8 = undefined;
    var writer = std.fs.File.stdout().writer(&stdout);
    const out = &writer.interface;
    try out.print(
        "cleaned accounts: auth_backups={d}, registry_backups={d}, stale_entries={d}\n",
        .{
            summary.auth_backups_removed,
            summary.registry_backups_removed,
            summary.stale_snapshot_files_removed,
        },
    );
    try out.flush();
}

// Tests live in separate files but are pulled in by main.zig for zig test.
test {
    _ = @import("tests/auth_test.zig");
    _ = @import("tests/sessions_test.zig");
    _ = @import("tests/auto_test.zig");
    _ = @import("tests/registry_test.zig");
    _ = @import("tests/registry_bdd_test.zig");
    _ = @import("tests/cli_bdd_test.zig");
    _ = @import("tests/display_rows_test.zig");
    _ = @import("tests/main_test.zig");
    _ = @import("tests/migration_test.zig");
}

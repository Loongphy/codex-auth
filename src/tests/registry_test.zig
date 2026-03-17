const std = @import("std");
const registry = @import("../registry.zig");
const bdd = @import("bdd_helpers.zig");

fn countBackups(dir: std.fs.Dir, prefix: []const u8) !usize {
    var count: usize = 0;
    var it = dir.iterate();
    while (try it.next()) |entry| {
        if (entry.kind != .file) continue;
        if (std.mem.startsWith(u8, entry.name, prefix) and std.mem.containsAtLeast(u8, entry.name, 1, ".bak.")) {
            count += 1;
        }
    }
    return count;
}

test "registry save/load" {
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const codex_home = try tmp.dir.realpathAlloc(gpa, ".");
    defer gpa.free(codex_home);
    try tmp.dir.makePath("accounts");

    var reg = bdd.makeEmptyRegistry();
    defer reg.deinit(gpa);

    try bdd.appendChatgptAccount(gpa, &reg, "a@b.com", "work", .pro);
    try registry.setActiveAccount(gpa, &reg, reg.accounts.items[0].account_id);
    try registry.saveRegistry(gpa, codex_home, &reg);

    var loaded = try registry.loadRegistry(gpa, codex_home);
    defer loaded.deinit(gpa);
    try std.testing.expect(loaded.accounts.items.len == 1);
    try std.testing.expect(loaded.active_account_id != null);
    try std.testing.expect(std.mem.eql(u8, loaded.active_account_id.?, reg.accounts.items[0].account_id));
}

test "auth backup only on change" {
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const codex_home = try tmp.dir.realpathAlloc(gpa, ".");
    defer gpa.free(codex_home);

    const current = try std.fs.path.join(gpa, &[_][]const u8{ codex_home, "auth.json" });
    defer gpa.free(current);
    const account_id = try registry.accountIdFromPartsAlloc(gpa, .chatgpt, "user@example.com", .pro, null);
    defer gpa.free(account_id);
    const new_auth = try registry.accountAuthPath(gpa, codex_home, account_id);
    defer gpa.free(new_auth);

    const encoded = try bdd.b64url(gpa, account_id);
    defer gpa.free(encoded);
    const account_path = try std.fmt.allocPrint(gpa, "accounts/{s}.auth.json", .{encoded});
    defer gpa.free(account_path);

    try tmp.dir.makePath("accounts");
    try tmp.dir.writeFile(.{ .sub_path = "auth.json", .data = "one" });
    try tmp.dir.writeFile(.{ .sub_path = account_path, .data = "two" });

    try registry.backupAuthIfChanged(gpa, codex_home, current, new_auth);

    var accounts = try tmp.dir.openDir("accounts", .{ .iterate = true });
    const count1 = try countBackups(accounts, "auth.json");
    accounts.close();
    try std.testing.expect(count1 == 1);

    try tmp.dir.writeFile(.{ .sub_path = "auth.json", .data = "two" });
    try registry.backupAuthIfChanged(gpa, codex_home, current, new_auth);
    accounts = try tmp.dir.openDir("accounts", .{ .iterate = true });
    const count2 = try countBackups(accounts, "auth.json");
    accounts.close();
    try std.testing.expect(count2 == 1);
}

test "sync active auth matches by email and plan" {
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const codex_home = try tmp.dir.realpathAlloc(gpa, ".");
    defer gpa.free(codex_home);
    try tmp.dir.makePath("accounts");

    var reg = bdd.makeEmptyRegistry();
    defer reg.deinit(gpa);
    try bdd.appendChatgptAccount(gpa, &reg, "user@example.com", "work", .pro);

    const account_auth = try bdd.authJsonWithEmailPlan(gpa, "user@example.com", "pro");
    defer gpa.free(account_auth);
    const account_id = reg.accounts.items[0].account_id;
    const encoded = try bdd.b64url(gpa, account_id);
    defer gpa.free(encoded);
    const account_path = try std.fmt.allocPrint(gpa, "accounts/{s}.auth.json", .{encoded});
    defer gpa.free(account_path);
    try tmp.dir.writeFile(.{ .sub_path = "auth.json", .data = account_auth });
    try tmp.dir.writeFile(.{ .sub_path = account_path, .data = account_auth });

    const changed = try registry.syncActiveAccountFromAuth(gpa, codex_home, &reg);
    try std.testing.expect(changed);
    try std.testing.expect(reg.active_account_id != null);
    try std.testing.expect(std.mem.eql(u8, reg.active_account_id.?, account_id));
}

test "import auth path with directory imports multiple plans for same email" {
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const codex_home = try tmp.dir.realpathAlloc(gpa, ".");
    defer gpa.free(codex_home);
    try tmp.dir.makePath("imports");

    const a = try bdd.authJsonWithEmailPlan(gpa, "a@example.com", "pro");
    defer gpa.free(a);
    const b = try bdd.authJsonWithEmailPlan(gpa, "a@example.com", "team");
    defer gpa.free(b);
    try tmp.dir.writeFile(.{ .sub_path = "imports/a.json", .data = a });
    try tmp.dir.writeFile(.{ .sub_path = "imports/b.json", .data = b });

    const imports_dir = try std.fs.path.join(gpa, &[_][]const u8{ codex_home, "imports" });
    defer gpa.free(imports_dir);

    var reg = bdd.makeEmptyRegistry();
    defer reg.deinit(gpa);

    const summary = try registry.importAuthPath(gpa, codex_home, &reg, imports_dir, null);
    try std.testing.expect(summary.imported == 2);
    try std.testing.expect(reg.accounts.items.len == 2);
}

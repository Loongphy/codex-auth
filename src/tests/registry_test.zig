const std = @import("std");
const registry = @import("../registry.zig");

fn b64url(allocator: std.mem.Allocator, input: []const u8) ![]u8 {
    const encoder = std.base64.url_safe_no_pad.Encoder;
    const out_len = encoder.calcSize(input.len);
    const buf = try allocator.alloc(u8, out_len);
    _ = encoder.encode(buf, input);
    return buf;
}

fn authJsonWithEmailPlan(allocator: std.mem.Allocator, email: []const u8, plan: []const u8) ![]u8 {
    const account_id = try accountIdForEmailAlloc(allocator, email);
    defer allocator.free(account_id);
    const header = "{\"alg\":\"none\",\"typ\":\"JWT\"}";
    const payload = try std.fmt.allocPrint(
        allocator,
        "{{\"email\":\"{s}\",\"https://api.openai.com/auth\":{{\"chatgpt_account_id\":\"{s}\",\"chatgpt_plan_type\":\"{s}\"}}}}",
        .{ email, account_id, plan },
    );
    defer allocator.free(payload);

    const h64 = try b64url(allocator, header);
    defer allocator.free(h64);
    const p64 = try b64url(allocator, payload);
    defer allocator.free(p64);

    const jwt = try std.mem.concat(allocator, u8, &[_][]const u8{ h64, ".", p64, ".sig" });
    defer allocator.free(jwt);

    return try std.fmt.allocPrint(allocator, "{{\"tokens\":{{\"account_id\":\"{s}\",\"id_token\":\"{s}\"}}}}", .{ account_id, jwt });
}

fn accountIdForEmailAlloc(allocator: std.mem.Allocator, email: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator, "acc:{s}", .{email});
}

fn makeEmptyRegistry() registry.Registry {
    return .{
        .version = 3,
        .active_account_id = null,
        .auto_switch = registry.defaultAutoSwitchConfig(),
        .accounts = std.ArrayList(registry.AccountRecord).empty,
    };
}

fn makeAccountRecord(
    allocator: std.mem.Allocator,
    email: []const u8,
    alias: []const u8,
    plan: ?registry.PlanType,
    auth_mode: ?registry.AuthMode,
    created_at: i64,
) !registry.AccountRecord {
    return .{
        .account_id = try accountIdForEmailAlloc(allocator, email),
        .email = try allocator.dupe(u8, email),
        .alias = try allocator.dupe(u8, alias),
        .plan = plan,
        .auth_mode = auth_mode,
        .created_at = created_at,
        .last_used_at = null,
        .last_usage = null,
        .last_usage_at = null,
    };
}

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
    var gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const codex_home = try tmp.dir.realpathAlloc(gpa, ".");
    defer gpa.free(codex_home);
    try tmp.dir.makePath("accounts");

    var reg = makeEmptyRegistry();
    defer reg.deinit(gpa);

    const rec = try makeAccountRecord(gpa, "a@b.com", "work", .pro, .chatgpt, 1);
    try reg.accounts.append(gpa, rec);
    const active_account_id = try accountIdForEmailAlloc(gpa, "a@b.com");
    defer gpa.free(active_account_id);
    try registry.setActiveAccount(gpa, &reg, active_account_id);
    try registry.setTrackedRolloutSignature(gpa, &reg.auto_switch, "/tmp/rollout.jsonl", 42);

    try registry.saveRegistry(gpa, codex_home, &reg);

    var loaded = try registry.loadRegistry(gpa, codex_home);
    defer loaded.deinit(gpa);
    try std.testing.expect(loaded.accounts.items.len == 1);
    try std.testing.expect(loaded.auto_switch.last_rollout.path != null);
    try std.testing.expect(std.mem.eql(u8, loaded.auto_switch.last_rollout.path.?, "/tmp/rollout.jsonl"));
    try std.testing.expect(loaded.auto_switch.last_rollout.mtime != null);
    try std.testing.expect(loaded.auto_switch.last_rollout.mtime.? == 42);
}

test "auth backup only on change" {
    var gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const codex_home = try tmp.dir.realpathAlloc(gpa, ".");
    defer gpa.free(codex_home);

    const current = try std.fs.path.join(gpa, &[_][]const u8{ codex_home, "auth.json" });
    defer gpa.free(current);
    const user_account_id = try accountIdForEmailAlloc(gpa, "user@example.com");
    defer gpa.free(user_account_id);
    const new_auth = try registry.accountAuthPath(gpa, codex_home, user_account_id);
    defer gpa.free(new_auth);
    const account_path = try std.fmt.allocPrint(gpa, "accounts/{s}.auth.json", .{user_account_id});
    defer gpa.free(account_path);

    try tmp.dir.makePath("accounts");
    try tmp.dir.writeFile(.{ .sub_path = "auth.json", .data = "one" });
    try tmp.dir.writeFile(.{ .sub_path = account_path, .data = "two" });

    try registry.backupAuthIfChanged(gpa, codex_home, current, new_auth);

    var accounts = try tmp.dir.openDir("accounts", .{ .iterate = true });
    defer accounts.close();
    const count1 = try countBackups(accounts, "auth.json");
    try std.testing.expect(count1 == 1);

    try tmp.dir.writeFile(.{ .sub_path = "auth.json", .data = "two" });
    try registry.backupAuthIfChanged(gpa, codex_home, current, new_auth);
    const count2 = try countBackups(accounts, "auth.json");
    try std.testing.expect(count2 == 1);
}

test "auth backup rotation" {
    var gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const codex_home = try tmp.dir.realpathAlloc(gpa, ".");
    defer gpa.free(codex_home);

    const current = try std.fs.path.join(gpa, &[_][]const u8{ codex_home, "auth.json" });
    defer gpa.free(current);
    const user_account_id = try accountIdForEmailAlloc(gpa, "user@example.com");
    defer gpa.free(user_account_id);
    const new_auth = try registry.accountAuthPath(gpa, codex_home, user_account_id);
    defer gpa.free(new_auth);
    const account_path = try std.fmt.allocPrint(gpa, "accounts/{s}.auth.json", .{user_account_id});
    defer gpa.free(account_path);

    try tmp.dir.makePath("accounts");
    try tmp.dir.writeFile(.{ .sub_path = account_path, .data = "base" });

    var i: usize = 0;
    while (i < 8) : (i += 1) {
        const data = try std.fmt.allocPrint(gpa, "v{d}", .{i});
        defer gpa.free(data);
        try tmp.dir.writeFile(.{ .sub_path = "auth.json", .data = data });
        try registry.backupAuthIfChanged(gpa, codex_home, current, new_auth);
    }

    var accounts = try tmp.dir.openDir("accounts", .{ .iterate = true });
    defer accounts.close();
    const count = try countBackups(accounts, "auth.json");
    try std.testing.expect(count <= 5);
}

test "sync active auth matches by email and updates account auth" {
    var gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const codex_home = try tmp.dir.realpathAlloc(gpa, ".");
    defer gpa.free(codex_home);
    try tmp.dir.makePath("accounts");

    var reg = makeEmptyRegistry();
    defer reg.deinit(gpa);

    const rec = try makeAccountRecord(gpa, "user@example.com", "work", null, null, 1);
    try reg.accounts.append(gpa, rec);

    const account_auth = try authJsonWithEmailPlan(gpa, "user@example.com", "pro");
    defer gpa.free(account_auth);
    const user_account_id = try accountIdForEmailAlloc(gpa, "user@example.com");
    defer gpa.free(user_account_id);
    const account_path = try std.fmt.allocPrint(gpa, "accounts/{s}.auth.json", .{user_account_id});
    defer gpa.free(account_path);
    try tmp.dir.writeFile(.{ .sub_path = account_path, .data = account_auth });

    const active_auth = try authJsonWithEmailPlan(gpa, "user@example.com", "free");
    defer gpa.free(active_auth);
    try tmp.dir.writeFile(.{ .sub_path = "auth.json", .data = active_auth });

    const changed = try registry.syncActiveAccountFromAuth(gpa, codex_home, &reg);
    try std.testing.expect(changed);
    try std.testing.expect(reg.accounts.items.len == 1);
    try std.testing.expect(std.mem.eql(u8, reg.accounts.items[0].email, "user@example.com"));

    const acc_path = try registry.accountAuthPath(gpa, codex_home, user_account_id);
    defer gpa.free(acc_path);
    var file = try std.fs.cwd().openFile(acc_path, .{});
    defer file.close();
    const data = try file.readToEndAlloc(gpa, 10 * 1024 * 1024);
    defer gpa.free(data);
    try std.testing.expect(std.mem.eql(u8, data, active_auth));
}

test "registry backup only on change" {
    var gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const codex_home = try tmp.dir.realpathAlloc(gpa, ".");
    defer gpa.free(codex_home);

    var reg = makeEmptyRegistry();
    defer reg.deinit(gpa);
    try registry.saveRegistry(gpa, codex_home, &reg);

    var accounts = try tmp.dir.openDir("accounts", .{ .iterate = true });
    defer accounts.close();
    const count0 = try countBackups(accounts, "registry.json");
    try std.testing.expect(count0 == 0);

    const rec = try makeAccountRecord(gpa, "user@example.com", "work", null, null, 1);
    try reg.accounts.append(gpa, rec);

    try registry.saveRegistry(gpa, codex_home, &reg);
    const count1 = try countBackups(accounts, "registry.json");
    try std.testing.expect(count1 == 1);

    try registry.saveRegistry(gpa, codex_home, &reg);
    const count2 = try countBackups(accounts, "registry.json");
    try std.testing.expect(count2 == 1);
}

test "clean uses a whitelist and only removes non-current entries under accounts" {
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const codex_home = try tmp.dir.realpathAlloc(gpa, ".");
    defer gpa.free(codex_home);
    try tmp.dir.makePath("accounts");

    var reg = makeEmptyRegistry();
    defer reg.deinit(gpa);
    const active_record = try makeAccountRecord(gpa, "keep@example.com", "", .team, .chatgpt, 1);
    try reg.accounts.append(gpa, active_record);
    try registry.saveRegistry(gpa, codex_home, &reg);

    try tmp.dir.writeFile(.{ .sub_path = "accounts/auth.json.bak.1", .data = "a1" });
    try tmp.dir.writeFile(.{ .sub_path = "accounts/auth.json.bak.2", .data = "a2" });
    try tmp.dir.writeFile(.{ .sub_path = "accounts/auth.json.bak.3", .data = "a3" });
    try tmp.dir.writeFile(.{ .sub_path = "accounts/registry.json.bak.1", .data = "r1" });
    try tmp.dir.writeFile(.{ .sub_path = "accounts/registry.json.bak.2", .data = "r2" });
    try tmp.dir.writeFile(.{ .sub_path = "accounts/acc:keep@example.com.auth.json", .data = "keep" });
    try tmp.dir.writeFile(.{ .sub_path = "accounts/bGVnYWN5QGV4YW1wbGUuY29t.auth.json", .data = "legacy" });
    try tmp.dir.writeFile(.{ .sub_path = "accounts/notes.txt", .data = "junk" });
    try tmp.dir.makePath("accounts/tmpdir");
    try tmp.dir.writeFile(.{ .sub_path = "accounts/tmpdir/old.txt", .data = "junk" });
    try tmp.dir.makePath("backups/v2/20260312-063235");
    try tmp.dir.writeFile(.{ .sub_path = "backups/v2/20260312-063235/registry.json", .data = "keep" });

    const summary = try registry.cleanAccountsBackups(gpa, codex_home);
    try std.testing.expect(summary.auth_backups_removed == 3);
    try std.testing.expect(summary.registry_backups_removed == 2);
    try std.testing.expect(summary.stale_snapshot_files_removed == 3);

    var accounts = try tmp.dir.openDir("accounts", .{ .iterate = true });
    defer accounts.close();
    try std.testing.expect(try countBackups(accounts, "auth.json") == 0);
    try std.testing.expect(try countBackups(accounts, "registry.json") == 0);
    var kept = try tmp.dir.openFile("accounts/acc:keep@example.com.auth.json", .{});
    kept.close();
    try std.testing.expectError(error.FileNotFound, tmp.dir.openFile("accounts/bGVnYWN5QGV4YW1wbGUuY29t.auth.json", .{}));
    try std.testing.expectError(error.FileNotFound, tmp.dir.openFile("accounts/notes.txt", .{}));
    try std.testing.expectError(error.FileNotFound, tmp.dir.openFile("accounts/tmpdir/old.txt", .{}));

    var preserved_backup = try tmp.dir.openFile("backups/v2/20260312-063235/registry.json", .{});
    preserved_backup.close();
}

test "import auth path with single file keeps explicit alias" {
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const codex_home = try tmp.dir.realpathAlloc(gpa, ".");
    defer gpa.free(codex_home);
    try tmp.dir.makePath("imports");

    const auth_json = try authJsonWithEmailPlan(gpa, "single@example.com", "plus");
    defer gpa.free(auth_json);
    try tmp.dir.writeFile(.{ .sub_path = "imports/one.json", .data = auth_json });

    const one_path = try std.fs.path.join(gpa, &[_][]const u8{ codex_home, "imports", "one.json" });
    defer gpa.free(one_path);

    var reg = makeEmptyRegistry();
    defer reg.deinit(gpa);

    const summary = try registry.importAuthPath(gpa, codex_home, &reg, one_path, "personal");
    try std.testing.expect(summary.imported == 1);
    try std.testing.expect(summary.skipped == 0);
    try std.testing.expect(reg.accounts.items.len == 1);
    try std.testing.expect(std.mem.eql(u8, reg.accounts.items[0].alias, "personal"));
}

test "import auth path with directory imports multiple json files and skips bad files" {
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const codex_home = try tmp.dir.realpathAlloc(gpa, ".");
    defer gpa.free(codex_home);
    try tmp.dir.makePath("imports");

    const a = try authJsonWithEmailPlan(gpa, "a@example.com", "pro");
    defer gpa.free(a);
    const b = try authJsonWithEmailPlan(gpa, "b@example.com", "team");
    defer gpa.free(b);
    try tmp.dir.writeFile(.{ .sub_path = "imports/a.json", .data = a });
    try tmp.dir.writeFile(.{ .sub_path = "imports/b.json", .data = b });
    try tmp.dir.writeFile(.{ .sub_path = "imports/readme.txt", .data = "ignored" });
    try tmp.dir.writeFile(.{ .sub_path = "imports/bad.json", .data = "{not-json}" });

    const imports_dir = try std.fs.path.join(gpa, &[_][]const u8{ codex_home, "imports" });
    defer gpa.free(imports_dir);

    var reg = makeEmptyRegistry();
    defer reg.deinit(gpa);

    const summary = try registry.importAuthPath(gpa, codex_home, &reg, imports_dir, null);
    try std.testing.expect(summary.imported == 2);
    try std.testing.expect(summary.skipped == 1);
    try std.testing.expect(reg.accounts.items.len == 2);
    try std.testing.expect(reg.accounts.items[0].alias.len == 0);
    try std.testing.expect(reg.accounts.items[1].alias.len == 0);

    const account_id_a = try accountIdForEmailAlloc(gpa, "a@example.com");
    defer gpa.free(account_id_a);
    const path_a = try registry.accountAuthPath(gpa, codex_home, account_id_a);
    defer gpa.free(path_a);
    const account_id_b = try accountIdForEmailAlloc(gpa, "b@example.com");
    defer gpa.free(account_id_b);
    const path_b = try registry.accountAuthPath(gpa, codex_home, account_id_b);
    defer gpa.free(path_b);
    var file_a = try std.fs.cwd().openFile(path_a, .{});
    defer file_a.close();
    var file_b = try std.fs.cwd().openFile(path_b, .{});
    defer file_b.close();
}

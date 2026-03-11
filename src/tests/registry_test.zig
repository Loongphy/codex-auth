const std = @import("std");
const builtin = @import("builtin");
const registry = @import("../registry.zig");

fn b64url(allocator: std.mem.Allocator, input: []const u8) ![]u8 {
    const encoder = std.base64.url_safe_no_pad.Encoder;
    const out_len = encoder.calcSize(input.len);
    const buf = try allocator.alloc(u8, out_len);
    _ = encoder.encode(buf, input);
    return buf;
}

fn authJsonWithEmailPlan(allocator: std.mem.Allocator, email: []const u8, plan: []const u8) ![]u8 {
    const header = "{\"alg\":\"none\",\"typ\":\"JWT\"}";
    const payload = try std.fmt.allocPrint(
        allocator,
        "{{\"email\":\"{s}\",\"https://api.openai.com/auth\":{{\"chatgpt_plan_type\":\"{s}\"}}}}",
        .{ email, plan },
    );
    defer allocator.free(payload);

    const h64 = try b64url(allocator, header);
    defer allocator.free(h64);
    const p64 = try b64url(allocator, payload);
    defer allocator.free(p64);

    const jwt = try std.mem.concat(allocator, u8, &[_][]const u8{ h64, ".", p64, ".sig" });
    defer allocator.free(jwt);

    return try std.fmt.allocPrint(allocator, "{{\"tokens\":{{\"id_token\":\"{s}\"}}}}", .{jwt});
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

fn assertModeUnix(path: []const u8, expected_mode: u32) !void {
    if (comptime builtin.os.tag == .windows) return;
    const stat = try std.fs.cwd().statFile(path);
    try std.testing.expectEqual(expected_mode, @as(u32, @intCast(stat.mode & 0o777)));
}

test "registry save/load" {
    var gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const codex_home = try tmp.dir.realpathAlloc(gpa, ".");
    defer gpa.free(codex_home);
    try tmp.dir.makePath("accounts");

    var reg = registry.Registry{ .version = 2, .active_email = null, .accounts = std.ArrayList(registry.AccountRecord).empty };
    defer reg.deinit(gpa);

    const rec = registry.AccountRecord{
        .email = try gpa.dupe(u8, "a@b.com"),
        .alias = try gpa.dupe(u8, "work"),
        .plan = .pro,
        .auth_mode = .chatgpt,
        .created_at = 1,
        .last_used_at = null,
        .last_usage = null,
        .last_usage_at = null,
    };
    try reg.accounts.append(gpa, rec);
    try registry.setActiveAccount(gpa, &reg, "a@b.com");

    try registry.saveRegistry(gpa, codex_home, &reg);

    var loaded = try registry.loadRegistry(gpa, codex_home);
    defer loaded.deinit(gpa);
    try std.testing.expect(loaded.accounts.items.len == 1);
}

test "accounts directory is hardened to 0700" {
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const codex_home = try tmp.dir.realpathAlloc(gpa, ".");
    defer gpa.free(codex_home);
    try registry.ensureAccountsDir(gpa, codex_home);

    const accounts_path = try std.fs.path.join(gpa, &[_][]const u8{ codex_home, "accounts" });
    defer gpa.free(accounts_path);
    try assertModeUnix(accounts_path, 0o700);
}

test "copyFile hardens destination to 0600" {
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const codex_home = try tmp.dir.realpathAlloc(gpa, ".");
    defer gpa.free(codex_home);

    try tmp.dir.writeFile(.{ .sub_path = "source.json", .data = "secret" });
    const src = try std.fs.path.join(gpa, &[_][]const u8{ codex_home, "source.json" });
    defer gpa.free(src);
    const dest = try std.fs.path.join(gpa, &[_][]const u8{ codex_home, "dest.json" });
    defer gpa.free(dest);

    try registry.copyFile(src, dest);
    try assertModeUnix(dest, 0o600);
}

test "saveRegistry writes registry with 0600 mode" {
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const codex_home = try tmp.dir.realpathAlloc(gpa, ".");
    defer gpa.free(codex_home);

    var reg = registry.Registry{ .version = 2, .active_email = null, .accounts = std.ArrayList(registry.AccountRecord).empty };
    defer reg.deinit(gpa);

    try registry.saveRegistry(gpa, codex_home, &reg);

    const path = try registry.registryPath(gpa, codex_home);
    defer gpa.free(path);
    try assertModeUnix(path, 0o600);
}

test "auth backup only on change" {
    var gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const codex_home = try tmp.dir.realpathAlloc(gpa, ".");
    defer gpa.free(codex_home);

    const current = try std.fs.path.join(gpa, &[_][]const u8{ codex_home, "auth.json" });
    defer gpa.free(current);
    const new_auth = try registry.accountAuthPath(gpa, codex_home, "user@example.com");
    defer gpa.free(new_auth);
    const encoded = try b64url(gpa, "user@example.com");
    defer gpa.free(encoded);
    const account_path = try std.fmt.allocPrint(gpa, "accounts/{s}.auth.json", .{encoded});
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
    const new_auth = try registry.accountAuthPath(gpa, codex_home, "user@example.com");
    defer gpa.free(new_auth);
    const encoded = try b64url(gpa, "user@example.com");
    defer gpa.free(encoded);
    const account_path = try std.fmt.allocPrint(gpa, "accounts/{s}.auth.json", .{encoded});
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

    var reg = registry.Registry{ .version = 2, .active_email = null, .accounts = std.ArrayList(registry.AccountRecord).empty };
    defer reg.deinit(gpa);

    const rec = registry.AccountRecord{
        .email = try gpa.dupe(u8, "user@example.com"),
        .alias = try gpa.dupe(u8, "work"),
        .plan = null,
        .auth_mode = null,
        .created_at = 1,
        .last_used_at = null,
        .last_usage = null,
        .last_usage_at = null,
    };
    try reg.accounts.append(gpa, rec);

    const account_auth = try authJsonWithEmailPlan(gpa, "user@example.com", "pro");
    defer gpa.free(account_auth);
    const encoded = try b64url(gpa, "user@example.com");
    defer gpa.free(encoded);
    const account_path = try std.fmt.allocPrint(gpa, "accounts/{s}.auth.json", .{encoded});
    defer gpa.free(account_path);
    try tmp.dir.writeFile(.{ .sub_path = account_path, .data = account_auth });

    const active_auth = try authJsonWithEmailPlan(gpa, "user@example.com", "free");
    defer gpa.free(active_auth);
    try tmp.dir.writeFile(.{ .sub_path = "auth.json", .data = active_auth });

    const changed = try registry.syncActiveAccountFromAuth(gpa, codex_home, &reg);
    try std.testing.expect(changed);
    try std.testing.expect(reg.accounts.items.len == 1);
    try std.testing.expect(std.mem.eql(u8, reg.accounts.items[0].email, "user@example.com"));

    const acc_path = try registry.accountAuthPath(gpa, codex_home, "user@example.com");
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

    var reg = registry.Registry{ .version = 2, .active_email = null, .accounts = std.ArrayList(registry.AccountRecord).empty };
    defer reg.deinit(gpa);
    try registry.saveRegistry(gpa, codex_home, &reg);

    var accounts = try tmp.dir.openDir("accounts", .{ .iterate = true });
    defer accounts.close();
    const count0 = try countBackups(accounts, "registry.json");
    try std.testing.expect(count0 == 0);

    const rec = registry.AccountRecord{
        .email = try gpa.dupe(u8, "user@example.com"),
        .alias = try gpa.dupe(u8, "work"),
        .plan = null,
        .auth_mode = null,
        .created_at = 1,
        .last_used_at = null,
        .last_usage = null,
        .last_usage_at = null,
    };
    try reg.accounts.append(gpa, rec);

    try registry.saveRegistry(gpa, codex_home, &reg);
    const count1 = try countBackups(accounts, "registry.json");
    try std.testing.expect(count1 == 1);

    try registry.saveRegistry(gpa, codex_home, &reg);
    const count2 = try countBackups(accounts, "registry.json");
    try std.testing.expect(count2 == 1);
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

    var reg = registry.Registry{ .version = 2, .active_email = null, .accounts = std.ArrayList(registry.AccountRecord).empty };
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

    var reg = registry.Registry{ .version = 2, .active_email = null, .accounts = std.ArrayList(registry.AccountRecord).empty };
    defer reg.deinit(gpa);

    const summary = try registry.importAuthPath(gpa, codex_home, &reg, imports_dir, null);
    try std.testing.expect(summary.imported == 2);
    try std.testing.expect(summary.skipped == 1);
    try std.testing.expect(reg.accounts.items.len == 2);
    try std.testing.expect(reg.accounts.items[0].alias.len == 0);
    try std.testing.expect(reg.accounts.items[1].alias.len == 0);

    const path_a = try registry.accountAuthPath(gpa, codex_home, "a@example.com");
    defer gpa.free(path_a);
    const path_b = try registry.accountAuthPath(gpa, codex_home, "b@example.com");
    defer gpa.free(path_b);
    var file_a = try std.fs.cwd().openFile(path_a, .{});
    defer file_a.close();
    var file_b = try std.fs.cwd().openFile(path_b, .{});
    defer file_b.close();
}

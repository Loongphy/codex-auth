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
    const chatgpt_account_id = try chatgptAccountIdForEmailAlloc(allocator, email);
    defer allocator.free(chatgpt_account_id);
    const chatgpt_user_id = try chatgptUserIdForEmailAlloc(allocator, email);
    defer allocator.free(chatgpt_user_id);
    const header = "{\"alg\":\"none\",\"typ\":\"JWT\"}";
    const payload = try std.fmt.allocPrint(
        allocator,
        "{{\"email\":\"{s}\",\"https://api.openai.com/auth\":{{\"chatgpt_account_id\":\"{s}\",\"chatgpt_user_id\":\"{s}\",\"user_id\":\"{s}\",\"chatgpt_plan_type\":\"{s}\"}}}}",
        .{ email, chatgpt_account_id, chatgpt_user_id, chatgpt_user_id, plan },
    );
    defer allocator.free(payload);

    const h64 = try b64url(allocator, header);
    defer allocator.free(h64);
    const p64 = try b64url(allocator, payload);
    defer allocator.free(p64);

    const jwt = try std.mem.concat(allocator, u8, &[_][]const u8{ h64, ".", p64, ".sig" });
    defer allocator.free(jwt);

    return try std.fmt.allocPrint(allocator, "{{\"tokens\":{{\"account_id\":\"{s}\",\"id_token\":\"{s}\"}}}}", .{ chatgpt_account_id, jwt });
}

fn accountKeyForEmailAlloc(allocator: std.mem.Allocator, email: []const u8) ![]u8 {
    const chatgpt_user_id = try chatgptUserIdForEmailAlloc(allocator, email);
    defer allocator.free(chatgpt_user_id);
    const chatgpt_account_id = try chatgptAccountIdForEmailAlloc(allocator, email);
    defer allocator.free(chatgpt_account_id);
    return std.fmt.allocPrint(allocator, "{s}::{s}", .{ chatgpt_user_id, chatgpt_account_id });
}

fn hashPart(seed: u64, email: []const u8, modulus: u64) u64 {
    return std.hash.Wyhash.hash(seed, email) % modulus;
}

fn chatgptAccountIdForEmailAlloc(allocator: std.mem.Allocator, email: []const u8) ![]u8 {
    return std.fmt.allocPrint(
        allocator,
        "{d:0>8}-{d:0>4}-{d:0>4}-{d:0>4}-{d:0>12}",
        .{
            hashPart(1, email, 100_000_000),
            hashPart(2, email, 10_000),
            4000 + hashPart(3, email, 1000),
            8000 + hashPart(4, email, 1000),
            hashPart(5, email, 1_000_000_000_000),
        },
    );
}

fn chatgptUserIdForEmailAlloc(allocator: std.mem.Allocator, email: []const u8) ![]u8 {
    return std.fmt.allocPrint(
        allocator,
        "user-{x:0>8}{x:0>8}{x:0>6}",
        .{
            hashPart(6, email, 0x100000000),
            hashPart(7, email, 0x100000000),
            hashPart(8, email, 0x1000000),
        },
    );
}

fn legacySnapshotRelPath(allocator: std.mem.Allocator, email: []const u8) ![]u8 {
    const key = try b64url(allocator, email);
    defer allocator.free(key);
    const filename = try std.fmt.allocPrint(allocator, "{s}.auth.json", .{key});
    defer allocator.free(filename);
    return try std.fs.path.join(allocator, &[_][]const u8{ "accounts", filename });
}

fn makeEmptyRegistry() registry.Registry {
    return .{
        .schema_version = registry.current_schema_version,
        .active_account_key = null,
        .active_account_activated_at_ms = null,
        .auto_switch = registry.defaultAutoSwitchConfig(),
        .api = registry.defaultApiConfig(),
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
        .account_key = try accountKeyForEmailAlloc(allocator, email),
        .chatgpt_account_id = try chatgptAccountIdForEmailAlloc(allocator, email),
        .chatgpt_user_id = try chatgptUserIdForEmailAlloc(allocator, email),
        .email = try allocator.dupe(u8, email),
        .alias = try allocator.dupe(u8, alias),
        .plan = plan,
        .auth_mode = auth_mode,
        .created_at = created_at,
        .last_used_at = null,
        .last_usage = null,
        .last_usage_at = null,
        .last_local_rollout = null,
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

fn expectBackupNameFormat(name: []const u8, prefix: []const u8) !void {
    const marker = ".bak.";
    try std.testing.expect(std.mem.startsWith(u8, name, prefix));
    const idx = std.mem.indexOf(u8, name, marker) orelse return error.TestExpectedEqual;
    const suffix = name[idx + marker.len ..];

    var stamp = suffix;
    if (std.mem.lastIndexOfScalar(u8, suffix, '.')) |dot_idx| {
        const maybe_counter = suffix[dot_idx + 1 ..];
        if (maybe_counter.len > 0) {
            for (maybe_counter) |ch| {
                if (!std.ascii.isDigit(ch)) return error.TestExpectedEqual;
            }
            stamp = suffix[0..dot_idx];
        }
    }

    if (stamp.len == 15 and stamp[8] == '-') {
        for (stamp, 0..) |ch, i| {
            if (i == 8) continue;
            try std.testing.expect(std.ascii.isDigit(ch));
        }
        return;
    }

    try std.testing.expect(stamp.len > 0);
    for (stamp) |ch| {
        try std.testing.expect(std.ascii.isDigit(ch));
    }
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
    const active_account_key = try accountKeyForEmailAlloc(gpa, "a@b.com");
    defer gpa.free(active_account_key);
    try registry.setActiveAccountKey(gpa, &reg, active_account_key);
    reg.auto_switch.threshold_5h_percent = 12;
    reg.auto_switch.threshold_weekly_percent = 8;
    reg.api.usage = true;
    try registry.setAccountLastLocalRollout(gpa, &reg.accounts.items[0], "/tmp/sessions/run-1/rollout-a.jsonl", 1735689600000);

    try registry.saveRegistry(gpa, codex_home, &reg);

    var loaded = try registry.loadRegistry(gpa, codex_home);
    defer loaded.deinit(gpa);
    try std.testing.expect(loaded.accounts.items.len == 1);
    try std.testing.expect(loaded.auto_switch.threshold_5h_percent == 12);
    try std.testing.expect(loaded.auto_switch.threshold_weekly_percent == 8);
    try std.testing.expect(loaded.api.usage);
    try std.testing.expect(loaded.active_account_activated_at_ms != null);
    try std.testing.expect(loaded.accounts.items[0].last_local_rollout != null);
    try std.testing.expectEqual(@as(i64, 1735689600000), loaded.accounts.items[0].last_local_rollout.?.event_timestamp_ms);
    try std.testing.expect(std.mem.eql(u8, loaded.accounts.items[0].last_local_rollout.?.path, "/tmp/sessions/run-1/rollout-a.jsonl"));
}

test "registry load defaults missing auto threshold fields" {
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const codex_home = try tmp.dir.realpathAlloc(gpa, ".");
    defer gpa.free(codex_home);
    try tmp.dir.makePath("accounts");
    try tmp.dir.writeFile(.{
        .sub_path = "accounts/registry.json",
        .data =
        \\{
        \\  "schema_version": 3,
        \\  "active_account_key": null,
        \\  "auto_switch": {
        \\    "enabled": true
        \\  },
        \\  "accounts": []
        \\}
        ,
    });

    var loaded = try registry.loadRegistry(gpa, codex_home);
    defer loaded.deinit(gpa);
    try std.testing.expect(loaded.auto_switch.enabled);
    try std.testing.expect(loaded.auto_switch.threshold_5h_percent == registry.default_auto_switch_threshold_5h_percent);
    try std.testing.expect(loaded.auto_switch.threshold_weekly_percent == registry.default_auto_switch_threshold_weekly_percent);
    try std.testing.expect(loaded.api.usage);
    try std.testing.expect(loaded.active_account_activated_at_ms == null);
}

test "schema 3 registry with legacy rollout attribution rewrites to normalized schema 3" {
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const codex_home = try tmp.dir.realpathAlloc(gpa, ".");
    defer gpa.free(codex_home);
    try tmp.dir.makePath("accounts");
    try tmp.dir.writeFile(.{
        .sub_path = "accounts/registry.json",
        .data =
        \\{
        \\  "schema_version": 3,
        \\  "active_account_key": "user-ESYgcy2QkOGZc0NoxSlFCeVT::67fe2bbb-0de6-49a4-b2b3-d1df366d1faf",
        \\  "last_attributed_rollout": {
        \\    "path": "/tmp/sessions/run-1/rollout-a.jsonl",
        \\    "event_timestamp_ms": 1735689600000
        \\  },
        \\  "accounts": [
        \\    {
        \\      "account_key": "user-ESYgcy2QkOGZc0NoxSlFCeVT::67fe2bbb-0de6-49a4-b2b3-d1df366d1faf",
        \\      "chatgpt_account_id": "67fe2bbb-0de6-49a4-b2b3-d1df366d1faf",
        \\      "chatgpt_user_id": "user-ESYgcy2QkOGZc0NoxSlFCeVT",
        \\      "email": "a@b.com",
        \\      "alias": "work",
        \\      "plan": "pro",
        \\      "auth_mode": "chatgpt",
        \\      "created_at": 1,
        \\      "last_used_at": null,
        \\      "last_usage_at": null
        \\    }
        \\  ]
        \\}
        ,
    });

    var loaded = try registry.loadRegistry(gpa, codex_home);
    defer loaded.deinit(gpa);
    try std.testing.expectEqual(@as(?i64, 0), loaded.active_account_activated_at_ms);
    try std.testing.expect(loaded.accounts.items[0].last_local_rollout == null);

    var file = try tmp.dir.openFile("accounts/registry.json", .{});
    defer file.close();
    const contents = try file.readToEndAlloc(gpa, 10 * 1024 * 1024);
    defer gpa.free(contents);
    try std.testing.expect(std.mem.indexOf(u8, contents, "\"schema_version\": 3") != null);
    try std.testing.expect(std.mem.indexOf(u8, contents, "\"active_account_activated_at_ms\": 0") != null);
    try std.testing.expect(std.mem.indexOf(u8, contents, "\"last_attributed_rollout\"") == null);
}

test "legacy current-layout registry version field rewrites to schema_version" {
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const codex_home = try tmp.dir.realpathAlloc(gpa, ".");
    defer gpa.free(codex_home);
    try tmp.dir.makePath("accounts");
    try tmp.dir.writeFile(.{
        .sub_path = "accounts/registry.json",
        .data =
        \\{
        \\  "version": 3,
        \\  "active_account_key": null,
        \\  "auto_switch": {
        \\    "enabled": true
        \\  },
        \\  "accounts": []
        \\}
        ,
    });

    var loaded = try registry.loadRegistry(gpa, codex_home);
    defer loaded.deinit(gpa);
    try std.testing.expect(loaded.schema_version == registry.current_schema_version);

    var file = try tmp.dir.openFile("accounts/registry.json", .{});
    defer file.close();
    const contents = try file.readToEndAlloc(gpa, 10 * 1024 * 1024);
    defer gpa.free(contents);
    try std.testing.expect(std.mem.indexOf(u8, contents, "\"schema_version\": 3") != null);
    try std.testing.expect(std.mem.indexOf(u8, contents, "\"version\"") == null);
}

test "too-new schema version is rejected without rewriting registry" {
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const codex_home = try tmp.dir.realpathAlloc(gpa, ".");
    defer gpa.free(codex_home);
    try tmp.dir.makePath("accounts");
    try tmp.dir.writeFile(.{
        .sub_path = "accounts/registry.json",
        .data =
        \\{
        \\  "schema_version": 999,
        \\  "active_account_key": null,
        \\  "accounts": []
        \\}
        ,
    });

    try std.testing.expectError(error.UnsupportedRegistryVersion, registry.loadRegistry(gpa, codex_home));

    var file = try tmp.dir.openFile("accounts/registry.json", .{});
    defer file.close();
    const contents = try file.readToEndAlloc(gpa, 10 * 1024 * 1024);
    defer gpa.free(contents);
    try std.testing.expect(std.mem.indexOf(u8, contents, "\"schema_version\": 999") != null);
}

test "v2 registry migrates active email records to current schema" {
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const codex_home = try tmp.dir.realpathAlloc(gpa, ".");
    defer gpa.free(codex_home);
    try tmp.dir.makePath("accounts");

    const legacy_auth = try authJsonWithEmailPlan(gpa, "legacy@example.com", "team");
    defer gpa.free(legacy_auth);
    const legacy_snapshot_rel = try legacySnapshotRelPath(gpa, "legacy@example.com");
    defer gpa.free(legacy_snapshot_rel);
    try tmp.dir.writeFile(.{ .sub_path = legacy_snapshot_rel, .data = legacy_auth });

    try tmp.dir.writeFile(.{
        .sub_path = "accounts/registry.json",
        .data =
        \\{
        \\  "version": 2,
        \\  "active_email": "legacy@example.com",
        \\  "accounts": [
        \\    {
        \\      "email": "legacy@example.com",
        \\      "alias": "work",
        \\      "plan": "team",
        \\      "auth_mode": "chatgpt",
        \\      "created_at": 1,
        \\      "last_used_at": null,
        \\      "last_usage_at": null
        \\    }
        \\  ]
        \\}
        ,
    });

    var loaded = try registry.loadRegistry(gpa, codex_home);
    defer loaded.deinit(gpa);
    try std.testing.expect(loaded.schema_version == registry.current_schema_version);
    try std.testing.expect(loaded.accounts.items.len == 1);

    const expected_account_id = try accountKeyForEmailAlloc(gpa, "legacy@example.com");
    defer gpa.free(expected_account_id);
    try std.testing.expect(loaded.active_account_key != null);
    try std.testing.expect(std.mem.eql(u8, loaded.active_account_key.?, expected_account_id));

    const migrated_snapshot_path = try registry.accountAuthPath(gpa, codex_home, expected_account_id);
    defer gpa.free(migrated_snapshot_path);
    var migrated_snapshot = try std.fs.cwd().openFile(migrated_snapshot_path, .{});
    migrated_snapshot.close();

    var file = try tmp.dir.openFile("accounts/registry.json", .{});
    defer file.close();
    const contents = try file.readToEndAlloc(gpa, 10 * 1024 * 1024);
    defer gpa.free(contents);
    try std.testing.expect(std.mem.indexOf(u8, contents, "\"schema_version\": 3") != null);
    const active_expect = try std.fmt.allocPrint(gpa, "\"active_account_key\": \"{s}\"", .{expected_account_id});
    defer gpa.free(active_expect);
    try std.testing.expect(std.mem.indexOf(u8, contents, active_expect) != null);
}

test "auth backup only on change" {
    var gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const codex_home = try tmp.dir.realpathAlloc(gpa, ".");
    defer gpa.free(codex_home);

    const current = try std.fs.path.join(gpa, &[_][]const u8{ codex_home, "auth.json" });
    defer gpa.free(current);
    const user_account_id = try accountKeyForEmailAlloc(gpa, "user@example.com");
    defer gpa.free(user_account_id);
    const new_auth = try registry.accountAuthPath(gpa, codex_home, user_account_id);
    defer gpa.free(new_auth);
    const account_name = std.fs.path.basename(new_auth);
    const account_path = try std.fs.path.join(gpa, &[_][]const u8{ "accounts", account_name });
    defer gpa.free(account_path);

    try tmp.dir.makePath("accounts");
    try tmp.dir.writeFile(.{ .sub_path = "auth.json", .data = "one" });
    try tmp.dir.writeFile(.{ .sub_path = account_path, .data = "two" });

    try registry.backupAuthIfChanged(gpa, codex_home, current, new_auth);

    var accounts = try tmp.dir.openDir("accounts", .{ .iterate = true });
    defer accounts.close();
    const count1 = try countBackups(accounts, "auth.json");
    try std.testing.expect(count1 == 1);
    var verify_accounts = try tmp.dir.openDir("accounts", .{ .iterate = true });
    defer verify_accounts.close();
    var it = verify_accounts.iterate();
    while (try it.next()) |entry| {
        if (entry.kind != .file) continue;
        if (std.mem.startsWith(u8, entry.name, "auth.json") and std.mem.containsAtLeast(u8, entry.name, 1, ".bak.")) {
            try expectBackupNameFormat(entry.name, "auth.json");
        }
    }

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
    const user_account_id = try accountKeyForEmailAlloc(gpa, "user@example.com");
    defer gpa.free(user_account_id);
    const new_auth = try registry.accountAuthPath(gpa, codex_home, user_account_id);
    defer gpa.free(new_auth);
    const account_name = std.fs.path.basename(new_auth);
    const account_path = try std.fs.path.join(gpa, &[_][]const u8{ "accounts", account_name });
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
    const user_account_id = try accountKeyForEmailAlloc(gpa, "user@example.com");
    defer gpa.free(user_account_id);
    const account_auth_abs = try registry.accountAuthPath(gpa, codex_home, user_account_id);
    defer gpa.free(account_auth_abs);
    const account_name = std.fs.path.basename(account_auth_abs);
    const account_path = try std.fs.path.join(gpa, &[_][]const u8{ "accounts", account_name });
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
    var verify_accounts = try tmp.dir.openDir("accounts", .{ .iterate = true });
    defer verify_accounts.close();
    var it = verify_accounts.iterate();
    while (try it.next()) |entry| {
        if (entry.kind != .file) continue;
        if (std.mem.startsWith(u8, entry.name, "registry.json") and std.mem.containsAtLeast(u8, entry.name, 1, ".bak.")) {
            try expectBackupNameFormat(entry.name, "registry.json");
        }
    }

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

    const keep_account_id = try accountKeyForEmailAlloc(gpa, "keep@example.com");
    defer gpa.free(keep_account_id);
    const keep_abs_path = try registry.accountAuthPath(gpa, codex_home, keep_account_id);
    defer gpa.free(keep_abs_path);
    const keep_name = std.fs.path.basename(keep_abs_path);
    const keep_rel_path = try std.fs.path.join(gpa, &[_][]const u8{ "accounts", keep_name });
    defer gpa.free(keep_rel_path);

    try tmp.dir.writeFile(.{ .sub_path = "accounts/auth.json.bak.1", .data = "a1" });
    try tmp.dir.writeFile(.{ .sub_path = "accounts/auth.json.bak.2", .data = "a2" });
    try tmp.dir.writeFile(.{ .sub_path = "accounts/auth.json.bak.3", .data = "a3" });
    try tmp.dir.writeFile(.{ .sub_path = "accounts/registry.json.bak.1", .data = "r1" });
    try tmp.dir.writeFile(.{ .sub_path = "accounts/registry.json.bak.2", .data = "r2" });
    try tmp.dir.writeFile(.{ .sub_path = keep_rel_path, .data = "keep" });
    try tmp.dir.writeFile(.{ .sub_path = "accounts/bGVnYWN5QGV4YW1wbGUuY29t.auth.json", .data = "legacy" });
    try tmp.dir.writeFile(.{ .sub_path = "accounts/notes.txt", .data = "junk" });
    try tmp.dir.makePath("accounts/tmpdir");
    try tmp.dir.writeFile(.{ .sub_path = "accounts/tmpdir/old.txt", .data = "junk" });
    try tmp.dir.makePath("accounts/backups/v2/20260312-063235");
    try tmp.dir.writeFile(.{ .sub_path = "accounts/backups/v2/20260312-063235/registry.json", .data = "keep" });

    const summary = try registry.cleanAccountsBackups(gpa, codex_home);
    try std.testing.expect(summary.auth_backups_removed == 3);
    try std.testing.expect(summary.registry_backups_removed == 2);
    try std.testing.expect(summary.stale_snapshot_files_removed == 3);

    var accounts = try tmp.dir.openDir("accounts", .{ .iterate = true });
    defer accounts.close();
    try std.testing.expect(try countBackups(accounts, "auth.json") == 0);
    try std.testing.expect(try countBackups(accounts, "registry.json") == 0);
    var kept = try tmp.dir.openFile(keep_rel_path, .{});
    kept.close();
    try std.testing.expectError(error.FileNotFound, tmp.dir.openFile("accounts/bGVnYWN5QGV4YW1wbGUuY29t.auth.json", .{}));
    try std.testing.expectError(error.FileNotFound, tmp.dir.openFile("accounts/notes.txt", .{}));
    try std.testing.expectError(error.FileNotFound, tmp.dir.openFile("accounts/tmpdir/old.txt", .{}));

    var preserved_backup = try tmp.dir.openFile("accounts/backups/v2/20260312-063235/registry.json", .{});
    preserved_backup.close();
}

test "clean preserves account snapshots when registry is missing" {
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const codex_home = try tmp.dir.realpathAlloc(gpa, ".");
    defer gpa.free(codex_home);
    try tmp.dir.makePath("accounts");

    var reg = makeEmptyRegistry();
    defer reg.deinit(gpa);
    const keep_record = try makeAccountRecord(gpa, "keep@example.com", "", .team, .chatgpt, 1);
    try reg.accounts.append(gpa, keep_record);
    try registry.saveRegistry(gpa, codex_home, &reg);

    const keep_account_key = try accountKeyForEmailAlloc(gpa, "keep@example.com");
    defer gpa.free(keep_account_key);
    const keep_abs_path = try registry.accountAuthPath(gpa, codex_home, keep_account_key);
    defer gpa.free(keep_abs_path);
    const keep_rel_path = try std.fs.path.join(gpa, &[_][]const u8{ "accounts", std.fs.path.basename(keep_abs_path) });
    defer gpa.free(keep_rel_path);

    const recover_account_key = try accountKeyForEmailAlloc(gpa, "recover@example.com");
    defer gpa.free(recover_account_key);
    const recover_abs_path = try registry.accountAuthPath(gpa, codex_home, recover_account_key);
    defer gpa.free(recover_abs_path);
    const recover_rel_path = try std.fs.path.join(gpa, &[_][]const u8{ "accounts", std.fs.path.basename(recover_abs_path) });
    defer gpa.free(recover_rel_path);

    try tmp.dir.writeFile(.{ .sub_path = keep_rel_path, .data = "keep" });
    try tmp.dir.writeFile(.{ .sub_path = recover_rel_path, .data = "recover" });
    try tmp.dir.writeFile(.{ .sub_path = "accounts/auth.json.bak.1", .data = "a1" });
    try tmp.dir.writeFile(.{ .sub_path = "accounts/registry.json.bak.1", .data = "r1" });
    try tmp.dir.deleteFile("accounts/registry.json");

    const summary = try registry.cleanAccountsBackups(gpa, codex_home);
    try std.testing.expect(summary.auth_backups_removed == 1);
    try std.testing.expect(summary.registry_backups_removed == 1);
    try std.testing.expect(summary.stale_snapshot_files_removed == 0);

    var keep_file = try tmp.dir.openFile(keep_rel_path, .{});
    keep_file.close();
    var recover_file = try tmp.dir.openFile(recover_rel_path, .{});
    recover_file.close();
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

    const account_id_a = try accountKeyForEmailAlloc(gpa, "a@example.com");
    defer gpa.free(account_id_a);
    const path_a = try registry.accountAuthPath(gpa, codex_home, account_id_a);
    defer gpa.free(path_a);
    const account_id_b = try accountKeyForEmailAlloc(gpa, "b@example.com");
    defer gpa.free(account_id_b);
    const path_b = try registry.accountAuthPath(gpa, codex_home, account_id_b);
    defer gpa.free(path_b);
    var file_a = try std.fs.cwd().openFile(path_a, .{});
    defer file_a.close();
    var file_b = try std.fs.cwd().openFile(path_b, .{});
    defer file_b.close();
}

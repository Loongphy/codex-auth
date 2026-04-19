const std = @import("std");
const fs = @import("../compat_fs.zig");
const builtin = @import("builtin");
const registry = @import("../registry.zig");

fn b64url(allocator: std.mem.Allocator, input: []const u8) ![]u8 {
    const encoder = std.base64.url_safe_no_pad.Encoder;
    const out_len = encoder.calcSize(input.len);
    const buf = try allocator.alloc(u8, out_len);
    _ = encoder.encode(buf, input);
    return buf;
}

fn legacySnapshotNameForEmail(allocator: std.mem.Allocator, email: []const u8) ![]u8 {
    const key = try b64url(allocator, email);
    defer allocator.free(key);
    return std.fmt.allocPrint(allocator, "{s}.auth.json", .{key});
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

    return try std.fmt.allocPrint(
        allocator,
        "{{\"tokens\":{{\"account_id\":\"{s}\",\"id_token\":\"{s}\"}}}}",
        .{ chatgpt_account_id, jwt },
    );
}

fn authJsonWithExplicitIds(
    allocator: std.mem.Allocator,
    email: []const u8,
    chatgpt_account_id: []const u8,
    chatgpt_user_id: []const u8,
    plan: []const u8,
) ![]u8 {
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

    return try std.fmt.allocPrint(
        allocator,
        "{{\"tokens\":{{\"account_id\":\"{s}\",\"id_token\":\"{s}\"}}}}",
        .{ chatgpt_account_id, jwt },
    );
}

test "Scenario: Given legacy version key current-layout registry when loading then it rewrites to schema_version" {
    const gpa = std.testing.allocator;
    var tmp = fs.tmpDir(.{});
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
    try std.testing.expect(loaded.auto_switch.enabled);
    try std.testing.expect(loaded.schema_version == registry.current_schema_version);

    var file = try tmp.dir.openFile("accounts/registry.json", .{});
    defer file.close();
    const contents = try file.readToEndAlloc(gpa, 10 * 1024 * 1024);
    defer gpa.free(contents);
    try std.testing.expect(std.mem.indexOf(u8, contents, "\"schema_version\": 3") != null);
    try std.testing.expect(std.mem.indexOf(u8, contents, "\"version\": 3") == null);
}

test "Scenario: Given newer schema version when loading then it is rejected" {
    const gpa = std.testing.allocator;
    var tmp = fs.tmpDir(.{});
    defer tmp.cleanup();

    const codex_home = try tmp.dir.realpathAlloc(gpa, ".");
    defer gpa.free(codex_home);
    try tmp.dir.makePath("accounts");
    try tmp.dir.writeFile(.{
        .sub_path = "accounts/registry.json",
        .data =
        \\{
        \\  "schema_version": 999,
        \\  "accounts": []
        \\}
        ,
    });

    try std.testing.expectError(error.UnsupportedRegistryVersion, registry.loadRegistry(gpa, codex_home));
}

test "Scenario: Given v2 registry when loading then it migrates to record-key layout and rewrites schema_version" {
    const gpa = std.testing.allocator;
    var tmp = fs.tmpDir(.{});
    defer tmp.cleanup();

    const codex_home = try tmp.dir.realpathAlloc(gpa, ".");
    defer gpa.free(codex_home);
    try tmp.dir.makePath("accounts");

    const email = "legacy@example.com";
    const auth_json = try authJsonWithEmailPlan(gpa, email, "team");
    defer gpa.free(auth_json);
    const legacy_name = try legacySnapshotNameForEmail(gpa, email);
    defer gpa.free(legacy_name);
    const legacy_rel = try fs.path.join(gpa, &[_][]const u8{ "accounts", legacy_name });
    defer gpa.free(legacy_rel);
    try tmp.dir.writeFile(.{ .sub_path = legacy_rel, .data = auth_json });
    try tmp.dir.writeFile(.{ .sub_path = "accounts/auth.json.bak.20260312-000000", .data = auth_json });

    try tmp.dir.writeFile(.{
        .sub_path = "accounts/registry.json",
        .data =
        \\{
        \\  "version": 2,
        \\  "active_email": "legacy@example.com",
        \\  "accounts": [
        \\    {
        \\      "email": "legacy@example.com",
        \\      "alias": "legacy",
        \\      "plan": "pro",
        \\      "auth_mode": "chatgpt",
        \\      "created_at": 1,
        \\      "last_used_at": 2,
        \\      "last_usage_at": 3,
        \\      "last_usage": {
        \\        "primary": {
        \\          "used_percent": 25,
        \\          "window_minutes": 300,
        \\          "resets_at": 123
        \\        },
        \\        "plan_type": "team"
        \\      }
        \\    }
        \\  ]
        \\}
        ,
    });

    var loaded = try registry.loadRegistry(gpa, codex_home);
    defer loaded.deinit(gpa);
    try std.testing.expect(loaded.schema_version == registry.current_schema_version);
    try std.testing.expect(loaded.accounts.items.len == 1);
    try std.testing.expect(loaded.active_account_key != null);

    const account_id = try accountKeyForEmailAlloc(gpa, email);
    defer gpa.free(account_id);
    try std.testing.expect(std.mem.eql(u8, loaded.accounts.items[0].account_key, account_id));
    try std.testing.expect(std.mem.eql(u8, loaded.active_account_key.?, account_id));
    try std.testing.expect(std.mem.eql(u8, loaded.accounts.items[0].alias, "legacy"));
    try std.testing.expect(loaded.accounts.items[0].last_used_at != null);
    try std.testing.expect(loaded.accounts.items[0].last_used_at.? >= 2);
    try std.testing.expectEqual(@as(i64, 3), loaded.accounts.items[0].last_usage_at.?);
    try std.testing.expectEqual(@as(f64, 25.0), loaded.accounts.items[0].last_usage.?.primary.?.used_percent);
    try std.testing.expectEqual(registry.PlanType.team, loaded.accounts.items[0].last_usage.?.plan_type.?);

    const migrated_path = try registry.accountAuthPath(gpa, codex_home, account_id);
    defer gpa.free(migrated_path);
    var migrated = try fs.cwd().openFile(migrated_path, .{});
    migrated.close();
    try std.testing.expectError(error.FileNotFound, tmp.dir.openFile(legacy_rel, .{}));

    var file = try tmp.dir.openFile("accounts/registry.json", .{});
    defer file.close();
    const contents = try file.readToEndAlloc(gpa, 10 * 1024 * 1024);
    defer gpa.free(contents);
    try std.testing.expect(std.mem.indexOf(u8, contents, "\"schema_version\": 3") != null);
    const active_expect = try std.fmt.allocPrint(gpa, "\"active_account_key\": \"{s}\"", .{account_id});
    defer gpa.free(active_expect);
    try std.testing.expect(std.mem.indexOf(u8, contents, active_expect) != null);
}

test "Scenario: Given purge import with file when rebuilding then current auth is imported as active and old registry entries are discarded" {
    const gpa = std.testing.allocator;
    var tmp = fs.tmpDir(.{});
    defer tmp.cleanup();

    const codex_home = try tmp.dir.realpathAlloc(gpa, ".");
    defer gpa.free(codex_home);
    try tmp.dir.makePath("accounts");
    try tmp.dir.makePath("imports");

    const imported_auth = try authJsonWithEmailPlan(gpa, "personal@example.com", "plus");
    defer gpa.free(imported_auth);
    try tmp.dir.writeFile(.{ .sub_path = "imports/personal.json", .data = imported_auth });

    const active_auth = try authJsonWithEmailPlan(gpa, "active@example.com", "team");
    defer gpa.free(active_auth);
    try tmp.dir.writeFile(.{ .sub_path = "auth.json", .data = active_auth });

    try tmp.dir.writeFile(.{
        .sub_path = "accounts/registry.json",
        .data =
        \\{
        \\  "schema_version": 3,
        \\  "active_account_key": "user-r4g1strystale000001::67fe2bbb-0de6-49a4-b2b3-d1df366d1faf",
        \\  "active_account_activated_at_ms": 1735689600000,
        \\  "auto_switch": {
        \\    "enabled": true,
        \\    "threshold_5h_percent": 12,
        \\    "threshold_weekly_percent": 7
        \\  },
        \\  "api": {
        \\    "usage": true
        \\  },
        \\  "accounts": [
        \\    {
        \\      "account_key": "user-r4g1strystale000001::67fe2bbb-0de6-49a4-b2b3-d1df366d1faf",
        \\      "chatgpt_account_id": "67fe2bbb-0de6-49a4-b2b3-d1df366d1faf",
        \\      "chatgpt_user_id": "user-r4g1strystale000001",
        \\      "email": "stale@example.com",
        \\      "alias": "stale",
        \\      "plan": "pro",
        \\      "auth_mode": "chatgpt",
        \\      "created_at": 1,
        \\      "last_used_at": null,
        \\      "last_usage_at": 9,
        \\      "last_usage": {
        \\        "primary": {
        \\          "used_percent": 99,
        \\          "window_minutes": 300,
        \\          "resets_at": 123
        \\        }
        \\      }
        \\    }
        \\  ]
        \\}
        ,
    });

    const import_path = try fs.path.join(gpa, &[_][]const u8{ codex_home, "imports", "personal.json" });
    defer gpa.free(import_path);

    var report = try registry.purgeRegistryFromImportSource(gpa, codex_home, import_path, "personal");
    defer report.deinit(gpa);

    var loaded = try registry.loadRegistry(gpa, codex_home);
    defer loaded.deinit(gpa);
    try std.testing.expect(loaded.accounts.items.len == 2);
    try std.testing.expect(loaded.auto_switch.enabled);
    try std.testing.expectEqual(@as(u8, 12), loaded.auto_switch.threshold_5h_percent);
    try std.testing.expectEqual(@as(u8, 7), loaded.auto_switch.threshold_weekly_percent);
    try std.testing.expect(loaded.api.usage);
    try std.testing.expect(loaded.api.account);
    try std.testing.expect(loaded.active_account_activated_at_ms != null);

    const active_account_key = try accountKeyForEmailAlloc(gpa, "active@example.com");
    defer gpa.free(active_account_key);
    try std.testing.expect(loaded.active_account_key != null);
    try std.testing.expect(std.mem.eql(u8, loaded.active_account_key.?, active_account_key));

    const stale_idx = registry.findAccountIndexByAccountKey(&loaded, "user-r4g1strystale000001::67fe2bbb-0de6-49a4-b2b3-d1df366d1faf");
    try std.testing.expect(stale_idx == null);

    const imported_account_id = try accountKeyForEmailAlloc(gpa, "personal@example.com");
    defer gpa.free(imported_account_id);
    const imported_idx = registry.findAccountIndexByAccountKey(&loaded, imported_account_id) orelse return error.TestExpectedEqual;
    try std.testing.expect(std.mem.eql(u8, loaded.accounts.items[imported_idx].alias, "personal"));
    try std.testing.expect(loaded.accounts.items[imported_idx].last_usage == null);
    try std.testing.expect(loaded.accounts.items[imported_idx].last_usage_at == null);
    try std.testing.expect(loaded.accounts.items[imported_idx].last_local_rollout == null);

    const active_idx = registry.findAccountIndexByAccountKey(&loaded, active_account_key) orelse return error.TestExpectedEqual;
    try std.testing.expect(loaded.accounts.items[active_idx].last_usage == null);
    try std.testing.expect(loaded.accounts.items[active_idx].last_usage_at == null);
    try std.testing.expect(loaded.accounts.items[active_idx].last_local_rollout == null);
}

test "Scenario: Given purge with newer schema registry when rebuilding then auto and api config are preserved" {
    const gpa = std.testing.allocator;
    var tmp = fs.tmpDir(.{});
    defer tmp.cleanup();

    const codex_home = try tmp.dir.realpathAlloc(gpa, ".");
    defer gpa.free(codex_home);
    try tmp.dir.makePath("accounts");
    try tmp.dir.makePath("imports");

    const imported_auth = try authJsonWithEmailPlan(gpa, "personal@example.com", "plus");
    defer gpa.free(imported_auth);
    try tmp.dir.writeFile(.{ .sub_path = "imports/personal.json", .data = imported_auth });

    try tmp.dir.writeFile(.{
        .sub_path = "accounts/registry.json",
        .data =
        \\{
        \\  "schema_version": 999,
        \\  "auto_switch": {
        \\    "enabled": true,
        \\    "threshold_5h_percent": 18,
        \\    "threshold_weekly_percent": 6
        \\  },
        \\  "api": {
        \\    "usage": true
        \\  },
        \\  "accounts": []
        \\}
        ,
    });

    const import_path = try fs.path.join(gpa, &[_][]const u8{ codex_home, "imports", "personal.json" });
    defer gpa.free(import_path);

    var report = try registry.purgeRegistryFromImportSource(gpa, codex_home, import_path, "personal");
    defer report.deinit(gpa);

    var loaded = try registry.loadRegistry(gpa, codex_home);
    defer loaded.deinit(gpa);
    try std.testing.expect(loaded.auto_switch.enabled);
    try std.testing.expectEqual(@as(u8, 18), loaded.auto_switch.threshold_5h_percent);
    try std.testing.expectEqual(@as(u8, 6), loaded.auto_switch.threshold_weekly_percent);
    try std.testing.expect(loaded.api.usage);
    try std.testing.expect(loaded.api.account);
}

test "Scenario: Given purge with malformed registry when rebuilding then auto and api config are recovered best effort" {
    const gpa = std.testing.allocator;
    var tmp = fs.tmpDir(.{});
    defer tmp.cleanup();

    const codex_home = try tmp.dir.realpathAlloc(gpa, ".");
    defer gpa.free(codex_home);
    try tmp.dir.makePath("accounts");
    try tmp.dir.makePath("imports");

    const imported_auth = try authJsonWithEmailPlan(gpa, "personal@example.com", "plus");
    defer gpa.free(imported_auth);
    try tmp.dir.writeFile(.{ .sub_path = "imports/personal.json", .data = imported_auth });

    try tmp.dir.writeFile(.{
        .sub_path = "accounts/registry.json",
        .data =
        \\{
        \\  "auto_switch": {
        \\    "enabled": true,
        \\    "threshold_5h_percent": 13,
        \\    "threshold_weekly_percent": 4
        \\  },
        \\  "api": {
        \\    "usage": true
        \\  },
        \\  "accounts": [oops]
        \\}
        ,
    });

    const import_path = try fs.path.join(gpa, &[_][]const u8{ codex_home, "imports", "personal.json" });
    defer gpa.free(import_path);

    var report = try registry.purgeRegistryFromImportSource(gpa, codex_home, import_path, "personal");
    defer report.deinit(gpa);

    var loaded = try registry.loadRegistry(gpa, codex_home);
    defer loaded.deinit(gpa);
    try std.testing.expect(loaded.auto_switch.enabled);
    try std.testing.expectEqual(@as(u8, 13), loaded.auto_switch.threshold_5h_percent);
    try std.testing.expectEqual(@as(u8, 4), loaded.auto_switch.threshold_weekly_percent);
    try std.testing.expect(loaded.api.usage);
    try std.testing.expect(loaded.api.account);
}

test "Scenario: Given purge without path when rebuilding then it scans account snapshots and ignores registry metadata files" {
    const gpa = std.testing.allocator;
    var tmp = fs.tmpDir(.{});
    defer tmp.cleanup();

    const codex_home = try tmp.dir.realpathAlloc(gpa, ".");
    defer gpa.free(codex_home);
    try tmp.dir.makePath("accounts");

    const snapshot_auth = try authJsonWithEmailPlan(gpa, "snap@example.com", "pro");
    defer gpa.free(snapshot_auth);
    const snapshot_account_id = try accountKeyForEmailAlloc(gpa, "snap@example.com");
    defer gpa.free(snapshot_account_id);
    const snapshot_path = try registry.accountAuthPath(gpa, codex_home, snapshot_account_id);
    defer gpa.free(snapshot_path);
    const snapshot_name = fs.path.basename(snapshot_path);
    const snapshot_rel = try fs.path.join(gpa, &[_][]const u8{ "accounts", snapshot_name });
    defer gpa.free(snapshot_rel);
    try tmp.dir.writeFile(.{ .sub_path = snapshot_rel, .data = snapshot_auth });
    try tmp.dir.writeFile(.{ .sub_path = "accounts/registry.json", .data = "{\"bad\":\"registry\"}" });
    try tmp.dir.writeFile(.{ .sub_path = "accounts/auth.json.bak.1", .data = "backup" });

    var report = try registry.purgeRegistryFromImportSource(gpa, codex_home, null, null);
    defer report.deinit(gpa);

    var loaded = try registry.loadRegistry(gpa, codex_home);
    defer loaded.deinit(gpa);
    try std.testing.expect(loaded.accounts.items.len == 1);
    try std.testing.expect(std.mem.eql(u8, loaded.accounts.items[0].email, "snap@example.com"));
}

test "Scenario: Given purge without path and only auth backups when rebuilding then it imports backup auth files too" {
    const gpa = std.testing.allocator;
    var tmp = fs.tmpDir(.{});
    defer tmp.cleanup();

    const codex_home = try tmp.dir.realpathAlloc(gpa, ".");
    defer gpa.free(codex_home);
    try tmp.dir.makePath("accounts");

    const backup_auth = try authJsonWithEmailPlan(gpa, "backup-only@example.com", "team");
    defer gpa.free(backup_auth);
    try tmp.dir.writeFile(.{ .sub_path = "accounts/auth.json.bak.20260317-010101", .data = backup_auth });

    var report = try registry.purgeRegistryFromImportSource(gpa, codex_home, null, null);
    defer report.deinit(gpa);

    var loaded = try registry.loadRegistry(gpa, codex_home);
    defer loaded.deinit(gpa);
    try std.testing.expectEqual(@as(usize, 1), loaded.accounts.items.len);
    try std.testing.expect(std.mem.eql(u8, loaded.accounts.items[0].email, "backup-only@example.com"));

    const record_key = try accountKeyForEmailAlloc(gpa, "backup-only@example.com");
    defer gpa.free(record_key);
    try std.testing.expect(std.mem.eql(u8, loaded.accounts.items[0].account_key, record_key));

    const snapshot_path = try registry.accountAuthPath(gpa, codex_home, record_key);
    defer gpa.free(snapshot_path);
    var snapshot = try fs.cwd().openFile(snapshot_path, .{});
    snapshot.close();
}

test "Scenario: Given purge without a recoverable active auth when rebuilding then it activates the first sorted account and backs up the previous auth" {
    const gpa = std.testing.allocator;
    var tmp = fs.tmpDir(.{});
    defer tmp.cleanup();

    const codex_home = try tmp.dir.realpathAlloc(gpa, ".");
    defer gpa.free(codex_home);
    try tmp.dir.makePath("accounts");

    const zed_auth = try authJsonWithEmailPlan(gpa, "zed@example.com", "team");
    defer gpa.free(zed_auth);
    const zed_record_key = try accountKeyForEmailAlloc(gpa, "zed@example.com");
    defer gpa.free(zed_record_key);
    const zed_snapshot_path = try registry.accountAuthPath(gpa, codex_home, zed_record_key);
    defer gpa.free(zed_snapshot_path);
    const zed_snapshot_rel = try std.fs.path.relative(gpa, codex_home, null, codex_home, zed_snapshot_path);
    defer gpa.free(zed_snapshot_rel);
    try tmp.dir.writeFile(.{ .sub_path = zed_snapshot_rel, .data = zed_auth });

    const alpha_auth = try authJsonWithEmailPlan(gpa, "alpha@example.com", "plus");
    defer gpa.free(alpha_auth);
    const alpha_record_key = try accountKeyForEmailAlloc(gpa, "alpha@example.com");
    defer gpa.free(alpha_record_key);
    const alpha_snapshot_path = try registry.accountAuthPath(gpa, codex_home, alpha_record_key);
    defer gpa.free(alpha_snapshot_path);
    const alpha_snapshot_rel = try std.fs.path.relative(gpa, codex_home, null, codex_home, alpha_snapshot_path);
    defer gpa.free(alpha_snapshot_rel);
    try tmp.dir.writeFile(.{ .sub_path = alpha_snapshot_rel, .data = alpha_auth });

    const stale_auth = "{\"broken\":true}";
    try tmp.dir.writeFile(.{ .sub_path = "auth.json", .data = stale_auth });

    var report = try registry.purgeRegistryFromImportSource(gpa, codex_home, null, null);
    defer report.deinit(gpa);

    try std.testing.expectEqual(@as(usize, 2), report.imported);
    try std.testing.expectEqual(@as(usize, 0), report.updated);
    try std.testing.expectEqual(@as(usize, 0), report.skipped);

    var loaded = try registry.loadRegistry(gpa, codex_home);
    defer loaded.deinit(gpa);
    try std.testing.expectEqual(@as(usize, 2), loaded.accounts.items.len);
    try std.testing.expect(loaded.active_account_key != null);
    try std.testing.expect(std.mem.eql(u8, loaded.active_account_key.?, alpha_record_key));

    const active_auth_path = try registry.activeAuthPath(gpa, codex_home);
    defer gpa.free(active_auth_path);
    var active_file = try fs.cwd().openFile(active_auth_path, .{});
    defer active_file.close();
    const active_auth = try active_file.readToEndAlloc(gpa, 10 * 1024 * 1024);
    defer gpa.free(active_auth);
    try std.testing.expectEqualStrings(alpha_auth, active_auth);

    var backup_name: ?[]u8 = null;
    defer if (backup_name) |name| gpa.free(name);

    var accounts = try tmp.dir.openDir("accounts", .{ .iterate = true });
    defer accounts.close();
    var it = accounts.iterate();
    var backup_count: usize = 0;
    while (try it.next()) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.startsWith(u8, entry.name, "auth.json.bak.")) continue;
        backup_count += 1;
        if (backup_name == null) {
            backup_name = try gpa.dupe(u8, entry.name);
        }
    }
    try std.testing.expectEqual(@as(usize, 1), backup_count);
    try std.testing.expect(backup_name != null);

    const backup_rel = try fs.path.join(gpa, &[_][]const u8{ "accounts", backup_name.? });
    defer gpa.free(backup_rel);
    var backup_file = try tmp.dir.openFile(backup_rel, .{});
    defer backup_file.close();
    const backup_contents = try backup_file.readToEndAlloc(gpa, 10 * 1024 * 1024);
    defer gpa.free(backup_contents);
    try std.testing.expectEqualStrings(stale_auth, backup_contents);
}

test "Scenario: Given purge without path and an empty snapshot when rebuilding then it reports malformed json and still imports valid backups" {
    const gpa = std.testing.allocator;
    var tmp = fs.tmpDir(.{});
    defer tmp.cleanup();

    const codex_home = try tmp.dir.realpathAlloc(gpa, ".");
    defer gpa.free(codex_home);
    try tmp.dir.makePath("accounts");

    const backup_auth = try authJsonWithEmailPlan(gpa, "backup-valid@example.com", "team");
    defer gpa.free(backup_auth);
    try tmp.dir.writeFile(.{ .sub_path = "accounts/auth.json.bak.20260317-010101", .data = backup_auth });
    try tmp.dir.writeFile(.{ .sub_path = "accounts/auth.json.bak.20260317-020202", .data = "" });

    var report = try registry.purgeRegistryFromImportSource(gpa, codex_home, null, null);
    defer report.deinit(gpa);

    try std.testing.expectEqual(@as(usize, 1), report.imported);
    try std.testing.expectEqual(@as(usize, 1), report.skipped);

    var found_malformed = false;
    for (report.events.items) |event| {
        if (event.outcome != .skipped) continue;
        if (std.mem.eql(u8, event.label, "auth.json.bak.20260317-020202")) {
            found_malformed = std.mem.eql(u8, event.reason.?, "MalformedJson");
            break;
        }
    }
    try std.testing.expect(found_malformed);

    var loaded = try registry.loadRegistry(gpa, codex_home);
    defer loaded.deinit(gpa);
    try std.testing.expectEqual(@as(usize, 1), loaded.accounts.items.len);
    try std.testing.expect(std.mem.eql(u8, loaded.accounts.items[0].email, "backup-valid@example.com"));
}

test "Scenario: Given purge without path and a broken snapshot symlink when rebuilding then it skips that entry and still imports valid backups" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;

    const gpa = std.testing.allocator;
    var tmp = fs.tmpDir(.{});
    defer tmp.cleanup();

    const codex_home = try tmp.dir.realpathAlloc(gpa, ".");
    defer gpa.free(codex_home);
    try tmp.dir.makePath("accounts");

    const backup_auth = try authJsonWithEmailPlan(gpa, "backup-symlink@example.com", "team");
    defer gpa.free(backup_auth);
    try tmp.dir.writeFile(.{ .sub_path = "accounts/auth.json.bak.20260317-010101", .data = backup_auth });
    try tmp.dir.symLink("missing.auth.json", "accounts/auth.json.bak.20260317-020202", .{});

    var report = try registry.purgeRegistryFromImportSource(gpa, codex_home, null, null);
    defer report.deinit(gpa);

    try std.testing.expectEqual(@as(usize, 1), report.imported);
    try std.testing.expectEqual(@as(usize, 1), report.skipped);

    var found_missing = false;
    for (report.events.items) |event| {
        if (event.outcome != .skipped) continue;
        if (std.mem.eql(u8, event.label, "auth.json.bak.20260317-020202")) {
            found_missing = std.mem.eql(u8, event.reason.?, "FileNotFound");
            break;
        }
    }
    try std.testing.expect(found_missing);

    var loaded = try registry.loadRegistry(gpa, codex_home);
    defer loaded.deinit(gpa);
    try std.testing.expectEqual(@as(usize, 1), loaded.accounts.items.len);
    try std.testing.expect(std.mem.eql(u8, loaded.accounts.items[0].email, "backup-symlink@example.com"));
}

test "Scenario: Given purge without path and duplicate snapshots when rebuilding then newest snapshot wins and accounts are sorted by email" {
    const gpa = std.testing.allocator;
    var tmp = fs.tmpDir(.{});
    defer tmp.cleanup();

    const codex_home = try tmp.dir.realpathAlloc(gpa, ".");
    defer gpa.free(codex_home);
    try tmp.dir.makePath("accounts");

    const duplicate_record_key = "1::acct1";
    const old_backup_auth = try authJsonWithExplicitIds(gpa, "zed@example.com", "acct1", "1", "free");
    defer gpa.free(old_backup_auth);
    try tmp.dir.writeFile(.{ .sub_path = "accounts/auth.json.bak.20260317-010101", .data = old_backup_auth });

    const current_snapshot_auth = try authJsonWithExplicitIds(gpa, "zed@example.com", "acct1", "1", "team");
    defer gpa.free(current_snapshot_auth);
    const current_snapshot_path = try registry.accountAuthPath(gpa, codex_home, duplicate_record_key);
    defer gpa.free(current_snapshot_path);
    const current_snapshot_rel = try std.fs.path.relative(gpa, codex_home, null, codex_home, current_snapshot_path);
    defer gpa.free(current_snapshot_rel);
    try tmp.dir.writeFile(.{
        .sub_path = current_snapshot_rel,
        .data = current_snapshot_auth,
    });

    const alpha_auth = try authJsonWithEmailPlan(gpa, "alpha@example.com", "plus");
    defer gpa.free(alpha_auth);
    try tmp.dir.writeFile(.{ .sub_path = "accounts/auth.json.bak.20260317-020202", .data = alpha_auth });

    var report = try registry.purgeRegistryFromImportSource(gpa, codex_home, null, null);
    defer report.deinit(gpa);

    var loaded = try registry.loadRegistry(gpa, codex_home);
    defer loaded.deinit(gpa);
    try std.testing.expectEqual(@as(usize, 2), loaded.accounts.items.len);
    try std.testing.expect(std.mem.eql(u8, loaded.accounts.items[0].email, "alpha@example.com"));
    try std.testing.expect(std.mem.eql(u8, loaded.accounts.items[1].email, "zed@example.com"));

    const duplicate_idx = registry.findAccountIndexByAccountKey(&loaded, duplicate_record_key) orelse return error.TestExpectedEqual;
    try std.testing.expectEqual(registry.PlanType.team, loaded.accounts.items[duplicate_idx].plan.?);

    var snapshot = try fs.cwd().openFile(current_snapshot_path, .{});
    defer snapshot.close();
    const snapshot_contents = try snapshot.readToEndAlloc(gpa, 10 * 1024 * 1024);
    defer gpa.free(snapshot_contents);
    try std.testing.expect(std.mem.eql(u8, snapshot_contents, current_snapshot_auth));
}

test "Scenario: Given same team account id across different users when purging then record key keeps both imported accounts" {
    const gpa = std.testing.allocator;
    var tmp = fs.tmpDir(.{});
    defer tmp.cleanup();

    const codex_home = try tmp.dir.realpathAlloc(gpa, ".");
    defer gpa.free(codex_home);
    try tmp.dir.makePath("accounts");

    const shared_chatgpt_account_id = "67fe2bbb-0de6-49a4-b2b3-d1df366d1faf";

    const first_auth = try authJsonWithExplicitIds(
        gpa,
        "trade5258@bytebit.ggff.net",
        shared_chatgpt_account_id,
        "user-VcL6uT0HoEblRE4RSV7NsUDI",
        "team",
    );
    defer gpa.free(first_auth);
    try tmp.dir.writeFile(.{ .sub_path = "accounts/auth.json.bak.20260317-154910", .data = first_auth });

    const second_auth = try authJsonWithExplicitIds(
        gpa,
        "cloning5942@bytebit.ggff.net",
        shared_chatgpt_account_id,
        "user-ESYgcy2QkOGZc0NoxSlFCeVT",
        "team",
    );
    defer gpa.free(second_auth);
    try tmp.dir.writeFile(.{ .sub_path = "accounts/auth.json.bak.20260317-171806", .data = second_auth });

    var report = try registry.purgeRegistryFromImportSource(gpa, codex_home, null, null);
    defer report.deinit(gpa);

    var loaded = try registry.loadRegistry(gpa, codex_home);
    defer loaded.deinit(gpa);
    try std.testing.expectEqual(@as(usize, 2), loaded.accounts.items.len);

    const first_record_key = "user-VcL6uT0HoEblRE4RSV7NsUDI::67fe2bbb-0de6-49a4-b2b3-d1df366d1faf";
    const second_record_key = "user-ESYgcy2QkOGZc0NoxSlFCeVT::67fe2bbb-0de6-49a4-b2b3-d1df366d1faf";

    const first_idx = registry.findAccountIndexByAccountKey(&loaded, first_record_key) orelse return error.TestExpectedEqual;
    const second_idx = registry.findAccountIndexByAccountKey(&loaded, second_record_key) orelse return error.TestExpectedEqual;

    try std.testing.expect(!std.mem.eql(u8, loaded.accounts.items[first_idx].account_key, loaded.accounts.items[second_idx].account_key));
    try std.testing.expect(std.mem.eql(u8, loaded.accounts.items[first_idx].chatgpt_account_id, shared_chatgpt_account_id));
    try std.testing.expect(std.mem.eql(u8, loaded.accounts.items[second_idx].chatgpt_account_id, shared_chatgpt_account_id));
    try std.testing.expect(std.mem.eql(u8, loaded.accounts.items[first_idx].chatgpt_user_id, "user-VcL6uT0HoEblRE4RSV7NsUDI"));
    try std.testing.expect(std.mem.eql(u8, loaded.accounts.items[second_idx].chatgpt_user_id, "user-ESYgcy2QkOGZc0NoxSlFCeVT"));
    try std.testing.expect(std.mem.eql(u8, loaded.accounts.items[first_idx].email, "trade5258@bytebit.ggff.net"));
    try std.testing.expect(std.mem.eql(u8, loaded.accounts.items[second_idx].email, "cloning5942@bytebit.ggff.net"));
}

test "Scenario: Given same user across team and free workspaces when purging then record key keeps both workspace records" {
    const gpa = std.testing.allocator;
    var tmp = fs.tmpDir(.{});
    defer tmp.cleanup();

    const codex_home = try tmp.dir.realpathAlloc(gpa, ".");
    defer gpa.free(codex_home);
    try tmp.dir.makePath("accounts");

    const shared_chatgpt_user_id = "user-NuLAf1g5RIAwHDQxfoHfgcPo";
    const shared_email = "flashback6936@8bits.ggff.net";

    const team_auth = try authJsonWithExplicitIds(
        gpa,
        shared_email,
        "d52355a3-bfa6-4d2b-882e-d4a2927f488c",
        shared_chatgpt_user_id,
        "team",
    );
    defer gpa.free(team_auth);
    try tmp.dir.writeFile(.{ .sub_path = "accounts/auth.json.bak.20260317-135020", .data = team_auth });

    const free_auth = try authJsonWithExplicitIds(
        gpa,
        shared_email,
        "fe43c186-7b49-4880-8744-e662b796a9d9",
        shared_chatgpt_user_id,
        "free",
    );
    defer gpa.free(free_auth);
    try tmp.dir.writeFile(.{ .sub_path = "accounts/auth.json.bak.20260317-172239", .data = free_auth });

    var report = try registry.purgeRegistryFromImportSource(gpa, codex_home, null, null);
    defer report.deinit(gpa);

    var loaded = try registry.loadRegistry(gpa, codex_home);
    defer loaded.deinit(gpa);
    try std.testing.expectEqual(@as(usize, 2), loaded.accounts.items.len);

    const team_record_key = "user-NuLAf1g5RIAwHDQxfoHfgcPo::d52355a3-bfa6-4d2b-882e-d4a2927f488c";
    const free_record_key = "user-NuLAf1g5RIAwHDQxfoHfgcPo::fe43c186-7b49-4880-8744-e662b796a9d9";

    const team_idx = registry.findAccountIndexByAccountKey(&loaded, team_record_key) orelse return error.TestExpectedEqual;
    const free_idx = registry.findAccountIndexByAccountKey(&loaded, free_record_key) orelse return error.TestExpectedEqual;

    try std.testing.expect(!std.mem.eql(u8, loaded.accounts.items[team_idx].account_key, loaded.accounts.items[free_idx].account_key));
    try std.testing.expect(std.mem.eql(u8, loaded.accounts.items[team_idx].chatgpt_user_id, shared_chatgpt_user_id));
    try std.testing.expect(std.mem.eql(u8, loaded.accounts.items[free_idx].chatgpt_user_id, shared_chatgpt_user_id));
    try std.testing.expect(std.mem.eql(u8, loaded.accounts.items[team_idx].chatgpt_account_id, "d52355a3-bfa6-4d2b-882e-d4a2927f488c"));
    try std.testing.expect(std.mem.eql(u8, loaded.accounts.items[free_idx].chatgpt_account_id, "fe43c186-7b49-4880-8744-e662b796a9d9"));
    try std.testing.expectEqual(registry.PlanType.team, loaded.accounts.items[team_idx].plan.?);
    try std.testing.expectEqual(registry.PlanType.free, loaded.accounts.items[free_idx].plan.?);
    try std.testing.expect(std.mem.eql(u8, loaded.accounts.items[team_idx].email, shared_email));
    try std.testing.expect(std.mem.eql(u8, loaded.accounts.items[free_idx].email, shared_email));
}

test "Scenario: Given purge without accounts directory when rebuilding then current auth still restores the active account" {
    const gpa = std.testing.allocator;
    var tmp = fs.tmpDir(.{});
    defer tmp.cleanup();

    const codex_home = try tmp.dir.realpathAlloc(gpa, ".");
    defer gpa.free(codex_home);

    const active_auth = try authJsonWithEmailPlan(gpa, "active@example.com", "team");
    defer gpa.free(active_auth);
    try tmp.dir.writeFile(.{ .sub_path = "auth.json", .data = active_auth });

    var report = try registry.purgeRegistryFromImportSource(gpa, codex_home, null, null);
    defer report.deinit(gpa);

    var loaded = try registry.loadRegistry(gpa, codex_home);
    defer loaded.deinit(gpa);
    try std.testing.expect(loaded.accounts.items.len == 1);
    try std.testing.expect(loaded.active_account_key != null);
    try std.testing.expect(std.mem.eql(u8, loaded.accounts.items[0].email, "active@example.com"));
}

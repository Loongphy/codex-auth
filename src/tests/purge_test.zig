const std = @import("std");
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

fn accountIdForEmailAlloc(allocator: std.mem.Allocator, email: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator, "acc:{s}", .{email});
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

    return try std.fmt.allocPrint(
        allocator,
        "{{\"tokens\":{{\"account_id\":\"{s}\",\"id_token\":\"{s}\"}}}}",
        .{ account_id, jwt },
    );
}

test "Scenario: Given legacy version key current-layout registry when loading then it rewrites to schema_version" {
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
        \\  "active_account_id": null,
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
        \\  "accounts": []
        \\}
        ,
    });

    try std.testing.expectError(error.UnsupportedRegistryVersion, registry.loadRegistry(gpa, codex_home));
}

test "Scenario: Given v2 registry when loading then it migrates to account-id layout and rewrites schema_version" {
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const codex_home = try tmp.dir.realpathAlloc(gpa, ".");
    defer gpa.free(codex_home);
    try tmp.dir.makePath("accounts");

    const email = "legacy@example.com";
    const auth_json = try authJsonWithEmailPlan(gpa, email, "team");
    defer gpa.free(auth_json);
    const legacy_name = try legacySnapshotNameForEmail(gpa, email);
    defer gpa.free(legacy_name);
    const legacy_rel = try std.fs.path.join(gpa, &[_][]const u8{ "accounts", legacy_name });
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
    try std.testing.expect(loaded.active_account_id != null);

    const account_id = try accountIdForEmailAlloc(gpa, email);
    defer gpa.free(account_id);
    try std.testing.expect(std.mem.eql(u8, loaded.accounts.items[0].account_id, account_id));
    try std.testing.expect(std.mem.eql(u8, loaded.active_account_id.?, account_id));
    try std.testing.expect(std.mem.eql(u8, loaded.accounts.items[0].alias, "legacy"));
    try std.testing.expectEqual(@as(i64, 2), loaded.accounts.items[0].last_used_at.?);
    try std.testing.expectEqual(@as(i64, 3), loaded.accounts.items[0].last_usage_at.?);
    try std.testing.expectEqual(@as(f64, 25.0), loaded.accounts.items[0].last_usage.?.primary.?.used_percent);
    try std.testing.expectEqual(registry.PlanType.team, loaded.accounts.items[0].last_usage.?.plan_type.?);

    const migrated_path = try registry.accountAuthPath(gpa, codex_home, account_id);
    defer gpa.free(migrated_path);
    var migrated = try std.fs.cwd().openFile(migrated_path, .{});
    migrated.close();
    try std.testing.expectError(error.FileNotFound, tmp.dir.openFile(legacy_rel, .{}));

    var file = try tmp.dir.openFile("accounts/registry.json", .{});
    defer file.close();
    const contents = try file.readToEndAlloc(gpa, 10 * 1024 * 1024);
    defer gpa.free(contents);
    try std.testing.expect(std.mem.indexOf(u8, contents, "\"schema_version\": 3") != null);
    try std.testing.expect(std.mem.indexOf(u8, contents, "\"active_account_id\": \"acc:legacy@example.com\"") != null);
}

test "Scenario: Given purge import with file when rebuilding then current auth is imported as active and old registry entries are discarded" {
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
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
        \\  "schema_version": 4,
        \\  "active_account_id": "acc:stale@example.com",
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
        \\      "account_id": "acc:stale@example.com",
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

    const import_path = try std.fs.path.join(gpa, &[_][]const u8{ codex_home, "imports", "personal.json" });
    defer gpa.free(import_path);

    _ = try registry.purgeRegistryFromImportSource(gpa, codex_home, import_path, "personal");

    var loaded = try registry.loadRegistry(gpa, codex_home);
    defer loaded.deinit(gpa);
    try std.testing.expect(loaded.accounts.items.len == 2);
    try std.testing.expect(loaded.auto_switch.enabled);
    try std.testing.expectEqual(@as(u8, 12), loaded.auto_switch.threshold_5h_percent);
    try std.testing.expectEqual(@as(u8, 7), loaded.auto_switch.threshold_weekly_percent);
    try std.testing.expect(loaded.api.usage);
    try std.testing.expect(loaded.active_account_activated_at_ms != null);

    const active_account_id = try accountIdForEmailAlloc(gpa, "active@example.com");
    defer gpa.free(active_account_id);
    try std.testing.expect(loaded.active_account_id != null);
    try std.testing.expect(std.mem.eql(u8, loaded.active_account_id.?, active_account_id));

    const stale_idx = registry.findAccountIndexByAccountId(&loaded, "acc:stale@example.com");
    try std.testing.expect(stale_idx == null);

    const imported_account_id = try accountIdForEmailAlloc(gpa, "personal@example.com");
    defer gpa.free(imported_account_id);
    const imported_idx = registry.findAccountIndexByAccountId(&loaded, imported_account_id) orelse return error.TestExpectedEqual;
    try std.testing.expect(std.mem.eql(u8, loaded.accounts.items[imported_idx].alias, "personal"));
    try std.testing.expect(loaded.accounts.items[imported_idx].last_usage == null);
    try std.testing.expect(loaded.accounts.items[imported_idx].last_usage_at == null);
    try std.testing.expect(loaded.accounts.items[imported_idx].last_local_rollout == null);

    const active_idx = registry.findAccountIndexByAccountId(&loaded, active_account_id) orelse return error.TestExpectedEqual;
    try std.testing.expect(loaded.accounts.items[active_idx].last_usage == null);
    try std.testing.expect(loaded.accounts.items[active_idx].last_usage_at == null);
    try std.testing.expect(loaded.accounts.items[active_idx].last_local_rollout == null);
}

test "Scenario: Given purge with newer schema registry when rebuilding then auto and api config are preserved" {
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
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

    const import_path = try std.fs.path.join(gpa, &[_][]const u8{ codex_home, "imports", "personal.json" });
    defer gpa.free(import_path);

    _ = try registry.purgeRegistryFromImportSource(gpa, codex_home, import_path, "personal");

    var loaded = try registry.loadRegistry(gpa, codex_home);
    defer loaded.deinit(gpa);
    try std.testing.expect(loaded.auto_switch.enabled);
    try std.testing.expectEqual(@as(u8, 18), loaded.auto_switch.threshold_5h_percent);
    try std.testing.expectEqual(@as(u8, 6), loaded.auto_switch.threshold_weekly_percent);
    try std.testing.expect(loaded.api.usage);
}

test "Scenario: Given purge with malformed registry when rebuilding then auto and api config are recovered best effort" {
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
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

    const import_path = try std.fs.path.join(gpa, &[_][]const u8{ codex_home, "imports", "personal.json" });
    defer gpa.free(import_path);

    _ = try registry.purgeRegistryFromImportSource(gpa, codex_home, import_path, "personal");

    var loaded = try registry.loadRegistry(gpa, codex_home);
    defer loaded.deinit(gpa);
    try std.testing.expect(loaded.auto_switch.enabled);
    try std.testing.expectEqual(@as(u8, 13), loaded.auto_switch.threshold_5h_percent);
    try std.testing.expectEqual(@as(u8, 4), loaded.auto_switch.threshold_weekly_percent);
    try std.testing.expect(loaded.api.usage);
}

test "Scenario: Given purge without path when rebuilding then it scans account snapshots and ignores registry metadata files" {
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const codex_home = try tmp.dir.realpathAlloc(gpa, ".");
    defer gpa.free(codex_home);
    try tmp.dir.makePath("accounts");

    const snapshot_auth = try authJsonWithEmailPlan(gpa, "snap@example.com", "pro");
    defer gpa.free(snapshot_auth);
    const snapshot_account_id = try accountIdForEmailAlloc(gpa, "snap@example.com");
    defer gpa.free(snapshot_account_id);
    const snapshot_path = try registry.accountAuthPath(gpa, codex_home, snapshot_account_id);
    defer gpa.free(snapshot_path);
    const snapshot_name = std.fs.path.basename(snapshot_path);
    const snapshot_rel = try std.fs.path.join(gpa, &[_][]const u8{ "accounts", snapshot_name });
    defer gpa.free(snapshot_rel);
    try tmp.dir.writeFile(.{ .sub_path = snapshot_rel, .data = snapshot_auth });
    try tmp.dir.writeFile(.{ .sub_path = "accounts/registry.json", .data = "{\"bad\":\"registry\"}" });
    try tmp.dir.writeFile(.{ .sub_path = "accounts/auth.json.bak.1", .data = "backup" });

    _ = try registry.purgeRegistryFromImportSource(gpa, codex_home, null, null);

    var loaded = try registry.loadRegistry(gpa, codex_home);
    defer loaded.deinit(gpa);
    try std.testing.expect(loaded.accounts.items.len == 1);
    try std.testing.expect(std.mem.eql(u8, loaded.accounts.items[0].email, "snap@example.com"));
}

test "Scenario: Given purge without accounts directory when rebuilding then current auth still restores the active account" {
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const codex_home = try tmp.dir.realpathAlloc(gpa, ".");
    defer gpa.free(codex_home);

    const active_auth = try authJsonWithEmailPlan(gpa, "active@example.com", "team");
    defer gpa.free(active_auth);
    try tmp.dir.writeFile(.{ .sub_path = "auth.json", .data = active_auth });

    _ = try registry.purgeRegistryFromImportSource(gpa, codex_home, null, null);

    var loaded = try registry.loadRegistry(gpa, codex_home);
    defer loaded.deinit(gpa);
    try std.testing.expect(loaded.accounts.items.len == 1);
    try std.testing.expect(loaded.active_account_id != null);
    try std.testing.expect(std.mem.eql(u8, loaded.accounts.items[0].email, "active@example.com"));
}

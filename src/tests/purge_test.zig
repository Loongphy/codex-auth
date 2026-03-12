const std = @import("std");
const registry = @import("../registry.zig");

fn b64url(allocator: std.mem.Allocator, input: []const u8) ![]u8 {
    const encoder = std.base64.url_safe_no_pad.Encoder;
    const out_len = encoder.calcSize(input.len);
    const buf = try allocator.alloc(u8, out_len);
    _ = encoder.encode(buf, input);
    return buf;
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

test "Scenario: Given current-layout registry versions when loading then version mismatches are accepted and save rewrites current version" {
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
        \\  "version": 999,
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

    try registry.saveRegistry(gpa, codex_home, &loaded);

    var file = try tmp.dir.openFile("accounts/registry.json", .{});
    defer file.close();
    const contents = try file.readToEndAlloc(gpa, 10 * 1024 * 1024);
    defer gpa.free(contents);
    try std.testing.expect(std.mem.indexOf(u8, contents, "\"version\": 3") != null);
}

test "Scenario: Given legacy active_email registry when loading then current layout rejects it" {
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
        \\  "version": 2,
        \\  "active_email": "legacy@example.com",
        \\  "accounts": []
        \\}
        ,
    });

    try std.testing.expectError(error.UnsupportedRegistryLayout, registry.loadRegistry(gpa, codex_home));
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
        \\  "version": 3,
        \\  "active_account_id": "acc:stale@example.com",
        \\  "auto_switch": {
        \\    "enabled": true
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
        \\      "last_usage_at": null
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

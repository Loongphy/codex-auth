const std = @import("std");
const migration = @import("../migration.zig");
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

    return std.fmt.allocPrint(allocator, "{{\"tokens\":{{\"account_id\":\"{s}\",\"id_token\":\"{s}\"}}}}", .{ account_id, jwt });
}

test "Scenario: Given v2 registry when ensuring migrated then account snapshots and v3 registry are written" {
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const codex_home = try tmp.dir.realpathAlloc(gpa, ".");
    defer gpa.free(codex_home);
    try tmp.dir.makePath("accounts");

    const a_email = "alpha@example.com";
    const b_email = "beta@example.com";
    const a_auth = try authJsonWithEmailPlan(gpa, a_email, "team");
    defer gpa.free(a_auth);
    const b_auth = try authJsonWithEmailPlan(gpa, b_email, "plus");
    defer gpa.free(b_auth);

    const a_key = try b64url(gpa, a_email);
    defer gpa.free(a_key);
    const b_key = try b64url(gpa, b_email);
    defer gpa.free(b_key);
    const a_legacy_path = try std.fmt.allocPrint(gpa, "accounts/{s}.auth.json", .{a_key});
    defer gpa.free(a_legacy_path);
    const b_legacy_path = try std.fmt.allocPrint(gpa, "accounts/{s}.auth.json", .{b_key});
    defer gpa.free(b_legacy_path);

    try tmp.dir.writeFile(.{ .sub_path = a_legacy_path, .data = a_auth });
    try tmp.dir.writeFile(.{ .sub_path = b_legacy_path, .data = b_auth });

    const registry_json =
        \\{
        \\  "version": 2,
        \\  "active_email": "alpha@example.com",
        \\  "accounts": [
        \\    {
        \\      "email": "alpha@example.com",
        \\      "alias": "",
        \\      "plan": "team",
        \\      "auth_mode": "chatgpt",
        \\      "created_at": 1,
        \\      "last_used_at": 2,
        \\      "last_usage_at": 3
        \\    },
        \\    {
        \\      "email": "beta@example.com",
        \\      "alias": "personal",
        \\      "plan": "plus",
        \\      "auth_mode": "chatgpt",
        \\      "created_at": 4,
        \\      "last_used_at": null,
        \\      "last_usage_at": null
        \\    }
        \\  ]
        \\}
    ;
    try tmp.dir.writeFile(.{ .sub_path = "accounts/registry.json", .data = registry_json });

    var output = std.Io.Writer.Allocating.init(gpa);
    defer output.deinit();
    const result = try migration.ensureMigratedWithWriter(gpa, codex_home, .automatic, &output.writer);
    try std.testing.expect(result.migrated);
    try std.testing.expect(result.current_version == 3);

    const migration_output = output.written();
    try std.testing.expect(std.mem.indexOf(u8, migration_output, "正在迁移到新版本：v2 -> v3") != null);
    try std.testing.expect(std.mem.indexOf(u8, migration_output, "迁移 v2 -> v3 中……") != null);
    try std.testing.expect(std.mem.indexOf(u8, migration_output, "迁移完成，当前版本：v3") != null);

    const a_account_id = try accountIdForEmailAlloc(gpa, a_email);
    defer gpa.free(a_account_id);
    const b_account_id = try accountIdForEmailAlloc(gpa, b_email);
    defer gpa.free(b_account_id);

    const a_new = try registry.accountAuthPath(gpa, codex_home, a_account_id);
    defer gpa.free(a_new);
    const b_new = try registry.accountAuthPath(gpa, codex_home, b_account_id);
    defer gpa.free(b_new);
    var a_file = try std.fs.cwd().openFile(a_new, .{});
    a_file.close();
    var b_file = try std.fs.cwd().openFile(b_new, .{});
    b_file.close();

    const a_old_name = try std.fmt.allocPrint(gpa, "{s}.auth.json", .{a_key});
    defer gpa.free(a_old_name);
    const a_old_abs = try std.fs.path.join(gpa, &[_][]const u8{ codex_home, "accounts", a_old_name });
    defer gpa.free(a_old_abs);
    try std.testing.expectError(error.FileNotFound, std.fs.cwd().openFile(a_old_abs, .{}));

    var loaded = try registry.loadRegistry(gpa, codex_home);
    defer loaded.deinit(gpa);
    try std.testing.expect(loaded.version == 3);
    try std.testing.expect(loaded.active_account_id != null);
    try std.testing.expect(std.mem.eql(u8, loaded.active_account_id.?, a_account_id));
    try std.testing.expect(loaded.accounts.items.len == 2);

    var backups = try tmp.dir.openDir("accounts/backups/v2", .{ .iterate = true });
    defer backups.close();
    var backup_count: usize = 0;
    var it = backups.iterate();
    while (try it.next()) |_| {
        backup_count += 1;
    }
    try std.testing.expect(backup_count == 1);
}

test "Scenario: Given unsafe account_id when resolving snapshot path then filename is encoded safely" {
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const codex_home = try tmp.dir.realpathAlloc(gpa, ".");
    defer gpa.free(codex_home);

    const account_id = "../../pwned";
    const expected_key = try b64url(gpa, account_id);
    defer gpa.free(expected_key);

    const path = try registry.accountAuthPath(gpa, codex_home, account_id);
    defer gpa.free(path);

    const expected_suffix = try std.fmt.allocPrint(gpa, "accounts/{s}.auth.json", .{expected_key});
    defer gpa.free(expected_suffix);
    try std.testing.expect(std.mem.endsWith(u8, path, expected_suffix));
    try std.testing.expect(std.mem.indexOf(u8, path, "../../pwned.auth.json") == null);
}

test "Scenario: Given mixed v2 snapshots when one is malformed then valid accounts still migrate" {
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const codex_home = try tmp.dir.realpathAlloc(gpa, ".");
    defer gpa.free(codex_home);
    try tmp.dir.makePath("accounts");

    const good_email = "alpha@example.com";
    const bad_email = "broken@example.com";
    const good_auth = try authJsonWithEmailPlan(gpa, good_email, "team");
    defer gpa.free(good_auth);
    const bad_auth = "{\"tokens\":{\"id_token\":\"broken\"}}";

    const good_key = try b64url(gpa, good_email);
    defer gpa.free(good_key);
    const bad_key = try b64url(gpa, bad_email);
    defer gpa.free(bad_key);

    const good_legacy_path = try std.fmt.allocPrint(gpa, "accounts/{s}.auth.json", .{good_key});
    defer gpa.free(good_legacy_path);
    const bad_legacy_path = try std.fmt.allocPrint(gpa, "accounts/{s}.auth.json", .{bad_key});
    defer gpa.free(bad_legacy_path);
    try tmp.dir.writeFile(.{ .sub_path = good_legacy_path, .data = good_auth });
    try tmp.dir.writeFile(.{ .sub_path = bad_legacy_path, .data = bad_auth });

    const registry_json =
        \\{
        \\  "version": 2,
        \\  "active_email": "alpha@example.com",
        \\  "accounts": [
        \\    {
        \\      "email": "alpha@example.com",
        \\      "alias": "",
        \\      "plan": "team",
        \\      "auth_mode": "chatgpt",
        \\      "created_at": 1,
        \\      "last_used_at": 2,
        \\      "last_usage_at": 3
        \\    },
        \\    {
        \\      "email": "broken@example.com",
        \\      "alias": "",
        \\      "plan": "plus",
        \\      "auth_mode": "chatgpt",
        \\      "created_at": 4,
        \\      "last_used_at": null,
        \\      "last_usage_at": null
        \\    }
        \\  ]
        \\}
    ;
    try tmp.dir.writeFile(.{ .sub_path = "accounts/registry.json", .data = registry_json });

    var output = std.Io.Writer.Allocating.init(gpa);
    defer output.deinit();
    const result = try migration.ensureMigratedWithWriter(gpa, codex_home, .automatic, &output.writer);
    try std.testing.expect(result.migrated);
    try std.testing.expect(std.mem.indexOf(u8, output.written(), "跳过损坏的旧账号 broken@example.com") != null);

    var loaded = try registry.loadRegistry(gpa, codex_home);
    defer loaded.deinit(gpa);
    try std.testing.expect(loaded.accounts.items.len == 1);
    try std.testing.expect(loaded.active_account_id != null);

    const good_account_id = try accountIdForEmailAlloc(gpa, good_email);
    defer gpa.free(good_account_id);
    try std.testing.expect(std.mem.eql(u8, loaded.active_account_id.?, good_account_id));
}

test "Scenario: Given current accounts when migrating from v2 then backup excludes nested historical backups" {
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const codex_home = try tmp.dir.realpathAlloc(gpa, ".");
    defer gpa.free(codex_home);
    try tmp.dir.makePath("accounts");
    try tmp.dir.makePath("accounts/backups/v2/existing");
    try tmp.dir.writeFile(.{ .sub_path = "accounts/backups/v2/existing/old.txt", .data = "keep-old-backup-outside" });

    const email = "user@example.com";
    const auth_json = try authJsonWithEmailPlan(gpa, email, "plus");
    defer gpa.free(auth_json);
    const email_key = try b64url(gpa, email);
    defer gpa.free(email_key);
    const legacy_auth_path = try std.fmt.allocPrint(gpa, "accounts/{s}.auth.json", .{email_key});
    defer gpa.free(legacy_auth_path);
    try tmp.dir.writeFile(.{ .sub_path = legacy_auth_path, .data = auth_json });
    try tmp.dir.writeFile(.{ .sub_path = "accounts/registry.json", .data =
        \\{
        \\  "version": 2,
        \\  "active_email": "user@example.com",
        \\  "accounts": [
        \\    {
        \\      "email": "user@example.com",
        \\      "alias": "",
        \\      "plan": "plus",
        \\      "auth_mode": "chatgpt",
        \\      "created_at": 1,
        \\      "last_used_at": null,
        \\      "last_usage_at": null
        \\    }
        \\  ]
        \\}
    });

    var output = std.Io.Writer.Allocating.init(gpa);
    defer output.deinit();
    _ = try migration.ensureMigratedWithWriter(gpa, codex_home, .automatic, &output.writer);

    var migrated_backup_root = try tmp.dir.openDir("accounts/backups/v2", .{ .iterate = true });
    defer migrated_backup_root.close();
    var it = migrated_backup_root.iterate();
    const entry = (try it.next()) orelse return error.TestExpectedEqual;
    const nested_backup = try std.fs.path.join(gpa, &[_][]const u8{
        codex_home,
        "accounts",
        "backups",
        "v2",
        entry.name,
        "backups",
        "v2",
        "existing",
        "old.txt",
    });
    defer gpa.free(nested_backup);
    try std.testing.expectError(error.FileNotFound, std.fs.cwd().openFile(nested_backup, .{}));
}

test "Scenario: Given latest registry when explicit migrate runs then it reports already latest" {
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const codex_home = try tmp.dir.realpathAlloc(gpa, ".");
    defer gpa.free(codex_home);

    var reg = registry.Registry{
        .version = 3,
        .active_account_id = null,
        .auto_switch = registry.defaultAutoSwitchConfig(),
        .accounts = std.ArrayList(registry.AccountRecord).empty,
    };
    defer reg.deinit(gpa);
    try registry.saveRegistry(gpa, codex_home, &reg);

    var output = std.Io.Writer.Allocating.init(gpa);
    defer output.deinit();
    const result = try migration.ensureMigratedWithWriter(gpa, codex_home, .explicit, &output.writer);
    try std.testing.expect(!result.migrated);
    try std.testing.expect(std.mem.indexOf(u8, output.written(), "当前已是最新版本：v3") != null);
}

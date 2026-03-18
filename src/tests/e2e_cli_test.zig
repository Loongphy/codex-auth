const std = @import("std");
const builtin = @import("builtin");
const registry = @import("../registry.zig");
const bdd = @import("bdd_helpers.zig");

fn projectRootAlloc(allocator: std.mem.Allocator) ![]u8 {
    return std.fs.cwd().realpathAlloc(allocator, ".");
}

fn buildCliBinary(allocator: std.mem.Allocator, project_root: []const u8) !void {
    const global_cache_dir = try std.fs.path.join(allocator, &[_][]const u8{
        project_root,
        ".zig-cache",
        "e2e-global",
    });
    defer allocator.free(global_cache_dir);

    const local_cache_dir = try std.fs.path.join(allocator, &[_][]const u8{
        project_root,
        ".zig-cache",
        "e2e-local",
    });
    defer allocator.free(local_cache_dir);

    var env_map = try std.process.getEnvMap(allocator);
    defer env_map.deinit();
    try env_map.put("ZIG_GLOBAL_CACHE_DIR", global_cache_dir);
    try env_map.put("ZIG_LOCAL_CACHE_DIR", local_cache_dir);

    const result = try std.process.Child.run(.{
        .allocator = allocator,
        .argv = &[_][]const u8{ "zig", "build" },
        .cwd = project_root,
        .env_map = &env_map,
        .max_output_bytes = 1024 * 1024,
    });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    switch (result.term) {
        .Exited => |code| if (code == 0) return,
        else => {},
    }

    std.log.err("zig build stdout:\n{s}", .{result.stdout});
    std.log.err("zig build stderr:\n{s}", .{result.stderr});
    return error.CommandFailed;
}

fn builtCliPathAlloc(allocator: std.mem.Allocator, project_root: []const u8) ![]u8 {
    const exe_name = if (builtin.os.tag == .windows) "codex-auth.exe" else "codex-auth";
    return std.fs.path.join(allocator, &[_][]const u8{ project_root, "zig-out", "bin", exe_name });
}

fn runCliWithIsolatedHome(
    allocator: std.mem.Allocator,
    project_root: []const u8,
    home_root: []const u8,
    args: []const []const u8,
) !std.process.Child.RunResult {
    const exe_path = try builtCliPathAlloc(allocator, project_root);
    defer allocator.free(exe_path);

    var argv = std.ArrayList([]const u8).empty;
    defer argv.deinit(allocator);
    try argv.append(allocator, exe_path);
    try argv.appendSlice(allocator, args);

    var env_map = try std.process.getEnvMap(allocator);
    defer env_map.deinit();
    try env_map.put("HOME", home_root);
    try env_map.put("USERPROFILE", home_root);
    try env_map.put("CODEX_AUTH_SKIP_SERVICE_RECONCILE", "1");

    return try std.process.Child.run(.{
        .allocator = allocator,
        .argv = argv.items,
        .cwd = project_root,
        .env_map = &env_map,
        .max_output_bytes = 1024 * 1024,
    });
}

fn expectSuccess(result: std.process.Child.RunResult) !void {
    switch (result.term) {
        .Exited => |code| try std.testing.expectEqual(@as(u8, 0), code),
        else => return error.TestUnexpectedResult,
    }
}

fn expectUsageApiWarningOnStderrOnly(result: std.process.Child.RunResult) !void {
    try std.testing.expect(std.mem.indexOf(u8, result.stderr, "Warning: Usage refresh is currently using the ChatGPT usage API") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.stderr, "`codex-auth config api disable`") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.stdout, "Warning: Usage refresh is currently using the ChatGPT usage API") == null);
    try std.testing.expect(std.mem.indexOf(u8, result.stdout, "`codex-auth config api disable`") == null);
}

fn authJsonPathAlloc(allocator: std.mem.Allocator, home_root: []const u8) ![]u8 {
    return std.fs.path.join(allocator, &[_][]const u8{ home_root, ".codex", "auth.json" });
}

fn codexHomeAlloc(allocator: std.mem.Allocator, home_root: []const u8) ![]u8 {
    return std.fs.path.join(allocator, &[_][]const u8{ home_root, ".codex" });
}

fn legacySnapshotNameForEmail(allocator: std.mem.Allocator, email: []const u8) ![]u8 {
    const encoded = try bdd.b64url(allocator, email);
    defer allocator.free(encoded);
    return try std.fmt.allocPrint(allocator, "{s}.auth.json", .{encoded});
}

// This simulates first-time use on v0.2 when ~/.codex/auth.json already exists
// but ~/.codex/accounts has not been created yet.
test "Scenario: Given first-time use on v0.2 with an existing auth.json and no accounts directory when list runs then cli auto-imports and stays usable" {
    const gpa = std.testing.allocator;
    const project_root = try projectRootAlloc(gpa);
    defer gpa.free(project_root);
    try buildCliBinary(gpa, project_root);

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const home_root = try tmp.dir.realpathAlloc(gpa, ".");
    defer gpa.free(home_root);
    try tmp.dir.makePath(".codex");

    const email = "fresh@example.com";
    const auth_json = try bdd.authJsonWithEmailPlan(gpa, email, "plus");
    defer gpa.free(auth_json);
    try tmp.dir.writeFile(.{ .sub_path = ".codex/auth.json", .data = auth_json });

    const result = try runCliWithIsolatedHome(gpa, project_root, home_root, &[_][]const u8{"list"});
    defer gpa.free(result.stdout);
    defer gpa.free(result.stderr);

    try expectSuccess(result);
    try std.testing.expect(std.mem.indexOf(u8, result.stdout, email) != null);

    const codex_home = try codexHomeAlloc(gpa, home_root);
    defer gpa.free(codex_home);
    var loaded = try registry.loadRegistry(gpa, codex_home);
    defer loaded.deinit(gpa);
    try std.testing.expectEqual(@as(usize, 1), loaded.accounts.items.len);
    try std.testing.expect(loaded.active_account_key != null);
    try std.testing.expect(std.mem.eql(u8, loaded.accounts.items[0].email, email));

    const expected_account_id = try bdd.accountKeyForEmailAlloc(gpa, email);
    defer gpa.free(expected_account_id);
    try std.testing.expect(std.mem.eql(u8, loaded.active_account_key.?, expected_account_id));

    const snapshot_path = try registry.accountAuthPath(gpa, codex_home, expected_account_id);
    defer gpa.free(snapshot_path);
    const snapshot_data = try bdd.readFileAlloc(gpa, snapshot_path);
    defer gpa.free(snapshot_data);

    const auth_path = try authJsonPathAlloc(gpa, home_root);
    defer gpa.free(auth_path);
    const active_data = try bdd.readFileAlloc(gpa, auth_path);
    defer gpa.free(active_data);
    try std.testing.expect(std.mem.eql(u8, snapshot_data, active_data));
}

// This simulates a real v0.1.x -> v0.2 upgrade:
// the old email-keyed registry and snapshot exist under ~/.codex/accounts before the new binary runs.
test "Scenario: Given upgrade from v0.1.x to v0.2 with legacy accounts data when list runs then cli migrates registry and keeps account usable" {
    const gpa = std.testing.allocator;
    const project_root = try projectRootAlloc(gpa);
    defer gpa.free(project_root);
    try buildCliBinary(gpa, project_root);

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const home_root = try tmp.dir.realpathAlloc(gpa, ".");
    defer gpa.free(home_root);
    try tmp.dir.makePath(".codex/accounts");

    const email = "legacy@example.com";
    const auth_json = try bdd.authJsonWithEmailPlan(gpa, email, "team");
    defer gpa.free(auth_json);

    try tmp.dir.writeFile(.{ .sub_path = ".codex/auth.json", .data = auth_json });

    const legacy_name = try legacySnapshotNameForEmail(gpa, email);
    defer gpa.free(legacy_name);
    const legacy_rel = try std.fs.path.join(gpa, &[_][]const u8{ ".codex", "accounts", legacy_name });
    defer gpa.free(legacy_rel);
    try tmp.dir.writeFile(.{ .sub_path = legacy_rel, .data = auth_json });

    try tmp.dir.writeFile(.{
        .sub_path = ".codex/accounts/registry.json",
        .data =
        \\{
        \\  "version": 2,
        \\  "active_email": "legacy@example.com",
        \\  "accounts": [
        \\    {
        \\      "email": "legacy@example.com",
        \\      "alias": "legacy",
        \\      "plan": "team",
        \\      "auth_mode": "chatgpt",
        \\      "created_at": 1,
        \\      "last_used_at": 2,
        \\      "last_usage_at": 3
        \\    }
        \\  ]
        \\}
        ,
    });

    const result = try runCliWithIsolatedHome(gpa, project_root, home_root, &[_][]const u8{"list"});
    defer gpa.free(result.stdout);
    defer gpa.free(result.stderr);

    try expectSuccess(result);
    try std.testing.expect(std.mem.indexOf(u8, result.stdout, email) != null);

    const codex_home = try codexHomeAlloc(gpa, home_root);
    defer gpa.free(codex_home);
    var loaded = try registry.loadRegistry(gpa, codex_home);
    defer loaded.deinit(gpa);
    try std.testing.expectEqual(@as(u32, registry.current_schema_version), loaded.schema_version);
    try std.testing.expectEqual(@as(usize, 1), loaded.accounts.items.len);
    try std.testing.expect(loaded.active_account_key != null);

    const expected_account_id = try bdd.accountKeyForEmailAlloc(gpa, email);
    defer gpa.free(expected_account_id);
    try std.testing.expect(std.mem.eql(u8, loaded.active_account_key.?, expected_account_id));
    try std.testing.expect(std.mem.eql(u8, loaded.accounts.items[0].account_key, expected_account_id));

    const migrated_path = try registry.accountAuthPath(gpa, codex_home, expected_account_id);
    defer gpa.free(migrated_path);
    var migrated = try std.fs.cwd().openFile(migrated_path, .{});
    migrated.close();
    try std.testing.expectError(error.FileNotFound, tmp.dir.openFile(legacy_rel, .{}));
}

test "Scenario: Given default api usage when rendering help then warning stays on stderr" {
    const gpa = std.testing.allocator;
    const project_root = try projectRootAlloc(gpa);
    defer gpa.free(project_root);
    try buildCliBinary(gpa, project_root);

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const home_root = try tmp.dir.realpathAlloc(gpa, ".");
    defer gpa.free(home_root);

    const result = try runCliWithIsolatedHome(gpa, project_root, home_root, &[_][]const u8{});
    defer gpa.free(result.stdout);
    defer gpa.free(result.stderr);

    try expectSuccess(result);
    try std.testing.expect(std.mem.indexOf(u8, result.stdout, "codex-auth") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.stdout, "Usage API: ON (api-only)") != null);
    try expectUsageApiWarningOnStderrOnly(result);
}

test "Scenario: Given default api usage when rendering status then warning stays on stderr" {
    const gpa = std.testing.allocator;
    const project_root = try projectRootAlloc(gpa);
    defer gpa.free(project_root);
    try buildCliBinary(gpa, project_root);

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const home_root = try tmp.dir.realpathAlloc(gpa, ".");
    defer gpa.free(home_root);

    const result = try runCliWithIsolatedHome(gpa, project_root, home_root, &[_][]const u8{"status"});
    defer gpa.free(result.stdout);
    defer gpa.free(result.stderr);

    try expectSuccess(result);
    try std.testing.expect(std.mem.indexOf(u8, result.stdout, "auto-switch: OFF") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.stdout, "usage: api") != null);
    try expectUsageApiWarningOnStderrOnly(result);
}

test "Scenario: Given default api usage when listing accounts then warning stays on stderr" {
    const gpa = std.testing.allocator;
    const project_root = try projectRootAlloc(gpa);
    defer gpa.free(project_root);
    try buildCliBinary(gpa, project_root);

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const home_root = try tmp.dir.realpathAlloc(gpa, ".");
    defer gpa.free(home_root);

    const result = try runCliWithIsolatedHome(gpa, project_root, home_root, &[_][]const u8{"list"});
    defer gpa.free(result.stdout);
    defer gpa.free(result.stderr);

    try expectSuccess(result);
    try std.testing.expect(std.mem.indexOf(u8, result.stdout, "ACCOUNT") != null);
    try expectUsageApiWarningOnStderrOnly(result);
}

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

fn expectFailure(result: std.process.Child.RunResult) !void {
    switch (result.term) {
        .Exited => |code| try std.testing.expect(code != 0),
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

test "Scenario: Given repeated single-file import when running import then first import reports imported and second reports updated" {
    const gpa = std.testing.allocator;
    const project_root = try projectRootAlloc(gpa);
    defer gpa.free(project_root);
    try buildCliBinary(gpa, project_root);

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const home_root = try tmp.dir.realpathAlloc(gpa, ".");
    defer gpa.free(home_root);
    try tmp.dir.makePath("imports");

    const rel_path = "imports/token_ryan.taylor.alpha@email.com.json";
    const auth_json = try bdd.authJsonWithEmailPlan(gpa, "ryan.taylor.alpha@email.com", "plus");
    defer gpa.free(auth_json);
    try tmp.dir.writeFile(.{ .sub_path = rel_path, .data = auth_json });

    const import_path = try std.fs.path.join(gpa, &[_][]const u8{ home_root, rel_path });
    defer gpa.free(import_path);

    const first = try runCliWithIsolatedHome(gpa, project_root, home_root, &[_][]const u8{ "import", import_path });
    defer gpa.free(first.stdout);
    defer gpa.free(first.stderr);
    try expectSuccess(first);
    try std.testing.expectEqualStrings("  ✓ imported  token_ryan.taylor.alpha@email.com\n", first.stdout);
    try std.testing.expectEqualStrings("", first.stderr);

    const second = try runCliWithIsolatedHome(gpa, project_root, home_root, &[_][]const u8{ "import", import_path });
    defer gpa.free(second.stdout);
    defer gpa.free(second.stderr);
    try expectSuccess(second);
    try std.testing.expectEqualStrings("  ✓ updated   token_ryan.taylor.alpha@email.com\n", second.stdout);
    try std.testing.expectEqualStrings("", second.stderr);
}

test "Scenario: Given single-file import missing email when running import then it exits non-zero after reporting the skipped file" {
    const gpa = std.testing.allocator;
    const project_root = try projectRootAlloc(gpa);
    defer gpa.free(project_root);
    try buildCliBinary(gpa, project_root);

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const home_root = try tmp.dir.realpathAlloc(gpa, ".");
    defer gpa.free(home_root);
    try tmp.dir.makePath("imports");

    const rel_path = "imports/token_bob.wilson.alpha@email.com.json";
    const auth_json = try bdd.authJsonWithoutEmail(gpa);
    defer gpa.free(auth_json);
    try tmp.dir.writeFile(.{ .sub_path = rel_path, .data = auth_json });

    const import_path = try std.fs.path.join(gpa, &[_][]const u8{ home_root, rel_path });
    defer gpa.free(import_path);

    const result = try runCliWithIsolatedHome(gpa, project_root, home_root, &[_][]const u8{ "import", import_path });
    defer gpa.free(result.stdout);
    defer gpa.free(result.stderr);

    try expectFailure(result);
    try std.testing.expectEqualStrings("Import Summary: 0 imported, 1 skipped\n", result.stdout);
    try std.testing.expect(std.mem.indexOf(u8, result.stderr, "  ✗ skipped   token_bob.wilson.alpha@email.com: MissingEmail\n") != null);
}

test "Scenario: Given directory import with new updated and invalid files when running import then stdout and stderr split the report" {
    const gpa = std.testing.allocator;
    const project_root = try projectRootAlloc(gpa);
    defer gpa.free(project_root);
    try buildCliBinary(gpa, project_root);

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const home_root = try tmp.dir.realpathAlloc(gpa, ".");
    defer gpa.free(home_root);
    try tmp.dir.makePath("imports");

    const existing_rel = "imports/token_jane.smith.alpha@email.com.json";
    const existing_auth = try bdd.authJsonWithEmailPlan(gpa, "jane.smith.alpha@email.com", "team");
    defer gpa.free(existing_auth);
    try tmp.dir.writeFile(.{ .sub_path = existing_rel, .data = existing_auth });

    const existing_path = try std.fs.path.join(gpa, &[_][]const u8{ home_root, existing_rel });
    defer gpa.free(existing_path);

    const seed_result = try runCliWithIsolatedHome(gpa, project_root, home_root, &[_][]const u8{ "import", existing_path });
    defer gpa.free(seed_result.stdout);
    defer gpa.free(seed_result.stderr);
    try expectSuccess(seed_result);

    const ryan_auth = try bdd.authJsonWithEmailPlan(gpa, "ryan.taylor.alpha@email.com", "plus");
    defer gpa.free(ryan_auth);
    try tmp.dir.writeFile(.{ .sub_path = "imports/token_ryan.taylor.alpha@email.com.json", .data = ryan_auth });

    const john_auth = try bdd.authJsonWithEmailPlan(gpa, "john.doe.alpha@email.com", "pro");
    defer gpa.free(john_auth);
    try tmp.dir.writeFile(.{ .sub_path = "imports/token_john.doe.alpha@email.com.json", .data = john_auth });

    const extra_auth = try bdd.authJsonWithEmailPlan(gpa, "mike.roe.alpha@email.com", "business");
    defer gpa.free(extra_auth);
    try tmp.dir.writeFile(.{ .sub_path = "imports/token_mike.roe.alpha@email.com.json", .data = extra_auth });

    const missing_email = try bdd.authJsonWithoutEmail(gpa);
    defer gpa.free(missing_email);
    try tmp.dir.writeFile(.{ .sub_path = "imports/token_bob.wilson.alpha@email.com.json", .data = missing_email });

    const missing_user_id =
        "{\"tokens\":{\"access_token\":\"access-missing-user\",\"account_id\":\"67000000-0000-4000-8000-000000000001\",\"id_token\":\"eyJhbGciOiJub25lIiwidHlwIjoiSldUIn0.eyJlbWFpbCI6ImFsaWNlLmJyb3duLmFscGhhQGVtYWlsLmNvbSIsImh0dHBzOi8vYXBpLm9wZW5haS5jb20vYXV0aCI6eyJjaGF0Z3B0X2FjY291bnRfaWQiOiI2NzAwMDAwMC0wMDAwLTQwMDAtODAwMC0wMDAwMDAwMDAwMDEiLCJjaGF0Z3B0X3BsYW5fdHlwZSI6InBybyJ9fQ.sig\"}}";
    try tmp.dir.writeFile(.{ .sub_path = "imports/token_alice.brown.alpha@email.com.json", .data = missing_user_id });

    try tmp.dir.writeFile(.{ .sub_path = "imports/token_invalid.json", .data = "{not-json}" });

    const imports_path = try std.fs.path.join(gpa, &[_][]const u8{ home_root, "imports" });
    defer gpa.free(imports_path);

    const result = try runCliWithIsolatedHome(gpa, project_root, home_root, &[_][]const u8{ "import", imports_path });
    defer gpa.free(result.stdout);
    defer gpa.free(result.stderr);

    try expectSuccess(result);
    const expected_stdout = try std.fmt.allocPrint(
        gpa,
        "Scanning {s}...\n" ++
            "  ✓ updated   token_jane.smith.alpha@email.com\n" ++
            "  ✓ imported  token_john.doe.alpha@email.com\n" ++
            "  ✓ imported  token_mike.roe.alpha@email.com\n" ++
            "  ✓ imported  token_ryan.taylor.alpha@email.com\n" ++
            "Import Summary: 3 imported, 1 updated, 3 skipped (total 7 files)\n",
        .{imports_path},
    );
    defer gpa.free(expected_stdout);
    try std.testing.expectEqualStrings(expected_stdout, result.stdout);
    try std.testing.expectEqualStrings(
        "  ✗ skipped   token_alice.brown.alpha@email.com: MissingChatgptUserId\n" ++
            "  ✗ skipped   token_bob.wilson.alpha@email.com: MissingEmail\n" ++
            "  ✗ skipped   token_invalid: MalformedJson\n",
        result.stderr,
    );
}

test "Scenario: Given directory import with an empty json file when running import then it is skipped as malformed and valid imports still persist" {
    const gpa = std.testing.allocator;
    const project_root = try projectRootAlloc(gpa);
    defer gpa.free(project_root);
    try buildCliBinary(gpa, project_root);

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const home_root = try tmp.dir.realpathAlloc(gpa, ".");
    defer gpa.free(home_root);
    try tmp.dir.makePath("imports");

    const valid_auth = try bdd.authJsonWithEmailPlan(gpa, "still-imported@example.com", "plus");
    defer gpa.free(valid_auth);
    try tmp.dir.writeFile(.{ .sub_path = "imports/valid.json", .data = valid_auth });
    try tmp.dir.writeFile(.{ .sub_path = "imports/empty.json", .data = "" });

    const imports_path = try std.fs.path.join(gpa, &[_][]const u8{ home_root, "imports" });
    defer gpa.free(imports_path);

    const result = try runCliWithIsolatedHome(gpa, project_root, home_root, &[_][]const u8{ "import", imports_path });
    defer gpa.free(result.stdout);
    defer gpa.free(result.stderr);

    try expectSuccess(result);
    const expected_stdout = try std.fmt.allocPrint(
        gpa,
        "Scanning {s}...\n" ++
            "  ✓ imported  valid\n" ++
            "Import Summary: 1 imported, 0 updated, 1 skipped (total 2 files)\n",
        .{imports_path},
    );
    defer gpa.free(expected_stdout);
    try std.testing.expectEqualStrings(expected_stdout, result.stdout);
    try std.testing.expectEqualStrings("  ✗ skipped   empty: MalformedJson\n", result.stderr);

    const codex_home = try codexHomeAlloc(gpa, home_root);
    defer gpa.free(codex_home);
    var loaded = try registry.loadRegistry(gpa, codex_home);
    defer loaded.deinit(gpa);
    try std.testing.expectEqual(@as(usize, 1), loaded.accounts.items.len);
    try std.testing.expect(std.mem.eql(u8, loaded.accounts.items[0].email, "still-imported@example.com"));
}

test "Scenario: Given directory import with a broken symlink when running import then it skips that entry and still imports valid files" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;

    const gpa = std.testing.allocator;
    const project_root = try projectRootAlloc(gpa);
    defer gpa.free(project_root);
    try buildCliBinary(gpa, project_root);

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const home_root = try tmp.dir.realpathAlloc(gpa, ".");
    defer gpa.free(home_root);
    try tmp.dir.makePath("imports");

    const valid_auth = try bdd.authJsonWithEmailPlan(gpa, "symlink-survivor@example.com", "plus");
    defer gpa.free(valid_auth);
    try tmp.dir.writeFile(.{ .sub_path = "imports/valid.json", .data = valid_auth });
    try tmp.dir.symLink("missing.json", "imports/broken.json", .{});

    const imports_path = try std.fs.path.join(gpa, &[_][]const u8{ home_root, "imports" });
    defer gpa.free(imports_path);

    const result = try runCliWithIsolatedHome(gpa, project_root, home_root, &[_][]const u8{ "import", imports_path });
    defer gpa.free(result.stdout);
    defer gpa.free(result.stderr);

    try expectSuccess(result);
    const expected_stdout = try std.fmt.allocPrint(
        gpa,
        "Scanning {s}...\n" ++
            "  ✓ imported  valid\n" ++
            "Import Summary: 1 imported, 0 updated, 1 skipped (total 2 files)\n",
        .{imports_path},
    );
    defer gpa.free(expected_stdout);
    try std.testing.expectEqualStrings(expected_stdout, result.stdout);
    try std.testing.expectEqualStrings("  ✗ skipped   broken: FileNotFound\n", result.stderr);

    const codex_home = try codexHomeAlloc(gpa, home_root);
    defer gpa.free(codex_home);
    var loaded = try registry.loadRegistry(gpa, codex_home);
    defer loaded.deinit(gpa);
    try std.testing.expectEqual(@as(usize, 1), loaded.accounts.items.len);
    try std.testing.expect(std.mem.eql(u8, loaded.accounts.items[0].email, "symlink-survivor@example.com"));
}

test "Scenario: Given cpa directory in default location when running import cpa then it imports from ~/.cli-proxy-api" {
    const gpa = std.testing.allocator;
    const project_root = try projectRootAlloc(gpa);
    defer gpa.free(project_root);
    try buildCliBinary(gpa, project_root);

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const home_root = try tmp.dir.realpathAlloc(gpa, ".");
    defer gpa.free(home_root);
    try tmp.dir.makePath(".cli-proxy-api");

    const first = try bdd.cpaJsonWithEmailPlan(gpa, "default-cpa@example.com", "plus");
    defer gpa.free(first);
    const second = try bdd.cpaJsonWithEmailPlan(gpa, "second-cpa@example.com", "team");
    defer gpa.free(second);
    const missing_refresh = try bdd.cpaJsonWithoutRefreshToken(gpa, "skip-cpa@example.com", "pro");
    defer gpa.free(missing_refresh);
    try tmp.dir.writeFile(.{ .sub_path = ".cli-proxy-api/first.json", .data = first });
    try tmp.dir.writeFile(.{ .sub_path = ".cli-proxy-api/second.json", .data = second });
    try tmp.dir.writeFile(.{ .sub_path = ".cli-proxy-api/no-refresh.json", .data = missing_refresh });

    const result = try runCliWithIsolatedHome(gpa, project_root, home_root, &[_][]const u8{ "import", "--cpa" });
    defer gpa.free(result.stdout);
    defer gpa.free(result.stderr);

    try expectSuccess(result);
    try std.testing.expectEqualStrings(
        "Scanning ~/.cli-proxy-api...\n" ++
            "  ✓ imported  first\n" ++
            "  ✓ imported  second\n" ++
            "Import Summary: 2 imported, 0 updated, 1 skipped (total 3 files)\n",
        result.stdout,
    );
    try std.testing.expectEqualStrings("  ✗ skipped   no-refresh: MissingRefreshToken\n", result.stderr);

    const codex_home = try codexHomeAlloc(gpa, home_root);
    defer gpa.free(codex_home);
    var loaded = try registry.loadRegistry(gpa, codex_home);
    defer loaded.deinit(gpa);
    try std.testing.expectEqual(@as(usize, 2), loaded.accounts.items.len);
}

test "Scenario: Given missing default cpa directory when running import cpa then it fails" {
    const gpa = std.testing.allocator;
    const project_root = try projectRootAlloc(gpa);
    defer gpa.free(project_root);
    try buildCliBinary(gpa, project_root);

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const home_root = try tmp.dir.realpathAlloc(gpa, ".");
    defer gpa.free(home_root);

    const result = try runCliWithIsolatedHome(gpa, project_root, home_root, &[_][]const u8{ "import", "--cpa" });
    defer gpa.free(result.stdout);
    defer gpa.free(result.stderr);

    try expectFailure(result);
}

test "Scenario: Given cpa file import when running import cpa then it stores a standard auth snapshot" {
    const gpa = std.testing.allocator;
    const project_root = try projectRootAlloc(gpa);
    defer gpa.free(project_root);
    try buildCliBinary(gpa, project_root);

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const home_root = try tmp.dir.realpathAlloc(gpa, ".");
    defer gpa.free(home_root);
    try tmp.dir.makePath("imports");

    const cpa_json = try bdd.cpaJsonWithEmailPlan(gpa, "single-file-cpa@example.com", "business");
    defer gpa.free(cpa_json);
    try tmp.dir.writeFile(.{ .sub_path = "imports/cpa.json", .data = cpa_json });

    const import_path = try std.fs.path.join(gpa, &[_][]const u8{ home_root, "imports", "cpa.json" });
    defer gpa.free(import_path);

    const result = try runCliWithIsolatedHome(gpa, project_root, home_root, &[_][]const u8{ "import", "--cpa", import_path, "--alias", "personal" });
    defer gpa.free(result.stdout);
    defer gpa.free(result.stderr);

    try expectSuccess(result);
    try std.testing.expectEqualStrings("  ✓ imported  cpa\n", result.stdout);
    try std.testing.expectEqualStrings("", result.stderr);

    const codex_home = try codexHomeAlloc(gpa, home_root);
    defer gpa.free(codex_home);
    const account_key = try bdd.accountKeyForEmailAlloc(gpa, "single-file-cpa@example.com");
    defer gpa.free(account_key);
    const snapshot_path = try registry.accountAuthPath(gpa, codex_home, account_key);
    defer gpa.free(snapshot_path);
    const snapshot_data = try bdd.readFileAlloc(gpa, snapshot_path);
    defer gpa.free(snapshot_data);
    try std.testing.expect(std.mem.indexOf(u8, snapshot_data, "\"tokens\": {") != null);
    try std.testing.expect(std.mem.indexOf(u8, snapshot_data, "\"refresh_token\": \"refresh-single-file-cpa@example.com\"") != null);

    var loaded = try registry.loadRegistry(gpa, codex_home);
    defer loaded.deinit(gpa);
    try std.testing.expect(std.mem.eql(u8, loaded.accounts.items[0].alias, "personal"));
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

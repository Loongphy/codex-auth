const std = @import("std");
const builtin = @import("builtin");
const registry = @import("../registry.zig");
const bdd = @import("bdd_helpers.zig");

const SeedAccount = struct {
    email: []const u8,
    alias: []const u8,
};

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

fn runCliWithIsolatedHomeAndStdin(
    allocator: std.mem.Allocator,
    project_root: []const u8,
    home_root: []const u8,
    args: []const []const u8,
    stdin_data: []const u8,
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

    var child = std.process.Child.init(argv.items, allocator);
    child.cwd = project_root;
    child.env_map = &env_map;
    child.stdin_behavior = .Pipe;
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Pipe;

    var stdout = std.ArrayList(u8).empty;
    defer stdout.deinit(allocator);
    var stderr = std.ArrayList(u8).empty;
    defer stderr.deinit(allocator);

    try child.spawn();
    errdefer {
        _ = child.kill() catch {};
    }

    if (child.stdin) |stdin_pipe| {
        try stdin_pipe.writeAll(stdin_data);
        stdin_pipe.close();
        child.stdin = null;
    }

    try child.collectOutput(allocator, &stdout, &stderr, 1024 * 1024);

    return .{
        .stdout = try stdout.toOwnedSlice(allocator),
        .stderr = try stderr.toOwnedSlice(allocator),
        .term = try child.wait(),
    };
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

fn countAuthBackups(dir: std.fs.Dir, rel_path: []const u8) !usize {
    var accounts = try dir.openDir(rel_path, .{ .iterate = true });
    defer accounts.close();

    var count: usize = 0;
    var it = accounts.iterate();
    while (try it.next()) |entry| {
        if (entry.kind != .file) continue;
        if (std.mem.startsWith(u8, entry.name, "auth.json.bak.")) count += 1;
    }
    return count;
}

fn legacySnapshotNameForEmail(allocator: std.mem.Allocator, email: []const u8) ![]u8 {
    const encoded = try bdd.b64url(allocator, email);
    defer allocator.free(encoded);
    return try std.fmt.allocPrint(allocator, "{s}.auth.json", .{encoded});
}

fn seedRegistryWithAccounts(
    allocator: std.mem.Allocator,
    home_root: []const u8,
    active_email: []const u8,
    entries: []const SeedAccount,
) !void {
    const codex_home = try codexHomeAlloc(allocator, home_root);
    defer allocator.free(codex_home);

    var reg = bdd.makeEmptyRegistry();
    defer reg.deinit(allocator);

    for (entries) |entry| {
        try bdd.appendAccount(allocator, &reg, entry.email, entry.alias, null);
    }

    const active_key = try bdd.accountKeyForEmailAlloc(allocator, active_email);
    reg.active_account_key = active_key;
    reg.active_account_activated_at_ms = std.time.milliTimestamp();
    try registry.saveRegistry(allocator, codex_home, &reg);
}

fn appendCustomAccount(
    allocator: std.mem.Allocator,
    reg: *registry.Registry,
    record_key: []const u8,
    email: []const u8,
    alias: []const u8,
    plan: registry.PlanType,
) !void {
    const sep = std.mem.lastIndexOf(u8, record_key, "::") orelse return error.InvalidRecordKey;
    const chatgpt_user_id = record_key[0..sep];
    const chatgpt_account_id = record_key[sep + 2 ..];
    try reg.accounts.append(allocator, .{
        .account_key = try allocator.dupe(u8, record_key),
        .chatgpt_account_id = try allocator.dupe(u8, chatgpt_account_id),
        .chatgpt_user_id = try allocator.dupe(u8, chatgpt_user_id),
        .email = try allocator.dupe(u8, email),
        .alias = try allocator.dupe(u8, alias),
        .plan = plan,
        .auth_mode = .chatgpt,
        .created_at = std.time.timestamp(),
        .last_used_at = null,
        .last_usage = null,
        .last_usage_at = null,
        .last_local_rollout = null,
    });
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

test "Scenario: Given remove query with one match when running remove then it deletes immediately and prints a summary" {
    const gpa = std.testing.allocator;
    const project_root = try projectRootAlloc(gpa);
    defer gpa.free(project_root);
    try buildCliBinary(gpa, project_root);

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const home_root = try tmp.dir.realpathAlloc(gpa, ".");
    defer gpa.free(home_root);

    try seedRegistryWithAccounts(gpa, home_root, "keeper@example.com", &[_]SeedAccount{
        .{ .email = "robot09@example.com", .alias = "" },
        .{ .email = "keeper@example.com", .alias = "" },
    });

    const codex_home = try codexHomeAlloc(gpa, home_root);
    defer gpa.free(codex_home);
    const removed_account_key = try bdd.accountKeyForEmailAlloc(gpa, "robot09@example.com");
    defer gpa.free(removed_account_key);
    const keeper_account_key = try bdd.accountKeyForEmailAlloc(gpa, "keeper@example.com");
    defer gpa.free(keeper_account_key);

    const removed_snapshot_path = try registry.accountAuthPath(gpa, codex_home, removed_account_key);
    defer gpa.free(removed_snapshot_path);
    const keeper_snapshot_path = try registry.accountAuthPath(gpa, codex_home, keeper_account_key);
    defer gpa.free(keeper_snapshot_path);

    const removed_auth = try bdd.authJsonWithEmailPlan(gpa, "robot09@example.com", "plus");
    defer gpa.free(removed_auth);
    const keeper_auth = try bdd.authJsonWithEmailPlan(gpa, "keeper@example.com", "team");
    defer gpa.free(keeper_auth);

    try std.fs.cwd().writeFile(.{ .sub_path = removed_snapshot_path, .data = removed_auth });
    try std.fs.cwd().writeFile(.{ .sub_path = keeper_snapshot_path, .data = keeper_auth });
    try tmp.dir.writeFile(.{ .sub_path = ".codex/accounts/auth.json.bak.20260320-010101", .data = removed_auth });
    try tmp.dir.writeFile(.{ .sub_path = ".codex/accounts/auth.json.bak.20260320-020202", .data = removed_auth });
    try tmp.dir.writeFile(.{ .sub_path = ".codex/accounts/auth.json.bak.20260320-030303", .data = keeper_auth });

    const result = try runCliWithIsolatedHomeAndStdin(gpa, project_root, home_root, &[_][]const u8{ "remove", "09" }, "");
    defer gpa.free(result.stdout);
    defer gpa.free(result.stderr);

    try expectSuccess(result);
    try std.testing.expectEqualStrings(
        "Removed 1 account(s): robot09@example.com\n",
        result.stdout,
    );
    try std.testing.expectEqualStrings("", result.stderr);

    var loaded = try registry.loadRegistry(gpa, codex_home);
    defer loaded.deinit(gpa);
    try std.testing.expectEqual(@as(usize, 1), loaded.accounts.items.len);
    try std.testing.expect(std.mem.eql(u8, loaded.accounts.items[0].email, "keeper@example.com"));
    try std.testing.expectError(error.FileNotFound, std.fs.cwd().openFile(removed_snapshot_path, .{}));
    var keeper_snapshot = try std.fs.cwd().openFile(keeper_snapshot_path, .{});
    keeper_snapshot.close();
    try std.testing.expectError(error.FileNotFound, tmp.dir.openFile(".codex/accounts/auth.json.bak.20260320-010101", .{}));
    try std.testing.expectError(error.FileNotFound, tmp.dir.openFile(".codex/accounts/auth.json.bak.20260320-020202", .{}));
    var keeper_backup = try tmp.dir.openFile(".codex/accounts/auth.json.bak.20260320-030303", .{});
    keeper_backup.close();
}

test "Scenario: Given active account removal with a replacement when running remove then it does not recreate a backup for the deleted auth" {
    const gpa = std.testing.allocator;
    const project_root = try projectRootAlloc(gpa);
    defer gpa.free(project_root);
    try buildCliBinary(gpa, project_root);

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const home_root = try tmp.dir.realpathAlloc(gpa, ".");
    defer gpa.free(home_root);

    try seedRegistryWithAccounts(gpa, home_root, "active@example.com", &[_]SeedAccount{
        .{ .email = "active@example.com", .alias = "" },
        .{ .email = "backup@example.com", .alias = "" },
    });

    const codex_home = try codexHomeAlloc(gpa, home_root);
    defer gpa.free(codex_home);
    const active_auth_path = try authJsonPathAlloc(gpa, home_root);
    defer gpa.free(active_auth_path);

    const active_key = try bdd.accountKeyForEmailAlloc(gpa, "active@example.com");
    defer gpa.free(active_key);
    const backup_key = try bdd.accountKeyForEmailAlloc(gpa, "backup@example.com");
    defer gpa.free(backup_key);
    const active_snapshot_path = try registry.accountAuthPath(gpa, codex_home, active_key);
    defer gpa.free(active_snapshot_path);
    const backup_snapshot_path = try registry.accountAuthPath(gpa, codex_home, backup_key);
    defer gpa.free(backup_snapshot_path);

    const active_auth = try bdd.authJsonWithEmailPlan(gpa, "active@example.com", "pro");
    defer gpa.free(active_auth);
    const backup_auth = try bdd.authJsonWithEmailPlan(gpa, "backup@example.com", "plus");
    defer gpa.free(backup_auth);
    try tmp.dir.writeFile(.{ .sub_path = ".codex/auth.json", .data = active_auth });
    try std.fs.cwd().writeFile(.{ .sub_path = active_snapshot_path, .data = active_auth });
    try std.fs.cwd().writeFile(.{ .sub_path = backup_snapshot_path, .data = backup_auth });

    const result = try runCliWithIsolatedHomeAndStdin(gpa, project_root, home_root, &[_][]const u8{ "remove", "active@" }, "");
    defer gpa.free(result.stdout);
    defer gpa.free(result.stderr);

    try expectSuccess(result);
    try std.testing.expectEqualStrings("Removed 1 account(s): active@example.com\n", result.stdout);
    try std.testing.expectEqualStrings("", result.stderr);

    const replaced_auth = try bdd.readFileAlloc(gpa, active_auth_path);
    defer gpa.free(replaced_auth);
    try std.testing.expectEqualStrings(backup_auth, replaced_auth);
    try std.testing.expectError(error.FileNotFound, std.fs.cwd().openFile(active_snapshot_path, .{}));
    try std.testing.expectEqual(@as(usize, 0), try countAuthBackups(tmp.dir, ".codex/accounts"));
}

test "Scenario: Given active account removal with missing auth json when running remove then replacement auth is recreated" {
    const gpa = std.testing.allocator;
    const project_root = try projectRootAlloc(gpa);
    defer gpa.free(project_root);
    try buildCliBinary(gpa, project_root);

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const home_root = try tmp.dir.realpathAlloc(gpa, ".");
    defer gpa.free(home_root);

    try seedRegistryWithAccounts(gpa, home_root, "active@example.com", &[_]SeedAccount{
        .{ .email = "active@example.com", .alias = "" },
        .{ .email = "backup@example.com", .alias = "" },
    });

    const codex_home = try codexHomeAlloc(gpa, home_root);
    defer gpa.free(codex_home);
    const active_auth_path = try authJsonPathAlloc(gpa, home_root);
    defer gpa.free(active_auth_path);

    const active_key = try bdd.accountKeyForEmailAlloc(gpa, "active@example.com");
    defer gpa.free(active_key);
    const backup_key = try bdd.accountKeyForEmailAlloc(gpa, "backup@example.com");
    defer gpa.free(backup_key);
    const active_snapshot_path = try registry.accountAuthPath(gpa, codex_home, active_key);
    defer gpa.free(active_snapshot_path);
    const backup_snapshot_path = try registry.accountAuthPath(gpa, codex_home, backup_key);
    defer gpa.free(backup_snapshot_path);

    const active_auth = try bdd.authJsonWithEmailPlan(gpa, "active@example.com", "pro");
    defer gpa.free(active_auth);
    const backup_auth = try bdd.authJsonWithEmailPlan(gpa, "backup@example.com", "plus");
    defer gpa.free(backup_auth);
    try std.fs.cwd().writeFile(.{ .sub_path = active_snapshot_path, .data = active_auth });
    try std.fs.cwd().writeFile(.{ .sub_path = backup_snapshot_path, .data = backup_auth });

    const result = try runCliWithIsolatedHomeAndStdin(gpa, project_root, home_root, &[_][]const u8{ "remove", "active@" }, "");
    defer gpa.free(result.stdout);
    defer gpa.free(result.stderr);

    try expectSuccess(result);
    try std.testing.expectEqualStrings("Removed 1 account(s): active@example.com\n", result.stdout);
    try std.testing.expectEqualStrings("", result.stderr);

    const recreated_auth = try bdd.readFileAlloc(gpa, active_auth_path);
    defer gpa.free(recreated_auth);
    try std.testing.expectEqualStrings(backup_auth, recreated_auth);
}

test "Scenario: Given missing auth json and no valid active key when running remove then replacement auth is recreated" {
    const gpa = std.testing.allocator;
    const project_root = try projectRootAlloc(gpa);
    defer gpa.free(project_root);
    try buildCliBinary(gpa, project_root);

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const home_root = try tmp.dir.realpathAlloc(gpa, ".");
    defer gpa.free(home_root);

    try seedRegistryWithAccounts(gpa, home_root, "active@example.com", &[_]SeedAccount{
        .{ .email = "active@example.com", .alias = "" },
        .{ .email = "backup@example.com", .alias = "" },
    });

    const codex_home = try codexHomeAlloc(gpa, home_root);
    defer gpa.free(codex_home);
    const active_auth_path = try authJsonPathAlloc(gpa, home_root);
    defer gpa.free(active_auth_path);

    const active_key = try bdd.accountKeyForEmailAlloc(gpa, "active@example.com");
    defer gpa.free(active_key);
    const backup_key = try bdd.accountKeyForEmailAlloc(gpa, "backup@example.com");
    defer gpa.free(backup_key);
    const active_snapshot_path = try registry.accountAuthPath(gpa, codex_home, active_key);
    defer gpa.free(active_snapshot_path);
    const backup_snapshot_path = try registry.accountAuthPath(gpa, codex_home, backup_key);
    defer gpa.free(backup_snapshot_path);

    const active_auth = try bdd.authJsonWithEmailPlan(gpa, "active@example.com", "pro");
    defer gpa.free(active_auth);
    const backup_auth = try bdd.authJsonWithEmailPlan(gpa, "backup@example.com", "plus");
    defer gpa.free(backup_auth);
    try std.fs.cwd().writeFile(.{ .sub_path = active_snapshot_path, .data = active_auth });
    try std.fs.cwd().writeFile(.{ .sub_path = backup_snapshot_path, .data = backup_auth });

    var reg = try registry.loadRegistry(gpa, codex_home);
    defer reg.deinit(gpa);
    if (reg.active_account_key) |key| {
        gpa.free(key);
        reg.active_account_key = null;
    }
    reg.active_account_activated_at_ms = null;
    try registry.saveRegistry(gpa, codex_home, &reg);

    const result = try runCliWithIsolatedHomeAndStdin(gpa, project_root, home_root, &[_][]const u8{ "remove", "active@" }, "");
    defer gpa.free(result.stdout);
    defer gpa.free(result.stderr);

    try expectSuccess(result);
    try std.testing.expectEqualStrings("Removed 1 account(s): active@example.com\n", result.stdout);
    try std.testing.expectEqualStrings("", result.stderr);

    const recreated_auth = try bdd.readFileAlloc(gpa, active_auth_path);
    defer gpa.free(recreated_auth);
    try std.testing.expectEqualStrings(backup_auth, recreated_auth);

    var loaded = try registry.loadRegistry(gpa, codex_home);
    defer loaded.deinit(gpa);
    try std.testing.expectEqual(@as(usize, 1), loaded.accounts.items.len);
    try std.testing.expect(loaded.active_account_key != null);
    try std.testing.expect(std.mem.eql(u8, loaded.active_account_key.?, backup_key));
}

test "Scenario: Given auth json already points at another registry account when removing it then later sync does not recreate that deleted account" {
    const gpa = std.testing.allocator;
    const project_root = try projectRootAlloc(gpa);
    defer gpa.free(project_root);
    try buildCliBinary(gpa, project_root);

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const home_root = try tmp.dir.realpathAlloc(gpa, ".");
    defer gpa.free(home_root);

    try seedRegistryWithAccounts(gpa, home_root, "alpha@example.com", &[_]SeedAccount{
        .{ .email = "alpha@example.com", .alias = "" },
        .{ .email = "beta@example.com", .alias = "" },
    });

    const codex_home = try codexHomeAlloc(gpa, home_root);
    defer gpa.free(codex_home);
    const active_auth_path = try authJsonPathAlloc(gpa, home_root);
    defer gpa.free(active_auth_path);

    const alpha_key = try bdd.accountKeyForEmailAlloc(gpa, "alpha@example.com");
    defer gpa.free(alpha_key);
    const beta_key = try bdd.accountKeyForEmailAlloc(gpa, "beta@example.com");
    defer gpa.free(beta_key);
    const alpha_snapshot_path = try registry.accountAuthPath(gpa, codex_home, alpha_key);
    defer gpa.free(alpha_snapshot_path);
    const beta_snapshot_path = try registry.accountAuthPath(gpa, codex_home, beta_key);
    defer gpa.free(beta_snapshot_path);

    const alpha_auth = try bdd.authJsonWithEmailPlan(gpa, "alpha@example.com", "team");
    defer gpa.free(alpha_auth);
    const beta_auth = try bdd.authJsonWithEmailPlan(gpa, "beta@example.com", "plus");
    defer gpa.free(beta_auth);
    try tmp.dir.writeFile(.{ .sub_path = ".codex/auth.json", .data = beta_auth });
    try std.fs.cwd().writeFile(.{ .sub_path = alpha_snapshot_path, .data = alpha_auth });
    try std.fs.cwd().writeFile(.{ .sub_path = beta_snapshot_path, .data = beta_auth });

    const remove_result = try runCliWithIsolatedHomeAndStdin(gpa, project_root, home_root, &[_][]const u8{ "remove", "beta@" }, "");
    defer gpa.free(remove_result.stdout);
    defer gpa.free(remove_result.stderr);

    try expectSuccess(remove_result);
    try std.testing.expectEqualStrings("Removed 1 account(s): beta@example.com\n", remove_result.stdout);
    try std.testing.expectEqualStrings("", remove_result.stderr);

    const auth_after_remove = try bdd.readFileAlloc(gpa, active_auth_path);
    defer gpa.free(auth_after_remove);
    try std.testing.expectEqualStrings(alpha_auth, auth_after_remove);

    var loaded_after_remove = try registry.loadRegistry(gpa, codex_home);
    defer loaded_after_remove.deinit(gpa);
    try std.testing.expectEqual(@as(usize, 1), loaded_after_remove.accounts.items.len);
    try std.testing.expect(std.mem.eql(u8, loaded_after_remove.accounts.items[0].email, "alpha@example.com"));
    try std.testing.expect(loaded_after_remove.active_account_key != null);
    try std.testing.expect(std.mem.eql(u8, loaded_after_remove.active_account_key.?, alpha_key));

    const list_result = try runCliWithIsolatedHome(gpa, project_root, home_root, &[_][]const u8{"list"});
    defer gpa.free(list_result.stdout);
    defer gpa.free(list_result.stderr);

    try expectSuccess(list_result);
    try std.testing.expect(std.mem.indexOf(u8, list_result.stdout, "alpha@example.com") != null);
    try std.testing.expect(std.mem.indexOf(u8, list_result.stdout, "beta@example.com") == null);

    var loaded_after_list = try registry.loadRegistry(gpa, codex_home);
    defer loaded_after_list.deinit(gpa);
    try std.testing.expectEqual(@as(usize, 1), loaded_after_list.accounts.items.len);
    try std.testing.expect(std.mem.eql(u8, loaded_after_list.accounts.items[0].email, "alpha@example.com"));
}

test "Scenario: Given remove query with no matches when running remove then it exits cleanly with one stderr line" {
    const gpa = std.testing.allocator;
    const project_root = try projectRootAlloc(gpa);
    defer gpa.free(project_root);
    try buildCliBinary(gpa, project_root);

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const home_root = try tmp.dir.realpathAlloc(gpa, ".");
    defer gpa.free(home_root);

    try seedRegistryWithAccounts(gpa, home_root, "keeper@example.com", &[_]SeedAccount{
        .{ .email = "keeper@example.com", .alias = "" },
    });

    const result = try runCliWithIsolatedHomeAndStdin(gpa, project_root, home_root, &[_][]const u8{ "remove", "tmp2" }, "");
    defer gpa.free(result.stdout);
    defer gpa.free(result.stderr);

    try expectFailure(result);
    try std.testing.expectEqualStrings("", result.stdout);
    try std.testing.expectEqualStrings("error: no account matches 'tmp2'.\n", result.stderr);
    try std.testing.expect(std.mem.indexOf(u8, result.stderr, "AccountNotFound") == null);
    try std.testing.expect(std.mem.indexOf(u8, result.stderr, "main.zig") == null);
}

test "Scenario: Given non-tty remove with invalid selection input when running remove then it fails without deleting accounts" {
    const gpa = std.testing.allocator;
    const project_root = try projectRootAlloc(gpa);
    defer gpa.free(project_root);
    try buildCliBinary(gpa, project_root);

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const home_root = try tmp.dir.realpathAlloc(gpa, ".");
    defer gpa.free(home_root);

    try seedRegistryWithAccounts(gpa, home_root, "keeper@example.com", &[_]SeedAccount{
        .{ .email = "alpha@example.com", .alias = "" },
        .{ .email = "keeper@example.com", .alias = "" },
    });

    const result = try runCliWithIsolatedHomeAndStdin(gpa, project_root, home_root, &[_][]const u8{"remove"}, "{\"id\":1}\n");
    defer gpa.free(result.stdout);
    defer gpa.free(result.stderr);

    try expectFailure(result);
    try std.testing.expect(std.mem.indexOf(u8, result.stdout, "Select accounts to delete:\n\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.stdout, "Enter account numbers (comma/space separated, empty to cancel): ") != null);
    try std.testing.expectEqualStrings(
        "error: invalid remove selection input.\n" ++
            "hint: Use numbers separated by commas or spaces, for example `1 2` or `1,2`.\n",
        result.stderr,
    );

    const codex_home = try codexHomeAlloc(gpa, home_root);
    defer gpa.free(codex_home);
    var loaded = try registry.loadRegistry(gpa, codex_home);
    defer loaded.deinit(gpa);
    try std.testing.expectEqual(@as(usize, 2), loaded.accounts.items.len);
}

test "Scenario: Given remove query with multiple matches in non-tty mode when running remove then it fails without reading piped stdin" {
    const gpa = std.testing.allocator;
    const project_root = try projectRootAlloc(gpa);
    defer gpa.free(project_root);
    try buildCliBinary(gpa, project_root);

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const home_root = try tmp.dir.realpathAlloc(gpa, ".");
    defer gpa.free(home_root);

    try seedRegistryWithAccounts(gpa, home_root, "keeper@example.com", &[_]SeedAccount{
        .{ .email = "alpha@example.com", .alias = "team-a" },
        .{ .email = "beta@example.com", .alias = "team-b" },
        .{ .email = "keeper@example.com", .alias = "" },
    });

    const result = try runCliWithIsolatedHomeAndStdin(gpa, project_root, home_root, &[_][]const u8{ "remove", "team" }, "y\n");
    defer gpa.free(result.stdout);
    defer gpa.free(result.stderr);

    try expectFailure(result);
    try std.testing.expectEqualStrings("", result.stdout);
    try std.testing.expectEqualStrings(
        "Matched multiple accounts:\n" ++
            "- (team-a)alpha@example.com\n" ++
            "- (team-b)beta@example.com\n" ++
            "error: multiple accounts match the query in non-interactive mode.\n" ++
            "hint: Refine the query to match one account, or run the command in a TTY.\n",
        result.stderr,
    );

    const codex_home = try codexHomeAlloc(gpa, home_root);
    defer gpa.free(codex_home);
    var loaded = try registry.loadRegistry(gpa, codex_home);
    defer loaded.deinit(gpa);
    try std.testing.expectEqual(@as(usize, 3), loaded.accounts.items.len);
}

test "Scenario: Given remove query with duplicate-email accounts when running remove then confirmation output keeps list-style identity" {
    const gpa = std.testing.allocator;
    const project_root = try projectRootAlloc(gpa);
    defer gpa.free(project_root);
    try buildCliBinary(gpa, project_root);

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const home_root = try tmp.dir.realpathAlloc(gpa, ".");
    defer gpa.free(home_root);

    const codex_home = try codexHomeAlloc(gpa, home_root);
    defer gpa.free(codex_home);
    var reg = bdd.makeEmptyRegistry();
    defer reg.deinit(gpa);
    try appendCustomAccount(gpa, &reg, "user-a::acct-work", "alice@example.com", "work", .team);
    try appendCustomAccount(gpa, &reg, "user-b::acct-personal", "alice@example.com", "personal", .plus);
    reg.active_account_key = try gpa.dupe(u8, "user-a::acct-work");
    reg.active_account_activated_at_ms = std.time.milliTimestamp();
    try registry.saveRegistry(gpa, codex_home, &reg);

    const result = try runCliWithIsolatedHomeAndStdin(gpa, project_root, home_root, &[_][]const u8{ "remove", "alice@" }, "y\n");
    defer gpa.free(result.stdout);
    defer gpa.free(result.stderr);

    try expectFailure(result);
    try std.testing.expectEqualStrings(
        "Matched multiple accounts:\n" ++
            "- alice@example.com / work\n" ++
            "- alice@example.com / personal\n" ++
            "error: multiple accounts match the query in non-interactive mode.\n" ++
            "hint: Refine the query to match one account, or run the command in a TTY.\n",
        result.stderr,
    );
}

test "Scenario: Given remove query deletes the final active account when running remove then active auth is deleted too" {
    const gpa = std.testing.allocator;
    const project_root = try projectRootAlloc(gpa);
    defer gpa.free(project_root);
    try buildCliBinary(gpa, project_root);

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const home_root = try tmp.dir.realpathAlloc(gpa, ".");
    defer gpa.free(home_root);

    try seedRegistryWithAccounts(gpa, home_root, "solo@example.com", &[_]SeedAccount{
        .{ .email = "solo@example.com", .alias = "" },
    });

    const codex_home = try codexHomeAlloc(gpa, home_root);
    defer gpa.free(codex_home);
    const active_auth_path = try authJsonPathAlloc(gpa, home_root);
    defer gpa.free(active_auth_path);
    const account_key = try bdd.accountKeyForEmailAlloc(gpa, "solo@example.com");
    defer gpa.free(account_key);
    const snapshot_path = try registry.accountAuthPath(gpa, codex_home, account_key);
    defer gpa.free(snapshot_path);

    const solo_auth = try bdd.authJsonWithEmailPlan(gpa, "solo@example.com", "pro");
    defer gpa.free(solo_auth);
    try tmp.dir.writeFile(.{ .sub_path = ".codex/auth.json", .data = solo_auth });
    try std.fs.cwd().writeFile(.{ .sub_path = snapshot_path, .data = solo_auth });

    const result = try runCliWithIsolatedHomeAndStdin(gpa, project_root, home_root, &[_][]const u8{ "remove", "solo" }, "");
    defer gpa.free(result.stdout);
    defer gpa.free(result.stderr);

    try expectSuccess(result);
    try std.testing.expectEqualStrings(
        "Removed 1 account(s): solo@example.com\n",
        result.stdout,
    );
    try std.testing.expectEqualStrings("", result.stderr);

    var loaded = try registry.loadRegistry(gpa, codex_home);
    defer loaded.deinit(gpa);
    try std.testing.expectEqual(@as(usize, 0), loaded.accounts.items.len);
    try std.testing.expect(loaded.active_account_key == null);
    try std.testing.expectError(error.FileNotFound, std.fs.cwd().openFile(active_auth_path, .{}));
    try std.testing.expectError(error.FileNotFound, std.fs.cwd().openFile(snapshot_path, .{}));
}

test "Scenario: Given non-tty stdin when running interactive remove then it falls back to the numbered selector" {
    const gpa = std.testing.allocator;
    const project_root = try projectRootAlloc(gpa);
    defer gpa.free(project_root);
    try buildCliBinary(gpa, project_root);

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const home_root = try tmp.dir.realpathAlloc(gpa, ".");
    defer gpa.free(home_root);

    try seedRegistryWithAccounts(gpa, home_root, "keeper@example.com", &[_]SeedAccount{
        .{ .email = "alpha@example.com", .alias = "" },
        .{ .email = "keeper@example.com", .alias = "" },
    });

    const result = try runCliWithIsolatedHomeAndStdin(gpa, project_root, home_root, &[_][]const u8{"remove"}, "");
    defer gpa.free(result.stdout);
    defer gpa.free(result.stderr);

    try expectSuccess(result);
    try std.testing.expect(std.mem.indexOf(u8, result.stdout, "Select accounts to delete:\n\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.stdout, "Enter account numbers (comma/space separated, empty to cancel): ") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.stdout, "\x1b[2J\x1b[H") == null);
    try std.testing.expect(std.mem.indexOf(u8, result.stdout, "Keys: ↑/↓ or j/k move") == null);
    try std.testing.expectEqualStrings("", result.stderr);
}

test "Scenario: Given remove all when running remove then it clears all accounts and deletes active auth" {
    const gpa = std.testing.allocator;
    const project_root = try projectRootAlloc(gpa);
    defer gpa.free(project_root);
    try buildCliBinary(gpa, project_root);

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const home_root = try tmp.dir.realpathAlloc(gpa, ".");
    defer gpa.free(home_root);

    try seedRegistryWithAccounts(gpa, home_root, "alpha@example.com", &[_]SeedAccount{
        .{ .email = "alpha@example.com", .alias = "" },
        .{ .email = "beta@example.com", .alias = "" },
    });

    const codex_home = try codexHomeAlloc(gpa, home_root);
    defer gpa.free(codex_home);
    const active_auth_path = try authJsonPathAlloc(gpa, home_root);
    defer gpa.free(active_auth_path);
    const active_auth = try bdd.authJsonWithEmailPlan(gpa, "alpha@example.com", "pro");
    defer gpa.free(active_auth);
    try tmp.dir.writeFile(.{ .sub_path = ".codex/auth.json", .data = active_auth });

    const result = try runCliWithIsolatedHomeAndStdin(gpa, project_root, home_root, &[_][]const u8{ "remove", "--all" }, "");
    defer gpa.free(result.stdout);
    defer gpa.free(result.stderr);

    try expectSuccess(result);
    try std.testing.expect(std.mem.indexOf(u8, result.stdout, "Removed 2 account(s): ") != null);
    try std.testing.expectEqualStrings("", result.stderr);

    var loaded = try registry.loadRegistry(gpa, codex_home);
    defer loaded.deinit(gpa);
    try std.testing.expectEqual(@as(usize, 0), loaded.accounts.items.len);
    try std.testing.expect(loaded.active_account_key == null);
    try std.testing.expectError(error.FileNotFound, std.fs.cwd().openFile(active_auth_path, .{}));
}

test "Scenario: Given remove all with malformed auth json when running remove then registry is cleared but auth json is preserved" {
    const gpa = std.testing.allocator;
    const project_root = try projectRootAlloc(gpa);
    defer gpa.free(project_root);
    try buildCliBinary(gpa, project_root);

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const home_root = try tmp.dir.realpathAlloc(gpa, ".");
    defer gpa.free(home_root);

    try seedRegistryWithAccounts(gpa, home_root, "alpha@example.com", &[_]SeedAccount{
        .{ .email = "alpha@example.com", .alias = "" },
        .{ .email = "beta@example.com", .alias = "" },
    });

    const codex_home = try codexHomeAlloc(gpa, home_root);
    defer gpa.free(codex_home);
    const active_auth_path = try authJsonPathAlloc(gpa, home_root);
    defer gpa.free(active_auth_path);
    try tmp.dir.writeFile(.{ .sub_path = ".codex/auth.json", .data = "{\"broken\":true}" });

    const result = try runCliWithIsolatedHomeAndStdin(gpa, project_root, home_root, &[_][]const u8{ "remove", "--all" }, "");
    defer gpa.free(result.stdout);
    defer gpa.free(result.stderr);

    try expectSuccess(result);
    try std.testing.expect(std.mem.indexOf(u8, result.stdout, "Removed 2 account(s): ") != null);
    try std.testing.expectEqualStrings("warning: auth.json missing email; skipping sync\n", result.stderr);

    var loaded = try registry.loadRegistry(gpa, codex_home);
    defer loaded.deinit(gpa);
    try std.testing.expectEqual(@as(usize, 0), loaded.accounts.items.len);
    try std.testing.expect(loaded.active_account_key == null);

    const auth_after = try bdd.readFileAlloc(gpa, active_auth_path);
    defer gpa.free(auth_after);
    try std.testing.expectEqualStrings("{\"broken\":true}", auth_after);
}

test "Scenario: Given remove all with tracked auth json and no active key when running remove then auth json is deleted too" {
    const gpa = std.testing.allocator;
    const project_root = try projectRootAlloc(gpa);
    defer gpa.free(project_root);
    try buildCliBinary(gpa, project_root);

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const home_root = try tmp.dir.realpathAlloc(gpa, ".");
    defer gpa.free(home_root);

    try seedRegistryWithAccounts(gpa, home_root, "alpha@example.com", &[_]SeedAccount{
        .{ .email = "alpha@example.com", .alias = "" },
        .{ .email = "beta@example.com", .alias = "" },
    });

    const codex_home = try codexHomeAlloc(gpa, home_root);
    defer gpa.free(codex_home);
    const active_auth_path = try authJsonPathAlloc(gpa, home_root);
    defer gpa.free(active_auth_path);
    const alpha_auth = try bdd.authJsonWithEmailPlan(gpa, "alpha@example.com", "pro");
    defer gpa.free(alpha_auth);
    try tmp.dir.writeFile(.{ .sub_path = ".codex/auth.json", .data = alpha_auth });

    var reg = try registry.loadRegistry(gpa, codex_home);
    defer reg.deinit(gpa);
    if (reg.active_account_key) |key| {
        gpa.free(key);
        reg.active_account_key = null;
    }
    reg.active_account_activated_at_ms = null;
    try registry.saveRegistry(gpa, codex_home, &reg);

    const result = try runCliWithIsolatedHomeAndStdin(gpa, project_root, home_root, &[_][]const u8{ "remove", "--all" }, "");
    defer gpa.free(result.stdout);
    defer gpa.free(result.stderr);

    try expectSuccess(result);
    try std.testing.expect(std.mem.indexOf(u8, result.stdout, "Removed 2 account(s): ") != null);
    try std.testing.expectEqualStrings("", result.stderr);

    var loaded = try registry.loadRegistry(gpa, codex_home);
    defer loaded.deinit(gpa);
    try std.testing.expectEqual(@as(usize, 0), loaded.accounts.items.len);
    try std.testing.expect(loaded.active_account_key == null);
    try std.testing.expectError(error.FileNotFound, std.fs.cwd().openFile(active_auth_path, .{}));
}

test "Scenario: Given remove all with tracked auth json and stale active key when running remove then auth json is deleted too" {
    const gpa = std.testing.allocator;
    const project_root = try projectRootAlloc(gpa);
    defer gpa.free(project_root);
    try buildCliBinary(gpa, project_root);

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const home_root = try tmp.dir.realpathAlloc(gpa, ".");
    defer gpa.free(home_root);

    try seedRegistryWithAccounts(gpa, home_root, "alpha@example.com", &[_]SeedAccount{
        .{ .email = "alpha@example.com", .alias = "" },
        .{ .email = "beta@example.com", .alias = "" },
    });

    const codex_home = try codexHomeAlloc(gpa, home_root);
    defer gpa.free(codex_home);
    const active_auth_path = try authJsonPathAlloc(gpa, home_root);
    defer gpa.free(active_auth_path);
    const alpha_auth = try bdd.authJsonWithEmailPlan(gpa, "alpha@example.com", "pro");
    defer gpa.free(alpha_auth);
    try tmp.dir.writeFile(.{ .sub_path = ".codex/auth.json", .data = alpha_auth });

    var reg = try registry.loadRegistry(gpa, codex_home);
    defer reg.deinit(gpa);
    if (reg.active_account_key) |key| {
        gpa.free(key);
    }
    reg.active_account_key = try gpa.dupe(u8, "user-stale::acct-stale");
    reg.active_account_activated_at_ms = std.time.milliTimestamp();
    try registry.saveRegistry(gpa, codex_home, &reg);

    const result = try runCliWithIsolatedHomeAndStdin(gpa, project_root, home_root, &[_][]const u8{ "remove", "--all" }, "");
    defer gpa.free(result.stdout);
    defer gpa.free(result.stderr);

    try expectSuccess(result);
    try std.testing.expect(std.mem.indexOf(u8, result.stdout, "Removed 2 account(s): ") != null);
    try std.testing.expectEqualStrings("", result.stderr);

    var loaded = try registry.loadRegistry(gpa, codex_home);
    defer loaded.deinit(gpa);
    try std.testing.expectEqual(@as(usize, 0), loaded.accounts.items.len);
    try std.testing.expect(loaded.active_account_key == null);
    try std.testing.expectError(error.FileNotFound, std.fs.cwd().openFile(active_auth_path, .{}));
}

test "Scenario: Given unsynced active auth when removing the active registry account then auth json is preserved" {
    const gpa = std.testing.allocator;
    const project_root = try projectRootAlloc(gpa);
    defer gpa.free(project_root);
    try buildCliBinary(gpa, project_root);

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const home_root = try tmp.dir.realpathAlloc(gpa, ".");
    defer gpa.free(home_root);

    try seedRegistryWithAccounts(gpa, home_root, "active@example.com", &[_]SeedAccount{
        .{ .email = "active@example.com", .alias = "" },
        .{ .email = "backup@example.com", .alias = "" },
    });

    const codex_home = try codexHomeAlloc(gpa, home_root);
    defer gpa.free(codex_home);
    const active_auth_path = try authJsonPathAlloc(gpa, home_root);
    defer gpa.free(active_auth_path);

    const active_key = try bdd.accountKeyForEmailAlloc(gpa, "active@example.com");
    defer gpa.free(active_key);
    const backup_key = try bdd.accountKeyForEmailAlloc(gpa, "backup@example.com");
    defer gpa.free(backup_key);
    const active_snapshot_path = try registry.accountAuthPath(gpa, codex_home, active_key);
    defer gpa.free(active_snapshot_path);
    const backup_snapshot_path = try registry.accountAuthPath(gpa, codex_home, backup_key);
    defer gpa.free(backup_snapshot_path);

    const active_auth = try bdd.authJsonWithEmailPlan(gpa, "active@example.com", "pro");
    defer gpa.free(active_auth);
    const backup_auth = try bdd.authJsonWithEmailPlan(gpa, "backup@example.com", "plus");
    defer gpa.free(backup_auth);
    try tmp.dir.writeFile(.{ .sub_path = ".codex/auth.json", .data = "{\"broken\":true}" });
    try std.fs.cwd().writeFile(.{ .sub_path = active_snapshot_path, .data = active_auth });
    try std.fs.cwd().writeFile(.{ .sub_path = backup_snapshot_path, .data = backup_auth });

    const result = try runCliWithIsolatedHomeAndStdin(gpa, project_root, home_root, &[_][]const u8{ "remove", "active@" }, "");
    defer gpa.free(result.stdout);
    defer gpa.free(result.stderr);

    try expectSuccess(result);
    try std.testing.expectEqualStrings("Removed 1 account(s): active@example.com\n", result.stdout);
    try std.testing.expectEqualStrings("warning: auth.json missing email; skipping sync\n", result.stderr);

    const auth_after = try bdd.readFileAlloc(gpa, active_auth_path);
    defer gpa.free(auth_after);
    try std.testing.expectEqualStrings("{\"broken\":true}", auth_after);

    var loaded = try registry.loadRegistry(gpa, codex_home);
    defer loaded.deinit(gpa);
    try std.testing.expectEqual(@as(usize, 1), loaded.accounts.items.len);
    try std.testing.expect(loaded.active_account_key != null);
    try std.testing.expect(std.mem.eql(u8, loaded.active_account_key.?, backup_key));
}

test "Scenario: Given parseable auth without email for the active account when removing it then auth json is preserved" {
    const gpa = std.testing.allocator;
    const project_root = try projectRootAlloc(gpa);
    defer gpa.free(project_root);
    try buildCliBinary(gpa, project_root);

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const home_root = try tmp.dir.realpathAlloc(gpa, ".");
    defer gpa.free(home_root);

    try seedRegistryWithAccounts(gpa, home_root, "active@example.com", &[_]SeedAccount{
        .{ .email = "active@example.com", .alias = "" },
        .{ .email = "backup@example.com", .alias = "" },
    });

    const codex_home = try codexHomeAlloc(gpa, home_root);
    defer gpa.free(codex_home);
    const active_auth_path = try authJsonPathAlloc(gpa, home_root);
    defer gpa.free(active_auth_path);

    const active_key = try bdd.accountKeyForEmailAlloc(gpa, "active@example.com");
    defer gpa.free(active_key);
    const backup_key = try bdd.accountKeyForEmailAlloc(gpa, "backup@example.com");
    defer gpa.free(backup_key);
    const active_snapshot_path = try registry.accountAuthPath(gpa, codex_home, active_key);
    defer gpa.free(active_snapshot_path);
    const backup_snapshot_path = try registry.accountAuthPath(gpa, codex_home, backup_key);
    defer gpa.free(backup_snapshot_path);

    const missing_email_auth = try bdd.authJsonWithoutEmailForEmail(gpa, "active@example.com", "pro");
    defer gpa.free(missing_email_auth);
    const active_auth = try bdd.authJsonWithEmailPlan(gpa, "active@example.com", "pro");
    defer gpa.free(active_auth);
    const backup_auth = try bdd.authJsonWithEmailPlan(gpa, "backup@example.com", "plus");
    defer gpa.free(backup_auth);
    try tmp.dir.writeFile(.{ .sub_path = ".codex/auth.json", .data = missing_email_auth });
    try std.fs.cwd().writeFile(.{ .sub_path = active_snapshot_path, .data = active_auth });
    try std.fs.cwd().writeFile(.{ .sub_path = backup_snapshot_path, .data = backup_auth });

    const result = try runCliWithIsolatedHomeAndStdin(gpa, project_root, home_root, &[_][]const u8{ "remove", "active@" }, "");
    defer gpa.free(result.stdout);
    defer gpa.free(result.stderr);

    try expectSuccess(result);
    try std.testing.expectEqualStrings("Removed 1 account(s): active@example.com\n", result.stdout);
    try std.testing.expectEqualStrings("warning: auth.json missing email; skipping sync\n", result.stderr);

    const auth_after = try bdd.readFileAlloc(gpa, active_auth_path);
    defer gpa.free(auth_after);
    try std.testing.expectEqualStrings(missing_email_auth, auth_after);

    var loaded = try registry.loadRegistry(gpa, codex_home);
    defer loaded.deinit(gpa);
    try std.testing.expectEqual(@as(usize, 1), loaded.accounts.items.len);
    try std.testing.expect(loaded.active_account_key != null);
    try std.testing.expect(std.mem.eql(u8, loaded.active_account_key.?, backup_key));
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

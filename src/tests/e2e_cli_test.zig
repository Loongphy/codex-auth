const std = @import("std");
const time_compat = @import("../compat_time.zig");
const fs = @import("../compat_fs.zig");
const process_compat = @import("../compat_process.zig");
const builtin = @import("builtin");
const registry = @import("../registry.zig");
const bdd = @import("bdd_helpers.zig");

const e2e_install_prefix_env = "CODEX_AUTH_E2E_INSTALL_PREFIX";
const e2e_project_root_env = "CODEX_AUTH_E2E_PROJECT_ROOT";

var cli_build_ready = false;
var cli_build_mutex: std.Io.Mutex = .init;

const SeedAccount = struct {
    email: []const u8,
    alias: []const u8,
};

fn projectRootAlloc(allocator: std.mem.Allocator) ![]u8 {
    const project_root = process_compat.getEnvVarOwned(allocator, e2e_project_root_env) catch |err| switch (err) {
        error.EnvironmentVariableNotFound => null,
        else => return err,
    };
    if (project_root) |path| return path;
    return fs.cwd().realpathAlloc(allocator, ".");
}

fn runCapture(
    allocator: std.mem.Allocator,
    cwd_path: []const u8,
    env_map: ?*const std.process.Environ.Map,
    argv: []const []const u8,
) !std.process.RunResult {
    const raw_result = std.process.run(std.heap.page_allocator, fs.io(), .{
        .argv = argv,
        .cwd = .{ .path = cwd_path },
        .environ_map = env_map,
        .stdout_limit = .limited(1024 * 1024),
        .stderr_limit = .limited(1024 * 1024),
    }) catch |err| switch (err) {
        error.OutOfMemory => return error.SkipZigTest,
        else => return err,
    };
    defer std.heap.page_allocator.free(raw_result.stdout);
    defer std.heap.page_allocator.free(raw_result.stderr);

    return .{
        .term = raw_result.term,
        .stdout = try allocator.dupe(u8, raw_result.stdout),
        .stderr = try allocator.dupe(u8, raw_result.stderr),
    };
}

fn buildCliBinary(allocator: std.mem.Allocator, project_root: []const u8) !void {
    cli_build_mutex.lockUncancelable(fs.io());
    defer cli_build_mutex.unlock(fs.io());

    if (cli_build_ready) return;

    const exe_path = try builtCliPathAlloc(allocator, project_root);
    defer allocator.free(exe_path);
    if (fs.accessAbsolute(exe_path, .{})) |_| {
        cli_build_ready = true;
        return;
    } else |_| {}

    var env_map = try process_compat.getEnvMap(allocator);
    defer env_map.deinit();
    const global_cache_dir = if (env_map.get("ZIG_GLOBAL_CACHE_DIR")) |dir|
        try allocator.dupe(u8, dir)
    else
        try fs.path.join(allocator, &[_][]const u8{
            project_root,
            ".zig-cache",
            "e2e-global",
        });
    defer allocator.free(global_cache_dir);

    const local_cache_dir = if (env_map.get("ZIG_LOCAL_CACHE_DIR")) |dir|
        try allocator.dupe(u8, dir)
    else
        try fs.path.join(allocator, &[_][]const u8{
            project_root,
            ".zig-cache",
            "e2e-local",
        });
    defer allocator.free(local_cache_dir);
    const install_prefix = if (env_map.get(e2e_install_prefix_env)) |dir|
        try allocator.dupe(u8, dir)
    else
        try fs.path.join(allocator, &[_][]const u8{ project_root, "zig-out" });
    defer allocator.free(install_prefix);

    try env_map.put("ZIG_GLOBAL_CACHE_DIR", global_cache_dir);
    try env_map.put("ZIG_LOCAL_CACHE_DIR", local_cache_dir);
    try env_map.put(e2e_install_prefix_env, install_prefix);

    const result = try runCapture(allocator, project_root, &env_map, &[_][]const u8{ "zig", "build", "-p", install_prefix });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    switch (result.term) {
        .exited => |code| if (code == 0) {
            cli_build_ready = true;
            return;
        },
        else => {},
    }

    std.log.err("zig build stdout:\n{s}", .{result.stdout});
    std.log.err("zig build stderr:\n{s}", .{result.stderr});
    return error.CommandFailed;
}

fn builtCliPathAlloc(allocator: std.mem.Allocator, project_root: []const u8) ![]u8 {
    const exe_name = if (builtin.os.tag == .windows) "codex-auth.exe" else "codex-auth";
    const install_prefix = process_compat.getEnvVarOwned(allocator, e2e_install_prefix_env) catch |err| switch (err) {
        error.EnvironmentVariableNotFound => null,
        else => return err,
    };
    defer if (install_prefix) |dir| allocator.free(dir);

    const prefix = install_prefix orelse return fs.path.join(allocator, &[_][]const u8{ project_root, "zig-out", "bin", exe_name });
    return fs.path.join(allocator, &[_][]const u8{ prefix, "bin", exe_name });
}

fn fakeCodexCommandPath() []const u8 {
    return if (builtin.os.tag == .windows) "fake-bin/codex.cmd" else "fake-bin/codex";
}

fn writeFailingFakeCodex(dir: fs.Dir, exit_code: u8) !void {
    var script_buf: [128]u8 = undefined;
    const script = if (builtin.os.tag == .windows)
        try std.fmt.bufPrint(&script_buf, "@echo off\r\n>\"%HOME%\\fake-codex-argv.txt\" echo %*\r\nexit /b {d}\r\n", .{exit_code})
    else
        try std.fmt.bufPrint(&script_buf, "#!/bin/sh\nprintf '%s\\n' \"$*\" > \"$HOME/fake-codex-argv.txt\"\nexit {d}\n", .{exit_code});
    const sub_path = fakeCodexCommandPath();
    try dir.writeFile(.{ .sub_path = sub_path, .data = script });

    if (builtin.os.tag != .windows) {
        var file = try dir.openFile(sub_path, .{ .mode = .read_write });
        defer file.close();
        try file.chmod(0o755);
    }
}

fn writeSuccessfulFakeCodex(dir: fs.Dir) !void {
    const script =
        if (builtin.os.tag == .windows)
            "@echo off\r\n" ++
                ">\"%HOME%\\fake-codex-argv.txt\" echo %*\r\n" ++
                "set \"CODEX_HOME_DIR=%CODEX_HOME%\"\r\n" ++
                "if \"%CODEX_HOME_DIR%\"==\"\" set \"CODEX_HOME_DIR=%HOME%\\.codex\"\r\n" ++
                "if not exist \"%CODEX_HOME_DIR%\" mkdir \"%CODEX_HOME_DIR%\"\r\n" ++
                "copy /Y \"%HOME%\\fake-auth.json\" \"%CODEX_HOME_DIR%\\auth.json\" >NUL\r\n" ++
                "exit /b 0\r\n"
        else
            "#!/bin/sh\n" ++
                "printf '%s\\n' \"$*\" > \"$HOME/fake-codex-argv.txt\"\n" ++
                "CODEX_HOME_DIR=\"${CODEX_HOME:-$HOME/.codex}\"\n" ++
                "mkdir -p \"$CODEX_HOME_DIR\"\n" ++
                "cp \"$HOME/fake-auth.json\" \"$CODEX_HOME_DIR/auth.json\"\n" ++
                "exit 0\n";
    const sub_path = fakeCodexCommandPath();
    try dir.writeFile(.{ .sub_path = sub_path, .data = script });

    if (builtin.os.tag != .windows) {
        var file = try dir.openFile(sub_path, .{ .mode = .read_write });
        defer file.close();
        try file.chmod(0o755);
    }
}

fn prependPathEntryAlloc(allocator: std.mem.Allocator, entry: []const u8) ![]u8 {
    var env_map = try process_compat.getEnvMap(allocator);
    defer env_map.deinit();

    const inherited_path = env_map.get("PATH") orelse return allocator.dupe(u8, entry);
    return try std.fmt.allocPrint(allocator, "{s}{c}{s}", .{ entry, fs.path.delimiter, inherited_path });
}

fn runCliWithIsolatedHome(
    allocator: std.mem.Allocator,
    project_root: []const u8,
    home_root: []const u8,
    args: []const []const u8,
) !std.process.RunResult {
    const exe_path = try builtCliPathAlloc(allocator, project_root);
    defer allocator.free(exe_path);

    var argv = std.ArrayList([]const u8).empty;
    defer argv.deinit(allocator);
    try argv.append(allocator, exe_path);
    try argv.appendSlice(allocator, args);

    var env_map = try process_compat.getEnvMap(allocator);
    defer env_map.deinit();
    try env_map.put("HOME", home_root);
    try env_map.put("USERPROFILE", home_root);
    _ = env_map.swapRemove("CODEX_HOME");
    try env_map.put("CODEX_AUTH_SKIP_SERVICE_RECONCILE", "1");
    try env_map.put("CODEX_AUTH_DISABLE_BACKGROUND_ACCOUNT_NAME_REFRESH", "1");

    return try runCapture(allocator, project_root, &env_map, argv.items);
}

fn runCliWithIsolatedHomeAndCodexHome(
    allocator: std.mem.Allocator,
    project_root: []const u8,
    home_root: []const u8,
    codex_home: []const u8,
    args: []const []const u8,
) !std.process.RunResult {
    const exe_path = try builtCliPathAlloc(allocator, project_root);
    defer allocator.free(exe_path);

    var argv = std.ArrayList([]const u8).empty;
    defer argv.deinit(allocator);
    try argv.append(allocator, exe_path);
    try argv.appendSlice(allocator, args);

    var env_map = try process_compat.getEnvMap(allocator);
    defer env_map.deinit();
    try env_map.put("HOME", home_root);
    try env_map.put("USERPROFILE", home_root);
    try env_map.put("CODEX_HOME", codex_home);
    try env_map.put("CODEX_AUTH_SKIP_SERVICE_RECONCILE", "1");
    try env_map.put("CODEX_AUTH_DISABLE_BACKGROUND_ACCOUNT_NAME_REFRESH", "1");

    return try runCapture(allocator, project_root, &env_map, argv.items);
}

fn runCliWithIsolatedHomeAndCodexHomeAndPath(
    allocator: std.mem.Allocator,
    project_root: []const u8,
    home_root: []const u8,
    codex_home: []const u8,
    path_override: []const u8,
    args: []const []const u8,
) !std.process.RunResult {
    const exe_path = try builtCliPathAlloc(allocator, project_root);
    defer allocator.free(exe_path);

    var argv = std.ArrayList([]const u8).empty;
    defer argv.deinit(allocator);
    try argv.append(allocator, exe_path);
    try argv.appendSlice(allocator, args);

    var env_map = try process_compat.getEnvMap(allocator);
    defer env_map.deinit();
    try env_map.put("HOME", home_root);
    try env_map.put("USERPROFILE", home_root);
    try env_map.put("CODEX_HOME", codex_home);
    try env_map.put("PATH", path_override);
    try env_map.put("CODEX_AUTH_SKIP_SERVICE_RECONCILE", "1");
    try env_map.put("CODEX_AUTH_DISABLE_BACKGROUND_ACCOUNT_NAME_REFRESH", "1");

    return try runCapture(allocator, project_root, &env_map, argv.items);
}

fn runCliWithIsolatedHomeAndPath(
    allocator: std.mem.Allocator,
    project_root: []const u8,
    home_root: []const u8,
    path_override: []const u8,
    args: []const []const u8,
) !std.process.RunResult {
    const exe_path = try builtCliPathAlloc(allocator, project_root);
    defer allocator.free(exe_path);

    var argv = std.ArrayList([]const u8).empty;
    defer argv.deinit(allocator);
    try argv.append(allocator, exe_path);
    try argv.appendSlice(allocator, args);

    var env_map = try process_compat.getEnvMap(allocator);
    defer env_map.deinit();
    try env_map.put("HOME", home_root);
    try env_map.put("USERPROFILE", home_root);
    _ = env_map.swapRemove("CODEX_HOME");
    try env_map.put("PATH", path_override);
    try env_map.put("CODEX_AUTH_SKIP_SERVICE_RECONCILE", "1");
    try env_map.put("CODEX_AUTH_DISABLE_BACKGROUND_ACCOUNT_NAME_REFRESH", "1");

    return try runCapture(allocator, project_root, &env_map, argv.items);
}

fn runCliWithIsolatedHomeAndStdin(
    allocator: std.mem.Allocator,
    project_root: []const u8,
    home_root: []const u8,
    args: []const []const u8,
    stdin_data: []const u8,
) !std.process.RunResult {
    const exe_path = try builtCliPathAlloc(allocator, project_root);
    defer allocator.free(exe_path);

    var argv = std.ArrayList([]const u8).empty;
    defer argv.deinit(allocator);
    try argv.append(allocator, exe_path);
    try argv.appendSlice(allocator, args);

    var env_map = try process_compat.getEnvMap(allocator);
    defer env_map.deinit();
    try env_map.put("HOME", home_root);
    try env_map.put("USERPROFILE", home_root);
    _ = env_map.swapRemove("CODEX_HOME");
    try env_map.put("CODEX_AUTH_SKIP_SERVICE_RECONCILE", "1");
    try env_map.put("CODEX_AUTH_DISABLE_BACKGROUND_ACCOUNT_NAME_REFRESH", "1");

    var child = std.process.spawn(fs.io(), .{
        .argv = argv.items,
        .cwd = .{ .path = project_root },
        .environ_map = &env_map,
        .stdin = .pipe,
        .stdout = .pipe,
        .stderr = .pipe,
    }) catch |err| switch (err) {
        error.OutOfMemory => return error.SkipZigTest,
        else => return err,
    };
    defer child.kill(fs.io());

    if (child.stdin) |stdin_pipe| {
        try fs.wrapFile(stdin_pipe).writeAll(stdin_data);
        fs.wrapFile(stdin_pipe).close();
        child.stdin = null;
    }

    var multi_reader_buffer: std.Io.File.MultiReader.Buffer(2) = undefined;
    var multi_reader: std.Io.File.MultiReader = undefined;
    multi_reader.init(allocator, fs.io(), multi_reader_buffer.toStreams(), &.{ child.stdout.?, child.stderr.? });
    defer multi_reader.deinit();

    const stdout_reader = multi_reader.reader(0);
    const stderr_reader = multi_reader.reader(1);

    while (multi_reader.fill(64, .none)) |_| {
        if (stdout_reader.buffered().len > 1024 * 1024) return error.StreamTooLong;
        if (stderr_reader.buffered().len > 1024 * 1024) return error.StreamTooLong;
    } else |err| switch (err) {
        error.EndOfStream => {},
        else => |e| return e,
    }

    try multi_reader.checkAnyError();
    const term = try child.wait(fs.io());

    return .{
        .stdout = try multi_reader.toOwnedSlice(0),
        .stderr = try multi_reader.toOwnedSlice(1),
        .term = term,
    };
}

fn expectSuccess(result: std.process.RunResult) !void {
    switch (result.term) {
        .exited => |code| try std.testing.expectEqual(@as(u8, 0), code),
        else => return error.TestUnexpectedResult,
    }
}

fn expectFailure(result: std.process.RunResult) !void {
    switch (result.term) {
        .exited => |code| try std.testing.expect(code != 0),
        else => return error.TestUnexpectedResult,
    }
}

fn authJsonPathAlloc(allocator: std.mem.Allocator, home_root: []const u8) ![]u8 {
    return fs.path.join(allocator, &[_][]const u8{ home_root, ".codex", "auth.json" });
}

fn codexHomeAlloc(allocator: std.mem.Allocator, home_root: []const u8) ![]u8 {
    return fs.path.join(allocator, &[_][]const u8{ home_root, ".codex" });
}

fn countAuthBackups(dir: fs.Dir, rel_path: []const u8) !usize {
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
    reg.active_account_activated_at_ms = time_compat.milliTimestamp();
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
        .account_name = null,
        .plan = plan,
        .auth_mode = .chatgpt,
        .created_at = time_compat.timestamp(),
        .last_used_at = null,
        .last_usage = null,
        .last_usage_at = null,
        .last_local_rollout = null,
    });
}

test "Scenario: Given device auth login when running login then it forwards the flag and imports the current account" {
    const gpa = std.testing.allocator;
    const project_root = try projectRootAlloc(gpa);
    defer gpa.free(project_root);
    try buildCliBinary(gpa, project_root);

    var tmp = fs.tmpDir(.{});
    defer tmp.cleanup();

    const home_root = try tmp.dir.realpathAlloc(gpa, ".");
    defer gpa.free(home_root);
    try tmp.dir.makePath(".codex");
    try tmp.dir.makePath("fake-bin");

    const expected_email = "device-auth@example.com";
    const fake_auth = try bdd.authJsonWithEmailPlan(gpa, expected_email, "plus");
    defer gpa.free(fake_auth);
    try tmp.dir.writeFile(.{ .sub_path = "fake-auth.json", .data = fake_auth });
    try writeSuccessfulFakeCodex(tmp.dir);

    const fake_bin_path = try fs.path.join(gpa, &[_][]const u8{ home_root, "fake-bin" });
    defer gpa.free(fake_bin_path);
    const path_override = try prependPathEntryAlloc(gpa, fake_bin_path);
    defer gpa.free(path_override);

    const result = try runCliWithIsolatedHomeAndPath(
        gpa,
        project_root,
        home_root,
        path_override,
        &[_][]const u8{ "login", "--device-auth" },
    );
    defer gpa.free(result.stdout);
    defer gpa.free(result.stderr);

    try expectSuccess(result);
    try std.testing.expectEqualStrings("", result.stdout);
    try std.testing.expectEqualStrings("", result.stderr);

    const argv_path = try fs.path.join(gpa, &[_][]const u8{ home_root, "fake-codex-argv.txt" });
    defer gpa.free(argv_path);
    const argv_data = try bdd.readFileAlloc(gpa, argv_path);
    defer gpa.free(argv_data);
    try std.testing.expect(std.mem.indexOf(u8, argv_data, "login --device-auth") != null);

    const codex_home = try codexHomeAlloc(gpa, home_root);
    defer gpa.free(codex_home);
    var loaded = try registry.loadRegistry(gpa, codex_home);
    defer loaded.deinit(gpa);
    try std.testing.expectEqual(@as(usize, 1), loaded.accounts.items.len);
    try std.testing.expect(loaded.active_account_key != null);
    try std.testing.expect(std.mem.eql(u8, loaded.accounts.items[0].email, expected_email));

    const expected_account_key = try bdd.accountKeyForEmailAlloc(gpa, expected_email);
    defer gpa.free(expected_account_key);
    try std.testing.expect(std.mem.eql(u8, loaded.active_account_key.?, expected_account_key));

    const snapshot_path = try registry.accountAuthPath(gpa, codex_home, expected_account_key);
    defer gpa.free(snapshot_path);
    const snapshot_data = try bdd.readFileAlloc(gpa, snapshot_path);
    defer gpa.free(snapshot_data);
    try std.testing.expectEqualStrings(fake_auth, snapshot_data);

    const active_auth_path = try authJsonPathAlloc(gpa, home_root);
    defer gpa.free(active_auth_path);
    const active_auth = try bdd.readFileAlloc(gpa, active_auth_path);
    defer gpa.free(active_auth);
    try std.testing.expectEqualStrings(fake_auth, active_auth);
}

test "Scenario: Given CODEX_HOME override when running login then it stores auth state under the override root" {
    const gpa = std.testing.allocator;
    const project_root = try projectRootAlloc(gpa);
    defer gpa.free(project_root);
    try buildCliBinary(gpa, project_root);

    var tmp = fs.tmpDir(.{});
    defer tmp.cleanup();

    const home_root = try tmp.dir.realpathAlloc(gpa, ".");
    defer gpa.free(home_root);
    try tmp.dir.makePath("custom-codex");
    try tmp.dir.makePath("fake-bin");

    const custom_codex_home = try tmp.dir.realpathAlloc(gpa, "custom-codex");
    defer gpa.free(custom_codex_home);

    const expected_email = "override@example.com";
    const fake_auth = try bdd.authJsonWithEmailPlan(gpa, expected_email, "plus");
    defer gpa.free(fake_auth);
    try tmp.dir.writeFile(.{ .sub_path = "fake-auth.json", .data = fake_auth });
    try writeSuccessfulFakeCodex(tmp.dir);

    const fake_bin_path = try fs.path.join(gpa, &[_][]const u8{ home_root, "fake-bin" });
    defer gpa.free(fake_bin_path);
    const path_override = try prependPathEntryAlloc(gpa, fake_bin_path);
    defer gpa.free(path_override);

    const result = try runCliWithIsolatedHomeAndCodexHomeAndPath(
        gpa,
        project_root,
        home_root,
        custom_codex_home,
        path_override,
        &[_][]const u8{ "login", "--device-auth" },
    );
    defer gpa.free(result.stdout);
    defer gpa.free(result.stderr);

    try expectSuccess(result);

    const custom_auth_path = try registry.activeAuthPath(gpa, custom_codex_home);
    defer gpa.free(custom_auth_path);
    try fs.cwd().access(custom_auth_path, .{});

    const default_auth_path = try authJsonPathAlloc(gpa, home_root);
    defer gpa.free(default_auth_path);
    try std.testing.expectError(error.FileNotFound, fs.cwd().access(default_auth_path, .{}));

    var loaded = try registry.loadRegistry(gpa, custom_codex_home);
    defer loaded.deinit(gpa);
    try std.testing.expectEqual(@as(usize, 1), loaded.accounts.items.len);
    try std.testing.expect(std.mem.eql(u8, loaded.accounts.items[0].email, expected_email));
}

test "Scenario: Given failed device auth login with existing auth json when running login then it forwards the flag and does not mutate the registry" {
    const gpa = std.testing.allocator;
    const project_root = try projectRootAlloc(gpa);
    defer gpa.free(project_root);
    try buildCliBinary(gpa, project_root);

    var tmp = fs.tmpDir(.{});
    defer tmp.cleanup();

    const home_root = try tmp.dir.realpathAlloc(gpa, ".");
    defer gpa.free(home_root);
    try tmp.dir.makePath(".codex");
    try tmp.dir.makePath("fake-bin");

    const existing_auth = try bdd.authJsonWithEmailPlan(gpa, "existing@example.com", "plus");
    defer gpa.free(existing_auth);
    try tmp.dir.writeFile(.{ .sub_path = ".codex/auth.json", .data = existing_auth });
    try writeFailingFakeCodex(tmp.dir, 9);

    const fake_bin_path = try fs.path.join(gpa, &[_][]const u8{ home_root, "fake-bin" });
    defer gpa.free(fake_bin_path);
    const path_override = try prependPathEntryAlloc(gpa, fake_bin_path);
    defer gpa.free(path_override);

    const result = try runCliWithIsolatedHomeAndPath(
        gpa,
        project_root,
        home_root,
        path_override,
        &[_][]const u8{ "login", "--device-auth" },
    );
    defer gpa.free(result.stdout);
    defer gpa.free(result.stderr);

    try expectFailure(result);
    try std.testing.expectEqualStrings("", result.stdout);
    try std.testing.expectEqualStrings("", result.stderr);

    const argv_path = try fs.path.join(gpa, &[_][]const u8{ home_root, "fake-codex-argv.txt" });
    defer gpa.free(argv_path);
    const argv_data = try bdd.readFileAlloc(gpa, argv_path);
    defer gpa.free(argv_data);
    try std.testing.expect(std.mem.indexOf(u8, argv_data, "login --device-auth") != null);

    try std.testing.expectError(error.FileNotFound, tmp.dir.openFile(".codex/accounts/registry.json", .{}));

    const active_auth_path = try authJsonPathAlloc(gpa, home_root);
    defer gpa.free(active_auth_path);
    const active_auth = try bdd.readFileAlloc(gpa, active_auth_path);
    defer gpa.free(active_auth);
    try std.testing.expectEqualStrings(existing_auth, active_auth);
}

// This simulates first-time use on v0.2 when ~/.codex/auth.json already exists
// but ~/.codex/accounts has not been created yet.
test "Scenario: Given first-time use on v0.2 with an existing auth.json and no accounts directory when list runs then cli auto-imports and stays usable" {
    const gpa = std.testing.allocator;
    const project_root = try projectRootAlloc(gpa);
    defer gpa.free(project_root);
    try buildCliBinary(gpa, project_root);

    var tmp = fs.tmpDir(.{});
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

    var tmp = fs.tmpDir(.{});
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
    const legacy_rel = try fs.path.join(gpa, &[_][]const u8{ ".codex", "accounts", legacy_name });
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
    try std.testing.expect(
        std.mem.indexOf(u8, result.stdout, email) != null or
            std.mem.indexOf(u8, result.stdout, "legacy") != null,
    );

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
    var migrated = try fs.cwd().openFile(migrated_path, .{});
    migrated.close();
    try std.testing.expectError(error.FileNotFound, tmp.dir.openFile(legacy_rel, .{}));
}

test "Scenario: Given repeated single-file import when running import then first import reports imported and second reports updated" {
    const gpa = std.testing.allocator;
    const project_root = try projectRootAlloc(gpa);
    defer gpa.free(project_root);
    try buildCliBinary(gpa, project_root);

    var tmp = fs.tmpDir(.{});
    defer tmp.cleanup();

    const home_root = try tmp.dir.realpathAlloc(gpa, ".");
    defer gpa.free(home_root);
    try tmp.dir.makePath("imports");

    const rel_path = "imports/token_ryan.taylor.alpha@email.com.json";
    const auth_json = try bdd.authJsonWithEmailPlan(gpa, "ryan.taylor.alpha@email.com", "plus");
    defer gpa.free(auth_json);
    try tmp.dir.writeFile(.{ .sub_path = rel_path, .data = auth_json });

    const import_path = try fs.path.join(gpa, &[_][]const u8{ home_root, rel_path });
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

    var tmp = fs.tmpDir(.{});
    defer tmp.cleanup();

    const home_root = try tmp.dir.realpathAlloc(gpa, ".");
    defer gpa.free(home_root);
    try tmp.dir.makePath("imports");

    const rel_path = "imports/token_bob.wilson.alpha@email.com.json";
    const auth_json = try bdd.authJsonWithoutEmail(gpa);
    defer gpa.free(auth_json);
    try tmp.dir.writeFile(.{ .sub_path = rel_path, .data = auth_json });

    const import_path = try fs.path.join(gpa, &[_][]const u8{ home_root, rel_path });
    defer gpa.free(import_path);

    const result = try runCliWithIsolatedHome(gpa, project_root, home_root, &[_][]const u8{ "import", import_path });
    defer gpa.free(result.stdout);
    defer gpa.free(result.stderr);

    try expectFailure(result);
    try std.testing.expectEqualStrings("Import Summary: 0 imported, 1 skipped\n", result.stdout);
    try std.testing.expect(std.mem.indexOf(u8, result.stderr, "  ✗ skipped   token_bob.wilson.alpha@email.com: MissingEmail\n") != null);
}

test "Scenario: Given purge with no recoverable active auth when running import then it activates the first rebuilt account and backs up auth json" {
    const gpa = std.testing.allocator;
    const project_root = try projectRootAlloc(gpa);
    defer gpa.free(project_root);
    try buildCliBinary(gpa, project_root);

    var tmp = fs.tmpDir(.{});
    defer tmp.cleanup();

    const home_root = try tmp.dir.realpathAlloc(gpa, ".");
    defer gpa.free(home_root);
    try tmp.dir.makePath(".codex/accounts");

    const codex_home = try codexHomeAlloc(gpa, home_root);
    defer gpa.free(codex_home);

    const zed_auth = try bdd.authJsonWithEmailPlan(gpa, "zed@example.com", "team");
    defer gpa.free(zed_auth);
    const zed_key = try bdd.accountKeyForEmailAlloc(gpa, "zed@example.com");
    defer gpa.free(zed_key);
    const zed_snapshot_path = try registry.accountAuthPath(gpa, codex_home, zed_key);
    defer gpa.free(zed_snapshot_path);
    try fs.cwd().writeFile(.{ .sub_path = zed_snapshot_path, .data = zed_auth });

    const alpha_auth = try bdd.authJsonWithEmailPlan(gpa, "alpha@example.com", "plus");
    defer gpa.free(alpha_auth);
    const alpha_key = try bdd.accountKeyForEmailAlloc(gpa, "alpha@example.com");
    defer gpa.free(alpha_key);
    const alpha_snapshot_path = try registry.accountAuthPath(gpa, codex_home, alpha_key);
    defer gpa.free(alpha_snapshot_path);
    try fs.cwd().writeFile(.{ .sub_path = alpha_snapshot_path, .data = alpha_auth });

    const stale_auth = "{\"broken\":true}";
    try tmp.dir.writeFile(.{ .sub_path = ".codex/auth.json", .data = stale_auth });

    const result = try runCliWithIsolatedHome(gpa, project_root, home_root, &[_][]const u8{ "import", "--purge" });
    defer gpa.free(result.stdout);
    defer gpa.free(result.stderr);

    try expectSuccess(result);
    try std.testing.expect(std.mem.indexOf(u8, result.stdout, "Import Summary: 2 imported, 0 updated, 0 skipped (total 2 files)\n") != null);
    try std.testing.expectEqualStrings("", result.stderr);

    const active_auth_path = try authJsonPathAlloc(gpa, home_root);
    defer gpa.free(active_auth_path);
    const active_auth = try bdd.readFileAlloc(gpa, active_auth_path);
    defer gpa.free(active_auth);
    try std.testing.expectEqualStrings(alpha_auth, active_auth);

    try std.testing.expectEqual(@as(usize, 1), try countAuthBackups(tmp.dir, ".codex/accounts"));

    var backup_name: ?[]u8 = null;
    defer if (backup_name) |name| gpa.free(name);

    var accounts = try tmp.dir.openDir(".codex/accounts", .{ .iterate = true });
    defer accounts.close();
    var it = accounts.iterate();
    while (try it.next()) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.startsWith(u8, entry.name, "auth.json.bak.")) continue;
        backup_name = try gpa.dupe(u8, entry.name);
        break;
    }
    try std.testing.expect(backup_name != null);

    const backup_rel = try fs.path.join(gpa, &[_][]const u8{ ".codex", "accounts", backup_name.? });
    defer gpa.free(backup_rel);
    var backup_file = try tmp.dir.openFile(backup_rel, .{});
    defer backup_file.close();
    const backup_contents = try backup_file.readToEndAlloc(gpa, 10 * 1024 * 1024);
    defer gpa.free(backup_contents);
    try std.testing.expectEqualStrings(stale_auth, backup_contents);

    var loaded = try registry.loadRegistry(gpa, codex_home);
    defer loaded.deinit(gpa);
    try std.testing.expect(loaded.active_account_key != null);
    try std.testing.expect(std.mem.eql(u8, loaded.active_account_key.?, alpha_key));
}

test "Scenario: Given directory import with new updated and invalid files when running import then stdout and stderr split the report" {
    const gpa = std.testing.allocator;
    const project_root = try projectRootAlloc(gpa);
    defer gpa.free(project_root);
    try buildCliBinary(gpa, project_root);

    var tmp = fs.tmpDir(.{});
    defer tmp.cleanup();

    const home_root = try tmp.dir.realpathAlloc(gpa, ".");
    defer gpa.free(home_root);
    try tmp.dir.makePath("imports");

    const existing_rel = "imports/token_jane.smith.alpha@email.com.json";
    const existing_auth = try bdd.authJsonWithEmailPlan(gpa, "jane.smith.alpha@email.com", "team");
    defer gpa.free(existing_auth);
    try tmp.dir.writeFile(.{ .sub_path = existing_rel, .data = existing_auth });

    const existing_path = try fs.path.join(gpa, &[_][]const u8{ home_root, existing_rel });
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

    const imports_path = try fs.path.join(gpa, &[_][]const u8{ home_root, "imports" });
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

    var tmp = fs.tmpDir(.{});
    defer tmp.cleanup();

    const home_root = try tmp.dir.realpathAlloc(gpa, ".");
    defer gpa.free(home_root);
    try tmp.dir.makePath("imports");

    const valid_auth = try bdd.authJsonWithEmailPlan(gpa, "still-imported@example.com", "plus");
    defer gpa.free(valid_auth);
    try tmp.dir.writeFile(.{ .sub_path = "imports/valid.json", .data = valid_auth });
    try tmp.dir.writeFile(.{ .sub_path = "imports/empty.json", .data = "" });

    const imports_path = try fs.path.join(gpa, &[_][]const u8{ home_root, "imports" });
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

    var tmp = fs.tmpDir(.{});
    defer tmp.cleanup();

    const home_root = try tmp.dir.realpathAlloc(gpa, ".");
    defer gpa.free(home_root);
    try tmp.dir.makePath("imports");

    const valid_auth = try bdd.authJsonWithEmailPlan(gpa, "symlink-survivor@example.com", "plus");
    defer gpa.free(valid_auth);
    try tmp.dir.writeFile(.{ .sub_path = "imports/valid.json", .data = valid_auth });
    try tmp.dir.symLink("missing.json", "imports/broken.json", .{});

    const imports_path = try fs.path.join(gpa, &[_][]const u8{ home_root, "imports" });
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

    var tmp = fs.tmpDir(.{});
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

    var tmp = fs.tmpDir(.{});
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

    var tmp = fs.tmpDir(.{});
    defer tmp.cleanup();

    const home_root = try tmp.dir.realpathAlloc(gpa, ".");
    defer gpa.free(home_root);
    try tmp.dir.makePath("imports");

    const cpa_json = try bdd.cpaJsonWithEmailPlan(gpa, "single-file-cpa@example.com", "business");
    defer gpa.free(cpa_json);
    try tmp.dir.writeFile(.{ .sub_path = "imports/cpa.json", .data = cpa_json });

    const import_path = try fs.path.join(gpa, &[_][]const u8{ home_root, "imports", "cpa.json" });
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

test "Scenario: Given default api usage when rendering help then the api enable risk note stays in stdout" {
    const gpa = std.testing.allocator;
    const project_root = try projectRootAlloc(gpa);
    defer gpa.free(project_root);
    try buildCliBinary(gpa, project_root);

    var tmp = fs.tmpDir(.{});
    defer tmp.cleanup();

    const home_root = try tmp.dir.realpathAlloc(gpa, ".");
    defer gpa.free(home_root);

    const result = try runCliWithIsolatedHome(gpa, project_root, home_root, &[_][]const u8{});
    defer gpa.free(result.stdout);
    defer gpa.free(result.stderr);

    try expectSuccess(result);
    try std.testing.expect(std.mem.indexOf(u8, result.stdout, "codex-auth") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.stdout, "Usage API: ON (api)") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.stdout, "Account API: ON") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.stdout, "`config api enable` may trigger OpenAI account restrictions or suspension in some environments.") != null);
    try std.testing.expectEqualStrings("", result.stderr);
}

test "Scenario: Given switch query with a direct local match when running switch then it does not require api refresh executables" {
    const gpa = std.testing.allocator;
    const project_root = try projectRootAlloc(gpa);
    defer gpa.free(project_root);
    try buildCliBinary(gpa, project_root);

    var tmp = fs.tmpDir(.{});
    defer tmp.cleanup();

    const home_root = try tmp.dir.realpathAlloc(gpa, ".");
    defer gpa.free(home_root);

    try seedRegistryWithAccounts(gpa, home_root, "active@example.com", &[_]SeedAccount{
        .{ .email = "active@example.com", .alias = "active" },
        .{ .email = "backup@example.com", .alias = "backup" },
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

    const active_auth = try bdd.authJsonWithEmailPlan(gpa, "active@example.com", "team");
    defer gpa.free(active_auth);
    const backup_auth = try bdd.authJsonWithEmailPlan(gpa, "backup@example.com", "plus");
    defer gpa.free(backup_auth);

    try tmp.dir.writeFile(.{ .sub_path = ".codex/auth.json", .data = active_auth });
    try fs.cwd().writeFile(.{ .sub_path = active_snapshot_path, .data = active_auth });
    try fs.cwd().writeFile(.{ .sub_path = backup_snapshot_path, .data = backup_auth });

    try tmp.dir.makePath("empty-bin");
    const empty_path = try tmp.dir.realpathAlloc(gpa, "empty-bin");
    defer gpa.free(empty_path);

    const result = try runCliWithIsolatedHomeAndPath(
        gpa,
        project_root,
        home_root,
        empty_path,
        &[_][]const u8{ "switch", "backup@" },
    );
    defer gpa.free(result.stdout);
    defer gpa.free(result.stderr);

    try expectSuccess(result);
    try std.testing.expectEqualStrings("", result.stdout);
    try std.testing.expectEqualStrings("", result.stderr);

    const auth_after = try bdd.readFileAlloc(gpa, active_auth_path);
    defer gpa.free(auth_after);
    try std.testing.expectEqualStrings(backup_auth, auth_after);

    var loaded = try registry.loadRegistry(gpa, codex_home);
    defer loaded.deinit(gpa);
    try std.testing.expect(loaded.active_account_key != null);
    try std.testing.expect(std.mem.eql(u8, loaded.active_account_key.?, backup_key));
}

test "Scenario: Given remove query with one match when running remove then it deletes immediately and prints a summary" {
    const gpa = std.testing.allocator;
    const project_root = try projectRootAlloc(gpa);
    defer gpa.free(project_root);
    try buildCliBinary(gpa, project_root);

    var tmp = fs.tmpDir(.{});
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

    try fs.cwd().writeFile(.{ .sub_path = removed_snapshot_path, .data = removed_auth });
    try fs.cwd().writeFile(.{ .sub_path = keeper_snapshot_path, .data = keeper_auth });
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
    try std.testing.expectError(error.FileNotFound, fs.cwd().openFile(removed_snapshot_path, .{}));
    var keeper_snapshot = try fs.cwd().openFile(keeper_snapshot_path, .{});
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

    var tmp = fs.tmpDir(.{});
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
    try fs.cwd().writeFile(.{ .sub_path = active_snapshot_path, .data = active_auth });
    try fs.cwd().writeFile(.{ .sub_path = backup_snapshot_path, .data = backup_auth });

    const result = try runCliWithIsolatedHomeAndStdin(gpa, project_root, home_root, &[_][]const u8{ "remove", "active@" }, "");
    defer gpa.free(result.stdout);
    defer gpa.free(result.stderr);

    try expectSuccess(result);
    try std.testing.expectEqualStrings("Removed 1 account(s): active@example.com\n", result.stdout);
    try std.testing.expectEqualStrings("", result.stderr);

    const replaced_auth = try bdd.readFileAlloc(gpa, active_auth_path);
    defer gpa.free(replaced_auth);
    try std.testing.expectEqualStrings(backup_auth, replaced_auth);
    try std.testing.expectError(error.FileNotFound, fs.cwd().openFile(active_snapshot_path, .{}));
    try std.testing.expectEqual(@as(usize, 0), try countAuthBackups(tmp.dir, ".codex/accounts"));
}

test "Scenario: Given active account removal with missing auth json when running remove then replacement auth is recreated" {
    const gpa = std.testing.allocator;
    const project_root = try projectRootAlloc(gpa);
    defer gpa.free(project_root);
    try buildCliBinary(gpa, project_root);

    var tmp = fs.tmpDir(.{});
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
    try fs.cwd().writeFile(.{ .sub_path = active_snapshot_path, .data = active_auth });
    try fs.cwd().writeFile(.{ .sub_path = backup_snapshot_path, .data = backup_auth });

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

    var tmp = fs.tmpDir(.{});
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
    try fs.cwd().writeFile(.{ .sub_path = active_snapshot_path, .data = active_auth });
    try fs.cwd().writeFile(.{ .sub_path = backup_snapshot_path, .data = backup_auth });

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

    var tmp = fs.tmpDir(.{});
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
    try fs.cwd().writeFile(.{ .sub_path = alpha_snapshot_path, .data = alpha_auth });
    try fs.cwd().writeFile(.{ .sub_path = beta_snapshot_path, .data = beta_auth });

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

    var tmp = fs.tmpDir(.{});
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

    var tmp = fs.tmpDir(.{});
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

    var tmp = fs.tmpDir(.{});
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
            "- alpha@example.com / team-a\n" ++
            "- beta@example.com / team-b\n" ++
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

    var tmp = fs.tmpDir(.{});
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
    reg.active_account_activated_at_ms = time_compat.milliTimestamp();
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

    var tmp = fs.tmpDir(.{});
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
    try fs.cwd().writeFile(.{ .sub_path = snapshot_path, .data = solo_auth });

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
    try std.testing.expectError(error.FileNotFound, fs.cwd().openFile(active_auth_path, .{}));
    try std.testing.expectError(error.FileNotFound, fs.cwd().openFile(snapshot_path, .{}));
}

test "Scenario: Given non-tty stdin when running interactive remove then it falls back to the numbered selector" {
    const gpa = std.testing.allocator;
    const project_root = try projectRootAlloc(gpa);
    defer gpa.free(project_root);
    try buildCliBinary(gpa, project_root);

    var tmp = fs.tmpDir(.{});
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

    var tmp = fs.tmpDir(.{});
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
    try std.testing.expectError(error.FileNotFound, fs.cwd().openFile(active_auth_path, .{}));
}

test "Scenario: Given remove all with malformed auth json when running remove then registry is cleared but auth json is preserved" {
    const gpa = std.testing.allocator;
    const project_root = try projectRootAlloc(gpa);
    defer gpa.free(project_root);
    try buildCliBinary(gpa, project_root);

    var tmp = fs.tmpDir(.{});
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

    var tmp = fs.tmpDir(.{});
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
    try std.testing.expectError(error.FileNotFound, fs.cwd().openFile(active_auth_path, .{}));
}

test "Scenario: Given remove all with tracked auth json and stale active key when running remove then auth json is deleted too" {
    const gpa = std.testing.allocator;
    const project_root = try projectRootAlloc(gpa);
    defer gpa.free(project_root);
    try buildCliBinary(gpa, project_root);

    var tmp = fs.tmpDir(.{});
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
    reg.active_account_activated_at_ms = time_compat.milliTimestamp();
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
    try std.testing.expectError(error.FileNotFound, fs.cwd().openFile(active_auth_path, .{}));
}

test "Scenario: Given unsynced active auth when removing the active registry account then auth json is preserved" {
    const gpa = std.testing.allocator;
    const project_root = try projectRootAlloc(gpa);
    defer gpa.free(project_root);
    try buildCliBinary(gpa, project_root);

    var tmp = fs.tmpDir(.{});
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
    try fs.cwd().writeFile(.{ .sub_path = active_snapshot_path, .data = active_auth });
    try fs.cwd().writeFile(.{ .sub_path = backup_snapshot_path, .data = backup_auth });

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

    var tmp = fs.tmpDir(.{});
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
    try fs.cwd().writeFile(.{ .sub_path = active_snapshot_path, .data = active_auth });
    try fs.cwd().writeFile(.{ .sub_path = backup_snapshot_path, .data = backup_auth });

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

test "Scenario: Given default api usage when rendering status then no warning is printed" {
    const gpa = std.testing.allocator;
    const project_root = try projectRootAlloc(gpa);
    defer gpa.free(project_root);
    try buildCliBinary(gpa, project_root);

    var tmp = fs.tmpDir(.{});
    defer tmp.cleanup();

    const home_root = try tmp.dir.realpathAlloc(gpa, ".");
    defer gpa.free(home_root);

    const result = try runCliWithIsolatedHome(gpa, project_root, home_root, &[_][]const u8{"status"});
    defer gpa.free(result.stdout);
    defer gpa.free(result.stderr);

    try expectSuccess(result);
    try std.testing.expect(std.mem.indexOf(u8, result.stdout, "auto-switch: OFF") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.stdout, "usage: api") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.stdout, "account: api") != null);
    try std.testing.expectEqualStrings("", result.stderr);
}

test "Scenario: Given default api usage when listing accounts then no warning is printed" {
    const gpa = std.testing.allocator;
    const project_root = try projectRootAlloc(gpa);
    defer gpa.free(project_root);
    try buildCliBinary(gpa, project_root);

    var tmp = fs.tmpDir(.{});
    defer tmp.cleanup();

    const home_root = try tmp.dir.realpathAlloc(gpa, ".");
    defer gpa.free(home_root);

    const result = try runCliWithIsolatedHome(gpa, project_root, home_root, &[_][]const u8{"list"});
    defer gpa.free(result.stdout);
    defer gpa.free(result.stderr);

    try expectSuccess(result);
    try std.testing.expect(std.mem.indexOf(u8, result.stdout, "ACCOUNT") != null);
    try std.testing.expectEqualStrings("", result.stderr);
}

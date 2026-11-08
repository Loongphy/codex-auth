const std = @import("std");
const builtin = @import("builtin");
const daemon = @import("codex_auth").workflows.codex_daemon;
const fs = @import("codex_auth").core.compat_fs;
const runtime = @import("codex_auth").core.runtime;
const fake = @import("support/codex_daemon.zig");

/// A managed executable placeholder with no control endpoint: enough for
/// Client.init to resolve the helper while every probe still reports
/// not_running, so no lifecycle command can run.
fn installStubExecutable(dir: fs.Dir) !void {
    const name = if (builtin.target.os.tag == .windows) "codex.exe" else "codex";
    const sub_path = try fs.path.join(std.testing.allocator, &.{ "packages", "app-server-daemon", "current", "bin", name });
    defer std.testing.allocator.free(sub_path);
    try dir.makePath("packages/app-server-daemon/current/bin");
    try dir.writeFile(.{ .sub_path = sub_path, .data = "stub" });
    if (builtin.target.os.tag == .windows) return;
    var file = try dir.openFile(sub_path, .{ .mode = .read_write });
    defer file.close();
    try file.chmod(0o700);
}

test "Scenario: Given a missing daemon endpoint then lifecycle commands are not invoked" {
    var tmp = fs.tmpDir(.{});
    defer tmp.cleanup();
    try installStubExecutable(tmp.dir);
    const home = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(home);
    var client = try daemon.Client.init(std.testing.allocator, home);
    defer client.deinit();
    try std.testing.expectEqual(daemon.Outcome.not_running, try client.restart(100));
    try std.testing.expectError(error.FileNotFound, tmp.dir.openFile("lifecycle-calls", .{}));
}

test "Scenario: Given a responsive daemon then explicit restart forwards the selected home exactly once" {
    if (builtin.target.os.tag == .windows) return error.SkipZigTest;
    var tmp = fs.tmpDir(.{});
    defer tmp.cleanup();
    try fake.install(tmp.dir, fake.succeed);
    const home = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(home);
    var client = try daemon.Client.init(std.testing.allocator, home);
    defer client.deinit();
    try std.testing.expectEqual(daemon.Outcome.restarted, try client.restart(1_000));
    const calls = try fake.read(tmp.dir, "lifecycle-calls");
    defer std.testing.allocator.free(calls);
    try std.testing.expectEqualStrings("version\nrestart\n", calls);
    const forwarded = try fake.read(tmp.dir, "restarted-home");
    defer std.testing.allocator.free(forwarded);
    try std.testing.expectEqualStrings(home, std.mem.trimEnd(u8, forwarded, "\n"));
}

test "Scenario: Given failed or malformed daemon probes then explicit restart remains indeterminate" {
    if (builtin.target.os.tag == .windows) return error.SkipZigTest;
    for ([_][]const u8{ "exit 1\n", "printf '%s\\n' '{}'\n", "printf '%s\\n' '{\"status\":\"notRunning\"}'\n" }) |body| {
        var tmp = fs.tmpDir(.{});
        defer tmp.cleanup();
        try fake.install(tmp.dir, body);
        const home = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
        defer std.testing.allocator.free(home);
        var client = try daemon.Client.init(std.testing.allocator, home);
        defer client.deinit();
        try std.testing.expectEqual(daemon.Outcome.unknown, try client.restart(100));
        const calls = try fake.read(tmp.dir, "lifecycle-calls");
        defer std.testing.allocator.free(calls);
        try std.testing.expectEqualStrings("version\n", calls);
    }
}

test "Scenario: Given a codex daemon that reloads auth then ensure reloads without restarting" {
    if (builtin.target.os.tag == .windows) return error.SkipZigTest;
    var tmp = fs.tmpDir(.{});
    defer tmp.cleanup();
    try fake.install(tmp.dir, fake.reload_changed);
    const home = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(home);
    var client = try daemon.Client.init(std.testing.allocator, home);
    defer client.deinit();
    try std.testing.expectEqual(daemon.Outcome.reloaded, try client.ensure(1_000));
    const calls = try fake.read(tmp.dir, "lifecycle-calls");
    defer std.testing.allocator.free(calls);
    try std.testing.expectEqualStrings("version\nreload-auth\n", calls);
    try std.testing.expectError(error.FileNotFound, tmp.dir.openFile("restarted-home", .{}));
}

test "Scenario: Given an upstream daemon without reload support then ensure falls back to restart" {
    if (builtin.target.os.tag == .windows) return error.SkipZigTest;
    var tmp = fs.tmpDir(.{});
    defer tmp.cleanup();
    try fake.install(tmp.dir, fake.reload_unsupported_succeed);
    const home = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(home);
    var client = try daemon.Client.init(std.testing.allocator, home);
    defer client.deinit();
    try std.testing.expectEqual(daemon.Outcome.restarted, try client.ensure(1_000));
    const calls = try fake.read(tmp.dir, "lifecycle-calls");
    defer std.testing.allocator.free(calls);
    try std.testing.expectEqualStrings("version\nreload-auth\nversion\nrestart\n", calls);
    const forwarded = try fake.read(tmp.dir, "restarted-home");
    defer std.testing.allocator.free(forwarded);
    try std.testing.expect(forwarded.len > 0);
}

test "Scenario: Given a busy daemon then the reload defers without restarting" {
    if (builtin.target.os.tag == .windows) return error.SkipZigTest;
    var tmp = fs.tmpDir(.{});
    defer tmp.cleanup();
    try fake.install(tmp.dir, fake.reload_busy);
    const home = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(home);
    var client = try daemon.Client.init(std.testing.allocator, home);
    defer client.deinit();
    try std.testing.expectEqual(daemon.Outcome.deferred, try client.ensure(1_000));
    const calls = try fake.read(tmp.dir, "lifecycle-calls");
    defer std.testing.allocator.free(calls);
    try std.testing.expectEqualStrings("version\nreload-auth\n", calls);
    try std.testing.expectError(error.FileNotFound, tmp.dir.openFile("restarted-home", .{}));
}

test "Scenario: Given a daemon that fails the reload then ensure reports the failure without restarting" {
    if (builtin.target.os.tag == .windows) return error.SkipZigTest;
    var tmp = fs.tmpDir(.{});
    defer tmp.cleanup();
    try fake.install(tmp.dir, fake.reload_failed_succeed);
    const home = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(home);
    var client = try daemon.Client.init(std.testing.allocator, home);
    defer client.deinit();
    try std.testing.expectEqual(daemon.Outcome.reload_failed, try client.ensure(1_000));
    const calls = try fake.read(tmp.dir, "lifecycle-calls");
    defer std.testing.allocator.free(calls);
    try std.testing.expectEqualStrings("version\nreload-auth\n", calls);
    try std.testing.expectError(error.FileNotFound, tmp.dir.openFile("restarted-home", .{}));
}

test "Scenario: Given a daemon that fails the reload then the default reload reports the failure" {
    if (builtin.target.os.tag == .windows) return error.SkipZigTest;
    var tmp = fs.tmpDir(.{});
    defer tmp.cleanup();
    try fake.install(tmp.dir, fake.reload_failed_succeed);
    const home = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(home);
    var client = try daemon.Client.init(std.testing.allocator, home);
    defer client.deinit();
    try std.testing.expectEqual(daemon.Outcome.reload_failed, try client.reload());
    const calls = try fake.read(tmp.dir, "lifecycle-calls");
    defer std.testing.allocator.free(calls);
    try std.testing.expectEqualStrings("version\nreload-auth\n", calls);
    try std.testing.expectError(error.FileNotFound, tmp.dir.openFile("restarted-home", .{}));
}

test "Scenario: Given a slow reload then ensure reports unconfirmed without restarting" {
    if (builtin.target.os.tag == .windows) return error.SkipZigTest;
    var tmp = fs.tmpDir(.{});
    defer tmp.cleanup();
    try fake.install(tmp.dir, fake.reload_slow);
    const home = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(home);
    var client = try daemon.Client.init(std.testing.allocator, home);
    defer client.deinit();
    client.reload_timeout_ms = 300;
    try std.testing.expectEqual(daemon.Outcome.unknown, try client.ensure(1_000));
    const calls = try fake.read(tmp.dir, "lifecycle-calls");
    defer std.testing.allocator.free(calls);
    try std.testing.expectEqualStrings("version\nreload-auth\n", calls);
    try std.testing.expectError(error.FileNotFound, tmp.dir.openFile("restarted-home", .{}));
}

test "Scenario: Given a missing daemon endpoint then the default reload stays a no-op" {
    var tmp = fs.tmpDir(.{});
    defer tmp.cleanup();
    try installStubExecutable(tmp.dir);
    const home = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(home);
    var client = try daemon.Client.init(std.testing.allocator, home);
    defer client.deinit();
    try std.testing.expectEqual(daemon.Outcome.not_running, try client.reload());
    try std.testing.expectError(error.FileNotFound, tmp.dir.openFile("lifecycle-calls", .{}));
}

test "Scenario: Given a codex daemon that reloads auth then the default reload applies it" {
    if (builtin.target.os.tag == .windows) return error.SkipZigTest;
    var tmp = fs.tmpDir(.{});
    defer tmp.cleanup();
    try fake.install(tmp.dir, fake.reload_changed);
    const home = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(home);
    var client = try daemon.Client.init(std.testing.allocator, home);
    defer client.deinit();
    try std.testing.expectEqual(daemon.Outcome.reloaded, try client.reload());
    const calls = try fake.read(tmp.dir, "lifecycle-calls");
    defer std.testing.allocator.free(calls);
    try std.testing.expectEqualStrings("version\nreload-auth\n", calls);
    try std.testing.expectError(error.FileNotFound, tmp.dir.openFile("restarted-home", .{}));
}

test "Scenario: Given a busy daemon then the default reload defers without restarting" {
    if (builtin.target.os.tag == .windows) return error.SkipZigTest;
    var tmp = fs.tmpDir(.{});
    defer tmp.cleanup();
    try fake.install(tmp.dir, fake.reload_busy);
    const home = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(home);
    var client = try daemon.Client.init(std.testing.allocator, home);
    defer client.deinit();
    try std.testing.expectEqual(daemon.Outcome.deferred, try client.reload());
    const calls = try fake.read(tmp.dir, "lifecycle-calls");
    defer std.testing.allocator.free(calls);
    try std.testing.expectEqualStrings("version\nreload-auth\n", calls);
    try std.testing.expectError(error.FileNotFound, tmp.dir.openFile("restarted-home", .{}));
}

test "Scenario: Given an upstream daemon without reload support then the default reload never restarts" {
    if (builtin.target.os.tag == .windows) return error.SkipZigTest;
    var tmp = fs.tmpDir(.{});
    defer tmp.cleanup();
    try fake.install(tmp.dir, fake.reload_unsupported_succeed);
    const home = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(home);
    var client = try daemon.Client.init(std.testing.allocator, home);
    defer client.deinit();
    try std.testing.expectEqual(daemon.Outcome.running, try client.reload());
    const calls = try fake.read(tmp.dir, "lifecycle-calls");
    defer std.testing.allocator.free(calls);
    try std.testing.expectEqualStrings("version\nreload-auth\n", calls);
    try std.testing.expectError(error.FileNotFound, tmp.dir.openFile("restarted-home", .{}));
}

test "Scenario: Given failed or malformed daemon probes then the default reload stays indeterminate" {
    if (builtin.target.os.tag == .windows) return error.SkipZigTest;
    for ([_][]const u8{ "exit 1\n", "printf '%s\\n' '{}'\n", "printf '%s\\n' '{\"status\":\"notRunning\"}'\n" }) |body| {
        var tmp = fs.tmpDir(.{});
        defer tmp.cleanup();
        try fake.install(tmp.dir, body);
        const home = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
        defer std.testing.allocator.free(home);
        var client = try daemon.Client.init(std.testing.allocator, home);
        defer client.deinit();
        try std.testing.expectEqual(daemon.Outcome.unknown, try client.reload());
        const calls = try fake.read(tmp.dir, "lifecycle-calls");
        defer std.testing.allocator.free(calls);
        try std.testing.expectEqualStrings("version\n", calls);
    }
}

test "Scenario: Given a restart failure then retry makes another explicit restart attempt" {
    if (builtin.target.os.tag == .windows) return error.SkipZigTest;
    var tmp = fs.tmpDir(.{});
    defer tmp.cleanup();
    try fake.install(tmp.dir, fake.running ++ "exit 42\n");
    const home = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(home);
    var client = try daemon.Client.init(std.testing.allocator, home);
    defer client.deinit();
    try std.testing.expectEqual(daemon.Outcome.restart_failed, try client.restart(1_000));
    try std.testing.expectEqual(daemon.Outcome.restart_failed, try client.restart(1_000));
    const calls = try fake.read(tmp.dir, "lifecycle-calls");
    defer std.testing.allocator.free(calls);
    try std.testing.expectEqualStrings("version\nrestart\nversion\nrestart\n", calls);
}

test "Scenario: Given a restart helper that stalls with open or closed pipes then timeout kills and reaps only the helper" {
    if (builtin.target.os.tag == .windows) return error.SkipZigTest;
    for ([_][]const u8{ "", "exec 1>&- 2>&-\n" }) |close_pipes| {
        var tmp = fs.tmpDir(.{});
        defer tmp.cleanup();
        const body = try std.mem.concat(std.testing.allocator, u8, &.{ fake.running, "printf '%s' \"$$\" > \"$CODEX_HOME/helper-pid\"\n", close_pipes, "while :; do :; done\n" });
        defer std.testing.allocator.free(body);
        try fake.install(tmp.dir, body);
        const home = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
        defer std.testing.allocator.free(home);
        var client = try daemon.Client.init(std.testing.allocator, home);
        defer client.deinit();
        const started = std.Io.Timestamp.now(runtime.io(), .awake);
        try std.testing.expectEqual(daemon.Outcome.timed_out, try client.restart(200));
        try std.testing.expect(started.untilNow(runtime.io(), .awake).toMilliseconds() < 3_000);
        const pid_bytes = try fake.read(tmp.dir, "helper-pid");
        defer std.testing.allocator.free(pid_bytes);
        const pid = try std.fmt.parseInt(std.posix.pid_t, pid_bytes, 10);
        try std.testing.expectError(error.ProcessNotFound, std.posix.kill(pid, .CONT));
        var status: c_int = 0;
        try std.testing.expectEqual(@as(std.posix.pid_t, -1), std.c.waitpid(pid, &status, std.c.W.NOHANG));
        try std.testing.expectEqual(std.posix.E.CHILD, std.posix.errno(-1));
    }
}

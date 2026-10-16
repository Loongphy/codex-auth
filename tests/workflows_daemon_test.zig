const std = @import("std");
const builtin = @import("builtin");
const daemon = @import("codex_auth").workflows.codex_daemon;
const fs = @import("codex_auth").core.compat_fs;
const runtime = @import("codex_auth").core.runtime;
const fake = @import("support/codex_daemon.zig");

test "Scenario: Given a missing daemon endpoint then lifecycle commands are not invoked" {
    var tmp = fs.tmpDir(.{});
    defer tmp.cleanup();
    const home = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(home);
    var client = try daemon.Client.init(std.testing.allocator, home);
    defer client.deinit();
    try std.testing.expectEqual(daemon.Outcome.not_running, try client.restart(100));
    try std.testing.expectError(error.FileNotFound, tmp.dir.openFile("lifecycle-calls", .{}));
}

test "Scenario: Given a responsive daemon then explicit restart forwards the selected home exactly once" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
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
    if (builtin.os.tag == .windows) return error.SkipZigTest;
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

test "Scenario: Given a restart failure then retry makes another explicit restart attempt" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
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
    if (builtin.os.tag == .windows) return error.SkipZigTest;
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

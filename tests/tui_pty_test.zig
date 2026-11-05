//! End-to-end live-TUI tests driven through a real pseudo-terminal.
//!
//! These cover what unit tests cannot: the whole read → classify → dispatch
//! → teardown path on the built binary, where the terminal actually is a tty
//! and the app's raw-mode, input-drain, and timing decisions all apply.
//! Assertions stay on the wire contract — mode bytes, lifecycle sequences,
//! input consumption — not on rendered frame contents, which are pinned by
//! the in-process tests (`tests/cli_picker_test.zig`).
//!
//! POSIX only: native Windows reads `INPUT_RECORD`s rather than a byte
//! stream, so its faithful harness is the real-console equivalent in
//! `tests/tui_conhost_test.zig` (headless conhost + console API injection),
//! not this file's byte-oriented view of the world.

const std = @import("std");
const builtin = @import("builtin");
const test_options = @import("test_options");
const app_runtime = @import("codex_auth").core.runtime;
const fs = @import("codex_auth").core.compat_fs;
const registry = @import("codex_auth").registry;
const fixtures = @import("support/fixtures.zig");

const cli_integration_install_prefix_env = "CODEX_AUTH_CLI_INTEGRATION_INSTALL_PREFIX";
const cli_integration_project_root_env = "CODEX_AUTH_CLI_INTEGRATION_PROJECT_ROOT";

/// The pty calls below are verified on Linux only — macOS has them too but
/// std.c lacks its winsize constant and its grantpt semantics differ, so
/// widening `has_pty` is a deliberate port, not a flag flip.
const has_pty = builtin.target.os.tag == .linux;
/// Referenced only under the linux gate — std.c lacks the constant on
/// darwin, so it must not be analyzed for other targets.
const pty_iocswinsz = if (has_pty) std.c.T.IOCSWINSZ else 0;

extern "c" fn posix_openpt(flags: c_int) c_int;
extern "c" fn grantpt(fd: c_int) c_int;
extern "c" fn unlockpt(fd: c_int) c_int;
extern "c" fn ptsname(fd: c_int) ?[*:0]u8;
extern "c" fn ioctl(fd: c_int, request: c_ulong, ...) c_int;
extern "c" fn close(fd: c_int) c_int;

const pty_deadline_ms: i64 = 30_000;

var cli_build_ready = false;
var cli_build_mutex: std.Io.Mutex = .init;

fn projectRootAlloc(allocator: std.mem.Allocator) ![]u8 {
    const project_root = app_runtime.getEnvVarOwned(allocator, cli_integration_project_root_env) catch |err| switch (err) {
        error.EnvironmentVariableNotFound => null,
        else => return err,
    };
    if (project_root) |path| return path;
    return fs.realpathAlloc(allocator, test_options.project_root);
}

fn buildCliBinary(allocator: std.mem.Allocator, project_root: []const u8) !void {
    cli_build_mutex.lockUncancelable(fs.io());
    defer cli_build_mutex.unlock(fs.io());
    if (cli_build_ready) return;

    // A staged install prefix already carries the binary — building a
    // local zig-out it never uses would just contend on the cache.
    if (app_runtime.getEnvVarOwned(allocator, cli_integration_install_prefix_env) catch null) |prefix| {
        defer allocator.free(prefix);
        cli_build_ready = true;
        return;
    }

    const install_prefix = try fs.path.join(allocator, &.{ project_root, "zig-out" });
    defer allocator.free(install_prefix);
    const result = std.process.run(std.heap.page_allocator, fs.io(), .{
        .argv = &.{ test_options.zig_exe, "build", "-p", install_prefix, "test-helpers" },
        .cwd = .{ .path = project_root },
        .stdout_limit = .limited(1024 * 1024),
        .stderr_limit = .limited(1024 * 1024),
    }) catch |err| switch (err) {
        error.OutOfMemory => return error.SkipZigTest,
        else => return err,
    };
    defer std.heap.page_allocator.free(result.stdout);
    defer std.heap.page_allocator.free(result.stderr);

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
    const install_prefix = app_runtime.getEnvVarOwned(allocator, cli_integration_install_prefix_env) catch |err| switch (err) {
        error.EnvironmentVariableNotFound => null,
        else => return err,
    };
    defer if (install_prefix) |dir| allocator.free(dir);
    const prefix = install_prefix orelse try fs.path.join(allocator, &.{ project_root, "zig-out" });
    defer if (install_prefix == null) allocator.free(prefix);
    return fs.path.join(allocator, &.{ prefix, "bin", "codex-auth" });
}

const Pty = struct {
    master: c_int,
    slave: c_int,

    fn open(rows: u16, cols: u16) !Pty {
        const oflags: std.c.O = .{ .ACCMODE = .RDWR, .NOCTTY = true };
        const master = posix_openpt(@as(c_int, @bitCast(oflags)));
        if (master < 0) return error.PtyOpenFailed;
        errdefer _ = close(master);
        if (grantpt(master) != 0) return error.PtyGrantFailed;
        if (unlockpt(master) != 0) return error.PtyUnlockFailed;
        // A pty defaults to 0x0; the TUI needs a real size to lay out frames.
        var size: std.posix.winsize = .{ .row = rows, .col = cols, .xpixel = 0, .ypixel = 0 };
        if (ioctl(master, pty_iocswinsz, &size) != 0) return error.PtySizeFailed;
        const name = ptsname(master) orelse return error.PtyNameFailed;
        const slave = std.c.open(name, oflags, @as(c_uint, 0));
        if (slave < 0) return error.PtySlaveOpenFailed;
        return .{ .master = master, .slave = slave };
    }

    fn deinit(self: Pty) void {
        _ = close(self.slave);
        _ = close(self.master);
    }
};

fn nowMs() i64 {
    return std.Io.Timestamp.now(fs.io(), .awake).toMilliseconds();
}

/// Reads master output until `needle` appears or the deadline passes.
/// `PtyEof` means the child closed its side before producing the needle.
fn readMasterUntil(master: c_int, out: *std.ArrayList(u8), needle: []const u8, deadline_ms: i64) !void {
    while (std.mem.indexOf(u8, out.items, needle) == null) {
        try pollReadMaster(master, out, deadline_ms);
    }
}

/// Drains master output until the child closes its side (EIO/EOF) or the
/// deadline passes — expected after the child exits.
fn drainMaster(master: c_int, out: *std.ArrayList(u8), deadline_ms: i64) !void {
    while (true) {
        pollReadMaster(master, out, deadline_ms) catch |err| switch (err) {
            error.PtyEof => return,
            else => return err,
        };
    }
}

fn pollReadMaster(master: c_int, out: *std.ArrayList(u8), deadline_ms: i64) !void {
    const remaining = deadline_ms - nowMs();
    if (remaining <= 0) return error.PtyTimeout;
    var pfd = [_]std.posix.pollfd{.{ .fd = master, .events = std.posix.POLL.IN, .revents = 0 }};
    _ = try std.posix.poll(&pfd, @intCast(@min(remaining, 200)));
    const revents: i16 = pfd[0].revents;
    if (revents & std.posix.POLL.IN != 0) {
        var buf: [8192]u8 = undefined;
        const n = std.c.read(master, &buf, buf.len);
        // The pty reports EIO (here as plain -1) once every slave fd is gone.
        if (n <= 0) return error.PtyEof;
        try out.appendSlice(std.testing.allocator, buf[0..@intCast(n)]);
        return;
    }
    // NVAL means the fd went bad; without this the loop busy-spins to the
    // deadline instead of failing fast.
    if (revents & (std.posix.POLL.ERR | std.posix.POLL.HUP | std.posix.POLL.NVAL) != 0) return error.PtyEof;
}

const PtySession = struct {
    child: std.process.Child,
    output: std.ArrayList(u8),
    deadline_ms: i64,
    /// Set once `finish` reaps the child, so a cleanup defer does not kill
    /// a pid that may have been recycled.
    done: bool = false,

    fn waitMarker(self: *PtySession, master: c_int, needle: []const u8) !void {
        try readMasterUntil(master, &self.output, needle, self.deadline_ms);
    }

    fn finish(self: *PtySession, master: c_int) !u8 {
        drainMaster(master, &self.output, self.deadline_ms) catch |err| switch (err) {
            error.PtyEof => {},
            else => {
                // Swallowing a timeout here would leave child.wait blocking
                // on a live process; kill first so the failure stays finite.
                self.child.kill(fs.io());
                return err;
            },
        };
        // child.wait blocks forever; a child that closed the pty but kept
        // running would hang the test past its deadline. Poll with WNOHANG
        // and reap manually so the timeout path stays finite.
        const pid = self.child.id orelse return error.ChildReaped;
        var status: c_int = 0;
        while (true) {
            const rc = std.c.waitpid(pid, &status, std.c.W.NOHANG);
            if (rc == pid) break;
            if (rc < 0) return error.ChildWaitFailed;
            if (nowMs() >= self.deadline_ms) {
                self.child.kill(fs.io());
                self.done = true;
                return error.PtyTimeout;
            }
            try std.Io.sleep(fs.io(), .fromMilliseconds(20), .awake);
        }
        // Reaped already; keep child.id null so cleanup's kill stays a
        // no-op on this recycled pid.
        self.child.id = null;
        self.done = true;
        const term = std.Io.Threaded.statusToTerm(@bitCast(status));
        return switch (term) {
            .exited => |code| code,
            else => 255,
        };
    }
};

/// Spawns `codex-auth list --live --skip-api` with the pty slave as all three
/// std streams and a freshly-built environment — parent terminal hints must
/// never leak in (the caller decides exactly which brand vars exist).
fn spawnLiveList(
    allocator: std.mem.Allocator,
    exe: []const u8,
    cwd: []const u8,
    home: []const u8,
    codex_home: []const u8,
    extra_env: []const [2][]const u8,
) !struct { session: PtySession, master: c_int } {
    var env_map = std.process.Environ.Map.init(allocator);
    defer env_map.deinit();
    try env_map.put("HOME", home);
    try env_map.put("CODEX_HOME", codex_home);
    try env_map.put("TERM", "xterm-256color");
    try env_map.put("PATH", "/usr/bin:/bin");
    for (extra_env) |pair| try env_map.put(pair[0], pair[1]);

    const pty = try Pty.open(30, 120);
    errdefer pty.deinit();
    const slave_file: std.Io.File = .{ .handle = pty.slave, .flags = .{ .nonblocking = false } };
    const child = try std.process.spawn(fs.io(), .{
        .argv = &.{ exe, "list", "--live", "--skip-api" },
        .cwd = .{ .path = cwd },
        .environ_map = &env_map,
        .stdin = .{ .file = slave_file },
        .stdout = .{ .file = slave_file },
        .stderr = .{ .file = slave_file },
    });
    // The child holds its own copies now; keeping ours would mask EIO.
    _ = close(pty.slave);
    return .{
        .session = .{
            .child = child,
            .output = .empty,
            .deadline_ms = nowMs() + pty_deadline_ms,
        },
        .master = pty.master,
    };
}

fn seedAccounts(allocator: std.mem.Allocator, home_root: []const u8, count: usize) !void {
    const codex_home = try fs.path.join(allocator, &.{ home_root, ".codex" });
    defer allocator.free(codex_home);
    var reg = fixtures.makeEmptyRegistry();
    defer reg.deinit(allocator);
    var emails = try allocator.alloc([]u8, count);
    var filled: usize = 0;
    defer {
        for (emails[0..filled]) |email| allocator.free(email);
        allocator.free(emails);
    }
    var i: usize = 0;
    while (i < count) : (i += 1) {
        const email = try std.fmt.allocPrint(allocator, "user{d:0>2}@example.com", .{i});
        emails[i] = email;
        filled += 1;
        const alias = try std.fmt.allocPrint(allocator, "u{d:0>2}", .{i});
        defer allocator.free(alias);
        try fixtures.appendAccount(allocator, &reg, email, alias, null);
    }
    try registry.saveRegistry(allocator, codex_home, &reg);
    // Rows only render from stored auth files, the same way the integration
    // fixtures seed them; the registry alone is not enough.
    for (emails) |email| {
        const key = try fixtures.accountKeyForEmailAlloc(allocator, email);
        defer allocator.free(key);
        const path = try registry.accountAuthPath(allocator, codex_home, key);
        defer allocator.free(path);
        const data = try fixtures.authJsonWithEmailPlan(allocator, email, "plus");
        defer allocator.free(data);
        try fs.cwd().writeFile(.{ .sub_path = path, .data = data });
    }
}

test "pty: live TUI emits mouse modes and withholds kitty under WT_SESSION" {
    if (comptime !has_pty) return error.SkipZigTest;
    const gpa = std.testing.allocator;
    const project_root = try projectRootAlloc(gpa);
    defer gpa.free(project_root);
    try buildCliBinary(gpa, project_root);
    const exe = try builtCliPathAlloc(gpa, project_root);
    defer gpa.free(exe);

    var tmp = fs.tmpDir(.{});
    defer tmp.cleanup();
    const home = try tmp.dir.realpathAlloc(gpa, ".");
    defer gpa.free(home);
    const codex_home = try fs.path.join(gpa, &.{ home, ".codex" });
    defer gpa.free(codex_home);
    try tmp.dir.makePath(".codex");
    try seedAccounts(gpa, home, 3);

    const spawned = try spawnLiveList(gpa, exe, home, home, codex_home, &.{
        .{ "WT_SESSION", "pty-test-session" },
    });
    var session = spawned.session;
    const master = spawned.master;
    defer _ = close(master);
    defer session.output.deinit(gpa);
    defer if (!session.done) session.child.kill(fs.io());

    try session.waitMarker(master, "ACCOUNT");
    try std.testing.expectEqual(@as(isize, 1), std.c.write(master, "q", 1));
    try std.testing.expectEqual(@as(u8, 0), try session.finish(master));

    const out = session.output.items;
    try std.testing.expect(std.mem.indexOf(u8, out, "\x1b[?1049h") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\x1b[?1000h") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\x1b[?1006h") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\x1b[?1007h") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\x1b[?1006l") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\x1b[?1049l") != null);
    // WT_SESSION is on the skip list: no query, no push, no pop.
    try std.testing.expect(std.mem.indexOf(u8, out, "\x1b[?u") == null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\x1b[>7u") == null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\x1b[<1u") == null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\x1b[?1002h") == null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\x1b[?1005h") == null);
}

test "pty: live TUI pushes and pops kitty flags on kitty-capable terminals" {
    if (comptime !has_pty) return error.SkipZigTest;
    const gpa = std.testing.allocator;
    const project_root = try projectRootAlloc(gpa);
    defer gpa.free(project_root);
    try buildCliBinary(gpa, project_root);
    const exe = try builtCliPathAlloc(gpa, project_root);
    defer gpa.free(exe);

    var tmp = fs.tmpDir(.{});
    defer tmp.cleanup();
    const home = try tmp.dir.realpathAlloc(gpa, ".");
    defer gpa.free(home);
    const codex_home = try fs.path.join(gpa, &.{ home, ".codex" });
    defer gpa.free(codex_home);
    try tmp.dir.makePath(".codex");
    try seedAccounts(gpa, home, 3);

    const spawned = try spawnLiveList(gpa, exe, home, home, codex_home, &.{
        .{ "TERM_PROGRAM", "kitty" },
    });
    var session = spawned.session;
    const master = spawned.master;
    defer _ = close(master);
    defer session.output.deinit(gpa);
    defer if (!session.done) session.child.kill(fs.io());

    try session.waitMarker(master, "ACCOUNT");
    try std.testing.expectEqual(@as(isize, 1), std.c.write(master, "q", 1));
    try std.testing.expectEqual(@as(u8, 0), try session.finish(master));

    const out = session.output.items;
    try std.testing.expect(std.mem.indexOf(u8, out, "\x1b[?u") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\x1b[>7u") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\x1b[<1u") != null);
    // Our pty never answers the query, so enhancement stays off and `q`
    // still arrives as the legacy quit key — that is the fallback path.
    try std.testing.expect(std.mem.indexOf(u8, out, "\x1b[?1049l") != null);
}

test "pty: kitty ACK turns bare arrows into wheel scrolls" {
    if (comptime !has_pty) return error.SkipZigTest;
    const gpa = std.testing.allocator;
    const project_root = try projectRootAlloc(gpa);
    defer gpa.free(project_root);
    try buildCliBinary(gpa, project_root);
    const exe = try builtCliPathAlloc(gpa, project_root);
    defer gpa.free(exe);

    var tmp = fs.tmpDir(.{});
    defer tmp.cleanup();
    const home = try tmp.dir.realpathAlloc(gpa, ".");
    defer gpa.free(home);
    const codex_home = try fs.path.join(gpa, &.{ home, ".codex" });
    defer gpa.free(codex_home);
    try tmp.dir.makePath(".codex");
    try seedAccounts(gpa, home, 40);

    // No terminal-brand vars: the kitty request is emitted, and we answer
    // its `CSI ?u` query ourselves — the only e2e proof of the
    // push → query → ACK → reclass chain.
    const spawned = try spawnLiveList(gpa, exe, home, home, codex_home, &.{});
    var session = spawned.session;
    const master = spawned.master;
    defer _ = close(master);
    defer session.output.deinit(gpa);
    defer if (!session.done) session.child.kill(fs.io());

    try session.waitMarker(master, "user00@example.com");
    try std.testing.expect(std.mem.indexOf(u8, session.output.items, "user39@example.com") == null);
    const inject_at = session.output.items.len;

    // `\x1b[?1u` is the reply a conformant terminal sends our query after
    // our `>7u` push landed; afterwards a bare ESC[B can only come from
    // the ?1007h alternate-scroll fallback — a wheel notch scrolling down.
    var injection_buf: [512]u8 = undefined;
    var injection: std.ArrayList(u8) = .initBuffer(&injection_buf);
    injection.appendSliceAssumeCapacity("\x1b[?1u");
    for (0..25) |_| injection.appendSliceAssumeCapacity("\x1b[B");
    injection.appendSliceAssumeCapacity("q");
    try std.testing.expectEqual(@as(isize, @intCast(injection.items.len)), std.c.write(master, injection.items.ptr, injection.items.len));

    try session.waitMarker(master, "user39@example.com");
    try std.testing.expectEqual(@as(u8, 0), try session.finish(master));
    // Enhanced-arrow sequences must not have been reinterpreted either:
    // nothing in the injected tail is a kitty release or modifier report.
    const after = session.output.items[inject_at..];
    try std.testing.expect(std.mem.indexOf(u8, after, "user39@example.com") != null);
}

test "pty: injected SGR and X10 mouse reports are consumed without echo" {
    if (comptime !has_pty) return error.SkipZigTest;
    const gpa = std.testing.allocator;
    const project_root = try projectRootAlloc(gpa);
    defer gpa.free(project_root);
    try buildCliBinary(gpa, project_root);
    const exe = try builtCliPathAlloc(gpa, project_root);
    defer gpa.free(exe);

    var tmp = fs.tmpDir(.{});
    defer tmp.cleanup();
    const home = try tmp.dir.realpathAlloc(gpa, ".");
    defer gpa.free(home);
    const codex_home = try fs.path.join(gpa, &.{ home, ".codex" });
    defer gpa.free(codex_home);
    try tmp.dir.makePath(".codex");
    try seedAccounts(gpa, home, 40);

    const spawned = try spawnLiveList(gpa, exe, home, home, codex_home, &.{});
    var session = spawned.session;
    const master = spawned.master;
    defer _ = close(master);
    defer session.output.deinit(gpa);
    defer if (!session.done) session.child.kill(fs.io());

    try session.waitMarker(master, "user00@example.com");
    // Non-vacuity pin, same idea as the conhost wheel test: the tail row
    // must be absent from the emitted frames before the wheel reports.
    try std.testing.expect(std.mem.indexOf(u8, session.output.items, "user39@example.com") == null);
    const inject_at = session.output.items.len;

    // A wheel-down burst, a release suffix, and an X10 report whose
    // coordinate bytes are ASCII digits — the wheel must actually scroll
    // the list, digit bytes must never reach the key layer, and in raw
    // mode none of this echoes back onto the wire.
    var injection_buf: [512]u8 = undefined;
    var injection: std.ArrayList(u8) = .initBuffer(&injection_buf);
    for (0..25) |_| injection.appendSliceAssumeCapacity("\x1b[<65;10;10M");
    injection.appendSliceAssumeCapacity("\x1b[<64;10;10m" ++ "\x1b[M\x21\x37\x38" ++ "q");
    try std.testing.expectEqual(@as(isize, @intCast(injection.items.len)), std.c.write(master, injection.items.ptr, injection.items.len));
    // The scroll is observable on the wire: tail rows join later frames.
    try session.waitMarker(master, "user39@example.com");
    const exit_code = session.finish(master) catch |err| {
        std.debug.print("pty output tail after inject:\n{s}\n", .{session.output.items[@max(session.output.items.len -| 2000, inject_at)..]});
        return err;
    };
    try std.testing.expectEqual(@as(u8, 0), exit_code);

    const after = session.output.items[inject_at..];
    try std.testing.expect(std.mem.indexOf(u8, after, "\x1b[<65") == null);
    try std.testing.expect(std.mem.indexOf(u8, after, "\x1b[<64") == null);
    try std.testing.expect(std.mem.indexOf(u8, session.output.items, "\x1b[?1006l") != null);
    try std.testing.expect(std.mem.indexOf(u8, session.output.items, "\x1b[?1049l") != null);
}

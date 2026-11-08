const std = @import("std");
const builtin = @import("builtin");
const runtime = @import("../core/runtime.zig");

pub const restart_timeout_ms = 120_000;
pub const reload_timeout_ms = 10_000;
const probe_timeout_ms = 5_000;
const stdout_limit = 16 * 1024;
const stderr_limit = 64 * 1024;

pub const Outcome = enum { not_running, running, unknown, unsupported, reloaded, deferred, reload_failed, restarted, restart_failed, timed_out };

/// Coordinates the supported Codex lifecycle commands for one selected home.
pub const Client = struct {
    allocator: std.mem.Allocator,
    codex_home: []const u8,
    executable: []u8,
    /// Optional cancellation flag polled between subprocess reads and process
    /// waits. Lifecycle helpers bail out with error.Canceled once it flips, so
    /// a caller (the live-switch worker) can stop a slow helper promptly.
    cancel: ?*const std.atomic.Value(bool) = null,
    /// reload-auth RPC deadline; tests override it to exercise timeouts
    /// without waiting for the full default.
    reload_timeout_ms: u64,

    pub fn init(allocator: std.mem.Allocator, codex_home: []const u8) !Client {
        return .{
            .allocator = allocator,
            .codex_home = codex_home,
            .executable = try resolveExecutable(allocator, codex_home),
            .reload_timeout_ms = reload_timeout_ms,
        };
    }

    pub fn deinit(self: *Client) void {
        self.allocator.free(self.executable);
    }

    fn controlSocketPathAlloc(allocator: std.mem.Allocator, codex_home: []const u8) ![]u8 {
        return std.Io.Dir.path.join(allocator, &.{ codex_home, "app-server-control", "app-server-control.sock" });
    }

    /// The control endpoint is the only presence signal that survives a
    /// missing or moved helper executable: callers that cannot resolve one
    /// must still consult the socket before reporting the daemon absent. A
    /// probe error is conservatively presence, not absence.
    pub fn controlEndpointPresent(codex_home: []const u8) !bool {
        const socket = try controlSocketPathAlloc(runtime.scratchAllocator(), codex_home);
        defer runtime.scratchAllocator().free(socket);
        std.Io.Dir.cwd().access(runtime.io(), socket, .{}) catch |err| switch (err) {
            error.FileNotFound => return false,
            else => return true,
        };
        return true;
    }

    /// A socket path alone never establishes responsiveness. A missing endpoint
    /// is a best-effort absence check; errors and stale endpoints stay unknown.
    pub fn probe(self: *const Client) !Outcome {
        if (!supported()) return .unsupported;
        const socket = try controlSocketPathAlloc(self.allocator, self.codex_home);
        defer self.allocator.free(socket);
        std.Io.Dir.cwd().access(runtime.io(), socket, .{}) catch |err| switch (err) {
            error.FileNotFound => return .not_running,
            else => return .unknown,
        };
        const result = self.runLifecycle("version", probe_timeout_ms) catch |err| switch (err) {
            error.OutOfMemory, error.Canceled => return err,
            else => return .unknown,
        };
        defer result.deinit(self.allocator);
        if (!result.succeeded) return .unknown;
        var parsed = std.json.parseFromSlice(std.json.Value, self.allocator, result.stdout, .{}) catch |err| switch (err) {
            error.OutOfMemory => return err,
            else => return .unknown,
        };
        defer parsed.deinit();
        if (parsed.value != .object) return .unknown;
        const status = parsed.value.object.get("status") orelse return .unknown;
        const version = parsed.value.object.get("appServerVersion") orelse return .unknown;
        if (status != .string or version != .string or version.string.len == 0) return .unknown;
        return if (std.mem.eql(u8, status.string, "running")) .running else .unknown;
    }

    /// The `--no-restart-daemon` coordination: one best-effort auth reload,
    /// never a restart. Daemons that cannot reload stay `.running` so callers
    /// can still point at manual recovery; nothing here disconnects clients.
    pub fn reload(self: *const Client) !Outcome {
        const state = try self.probe();
        if (state != .running) return state;
        if (try self.tryReload()) |outcome| return outcome;
        return .running;
    }

    /// Explicit requests intentionally include unchanged-file recovery. The
    /// caller supplies an operational budget, not a persisted/user setting.
    pub fn restart(self: *const Client, timeout_ms: u64) !Outcome {
        const state = try self.probe();
        if (state != .running) return state;
        // Codex can start a daemon if it disappears after this probe. Accept
        // that lifecycle race rather than adding our own process management.
        const result = self.runLifecycle("restart", timeout_ms) catch |err| switch (err) {
            error.OutOfMemory, error.Canceled => return err,
            else => return .restart_failed,
        };
        defer result.deinit(self.allocator);
        if (result.timed_out) return .timed_out;
        return if (result.succeeded) .restarted else .restart_failed;
    }

    /// Two-tier coordination: prefer the non-disruptive reload when the running
    /// daemon supports it (codex daemons), and fall back to a full restart for
    /// upstream daemons without reload support. Busy daemons defer instead of
    /// interrupting a running turn; a daemon that answers reload-auth but
    /// reports a failure is left running because a restart re-reads the same
    /// auth file and would interrupt sessions for nothing.
    pub fn ensure(self: *const Client, timeout_ms: u64) !Outcome {
        const state = try self.probe();
        if (state != .running) return state;
        if (try self.tryReload()) |outcome| return outcome;
        // The daemon was alive moments ago; a vanished endpoint before the
        // restart probe means its state is unconfirmed rather than absent.
        return switch (try self.restart(timeout_ms)) {
            .not_running => .unknown,
            else => |outcome| outcome,
        };
    }

    /// Returns the reload outcome when the daemon understood the request;
    /// null means the command is unavailable and the caller should fall back
    /// to a restart. A non-zero exit without the unsupported marker means the
    /// RPC itself failed, which a restart cannot fix. A timeout is likewise
    /// not evidence of a missing command: a slow helper gets .unknown instead
    /// of a restart that would interrupt attached sessions for nothing.
    fn tryReload(self: *const Client) !?Outcome {
        const result = self.runLifecycle("reload-auth", self.reload_timeout_ms) catch |err| switch (err) {
            error.OutOfMemory, error.Canceled => return err,
            // Output overflow means the helper ran but became unreadable;
            // that is an RPC failure, not a missing command.
            error.StreamTooLong => return .reload_failed,
            else => return null,
        };
        defer result.deinit(self.allocator);
        if (result.timed_out) return .unknown;
        if (!result.succeeded)
            return if (looksUnsupported(result.stderr)) null else .reload_failed;
        if (std.mem.find(u8, result.stdout, "skipped the auth reload") != null) return .deferred;
        return .reloaded;
    }

    /// codext prints "does not implement account/reload" for a daemon without
    /// the RPC; a CLI too old to know the subcommand fails argument parsing —
    /// clap 4 says "unrecognized subcommand", older clap says the argument
    /// "wasn't recognized"/"wasn't expected". All mean restart is the only
    /// coordination left.
    fn looksUnsupported(stderr: []const u8) bool {
        return std.mem.find(u8, stderr, "does not implement account/reload") != null or
            std.mem.find(u8, stderr, "unrecognized subcommand") != null or
            std.mem.find(u8, stderr, "wasn't recognized") != null or
            std.mem.find(u8, stderr, "wasn't expected") != null;
    }

    fn cancelRequested(self: *const Client) bool {
        const cancel = self.cancel orelse return false;
        return cancel.load(.acquire);
    }

    const Result = struct {
        stdout: []u8,
        stderr: []u8,
        succeeded: bool,
        timed_out: bool,

        fn deinit(self: *const Result, allocator: std.mem.Allocator) void {
            allocator.free(self.stdout);
            allocator.free(self.stderr);
        }
    };

    fn runLifecycle(self: *const Client, command: []const u8, timeout_ms: u64) !Result {
        const io = runtime.io();
        if (self.cancelRequested()) return error.Canceled;
        const deadline = std.Io.Clock.Timestamp.now(io, .awake).addDuration(.{
            .clock = .awake,
            .raw = .fromMilliseconds(@intCast(timeout_ms)),
        });
        var env = try runtime.currentEnviron().createMap(self.allocator);
        defer env.deinit();
        try env.put("CODEX_HOME", self.codex_home);
        var child = try std.process.spawn(io, .{
            .argv = &.{ self.executable, "app-server", "daemon", command },
            .environ_map = &env,
            .stdin = .ignore,
            .stdout = .pipe,
            .stderr = .pipe,
            .create_no_window = true,
        });
        // Child.kill terminates and reaps only this helper, and is idempotent.
        defer child.kill(io);
        var buffer: std.Io.File.MultiReader.Buffer(2) = undefined;
        var reader: std.Io.File.MultiReader = undefined;
        reader.init(self.allocator, io, buffer.toStreams(), &.{ child.stdout.?, child.stderr.? });
        defer reader.deinit();
        // Fill in short chunks so a flipped cancel flag stops a helper that
        // would otherwise block until the full command deadline.
        while (true) {
            if (self.cancelRequested()) return error.Canceled;
            const step_deadline = std.Io.Clock.Timestamp.now(io, .awake).addDuration(.{
                .clock = .awake,
                .raw = .fromMilliseconds(cancel_poll_ms),
            });
            const chunk_deadline = if (step_deadline.compare(.lt, deadline)) step_deadline else deadline;
            reader.fill(64, .{ .deadline = chunk_deadline }) catch |err| switch (err) {
                error.EndOfStream => break,
                error.Timeout => {
                    if (std.Io.Clock.Timestamp.now(io, .awake).compare(.gte, deadline))
                        return .{ .stdout = try self.allocator.dupe(u8, ""), .stderr = try self.allocator.dupe(u8, ""), .succeeded = false, .timed_out = true };
                    continue;
                },
                else => return err,
            };
            if (reader.reader(0).buffered().len > stdout_limit or reader.reader(1).buffered().len > stderr_limit)
                return error.StreamTooLong;
        }
        try reader.checkAnyError();
        const term = waitForExit(&child, deadline, self.cancel) catch |err| switch (err) {
            error.Timeout => return .{ .stdout = try self.allocator.dupe(u8, ""), .stderr = try self.allocator.dupe(u8, ""), .succeeded = false, .timed_out = true },
            else => return err,
        };
        return .{
            .stdout = try reader.toOwnedSlice(0),
            .stderr = try reader.toOwnedSlice(1),
            .succeeded = switch (term) {
                .exited => |code| code == 0,
                else => false,
            },
            .timed_out = false,
        };
    }
};

fn supported() bool {
    return builtin.target.os.tag == .linux or builtin.target.os.tag == .macos or builtin.target.os.tag == .windows;
}

fn resolveExecutable(allocator: std.mem.Allocator, home: []const u8) ![]u8 {
    const name = if (builtin.target.os.tag == .windows) "codex.exe" else "codex";
    const layouts = [_][]const []const u8{
        &.{ "packages", "app-server-daemon", "current", "bin" },
        &.{ "packages", "standalone", "current", "bin" },
        &.{ "packages", "standalone", "current" },
    };
    for (layouts) |layout| {
        const dir = try std.Io.Dir.path.join(allocator, layout);
        defer allocator.free(dir);
        const path = try std.Io.Dir.path.join(allocator, &.{ home, dir, name });
        if (isExecutable(path)) return path;
        allocator.free(path);
    }
    var env = try runtime.currentEnviron().createMap(allocator);
    defer env.deinit();
    var paths = std.mem.splitScalar(u8, env.get("PATH") orelse "", if (builtin.target.os.tag == .windows) ';' else ':');
    while (paths.next()) |dir| {
        // Empty PATH segments resolve relative to the current directory, which
        // must never be searched for a lifecycle helper.
        if (dir.len == 0) continue;
        const path = try std.Io.Dir.path.join(allocator, &.{ dir, name });
        if (isExecutable(path)) {
            defer allocator.free(path);
            return try runtime.realPathFileAlloc(allocator, std.Io.Dir.cwd(), path);
        }
        allocator.free(path);
    }
    // Spawning a bare name would let the OS search the current directory, so
    // an unresolvable daemon executable stays an init failure instead.
    return error.ExecutableRequired;
}

fn isExecutable(path: []const u8) bool {
    const stat = std.Io.Dir.cwd().statFile(runtime.io(), path, .{}) catch return false;
    if (stat.kind != .file) return false;
    if (builtin.target.os.tag != .windows)
        std.Io.Dir.cwd().access(runtime.io(), path, .{ .execute = true }) catch return false;
    return true;
}

// Output EOF is not proof of exit. Poll without blocking so a helper that
// closes its pipes but stays alive is still covered by the same deadline.
const cancel_poll_ms = 50;

fn waitForExit(child: *std.process.Child, deadline: std.Io.Clock.Timestamp, cancel: ?*const std.atomic.Value(bool)) !std.process.Child.Term {
    const io = runtime.io();
    while (true) {
        if (builtin.target.os.tag == .windows) {
            const windows = std.os.windows;
            const zero: windows.LARGE_INTEGER = 0;
            switch (windows.ntdll.NtWaitForSingleObject(child.id.?, .FALSE, &zero)) {
                .WAIT_0 => return try child.wait(io),
                .TIMEOUT => {},
                else => return error.ChildWaitFailed,
            }
        } else {
            var raw_status: c_int = 0;
            const pid = std.c.waitpid(child.id.?, &raw_status, std.c.W.NOHANG);
            switch (std.posix.errno(pid)) {
                .SUCCESS => if (pid != 0) {
                    const status: u32 = @bitCast(raw_status);
                    // waitpid has reaped our helper. Close its remaining pipes
                    // and relinquish ownership so deferred kill cannot reuse PID.
                    if (child.stdout) |file| file.close(io);
                    if (child.stderr) |file| file.close(io);
                    child.stdout = null;
                    child.stderr = null;
                    child.id = null;
                    if (std.c.W.IFEXITED(status)) return .{ .exited = std.c.W.EXITSTATUS(status) };
                    if (std.c.W.IFSIGNALED(status)) return .{ .signal = std.c.W.TERMSIG(status) };
                    return .{ .unknown = status };
                },
                .INTR => {},
                else => return error.ChildWaitFailed,
            }
        }
        if (cancel) |flag| {
            if (flag.load(.acquire)) return error.Canceled;
        }
        if (std.Io.Clock.Timestamp.now(io, .awake).compare(.gte, deadline)) return error.Timeout;
        const next = std.Io.Clock.Timestamp.now(io, .awake).addDuration(.{ .clock = .awake, .raw = .fromMilliseconds(10) });
        try (if (next.compare(.lt, deadline)) next else deadline).wait(io);
    }
}

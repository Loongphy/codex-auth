const std = @import("std");
const builtin = @import("builtin");
const runtime = @import("../core/runtime.zig");

pub const restart_timeout_ms = 120_000;
const probe_timeout_ms = 5_000;
const output_limit = 16 * 1024;

pub const Outcome = enum { not_running, running, unknown, unsupported, restarted, restart_failed, timed_out };

/// Coordinates the supported Codex lifecycle commands for one selected home.
pub const Client = struct {
    allocator: std.mem.Allocator,
    codex_home: []const u8,
    executable: []u8,

    pub fn init(allocator: std.mem.Allocator, codex_home: []const u8) !Client {
        return .{
            .allocator = allocator,
            .codex_home = codex_home,
            .executable = try resolveExecutable(allocator, codex_home),
        };
    }

    pub fn deinit(self: *Client) void {
        self.allocator.free(self.executable);
    }

    /// A socket path alone never establishes responsiveness. A missing endpoint
    /// is a best-effort absence check; errors and stale endpoints stay unknown.
    pub fn probe(self: *const Client) !Outcome {
        if (!supported()) return .unsupported;
        const socket = try std.fs.path.join(self.allocator, &.{ self.codex_home, "app-server-control", "app-server-control.sock" });
        defer self.allocator.free(socket);
        std.Io.Dir.cwd().access(runtime.io(), socket, .{}) catch |err| switch (err) {
            error.FileNotFound => return .not_running,
            else => return .unknown,
        };
        const result = self.runLifecycle("version", probe_timeout_ms) catch |err| switch (err) {
            error.OutOfMemory => return err,
            else => return .unknown,
        };
        defer self.allocator.free(result.stdout);
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

    /// Explicit requests intentionally include unchanged-file recovery. The
    /// caller supplies an operational budget, not a persisted/user setting.
    pub fn restart(self: *const Client, timeout_ms: u64) !Outcome {
        const state = try self.probe();
        if (state != .running) return state;
        // Codex can start a daemon if it disappears after this probe. Accept
        // that lifecycle race rather than adding our own process management.
        const result = self.runLifecycle("restart", timeout_ms) catch |err| switch (err) {
            error.OutOfMemory => return err,
            else => return .restart_failed,
        };
        defer self.allocator.free(result.stdout);
        if (result.timed_out) return .timed_out;
        return if (result.succeeded) .restarted else .restart_failed;
    }

    const Result = struct { stdout: []u8, succeeded: bool, timed_out: bool };

    fn runLifecycle(self: *const Client, command: []const u8, timeout_ms: u64) !Result {
        const io = runtime.io();
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
        while (reader.fill(64, .{ .deadline = deadline })) |_| {
            if (reader.reader(0).buffered().len > output_limit or reader.reader(1).buffered().len > output_limit)
                return error.StreamTooLong;
        } else |err| switch (err) {
            error.EndOfStream => {},
            error.Timeout => return .{ .stdout = try self.allocator.dupe(u8, ""), .succeeded = false, .timed_out = true },
            else => return err,
        }
        try reader.checkAnyError();
        const term = waitForExit(&child, deadline) catch |err| switch (err) {
            error.Timeout => return .{ .stdout = try self.allocator.dupe(u8, ""), .succeeded = false, .timed_out = true },
            else => return err,
        };
        return .{
            .stdout = try reader.toOwnedSlice(0),
            .succeeded = switch (term) {
                .exited => |code| code == 0,
                else => false,
            },
            .timed_out = false,
        };
    }
};

fn supported() bool {
    return builtin.os.tag == .linux or builtin.os.tag == .macos or builtin.os.tag == .windows;
}

fn resolveExecutable(allocator: std.mem.Allocator, home: []const u8) ![]u8 {
    const name = if (builtin.os.tag == .windows) "codex.exe" else "codex";
    const layouts = [_][]const []const u8{
        &.{ "packages", "app-server-daemon", "current", "bin" },
        &.{ "packages", "standalone", "current", "bin" },
        &.{ "packages", "standalone", "current" },
    };
    for (layouts) |layout| {
        const dir = try std.fs.path.join(allocator, layout);
        defer allocator.free(dir);
        const path = try std.fs.path.join(allocator, &.{ home, dir, name });
        if (isExecutable(path)) return path;
        allocator.free(path);
    }
    var env = try runtime.currentEnviron().createMap(allocator);
    defer env.deinit();
    var paths = std.mem.splitScalar(u8, env.get("PATH") orelse "", if (builtin.os.tag == .windows) ';' else ':');
    while (paths.next()) |dir| {
        const path = try std.fs.path.join(allocator, &.{ dir, name });
        if (isExecutable(path)) {
            defer allocator.free(path);
            return try runtime.realPathFileAlloc(allocator, std.Io.Dir.cwd(), path);
        }
        allocator.free(path);
    }
    return try allocator.dupe(u8, name);
}

fn isExecutable(path: []const u8) bool {
    const stat = std.Io.Dir.cwd().statFile(runtime.io(), path, .{}) catch return false;
    if (stat.kind != .file) return false;
    if (builtin.os.tag != .windows)
        std.Io.Dir.cwd().access(runtime.io(), path, .{ .execute = true }) catch return false;
    return true;
}

// Output EOF is not proof of exit. Poll without blocking so a helper that
// closes its pipes but stays alive is still covered by the same deadline.
fn waitForExit(child: *std.process.Child, deadline: std.Io.Clock.Timestamp) !std.process.Child.Term {
    const io = runtime.io();
    while (true) {
        if (builtin.os.tag == .windows) {
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
        if (std.Io.Clock.Timestamp.now(io, .awake).compare(.gte, deadline)) return error.Timeout;
        const next = std.Io.Clock.Timestamp.now(io, .awake).addDuration(.{ .clock = .awake, .raw = .fromMilliseconds(10) });
        try (if (next.compare(.lt, deadline)) next else deadline).wait(io);
    }
}

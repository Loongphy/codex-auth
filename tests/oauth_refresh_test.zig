const std = @import("std");
const refresh = @import("codex_auth").auth.oauth_refresh;
const sensitive_file = @import("codex_auth").core.sensitive_file;
const app_runtime = @import("codex_auth").core.runtime;
const builtin = @import("builtin");
const http = @import("codex_auth").api.http;

const ConcurrentRequester = struct {
    var calls: std.atomic.Value(usize) = .init(0);

    fn request(allocator: std.mem.Allocator, _: []const u8, _: []const u8) anyerror!http.HttpResult {
        _ = calls.fetchAdd(1, .seq_cst);
        const deadline = std.Io.Timestamp.now(app_runtime.io(), .real).toMilliseconds() + 100;
        while (std.Io.Timestamp.now(app_runtime.io(), .real).toMilliseconds() < deadline) {
            std.Thread.yield() catch {};
        }
        return .{
            .body = try allocator.dupe(u8, "{\"access_token\":\"e30.eyJleHAiOjQxMDI0NDQ4MDB9.x\",\"refresh_token\":\"rotated\"}"),
            .status_code = 200,
        };
    }
};

fn lockExclusive(file: std.Io.File) anyerror!void {
    try file.lock(app_runtime.io(), .exclusive);
}

fn unsupportedLock(_: std.Io.File) anyerror!void {
    return error.FileLocksUnsupported;
}

fn unexpectedRequest(_: std.mem.Allocator, _: []const u8, _: []const u8) anyerror!http.HttpResult {
    return error.UnexpectedRequest;
}

fn authWithExp(allocator: std.mem.Allocator, exp: i64) ![]u8 {
    const claims = try std.fmt.allocPrint(allocator, "{{\"exp\":{d}}}", .{exp});
    defer allocator.free(claims);
    const encoded_len = std.base64.url_safe_no_pad.Encoder.calcSize(claims.len);
    const encoded = try allocator.alloc(u8, encoded_len);
    defer allocator.free(encoded);
    _ = std.base64.url_safe_no_pad.Encoder.encode(encoded, claims);
    return std.fmt.allocPrint(allocator, "{{\"tokens\":{{\"access_token\":\"e30.{s}.x\"}},\"last_refresh\":\"2026-08-01T00:00:00Z\",\"unknown\":true}}", .{encoded});
}

test "OAuth refresh policy uses the five minute access token window" {
    const allocator = std.testing.allocator;
    const fresh = try authWithExp(allocator, 10_301);
    defer allocator.free(fresh);
    const near_expiry = try authWithExp(allocator, 10_300);
    defer allocator.free(near_expiry);
    try std.testing.expect(!refresh.shouldRefreshAuthData(allocator, fresh, 10_000));
    try std.testing.expect(refresh.shouldRefreshAuthData(allocator, near_expiry, 10_000));
}

test "OAuth refresh policy falls back to eight day last refresh only for undecodable tokens" {
    const allocator = std.testing.allocator;
    const old = "{\"tokens\":{\"access_token\":\"invalid\"},\"last_refresh\":\"2026-08-01T00:00:00Z\"}";
    const recent = "{\"tokens\":{\"access_token\":\"invalid\"},\"last_refresh\":\"2026-08-08T23:59:59Z\"}";
    const now: i64 = 1_786_233_600;
    try std.testing.expect(refresh.shouldRefreshAuthData(allocator, old, now));
    try std.testing.expect(!refresh.shouldRefreshAuthData(allocator, recent, now));
}

test "OAuth refresh failure classification accepts supported payload shapes" {
    try std.testing.expectEqual(refresh.FailureClass.permanent, refresh.classifyFailure(400, "{\"error\":{\"code\":\"refresh_token_expired\"}}"));
    try std.testing.expectEqual(refresh.FailureClass.permanent, refresh.classifyFailure(400, "{\"error\":\"invalid_grant\"}"));
    try std.testing.expectEqual(refresh.FailureClass.permanent, refresh.classifyFailure(401, "{\"code\":\"refresh_token_reused\"}"));
    try std.testing.expectEqual(refresh.FailureClass.protocol, refresh.classifyFailure(403, "{\"error\":\"unknown\"}"));
    try std.testing.expectEqual(refresh.FailureClass.transient, refresh.classifyFailure(429, "{}"));
    try std.testing.expectEqual(refresh.FailureClass.transient, refresh.classifyFailure(503, "{}"));
}

test "OAuth refresh response rotates returned tokens and preserves omitted and unknown fields" {
    const allocator = std.testing.allocator;
    const original = "{\"tokens\":{\"id_token\":\"old-id\",\"access_token\":\"old-access\",\"refresh_token\":\"old-refresh\",\"account_id\":\"acct\"},\"unknown\":{\"keep\":true}}";
    const complete = try refresh.applyRefreshResponse(allocator, original, "{\"id_token\":\"new-id\",\"access_token\":\"new-access\",\"refresh_token\":\"rotated\"}", 0);
    defer allocator.free(complete);
    try std.testing.expect(std.mem.indexOf(u8, complete, "\"refresh_token\": \"rotated\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, complete, "\"unknown\"") != null);

    const partial = try refresh.applyRefreshResponse(allocator, original, "{\"access_token\":\"new-access\"}", 0);
    defer allocator.free(partial);
    try std.testing.expect(std.mem.indexOf(u8, partial, "\"refresh_token\": \"old-refresh\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, partial, "\"id_token\": \"old-id\"") != null);
}

test "sensitive atomic writes replace content and enforce POSIX owner-only permissions" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir_path = try tmp.dir.realPathFileAlloc(app_runtime.io(), ".", allocator);
    defer allocator.free(dir_path);
    const path = try std.fs.path.join(allocator, &.{ dir_path, "auth.json" });
    defer allocator.free(path);
    try sensitive_file.writeAtomic(path, "first");
    try sensitive_file.writeAtomic(path, "second");
    const stat = try std.Io.Dir.cwd().statFile(app_runtime.io(), path, .{});
    try std.testing.expectEqual(@as(std.posix.mode_t, 0o600), stat.permissions.toMode() & 0o777);
    const file = try std.Io.Dir.cwd().openFile(app_runtime.io(), path, .{});
    defer file.close(app_runtime.io());
    var buffer: [16]u8 = undefined;
    var reader = file.reader(app_runtime.io(), &buffer);
    const content = try reader.interface.allocRemaining(allocator, .limited(16));
    defer allocator.free(content);
    try std.testing.expectEqualStrings("second", content);
}

test "concurrent refresh callers collapse refresh token rotation to one request" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const codex_home_z = try tmp.dir.realPathFileAlloc(app_runtime.io(), ".", allocator);
    defer allocator.free(codex_home_z);
    const codex_home: []const u8 = codex_home_z;
    try registryTestSnapshot(allocator, codex_home, "acct");
    ConcurrentRequester.calls.store(0, .seq_cst);

    const Runner = struct {
        fn run(home: []const u8) void {
            _ = refresh.refreshAccountWith(
                std.heap.smp_allocator,
                home,
                "acct",
                false,
                false,
                1,
                ConcurrentRequester.request,
                lockExclusive,
            ) catch unreachable;
        }
    };
    const first = try std.Thread.spawn(.{}, Runner.run, .{codex_home});
    const second = try std.Thread.spawn(.{}, Runner.run, .{codex_home});
    first.join();
    second.join();
    try std.testing.expectEqual(@as(usize, 1), ConcurrentRequester.calls.load(.seq_cst));
}

test "unsupported file locking fails closed before token transport" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const codex_home_z = try tmp.dir.realPathFileAlloc(app_runtime.io(), ".", allocator);
    defer allocator.free(codex_home_z);
    const codex_home: []const u8 = codex_home_z;
    try registryTestSnapshot(allocator, codex_home, "acct");
    try std.testing.expectError(
        error.RefreshLockUnsupported,
        refresh.refreshAccountWith(allocator, codex_home, "acct", false, true, 1, unexpectedRequest, unsupportedLock),
    );
}

fn registryTestSnapshot(allocator: std.mem.Allocator, codex_home: []const u8, account_key: []const u8) !void {
    const registry = @import("codex_auth").registry;
    try registry.ensureAccountsDir(allocator, codex_home);
    const path = try registry.accountAuthPath(allocator, codex_home, account_key);
    defer allocator.free(path);
    try sensitive_file.writeAtomic(path, "{\"tokens\":{\"access_token\":\"e30.eyJleHAiOjB9.x\",\"refresh_token\":\"original\"},\"last_refresh\":\"1970-01-01T00:00:00Z\"}");
}

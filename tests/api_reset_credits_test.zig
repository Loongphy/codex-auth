const std = @import("std");
const app_runtime = @import("codex_auth").core.runtime;
const registry = @import("codex_auth").registry;
const reset_credits_api = @import("codex_auth").api.reset_credits;
const fixtures = @import("support/fixtures.zig");
const scripted = @import("support/scripted_transport.zig");

/// Port-level coverage for `consumeCreditForAccount`: a scripted transport
/// replaces the HTTP peer, while auth loading, body building and outcome
/// mapping all run the real production code in-process. The curl assembly
/// itself stays covered by the fake-curl integration tests.
const Ctx = struct {
    tmp: std.testing.TmpDir,
    codex_home: []u8,
    account_key: []u8,
    account_id: []const u8,
    backend: scripted.ScriptedTransport,

    fn deinit(self: *Ctx, gpa: std.mem.Allocator) void {
        self.backend.deinit();
        gpa.free(self.codex_home);
        gpa.free(self.account_key);
        gpa.free(self.account_id);
        self.tmp.cleanup();
        self.* = undefined;
    }
};

fn seedAccount(gpa: std.mem.Allocator, email: []const u8, auth_json: []const u8) !Ctx {
    var tmp = std.testing.tmpDir(.{});
    errdefer tmp.cleanup();
    const codex_home = try app_runtime.realPathFileAlloc(gpa, tmp.dir, ".");
    errdefer gpa.free(codex_home);
    const account_key = try fixtures.accountKeyForEmailAlloc(gpa, email);
    errdefer gpa.free(account_key);

    try registry.ensureAccountsDir(gpa, codex_home);
    const auth_path = try registry.accountAuthPath(gpa, codex_home, account_key);
    defer gpa.free(auth_path);
    try std.Io.Dir.cwd().writeFile(app_runtime.io(), .{ .sub_path = auth_path, .data = auth_json });

    const account_id = try fixtures.chatgptAccountIdForEmailAlloc(gpa, email);
    defer gpa.free(account_id);
    return .{
        .tmp = tmp,
        .codex_home = codex_home,
        .account_key = account_key,
        .account_id = try gpa.dupe(u8, account_id),
        .backend = scripted.ScriptedTransport.init(gpa),
    };
}

fn seedChatgptAccount(gpa: std.mem.Allocator, email: []const u8) !Ctx {
    const auth_json = try fixtures.authJsonWithEmailPlan(gpa, email, "plus");
    defer gpa.free(auth_json);
    return seedAccount(gpa, email, auth_json);
}

test "consume credit maps each documented backend code through the transport port" {
    const gpa = std.testing.allocator;
    var ctx = try seedChatgptAccount(gpa, "port-matrix@example.com");
    defer ctx.deinit(gpa);

    const cases = [_]struct { code: []const u8, outcome: reset_credits_api.ConsumeOutcome }{
        .{ .code = "reset", .outcome = .reset },
        .{ .code = "already_redeemed", .outcome = .already_redeemed },
        .{ .code = "nothing_to_reset", .outcome = .nothing_to_reset },
        .{ .code = "no_credit", .outcome = .no_credit },
    };
    for (cases) |case| {
        const body = try gpa.print("{{\"code\":\"{s}\"}}", .{case.code});
        defer gpa.free(body);
        try ctx.backend.queuePostJson(body, 200);
    }

    for (cases) |case| {
        var result = try reset_credits_api.consumeCreditForAccount(
            gpa,
            ctx.backend.transport(),
            ctx.codex_home,
            ctx.account_key,
            "redeem-port-test",
            "credit-port-test",
        );
        defer result.deinit(gpa);
        try std.testing.expectEqual(case.outcome, result.outcome);
        try std.testing.expectEqual(@as(?u16, 200), result.status_code);
    }

    // The scripted transport captured every request as structured data: the
    // consume endpoint, the account header and the exact JSON body are all
    // asserted without parsing any curl config text.
    try std.testing.expectEqual(cases.len, ctx.backend.requests.items.len);
    for (ctx.backend.requests.items) |req| {
        try std.testing.expectEqualStrings(reset_credits_api.default_reset_credits_consume_endpoint, req.endpoint);
        try std.testing.expectEqualStrings(ctx.account_id, req.account_id);
        try std.testing.expectEqualStrings("{\"redeem_request_id\":\"redeem-port-test\",\"credit_id\":\"credit-port-test\"}", req.body.?);
    }
}

test "consume credit treats an unknown backend code as unexpected response" {
    const gpa = std.testing.allocator;
    var ctx = try seedChatgptAccount(gpa, "port-unknown@example.com");
    defer ctx.deinit(gpa);

    try ctx.backend.queuePostJson("{\"code\":\"reset_all\"}", 200);
    var result = try reset_credits_api.consumeCreditForAccount(
        gpa,
        ctx.backend.transport(),
        ctx.codex_home,
        ctx.account_key,
        "redeem-port-test",
        "credit-port-test",
    );
    defer result.deinit(gpa);
    try std.testing.expectEqual(.unexpected_response, result.outcome);
}

test "consume credit surfaces the http status on a non-2xx response" {
    const gpa = std.testing.allocator;
    var ctx = try seedChatgptAccount(gpa, "port-http500@example.com");
    defer ctx.deinit(gpa);

    try ctx.backend.queuePostJson("{\"error\":{\"message\":\"boom\"}}", 500);
    var result = try reset_credits_api.consumeCreditForAccount(
        gpa,
        ctx.backend.transport(),
        ctx.codex_home,
        ctx.account_key,
        "redeem-port-test",
        "credit-port-test",
    );
    defer result.deinit(gpa);
    try std.testing.expectEqual(.http_error, result.outcome);
    try std.testing.expectEqual(@as(?u16, 500), result.status_code);
}

test "consume credit maps a transport failure to a request error" {
    const gpa = std.testing.allocator;
    var ctx = try seedChatgptAccount(gpa, "port-timeout@example.com");
    defer ctx.deinit(gpa);

    try ctx.backend.queuePostJsonFailure(error.TimedOut);
    var result = try reset_credits_api.consumeCreditForAccount(
        gpa,
        ctx.backend.transport(),
        ctx.codex_home,
        ctx.account_key,
        "redeem-port-test",
        "credit-port-test",
    );
    defer result.deinit(gpa);
    try std.testing.expectEqual(.request_error, result.outcome);
    try std.testing.expectEqualStrings("TimedOut", result.error_name.?);
    try std.testing.expectEqual(@as(?u16, null), result.status_code);
}

test "consume credit rejects api key auth before touching the transport" {
    const gpa = std.testing.allocator;
    var ctx = try seedAccount(gpa, "port-apikey@example.com", "{\"OPENAI_API_KEY\":\"sk-test\"}");
    defer ctx.deinit(gpa);

    var result = try reset_credits_api.consumeCreditForAccount(
        gpa,
        ctx.backend.transport(),
        ctx.codex_home,
        ctx.account_key,
        "redeem-port-test",
        "credit-port-test",
    );
    defer result.deinit(gpa);
    try std.testing.expectEqual(.request_error, result.outcome);
    try std.testing.expectEqualStrings("MissingAuth", result.error_name.?);
    try std.testing.expectEqual(@as(usize, 0), ctx.backend.requests.items.len);
}

test "describeRequestError translates stored error codes to user-facing text" {
    // error_name stays the machine code for logs and JSON; display paths show
    // the phrasing instead. Unknown names pass through rather than collapsing
    // into a vague placeholder.
    try std.testing.expectEqualStrings("request timed out", reset_credits_api.describeRequestError("TimedOut"));
    try std.testing.expectEqualStrings("request failed", reset_credits_api.describeRequestError("RequestFailed"));
    try std.testing.expectEqualStrings("no ChatGPT login on this account", reset_credits_api.describeRequestError("MissingAuth"));
    try std.testing.expectEqualStrings("auth file not found", reset_credits_api.describeRequestError("FileNotFound"));
    try std.testing.expectEqualStrings("HomeDirUnavailable", reset_credits_api.describeRequestError("HomeDirUnavailable"));
}

const std = @import("std");

/// Mock backend for `codex-auth`, installed as `curl` by `zig build test-helpers`.
///
/// Without `CODEX_AUTH_FAKE_CURL_DIR` it answers the two fixed bodies the test
/// suite was written against. With it, the directory drives the responses:
///
///   usage[-<account_id>].json           GET  wham/usage
///   credits[-<account_id>].json         GET  wham/rate-limit-reset-credits
///   accounts[-<account_id>].json        GET  accounts
///   me.json                             GET  v1/me
///   consume[-<account_id>].json         POST wham/rate-limit-reset-credits/consume;
///                                         a per-account fixture wins over the global
///                                         one, so a single session can redeem for one
///                                         account and fail for another
///   after-consume-usage[-<id>].json     served instead of usage once a consume
///   after-consume-credits[-<id>].json   succeeded, so a live session shows the
///                                       reset without editing any file
///   <name>.status                       HTTP status for <name>.json, default 200
///   <name>.exit                         exit with this curl code instead of
///                                       answering, so one account in a batch can
///                                       fail transport while the others succeed
///   requests.log                        appended: consume requests, or every
///                                       request with CODEX_AUTH_FAKE_CURL_LOG_ALL=1
///
/// `CODEX_AUTH_FAKE_CURL_SCENARIO` picks the built-in consume answer when there
/// is no `consume.json`: ok (default), already_redeemed, no_credit,
/// nothing_to_reset, unknown_code, http500, timeout, resolve_failed.
///
/// The log never contains an Authorization header or any other credential.
const me_body = "{\"id\":\"user_api_e2e\",\"email\":\"apikey-flow@example.com\",\"name\":\"API Flow\"}";
const usage_body = "{\"plan_type\":\"plus\",\"rate_limit\":{\"primary_window\":{\"used_percent\":12,\"limit_window_seconds\":18000,\"reset_at\":4102444800},\"secondary_window\":{\"used_percent\":34,\"limit_window_seconds\":604800,\"reset_at\":4103049600}}}";

/// curl exit codes as `codex-auth` maps them: 28 becomes `error.TimedOut`, every
/// other non-zero exit becomes `error.RequestFailed`.
const exit_resolve_failed: u8 = 6;
const exit_timed_out: u8 = 28;

const log_name = "requests.log";

/// A live session polls continuously, so the log keeps only its tail.
const max_log_lines = 200;

const Route = enum { usage, credits, accounts, me, consume, unknown };

const Scenario = enum {
    ok,
    already_redeemed,
    no_credit,
    nothing_to_reset,
    unknown_code,
    http500,
    timeout,
    resolve_failed,

    fn parse(text: []const u8) Scenario {
        const trimmed = std.mem.trim(u8, text, " \r\n\t");
        return std.meta.stringToEnum(Scenario, trimmed) orelse .ok;
    }

    fn body(self: Scenario) []const u8 {
        return switch (self) {
            .ok => "{\"code\":\"reset\",\"windows_reset\":1}",
            .already_redeemed => "{\"code\":\"already_redeemed\"}",
            .no_credit => "{\"code\":\"no_credit\"}",
            .nothing_to_reset => "{\"code\":\"nothing_to_reset\"}",
            .unknown_code => "{\"code\":\"reset_all\"}",
            .http500 => "{\"code\":\"reset\"}",
            .timeout, .resolve_failed => "",
        };
    }

    fn status(self: Scenario) u16 {
        return switch (self) {
            .http500 => 500,
            else => 200,
        };
    }
};

const Request = struct {
    route: Route,
    url: []const u8,
    account_id: []const u8,
    /// The unescaped `data` config value of a POST; null for a GET.
    body: ?[]u8,

    fn parse(gpa: std.mem.Allocator, config: []const u8) !Request {
        const url = configValue(config, "url = \"") orelse "";
        const route: Route = if (std.mem.find(u8, url, "/rate-limit-reset-credits/consume") != null)
            .consume
        else if (std.mem.find(u8, url, "/wham/rate-limit-reset-credits") != null)
            .credits
        else if (std.mem.find(u8, url, "/wham/usage") != null)
            .usage
        else if (std.mem.find(u8, url, "/backend-api/accounts") != null)
            .accounts
        else if (std.mem.find(u8, url, "/v1/me") != null)
            .me
        else
            .unknown;

        var body: ?[]u8 = null;
        errdefer if (body) |value| gpa.free(value);
        if (configValue(config, "data = \"")) |escaped| {
            body = try unescapeJson(gpa, escaped);
        }
        return .{
            .route = route,
            .url = url,
            .account_id = configValue(config, "ChatGPT-Account-Id: ") orelse "",
            .body = body,
        };
    }

    fn deinit(self: Request, gpa: std.mem.Allocator) void {
        if (self.body) |value| gpa.free(value);
    }

    fn method(self: Request) []const u8 {
        return if (self.route == .consume) "POST" else "GET";
    }
};

pub fn main(init: std.process.Init) !void {
    var read_buffer: [4096]u8 = undefined;
    var stdin_reader = std.Io.File.stdin().reader(init.io, &read_buffer);
    const config = try stdin_reader.interface.allocRemaining(init.gpa, .limited(64 * 1024));
    defer init.gpa.free(config);
    const dir_path = init.environ_map.get("CODEX_AUTH_FAKE_CURL_DIR") orelse {
        const body = if (std.mem.find(u8, config, "/v1/me") != null) me_body else usage_body;
        try respond(init, body, 200);
        return;
    };

    const request = try Request.parse(init.gpa, config);
    defer request.deinit(init.gpa);

    var dir = try std.Io.Dir.openDirAbsolute(init.io, dir_path, .{});
    defer dir.close(init.io);

    if (request.route == .consume or init.environ_map.get("CODEX_AUTH_FAKE_CURL_LOG_ALL") != null) {
        try appendLog(init, dir, request);
    }

    switch (request.route) {
        .consume => try serveConsume(init, dir, request),
        .usage => try serveFixture(init, dir, request, "usage", usage_body),
        .credits => try serveFixture(init, dir, request, "credits", null),
        .accounts => try serveFixture(init, dir, request, "accounts", null),
        .me => try serveFixture(init, dir, request, "me", me_body),
        .unknown => try respond(init, "{}", 404),
    }
}

fn serveConsume(init: std.process.Init, dir: std.Io.Dir, request: Request) !void {
    // A per-account fixture wins over the global fixture and the scenario env,
    // so one account in a session can fail while the others succeed. Files are
    // re-read on every request, which makes mid-session edits possible.
    if (request.account_id.len != 0) {
        const per_account = try init.gpa.print("consume-{s}.json", .{request.account_id});
        defer init.gpa.free(per_account);
        if (try readExitCode(init, dir, per_account)) |code| std.process.exit(code);
        if (try readFixture(init, dir, per_account)) |body| {
            defer init.gpa.free(body);
            const status = try readStatus(init, dir, per_account);
            if (status < 300 and std.mem.find(u8, body, "\"code\":\"reset\"") != null) {
                try recordConsume(init, dir, request);
            }
            return try respond(init, body, status);
        }
    }

    if (try readExitCode(init, dir, "consume.json")) |code| std.process.exit(code);
    const scenario = Scenario.parse(init.environ_map.get("CODEX_AUTH_FAKE_CURL_SCENARIO") orelse "ok");

    if (try readFixture(init, dir, "consume.json")) |body| {
        defer init.gpa.free(body);
        const status = try readStatus(init, dir, "consume.json");
        if (status < 300 and std.mem.find(u8, body, "\"code\":\"reset\"") != null) {
            try recordConsume(init, dir, request);
        }
        return try respond(init, body, status);
    }

    switch (scenario) {
        .timeout => std.process.exit(exit_timed_out),
        .resolve_failed => std.process.exit(exit_resolve_failed),
        else => {},
    }

    if (scenario == .ok) try recordConsume(init, dir, request);
    try respond(init, scenario.body(), scenario.status());
}

fn serveFixture(
    init: std.process.Init,
    dir: std.Io.Dir,
    request: Request,
    name: []const u8,
    fallback: ?[]const u8,
) !void {
    var names = std.ArrayList([]u8).empty;
    defer {
        for (names.items) |candidate| init.gpa.free(candidate);
        names.deinit(init.gpa);
    }

    // After a successful redeem the account changed state, so a fixture for that
    // state wins over the pre-redeem one.
    const marker = try consumedMarkerName(init.gpa, request.account_id);
    defer init.gpa.free(marker);
    if (try exists(init, dir, marker)) {
        try names.append(init.gpa, try init.gpa.print("after-consume-{s}-{s}.json", .{ name, request.account_id }));
        try names.append(init.gpa, try init.gpa.print("after-consume-{s}.json", .{name}));
    }
    try names.append(init.gpa, try init.gpa.print("{s}-{s}.json", .{ name, request.account_id }));
    try names.append(init.gpa, try init.gpa.print("{s}.json", .{name}));

    for (names.items) |candidate| {
        if (try readExitCode(init, dir, candidate)) |code| std.process.exit(code);
        const body = try readFixture(init, dir, candidate) orelse continue;
        defer init.gpa.free(body);
        const status = try readStatus(init, dir, candidate);
        return try respond(init, body, status);
    }

    if (fallback) |body| return try respond(init, body, 200);
    try respond(init, "{}", 404);
}

fn consumedMarkerName(gpa: std.mem.Allocator, account_id: []const u8) ![]u8 {
    return try gpa.print("consumed-{s}", .{account_id});
}

fn markConsumed(init: std.process.Init, dir: std.Io.Dir, account_id: []const u8) !void {
    const marker = try consumedMarkerName(init.gpa, account_id);
    defer init.gpa.free(marker);
    const stamp = try init.gpa.print("{d}\n", .{nowSeconds(init)});
    defer init.gpa.free(stamp);
    try dir.writeFile(init.io, .{ .sub_path = marker, .data = stamp });
}

const FakeCredit = struct {
    id: []const u8,
    status: []const u8,
    expires_at: ?[]const u8 = null,
    title: ?[]const u8 = null,
};

const FakeCreditsFile = struct {
    credits: []FakeCredit,
};

/// Applies a successful consume to the account's credit state: the card named
/// in the request body is removed from the remaining list, and that list is
/// persisted as the new after-consume state. This models the real backend —
/// whichever card the caller consumed disappears, not "all of them" — so a
/// multi-card account still shows what is left, in any redemption order.
fn recordConsume(
    init: std.process.Init,
    dir: std.Io.Dir,
    request: Request,
) !void {
    try markConsumed(init, dir, request.account_id);
    const body = request.body orelse return;

    const parsed_body = std.json.parseFromSlice(struct { credit_id: []const u8 }, init.gpa, body, .{
        .ignore_unknown_fields = true,
    }) catch return;
    defer parsed_body.deinit();
    if (parsed_body.value.credit_id.len == 0) return;
    const credit_id = parsed_body.value.credit_id;

    // Current remaining state: a previous consume this session wins over the
    // pristine per-account fixture.
    const after_name = try init.gpa.print("after-consume-credits-{s}.json", .{request.account_id});
    defer init.gpa.free(after_name);
    const base_name = try init.gpa.print("credits-{s}.json", .{request.account_id});
    defer init.gpa.free(base_name);
    const current = (try readFixture(init, dir, after_name)) orelse
        (try readFixture(init, dir, base_name)) orelse return;
    defer init.gpa.free(current);

    const parsed_credits = std.json.parseFromSliceLeaky(FakeCreditsFile, init.gpa, current, .{
        .ignore_unknown_fields = true,
    }) catch return;
    var flipped = false;
    var available_count: usize = 0;
    for (parsed_credits.credits) |*credit| {
        if (std.mem.eql(u8, credit.id, credit_id)) {
            credit.status = "consumed";
            flipped = true;
        }
        if (std.mem.eql(u8, credit.status, "available")) available_count += 1;
    }
    if (!flipped) return;

    // Stringify copies, so the written body outlives the parse allocation.
    const credits_body = std.json.Stringify.valueAlloc(init.gpa, .{ .credits = parsed_credits.credits }, .{}) catch return;
    defer init.gpa.free(credits_body);
    try dir.writeFile(init.io, .{ .sub_path = after_name, .data = credits_body });

    patchAfterConsumeUsageCount(init, dir, request.account_id, available_count) catch {};
}

/// Keeps the usage fixture's `available_count` in step with the remaining
/// credit list, so the table cell and the rail header tell the same story.
fn patchAfterConsumeUsageCount(
    init: std.process.Init,
    dir: std.Io.Dir,
    account_id: []const u8,
    count: usize,
) !void {
    const name = try init.gpa.print("after-consume-usage-{s}.json", .{account_id});
    defer init.gpa.free(name);
    const text = (try readFixture(init, dir, name)) orelse return;
    defer init.gpa.free(text);
    const needle = "\"available_count\":";
    const idx = std.mem.find(u8, text, needle) orelse return;
    var digits_end = idx + needle.len;
    while (digits_end < text.len and std.ascii.isDigit(text[digits_end])) digits_end += 1;
    const patched = try init.gpa.print("{s}{d}{s}", .{ text[0 .. idx + needle.len], count, text[digits_end..] });
    defer init.gpa.free(patched);
    try dir.writeFile(init.io, .{ .sub_path = name, .data = patched });
}

fn nowSeconds(init: std.process.Init) i64 {
    return std.Io.Timestamp.now(init.io, .real).toSeconds();
}

fn exists(init: std.process.Init, dir: std.Io.Dir, name: []const u8) !bool {
    var file = dir.openFile(init.io, name, .{}) catch |err| switch (err) {
        error.FileNotFound => return false,
        else => return err,
    };
    file.close(init.io);
    return true;
}

/// Reads a fixture, or null when it is absent or empty.
fn readFixture(init: std.process.Init, dir: std.Io.Dir, name: []const u8) !?[]u8 {
    var file = dir.openFile(init.io, name, .{}) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return err,
    };
    defer file.close(init.io);
    var buffer: [8192]u8 = undefined;
    var reader = file.reader(init.io, &buffer);
    const data = try reader.interface.allocRemaining(init.gpa, .limited(4 * 1024 * 1024));
    // An empty read owns no allocation, so it must not be handed out for freeing.
    if (data.len == 0) return null;
    return data;
}

/// HTTP status for `<name>.json`, read from a sibling `<name>.status` file.
fn readStatus(init: std.process.Init, dir: std.Io.Dir, json_name: []const u8) !u16 {
    const suffix = ".json";
    if (!std.mem.endsWith(u8, json_name, suffix)) return 200;
    const status_name = try init.gpa.print("{s}.status", .{json_name[0 .. json_name.len - suffix.len]});
    defer init.gpa.free(status_name);
    const text = try readFixture(init, dir, status_name) orelse return 200;
    defer init.gpa.free(text);
    return std.fmt.parseInt(u16, std.mem.trim(u8, text, " \r\n\t"), 10) catch 200;
}

/// A sibling `<name>.exit` file makes the request fail the way curl would, without
/// answering, so one account in a batch can fail transport while others succeed.
fn readExitCode(init: std.process.Init, dir: std.Io.Dir, json_name: []const u8) !?u8 {
    const suffix = ".json";
    if (!std.mem.endsWith(u8, json_name, suffix)) return null;
    const exit_name = try init.gpa.print("{s}.exit", .{json_name[0 .. json_name.len - suffix.len]});
    defer init.gpa.free(exit_name);
    const text = try readFixture(init, dir, exit_name) orelse return null;
    defer init.gpa.free(text);
    return std.fmt.parseInt(u8, std.mem.trim(u8, text, " \r\n\t"), 10) catch null;
}

fn appendLog(init: std.process.Init, dir: std.Io.Dir, request: Request) !void {
    const line = try init.gpa.print("{d} {s} {s} account={s} body={s}\n", .{
        nowSeconds(init),
        request.method(),
        request.url,
        request.account_id,
        request.body orelse "-",
    });
    defer init.gpa.free(line);

    const existing = try readFixture(init, dir, log_name) orelse "";
    defer if (existing.len != 0) init.gpa.free(existing);

    var lines = std.ArrayList([]const u8).empty;
    defer lines.deinit(init.gpa);
    var iter = std.mem.splitScalar(u8, existing, '\n');
    while (iter.next()) |entry| {
        if (entry.len == 0) continue;
        try lines.append(init.gpa, entry);
    }

    var combined: std.Io.Writer.Allocating = .init(init.gpa);
    defer combined.deinit();
    const start = if (lines.items.len + 1 > max_log_lines) lines.items.len + 1 - max_log_lines else 0;
    for (lines.items[start..]) |entry| {
        try combined.writer.print("{s}\n", .{entry});
    }
    try combined.writer.print("{s}", .{line});

    try dir.writeFile(init.io, .{ .sub_path = log_name, .data = combined.written() });
}

fn respond(init: std.process.Init, body: []const u8, status: u16) !void {
    var buffer: [4096]u8 = undefined;
    var writer = std.Io.File.stdout().writer(init.io, &buffer);
    try writer.interface.print("{s}\n{d}", .{ body, status });
    try writer.interface.flush();
}

/// Value of a curl config entry, either `key = "value"` or a header fragment
/// such as `ChatGPT-Account-Id: `, up to the closing quote.
fn configValue(config: []const u8, needle: []const u8) ?[]const u8 {
    const start = (std.mem.find(u8, config, needle) orelse return null) + needle.len;
    var index = start;
    while (index < config.len) : (index += 1) {
        switch (config[index]) {
            '\\' => index += 1,
            '"' => return config[start..index],
            else => {},
        }
    }
    return config[start..];
}

/// Turns the escaped `data` value of a curl config line back into JSON text so
/// the request log stays readable.
fn unescapeJson(gpa: std.mem.Allocator, escaped: []const u8) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(gpa);
    errdefer out.deinit();
    var index: usize = 0;
    while (index < escaped.len) : (index += 1) {
        if (escaped[index] == '\\' and index + 1 < escaped.len) {
            index += 1;
            switch (escaped[index]) {
                'n' => try out.writer.writeByte('\n'),
                'r' => try out.writer.writeByte('\r'),
                't' => try out.writer.writeByte('\t'),
                else => try out.writer.writeByte(escaped[index]),
            }
            continue;
        }
        try out.writer.writeByte(escaped[index]);
    }
    const copy = try gpa.dupe(u8, out.written());
    out.deinit();
    return copy;
}

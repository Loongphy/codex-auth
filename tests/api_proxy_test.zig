const std = @import("std");
const codex_auth = @import("codex_auth");

const http = codex_auth.api.http;
const proxy = http.proxy;
const curl = http.curl;

const Proxy = proxy.Proxy;
const SystemProxy = proxy.SystemProxy;

/// `Proxy` owns its strings, so tests build one through an allocator.
fn ownedProxy(
    allocator: std.mem.Allocator,
    url: []const u8,
    noproxy: ?[]const u8,
) !Proxy {
    var value = Proxy{ .url = try allocator.dupe(u8, url), .noproxy = null };
    errdefer value.deinit(allocator);
    if (noproxy) |excluded| value.noproxy = try allocator.dupe(u8, excluded);
    return value;
}

const EnvFixture = struct {
    map: std.process.Environ.Map,

    fn init(values: []const [2][]const u8) !EnvFixture {
        var map = std.process.Environ.Map.init(std.testing.allocator);
        errdefer map.deinit();
        for (values) |entry| try map.put(entry[0], entry[1]);
        return .{ .map = map };
    }

    fn deinit(self: *EnvFixture) void {
        self.map.deinit();
    }
};

/// `decide` must yield no proxy at all.
fn expectDirect(
    values: []const [2][]const u8,
    system: SystemProxy,
    scheme: proxy.Scheme,
) !void {
    var fixture = try EnvFixture.init(values);
    defer fixture.deinit();
    const resolved = try proxy.decide(std.testing.allocator, &fixture.map, system, scheme);
    try std.testing.expect(resolved == null);
}

/// `decide` must yield exactly this proxy and exclusion list.
fn expectProxied(
    values: []const [2][]const u8,
    system: SystemProxy,
    scheme: proxy.Scheme,
    want_url: []const u8,
    want_noproxy: ?[]const u8,
) !void {
    var fixture = try EnvFixture.init(values);
    defer fixture.deinit();

    var resolved = try proxy.decide(std.testing.allocator, &fixture.map, system, scheme) orelse {
        return error.TestUnexpectedResult;
    };
    defer resolved.deinit(std.testing.allocator);

    try std.testing.expectEqualStrings(want_url, resolved.url);
    if (want_noproxy) |noproxy| {
        try std.testing.expect(resolved.noproxy != null);
        try std.testing.expectEqualStrings(noproxy, resolved.noproxy.?);
    } else {
        try std.testing.expect(resolved.noproxy == null);
    }
}

test "CODEX_AUTH_PROXY overrides proxy environment and system settings" {
    try expectProxied(
        &.{
            .{ proxy.proxy_override_env, "http://127.0.0.1:8080" },
            .{ "HTTPS_PROXY", "http://from-env:7890" },
            .{ "NO_PROXY", "internal.example" },
        },
        .{ .server = "127.0.0.1:7890", .bypass = "<local>;127.*" },
        .https,
        "http://127.0.0.1:8080",
        "internal.example",
    );
}

test "CODEX_AUTH_PROXY can force a direct connection" {
    const cases = [_][]const u8{ "", "none", "NONE", " direct " };
    for (cases) |value| {
        try expectDirect(
            &.{
                .{ proxy.proxy_override_env, value },
                .{ "HTTPS_PROXY", "http://from-env:7890" },
            },
            .{ .server = "127.0.0.1:7890" },
            .https,
        );
    }
}

test "proxy environment variables are left to curl" {
    const system = SystemProxy{ .server = "127.0.0.1:7890" };
    // curl reads these for an https request, so nothing is injected.
    const https_keys = [_][]const u8{ "HTTPS_PROXY", "https_proxy", "ALL_PROXY", "all_proxy" };
    for (https_keys) |key| {
        try expectDirect(&.{.{ key, "http://from-env:7890" }}, system, .https);
    }
    const http_keys = [_][]const u8{ "HTTP_PROXY", "http_proxy", "ALL_PROXY", "all_proxy" };
    for (http_keys) |key| {
        try expectDirect(&.{.{ key, "http://from-env:7890" }}, system, .http);
    }

    // The other scheme's variable alone must not suppress the system proxy.
    try expectProxied(&.{.{ "HTTP_PROXY", "http://from-env:7890" }}, .{ .server = "127.0.0.1:7890" }, .https, "127.0.0.1:7890", null);
    try expectProxied(&.{.{ "HTTPS_PROXY", "http://from-env:7890" }}, .{ .server = "127.0.0.1:7890" }, .http, "127.0.0.1:7890", null);

    // An empty value means "not set".
    try expectProxied(
        &.{ .{ "HTTPS_PROXY", "" }, .{ "NO_PROXY", "localhost" } },
        .{ .server = "127.0.0.1:7890" },
        .https,
        "127.0.0.1:7890",
        "localhost",
    );
}

test "no proxy source yields a direct connection" {
    try expectDirect(&.{}, .{}, .https);
    try expectDirect(&.{.{ "NO_PROXY", "localhost" }}, .{}, .https);
    try expectDirect(&.{}, .{ .server = "" }, .https);
    try expectDirect(&.{}, .{ .server = "http=;https=" }, .https);
    try expectDirect(&.{}, .{ .server = "socks=127.0.0.1:7891" }, .https);
}

test "platform proxy settings are translated when nothing else is configured" {
    try expectProxied(&.{}, .{ .server = "127.0.0.1:7890" }, .https, "127.0.0.1:7890", null);
    try expectProxied(
        &.{},
        .{ .server = "127.0.0.1:7890", .bypass = "<local>;127.*" },
        .https,
        "127.0.0.1:7890",
        "localhost,127.*",
    );
    // NO_PROXY is the user's own intent, so it wins over the bypass list.
    try expectProxied(
        &.{.{ "NO_PROXY", "already-set" }},
        .{ .server = "127.0.0.1:7890", .bypass = "<local>;127.*" },
        .https,
        "127.0.0.1:7890",
        "already-set",
    );
}

test "per protocol proxy server lists select the matching scheme" {
    const mixed = "http=127.0.0.1:7890;https=127.0.0.1:7893;socks=127.0.0.1:7891";
    try std.testing.expectEqualStrings("127.0.0.1:7893", proxy.pickProxyServer(.https, mixed).?);
    try std.testing.expectEqualStrings("127.0.0.1:7890", proxy.pickProxyServer(.http, mixed).?);

    // Only an http entry: https falls back to it, curl speaks HTTP CONNECT.
    try std.testing.expectEqualStrings("127.0.0.1:7890", proxy.pickProxyServer(.https, "http=127.0.0.1:7890").?);
    try std.testing.expectEqualStrings(
        "127.0.0.1:7890",
        proxy.pickProxyServer(.https, "http = 127.0.0.1:7890 ; socks=127.0.0.1:7891").?,
    );

    // Bare host:port, surrounding spaces, and an explicit scheme.
    try std.testing.expectEqualStrings("127.0.0.1:7890", proxy.pickProxyServer(.https, " 127.0.0.1:7890 ").?);
    try std.testing.expectEqualStrings(
        "socks5://127.0.0.1:7891",
        proxy.pickProxyServer(.https, "https=socks5://127.0.0.1:7891").?,
    );

    // Nothing usable.
    try std.testing.expectEqual(null, proxy.pickProxyServer(.https, "socks=127.0.0.1:7891"));
    try std.testing.expectEqual(null, proxy.pickProxyServer(.https, "https=;"));
    try std.testing.expectEqual(null, proxy.pickProxyServer(.https, ""));
}

test "wininet bypass lists become curl noproxy lists" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const translated = (try proxy.translateBypass(allocator, "localhost;127.*;<local>;10.*")).?;
    try std.testing.expectEqualStrings("localhost,127.*,10.*", translated);

    const deduped = (try proxy.translateBypass(allocator, "<local>;localhost")).?;
    try std.testing.expectEqualStrings("localhost", deduped);

    const single = (try proxy.translateBypass(allocator, " example.com ")).?;
    try std.testing.expectEqualStrings("example.com", single);

    try std.testing.expectEqual(null, try proxy.translateBypass(allocator, ""));
    try std.testing.expectEqual(null, try proxy.translateBypass(allocator, ";;"));
}

test "request schemes are recognised" {
    try std.testing.expectEqual(proxy.Scheme.https, proxy.schemeOf("https://chatgpt.com/backend-api/wham/usage"));
    try std.testing.expectEqual(proxy.Scheme.https, proxy.schemeOf("HTTPS://ChatGPT.com/"));
    try std.testing.expectEqual(proxy.Scheme.http, proxy.schemeOf("http://127.0.0.1:7890/x"));
    try std.testing.expectEqual(proxy.Scheme.http, proxy.schemeOf("//host/x"));
}

test "curl config carries the translated proxy options" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const headers = [_][]const u8{"Authorization: Bearer t-o-k-e-n"};
    var config: std.ArrayList(u8) = .empty;
    defer config.deinit(allocator);
    var resolved = try ownedProxy(allocator, "http://127.0.0.1:7890", "localhost,127.*");
    defer resolved.deinit(allocator);
    try curl.appendCurlConfig(allocator, &config, "https://chatgpt.com/x", &headers, resolved);

    try std.testing.expect(std.mem.indexOf(u8, config.items, "url = \"https://chatgpt.com/x\"\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, config.items, "header = \"Authorization: Bearer t-o-k-e-n\"\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, config.items, "proxy = \"http://127.0.0.1:7890\"\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, config.items, "noproxy = \"localhost,127.*\"\n") != null);

    // Without a resolved proxy the document is unchanged from the old output.
    var plain: std.ArrayList(u8) = .empty;
    defer plain.deinit(allocator);
    try curl.appendCurlConfig(allocator, &plain, "https://chatgpt.com/x", &headers, null);
    try std.testing.expect(std.mem.indexOf(u8, plain.items, "proxy") == null);
    try std.testing.expect(std.mem.indexOf(u8, plain.items, "noproxy") == null);
}

test "curl config quotes proxy values" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const no_headers = [_][]const u8{};
    var config: std.ArrayList(u8) = .empty;
    defer config.deinit(allocator);
    var resolved = try ownedProxy(allocator, "http://user\"with\\quote:pw@127.0.0.1:1", "a\\b\"c");
    defer resolved.deinit(allocator);
    try curl.appendCurlConfig(allocator, &config, "https://x/y", &no_headers, resolved);
    try std.testing.expect(std.mem.indexOf(u8, config.items, "proxy = \"http://user\\\"with\\\\quote:pw@127.0.0.1:1\"\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, config.items, "noproxy = \"a\\\\b\\\"c\"\n") != null);
}

test "resolution against the live environment is stable" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    // Whatever the machine is configured with, resolution must succeed and be
    // idempotent: the platform proxy settings are cached after the first call.
    var first = try proxy.resolve(allocator, "https://chatgpt.com/backend-api/wham/usage");
    if (first) |*value| value.deinit(allocator);
    var second = try proxy.resolve(allocator, "https://chatgpt.com/backend-api/wham/usage");
    if (second) |*value| value.deinit(allocator);
    try std.testing.expect((first == null) == (second == null));
    if (first) |a| {
        try std.testing.expectEqualStrings(a.url, second.?.url);
    }

    const cached = proxy.systemProxy();
    const again = proxy.systemProxy();
    try std.testing.expectEqualStrings(cached.server orelse "", again.server orelse "");
    try std.testing.expectEqualStrings(cached.bypass orelse "", again.bypass orelse "");
}

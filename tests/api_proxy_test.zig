const std = @import("std");
const codex_auth = @import("codex_auth");

const http = codex_auth.api.http;
const proxy = http.proxy;
const scutil = http.scutil;
const curl = http.curl;

const Proxy = proxy.Proxy;
const SystemProxy = proxy.SystemProxy;

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

test "scheme of endpoint follows the url prefix" {
    try std.testing.expectEqual(
        proxy.Scheme.https,
        proxy.schemeOf("https://chatgpt.com/backend-api/wham/usage"),
    );
    try std.testing.expectEqual(proxy.Scheme.http, proxy.schemeOf("http://example.com"));
    try std.testing.expectEqual(proxy.Scheme.http, proxy.schemeOf("chatgpt.com"));
}

test "bare proxy server applies to every scheme" {
    const picked_https = proxy.pickProxyServer(.https, "127.0.0.1:7890").?;
    try std.testing.expectEqualStrings("127.0.0.1:7890", picked_https.hostport);
    try std.testing.expect(!picked_https.socks);

    const picked_http = proxy.pickProxyServer(.http, "  127.0.0.1:7890  ").?;
    try std.testing.expectEqualStrings("127.0.0.1:7890", picked_http.hostport);
}

test "per protocol proxy server picks the matching entry" {
    const raw = "http=127.0.0.1:7890;https=127.0.0.1:7891;socks=127.0.0.1:7892";
    try std.testing.expectEqualStrings("127.0.0.1:7891", proxy.pickProxyServer(.https, raw).?.hostport);
    try std.testing.expectEqualStrings("127.0.0.1:7890", proxy.pickProxyServer(.http, raw).?.hostport);
}

test "opposite http scheme outranks socks as a fallback" {
    try std.testing.expectEqualStrings(
        "127.0.0.1:7890",
        proxy.pickProxyServer(.https, "http=127.0.0.1:7890").?.hostport,
    );
    try std.testing.expectEqualStrings(
        "127.0.0.1:7890",
        proxy.pickProxyServer(.http, "https=127.0.0.1:7890").?.hostport,
    );
    try std.testing.expectEqualStrings(
        "127.0.0.1:7890",
        proxy.pickProxyServer(.https, "http=127.0.0.1:7890;socks=127.0.0.1:7892").?.hostport,
    );
}

test "socks only system proxy is still usable" {
    const picked = proxy.pickProxyServer(.https, "socks=127.0.0.1:7892").?;
    try std.testing.expectEqualStrings("127.0.0.1:7892", picked.hostport);
    try std.testing.expect(picked.socks);
}

test "exact scheme match is not flagged as socks" {
    const picked = proxy.pickProxyServer(.https, "https=127.0.0.1:7890;socks=127.0.0.1:7892").?;
    try std.testing.expectEqualStrings("127.0.0.1:7890", picked.hostport);
    try std.testing.expect(!picked.socks);
}

test "empty proxy server yields nothing" {
    try std.testing.expect(proxy.pickProxyServer(.https, "") == null);
    try std.testing.expect(proxy.pickProxyServer(.https, "   ") == null);
    try std.testing.expect(proxy.pickProxyServer(.https, "http=;https=") == null);
}

test "bypass list translates the wininet local shorthand" {
    const allocator = std.testing.allocator;
    const translated = (try proxy.translateBypass(allocator, "<local>;*.internal;127.0.0.1")).?;
    defer allocator.free(translated);
    try std.testing.expectEqualStrings("localhost,*.internal,127.0.0.1", translated);
}

test "bypass list drops duplicates and accepts either separator" {
    const allocator = std.testing.allocator;
    const translated = (try proxy.translateBypass(allocator, "a.com;A.COM,<local>,<LOCAL>,b.com")).?;
    defer allocator.free(translated);
    try std.testing.expectEqualStrings("a.com,localhost,b.com", translated);
}

test "empty bypass list yields nothing" {
    const allocator = std.testing.allocator;
    try std.testing.expect(try proxy.translateBypass(allocator, "") == null);
    try std.testing.expect(try proxy.translateBypass(allocator, " ; ; ") == null);
}

test "explicit proxy environment variable is left to curl" {
    const system = SystemProxy{ .server = "127.0.0.1:7890" };
    try expectDirect(&.{.{ "HTTPS_PROXY", "http://corp.example:8080" }}, system, .https);
    try expectDirect(&.{.{ "https_proxy", "http://corp.example:8080" }}, system, .https);
    try expectDirect(&.{.{ "HTTP_PROXY", "http://corp.example:8080" }}, system, .http);
    try expectDirect(&.{.{ "ALL_PROXY", "socks5h://127.0.0.1:7890" }}, system, .https);
}

test "system proxy is injected when no environment variable is set" {
    try expectProxied(
        &.{},
        SystemProxy{ .server = "127.0.0.1:7890", .bypass = "<local>" },
        .https,
        "127.0.0.1:7890",
        "localhost",
    );
}

test "no system proxy and no environment variable connects directly" {
    try expectDirect(&.{}, .{}, .https);
    try expectDirect(&.{}, SystemProxy{ .bypass = "<local>" }, .https);
}

test "socks only system proxy gets the curl socks5h scheme" {
    try expectProxied(
        &.{},
        SystemProxy{ .server = "socks=127.0.0.1:7892" },
        .https,
        "socks5h://127.0.0.1:7892",
        null,
    );
}

test "explicit no proxy wins over the platform bypass list" {
    try expectProxied(
        &.{.{ "NO_PROXY", "corp.example" }},
        SystemProxy{ .server = "127.0.0.1:7890", .bypass = "<local>;*.internal" },
        .https,
        "127.0.0.1:7890",
        "corp.example",
    );
}

test "scutil output becomes a per protocol proxy server list" {
    const allocator = std.testing.allocator;
    const text =
        \\<dictionary> {
        \\  ExceptionsList : <array> {
        \\    0 : 127.0.0.1
        \\    1 : *.local
        \\    2 : localhost
        \\  }
        \\  ExcludeSimpleHostnames : 1
        \\  HTTPEnable : 1
        \\  HTTPPort : 7890
        \\  HTTPProxy : 127.0.0.1
        \\  HTTPSEnable : 1
        \\  HTTPSPort : 7890
        \\  HTTPSProxy : 127.0.0.1
        \\  SOCKSEnable : 1
        \\  SOCKSPort : 7891
        \\  SOCKSProxy : 127.0.0.1
        \\}
        \\
    ;

    const values = try scutil.parse(allocator, text);
    defer if (values.server) |server| allocator.free(server);
    defer if (values.bypass) |bypass| allocator.free(bypass);

    try std.testing.expectEqualStrings(
        "http=127.0.0.1:7890;https=127.0.0.1:7890;socks=127.0.0.1:7891",
        values.server.?,
    );
    try std.testing.expectEqualStrings("127.0.0.1,*.local,localhost", values.bypass.?);
}

test "scutil reports only the enabled protocols" {
    const allocator = std.testing.allocator;
    const text =
        \\<dictionary> {
        \\  HTTPEnable : 0
        \\  HTTPProxy : 127.0.0.1
        \\  HTTPPort : 7890
        \\  HTTPSEnable : 1
        \\  HTTPSProxy : 127.0.0.1
        \\  HTTPSPort : 7890
        \\}
        \\
    ;

    const values = try scutil.parse(allocator, text);
    defer if (values.server) |server| allocator.free(server);

    try std.testing.expectEqualStrings("https=127.0.0.1:7890", values.server.?);
    try std.testing.expect(values.bypass == null);
}

test "scutil with no manual proxy reports nothing" {
    const allocator = std.testing.allocator;

    const disabled = try scutil.parse(allocator, "<dictionary> {\n  HTTPEnable : 0\n}\n");
    try std.testing.expect(disabled.server == null);

    // A PAC-only setup needs CFNetwork's JavaScript runner, so it is reported as
    // no system proxy and falls through to the environment.
    const pac_only = try scutil.parse(allocator, "<dictionary> {\n  ProxyAutoConfigEnable : 1\n  ProxyAutoConfigURLString : http://wpad.example/proxy.pac\n}\n");
    try std.testing.expect(pac_only.server == null);

    const empty = try scutil.parse(allocator, "<dictionary> {\n}\n");
    try std.testing.expect(empty.server == null);
}

test "scutil skips an enabled protocol that has no host" {
    const allocator = std.testing.allocator;
    const text =
        \\<dictionary> {
        \\  HTTPEnable : 1
        \\  HTTPPort : 7890
        \\  HTTPSEnable : 1
        \\  HTTPSProxy : 127.0.0.1
        \\  HTTPSPort : 7890
        \\}
        \\
    ;

    const values = try scutil.parse(allocator, text);
    defer if (values.server) |server| allocator.free(server);

    try std.testing.expectEqualStrings("https=127.0.0.1:7890", values.server.?);
}

test "resolved proxy is written into the curl config document" {
    const allocator = std.testing.allocator;

    var config = std.ArrayList(u8).empty;
    defer config.deinit(allocator);

    var resolved = Proxy{
        .url = try allocator.dupe(u8, "127.0.0.1:7890"),
        .noproxy = try allocator.dupe(u8, "localhost,*.internal"),
    };
    defer resolved.deinit(allocator);

    try curl.appendCurlConfig(allocator, &config, "https://chatgpt.com/backend-api/wham/usage", &.{"Authorization: Bearer token"}, resolved);

    try std.testing.expect(std.mem.indexOf(u8, config.items, "url = \"https://chatgpt.com/backend-api/wham/usage\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, config.items, "proxy = \"127.0.0.1:7890\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, config.items, "noproxy = \"localhost,*.internal\"") != null);
}

test "curl config document omits proxy options when none resolved" {
    const allocator = std.testing.allocator;

    var config = std.ArrayList(u8).empty;
    defer config.deinit(allocator);

    try curl.appendCurlConfig(allocator, &config, "https://chatgpt.com/backend-api/accounts", &.{}, null);

    try std.testing.expect(std.mem.indexOf(u8, config.items, "proxy = ") == null);
    try std.testing.expect(std.mem.indexOf(u8, config.items, "noproxy = ") == null);
    try std.testing.expect(std.mem.indexOf(u8, config.items, "url = \"https://chatgpt.com/backend-api/accounts\"") != null);
}

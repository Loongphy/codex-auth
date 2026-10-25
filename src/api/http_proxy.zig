//! Proxy selection for the `curl` child process.
//!
//! `curl` discovers proxies only through its own environment variables. On
//! Windows the user's proxy lives in the WinINET registry keys instead, and
//! `curl` never reads them, so a machine whose browser traffic is proxied would
//! connect directly from `curl` and stall until `--max-time` expires. This
//! module translates the platform proxy settings into explicit `curl` options.
//!
//! Decision order:
//!
//! 1. `CODEX_AUTH_PROXY` — an explicit override for scripts, CI, and support.
//!    Empty, `none`, or `direct` forces a direct connection.
//! 2. Proxy environment variables already present — `curl` handles those itself,
//!    together with `NO_PROXY`, so nothing is injected.
//! 3. The platform system proxy (Windows WinINET registry) — injected as the
//!    `proxy` and `noproxy` curl config options.
//! 4. Nothing — direct connection, which is the pre-existing behaviour.

const builtin = @import("builtin");
const std = @import("std");
const env = @import("http_env.zig");

const no_windows_proxy = struct {
    pub const Values = struct {
        enabled: bool = false,
        server: ?[]const u8 = null,
        bypass: ?[]const u8 = null,
    };
    pub fn read(_: std.mem.Allocator) !Values {
        return .{};
    }
};

const windows_registry = if (builtin.os.tag == .windows)
    @import("http_proxy_windows.zig")
else
    no_windows_proxy;

pub const proxy_override_env = "CODEX_AUTH_PROXY";
pub const direct_values = [_][]const u8{ "", "none", "direct" };

pub const Scheme = enum { http, https };

pub const Proxy = struct {
    url: []u8,
    noproxy: ?[]u8,

    pub fn deinit(self: *Proxy, allocator: std.mem.Allocator) void {
        allocator.free(self.url);
        if (self.noproxy) |noproxy| allocator.free(noproxy);
        self.* = undefined;
    }
};

/// Raw platform proxy settings, using the platform's own value formats.
pub const SystemProxy = struct {
    /// WinINET `ProxyServer`: `host:port` or a per-protocol list.
    server: ?[]const u8 = null,
    /// WinINET `ProxyOverride`: `;` separated bypass list.
    bypass: ?[]const u8 = null,
};

const no_proxy_env_keys = [_][]const u8{ "NO_PROXY", "no_proxy" };

/// Resolve the proxy to use for `endpoint` in this process.
pub fn resolve(allocator: std.mem.Allocator, endpoint: []const u8) !?Proxy {
    var env_map = try env.getEnvMap(allocator);
    defer env_map.deinit();
    return decide(allocator, &env_map, systemProxy(), schemeOf(endpoint));
}

pub fn schemeOf(endpoint: []const u8) Scheme {
    if (std.ascii.startsWithIgnoreCase(endpoint, "https://")) return .https;
    return .http;
}

/// `curl` only looks at these environment variables for a given scheme.
pub fn proxyEnvKeys(scheme: Scheme) []const []const u8 {
    return switch (scheme) {
        .https => &[_][]const u8{ "HTTPS_PROXY", "https_proxy", "ALL_PROXY", "all_proxy" },
        .http => &[_][]const u8{ "HTTP_PROXY", "http_proxy", "ALL_PROXY", "all_proxy" },
    };
}

/// Pure decision function, so the precedence rules stay testable on every
/// platform without touching a registry or the process environment.
pub fn decide(
    allocator: std.mem.Allocator,
    env_map: *const std.process.Environ.Map,
    system: SystemProxy,
    scheme: Scheme,
) !?Proxy {
    if (envValue(env_map, proxy_override_env)) |override| {
        if (isDirectValue(override)) return null;
        return Proxy{
            .url = try allocator.dupe(u8, override),
            .noproxy = try noproxyValue(allocator, env_map, null),
        };
    }

    for (proxyEnvKeys(scheme)) |key| {
        if (envValue(env_map, key) != null) return null;
    }

    const server = system.server orelse return null;
    const picked = pickProxyServer(scheme, server) orelse return null;
    return Proxy{
        .url = try allocator.dupe(u8, picked),
        .noproxy = try noproxyValue(allocator, env_map, system.bypass),
    };
}

/// Exclusion list for `noproxy`: an explicit `NO_PROXY` wins over the platform
/// bypass list, because it is the user's own current intent.
fn noproxyValue(
    allocator: std.mem.Allocator,
    env_map: *const std.process.Environ.Map,
    platform_bypass: ?[]const u8,
) !?[]u8 {
    if (noProxyEnvValue(env_map)) |from_env| return try allocator.dupe(u8, from_env);
    const bypass = platform_bypass orelse return null;
    return try translateBypass(allocator, bypass);
}

/// `ProxyServer` is either a bare `host:port` or a per-protocol list such as
/// `http=127.0.0.1:7890;https=127.0.0.1:7890;socks=127.0.0.1:7891`.
pub fn pickProxyServer(scheme: Scheme, raw: []const u8) ?[]const u8 {
    const trimmed = std.mem.trim(u8, raw, " \t");
    if (trimmed.len == 0) return null;
    if (std.mem.indexOfScalar(u8, trimmed, '=') == null) return trimmed;

    const wanted = switch (scheme) {
        .https => "https",
        .http => "http",
    };
    var fallback: ?[]const u8 = null;
    var it = std.mem.splitScalar(u8, trimmed, ';');
    while (it.next()) |entry| {
        const item = std.mem.trim(u8, entry, " \t");
        const eq = std.mem.indexOfScalar(u8, item, '=') orelse continue;
        const key = std.mem.trim(u8, item[0..eq], " \t");
        const value = std.mem.trim(u8, item[eq + 1 ..], " \t");
        if (value.len == 0) continue;
        if (std.ascii.eqlIgnoreCase(key, wanted)) return value;
        if (fallback == null and (std.ascii.eqlIgnoreCase(key, "https") or std.ascii.eqlIgnoreCase(key, "http"))) {
            fallback = value;
        }
    }
    return fallback;
}

/// Translate a WinINET bypass list into curl's comma separated `noproxy` list.
/// `<local>` becomes `localhost`, duplicates are dropped, and empty input yields
/// `null`.
pub fn translateBypass(allocator: std.mem.Allocator, raw: []const u8) !?[]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    var seen: std.ArrayList([]const u8) = .empty;
    defer seen.deinit(allocator);

    var it = std.mem.splitAny(u8, raw, ";,");
    while (it.next()) |part_raw| {
        var part = std.mem.trim(u8, part_raw, " \t");
        if (part.len == 0) continue;
        if (std.ascii.eqlIgnoreCase(part, "<local>") or std.ascii.eqlIgnoreCase(part, "<loopback>")) {
            part = "localhost";
        }
        if (containsEntry(seen.items, part)) continue;
        if (out.items.len != 0) try out.append(allocator, ',');
        try out.appendSlice(allocator, part);
        try seen.append(allocator, part);
    }
    if (out.items.len == 0) return null;
    return try out.toOwnedSlice(allocator);
}

fn containsEntry(list: []const []const u8, entry: []const u8) bool {
    for (list) |item| {
        if (std.ascii.eqlIgnoreCase(item, entry)) return true;
    }
    return false;
}

fn noProxyEnvValue(env_map: *const std.process.Environ.Map) ?[]const u8 {
    for (no_proxy_env_keys) |key| {
        const value = envValue(env_map, key) orelse continue;
        return value;
    }
    return null;
}

fn envValue(env_map: *const std.process.Environ.Map, key: []const u8) ?[]const u8 {
    const value = env_map.get(key) orelse return null;
    if (value.len == 0) return null;
    return value;
}

fn isDirectValue(value: []const u8) bool {
    const trimmed = std.mem.trim(u8, value, " \t");
    for (direct_values) |candidate| {
        if (std.ascii.eqlIgnoreCase(trimmed, candidate)) return true;
    }
    return false;
}

var system_proxy_mutex: std.atomic.Mutex = .unlocked;
var system_proxy_cached: ?*const SystemProxy = null;

/// Platform proxy settings, read once per process. Registry failures degrade to
/// "no system proxy" so a configuration problem never turns into a request
/// error, keeping the previous direct-connect behaviour.
pub fn systemProxy() SystemProxy {
    if (@atomicLoad(?*const SystemProxy, &system_proxy_cached, .acquire)) |cached| return cached.*;

    while (!system_proxy_mutex.tryLock()) {
        std.Thread.yield() catch {};
    }
    defer system_proxy_mutex.unlock();
    if (@atomicLoad(?*const SystemProxy, &system_proxy_cached, .acquire)) |cached| return cached.*;

    const stored = std.heap.page_allocator.create(SystemProxy) catch return readSystemProxy();
    stored.* = readSystemProxy();
    @atomicStore(?*const SystemProxy, &system_proxy_cached, stored, .release);
    return stored.*;
}

fn readSystemProxy() SystemProxy {
    // Registry problems are not request errors: fall back to the previous
    // direct-connect behaviour instead of reporting a configuration failure.
    const values = windows_registry.read(std.heap.page_allocator) catch return .{};
    return .{ .server = values.server, .bypass = values.bypass };
}

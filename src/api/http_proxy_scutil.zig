//! Parser for `scutil --proxy` output.
//!
//! Kept separate from the child process that produces the text so the field and
//! exception handling is covered on every platform, not only in the macOS CI job.

const std = @import("std");

pub const Values = struct {
    /// Per-protocol list such as `http=127.0.0.1:7890;socks=127.0.0.1:7891`.
    server: ?[]const u8 = null,
    /// `ExceptionsList`, comma separated.
    bypass: ?[]const u8 = null,
};

/// Fields are kept as slices into the input text, which is valid for the whole
/// parse. `scutil` emits far fewer keys than this, so the fixed table avoids an
/// allocator round trip per line.
const max_fields = 12;

const Fields = struct {
    keys: [max_fields][]const u8 = [_][]const u8{""} ** max_fields,
    values: [max_fields][]const u8 = [_][]const u8{""} ** max_fields,
    count: usize = 0,

    fn put(self: *Fields, key: []const u8, value: []const u8) void {
        if (self.count == max_fields) return;
        self.keys[self.count] = key;
        self.values[self.count] = value;
        self.count += 1;
    }

    fn get(self: *const Fields, key: []const u8) ?[]const u8 {
        for (self.keys[0..self.count], self.values[0..self.count]) |found, value| {
            if (std.mem.eql(u8, found, key)) return value;
        }
        return null;
    }

    fn enabled(self: *const Fields, key: []const u8) bool {
        const value = self.get(key) orelse return false;
        return std.mem.eql(u8, value, "1");
    }
};

pub fn parse(allocator: std.mem.Allocator, text: []const u8) !Values {
    var fields = Fields{};
    var exceptions: std.ArrayList(u8) = .empty;
    errdefer exceptions.deinit(allocator);

    var in_exceptions = false;
    var depth: usize = 0;

    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw_line| {
        const line = std.mem.trim(u8, raw_line, " \t\r");
        if (line.len == 0) continue;

        const colon = std.mem.indexOf(u8, line, " : ");
        const key = if (colon) |idx| std.mem.trim(u8, line[0..idx], " \t") else "";
        const value = if (colon) |idx| std.mem.trim(u8, line[idx + 3 ..], " \t") else line;

        if (std.mem.endsWith(u8, value, "{")) {
            if (depth == 1) in_exceptions = std.mem.eql(u8, key, "ExceptionsList");
            depth += 1;
            continue;
        }
        if (std.mem.eql(u8, value, "}")) {
            if (depth > 0) depth -= 1;
            if (depth == 1) in_exceptions = false;
            continue;
        }
        if (colon == null) continue;

        if (in_exceptions and depth == 2) {
            // Entries are `<index> : <host>`; the index carries no meaning here.
            if (value.len == 0) continue;
            if (exceptions.items.len != 0) try exceptions.append(allocator, ',');
            try exceptions.appendSlice(allocator, value);
            continue;
        }
        if (depth != 1) continue;
        fields.put(key, value);
    }

    var server: std.ArrayList(u8) = .empty;
    errdefer server.deinit(allocator);
    try appendProtocol(allocator, &server, &fields, "http", "HTTPEnable", "HTTPProxy", "HTTPPort");
    try appendProtocol(allocator, &server, &fields, "https", "HTTPSEnable", "HTTPSProxy", "HTTPSPort");
    try appendProtocol(allocator, &server, &fields, "socks", "SOCKSEnable", "SOCKSProxy", "SOCKSPort");

    if (server.items.len == 0) {
        exceptions.deinit(allocator);
        return .{};
    }

    return Values{
        .server = try server.toOwnedSlice(allocator),
        .bypass = if (exceptions.items.len == 0) null else try exceptions.toOwnedSlice(allocator),
    };
}

/// An enabled protocol with no host is skipped rather than emitted as a
/// half-formed entry, which `curl` would reject for the whole request.
fn appendProtocol(
    allocator: std.mem.Allocator,
    server: *std.ArrayList(u8),
    fields: *const Fields,
    protocol: []const u8,
    enable_key: []const u8,
    host_key: []const u8,
    port_key: []const u8,
) !void {
    if (!fields.enabled(enable_key)) return;
    const host = fields.get(host_key) orelse return;
    if (host.len == 0) return;

    if (server.items.len != 0) try server.append(allocator, ';');
    try server.appendSlice(allocator, protocol);
    try server.append(allocator, '=');
    try server.appendSlice(allocator, host);
    if (fields.get(port_key)) |port| {
        if (port.len != 0) {
            try server.append(allocator, ':');
            try server.appendSlice(allocator, port);
        }
    }
}

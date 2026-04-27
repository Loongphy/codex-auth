const std = @import("std");
const app_runtime = @import("../core/runtime.zig");
const common = @import("common.zig");
const parse = @import("parse.zig");

const AutoSwitchConfig = common.AutoSwitchConfig;
const ApiConfig = common.ApiConfig;
const LiveConfig = common.LiveConfig;
const defaultAutoSwitchConfig = common.defaultAutoSwitchConfig;
const defaultApiConfig = common.defaultApiConfig;
const defaultLiveConfig = common.defaultLiveConfig;
const registryPath = common.registryPath;
const readFileAlloc = common.readFileAlloc;
const parseAutoSwitch = parse.parseAutoSwitch;
const parseApiConfig = parse.parseApiConfig;
const parseLiveConfig = parse.parseLiveConfig;

const PurgeCarryForwardConfig = struct {
    auto_switch: AutoSwitchConfig = defaultAutoSwitchConfig(),
    api: ApiConfig = defaultApiConfig(),
    live: LiveConfig = defaultLiveConfig(),
};

pub fn loadPurgeCarryForwardConfig(allocator: std.mem.Allocator, codex_home: []const u8) !PurgeCarryForwardConfig {
    const path = try registryPath(allocator, codex_home);
    defer allocator.free(path);

    const cwd = std.Io.Dir.cwd();
    var file = cwd.openFile(app_runtime.io(), path, .{}) catch |err| switch (err) {
        error.FileNotFound => return .{},
        else => return err,
    };
    defer file.close(app_runtime.io());

    const data = try readFileAlloc(file, allocator, 10 * 1024 * 1024);
    defer allocator.free(data);

    return parsePurgeCarryForwardConfig(allocator, data);
}

fn parsePurgeCarryForwardConfig(allocator: std.mem.Allocator, data: []const u8) PurgeCarryForwardConfig {
    var cfg = PurgeCarryForwardConfig{};

    var parsed = std.json.parseFromSlice(std.json.Value, allocator, data, .{}) catch {
        applyCarryForwardObjectSlice(allocator, data, "auto_switch", &cfg.auto_switch, parseCarryForwardAutoSwitch);
        applyCarryForwardObjectSlice(allocator, data, "api", &cfg.api, parseCarryForwardApiConfig);
        applyCarryForwardObjectSlice(allocator, data, "live", &cfg.live, parseCarryForwardLiveConfig);
        return cfg;
    };
    defer parsed.deinit();

    switch (parsed.value) {
        .object => |obj| {
            if (obj.get("auto_switch")) |v| parseAutoSwitch(allocator, &cfg.auto_switch, v);
            if (obj.get("api")) |v| parseApiConfig(&cfg.api, v);
            if (obj.get("live")) |v| parseLiveConfig(&cfg.live, v);
        },
        else => {},
    }
    return cfg;
}

fn parseCarryForwardAutoSwitch(allocator: std.mem.Allocator, value: std.json.Value, target: *AutoSwitchConfig) void {
    parseAutoSwitch(allocator, target, value);
}

fn parseCarryForwardApiConfig(_: std.mem.Allocator, value: std.json.Value, target: *ApiConfig) void {
    parseApiConfig(target, value);
}

fn parseCarryForwardLiveConfig(_: std.mem.Allocator, value: std.json.Value, target: *LiveConfig) void {
    parseLiveConfig(target, value);
}

fn applyCarryForwardObjectSlice(
    allocator: std.mem.Allocator,
    data: []const u8,
    field_name: []const u8,
    target: anytype,
    comptime parser: fn (std.mem.Allocator, std.json.Value, @TypeOf(target)) void,
) void {
    const slice = findJsonObjectFieldSlice(data, field_name) orelse return;
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, slice, .{}) catch return;
    defer parsed.deinit();
    parser(allocator, parsed.value, target);
}

fn findJsonObjectFieldSlice(data: []const u8, field_name: []const u8) ?[]const u8 {
    var pattern_buffer: [64]u8 = undefined;
    if (field_name.len + 2 > pattern_buffer.len) return null;
    pattern_buffer[0] = '"';
    @memcpy(pattern_buffer[1 .. 1 + field_name.len], field_name);
    pattern_buffer[1 + field_name.len] = '"';
    const pattern = pattern_buffer[0 .. field_name.len + 2];

    var search_start: usize = 0;
    while (std.mem.indexOfPos(u8, data, search_start, pattern)) |name_idx| {
        search_start = name_idx + pattern.len;
        var idx = skipJsonWhitespace(data, search_start);
        if (idx >= data.len or data[idx] != ':') continue;
        idx = skipJsonWhitespace(data, idx + 1);
        if (idx >= data.len or data[idx] != '{') continue;
        const end_idx = findBalancedObjectEnd(data, idx) orelse continue;
        return data[idx .. end_idx + 1];
    }
    return null;
}

fn skipJsonWhitespace(data: []const u8, start: usize) usize {
    var idx = start;
    while (idx < data.len and std.ascii.isWhitespace(data[idx])) : (idx += 1) {}
    return idx;
}

fn findBalancedObjectEnd(data: []const u8, start: usize) ?usize {
    var idx = start;
    var depth: usize = 0;
    var in_string = false;
    var escaped = false;

    while (idx < data.len) : (idx += 1) {
        const ch = data[idx];
        if (in_string) {
            if (escaped) {
                escaped = false;
                continue;
            }
            switch (ch) {
                '\\' => escaped = true,
                '"' => in_string = false,
                else => {},
            }
            continue;
        }

        switch (ch) {
            '"' => in_string = true,
            '{' => depth += 1,
            '}' => {
                if (depth == 0) return null;
                depth -= 1;
                if (depth == 0) return idx;
            },
            else => {},
        }
    }

    return null;
}

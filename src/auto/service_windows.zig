const std = @import("std");
const service_defs = @import("service_defs.zig");
const windows_task_scheduler = @import("../platform/windows.zig");

pub fn taskMatches(allocator: std.mem.Allocator, codex_home: []const u8, helper_path: []const u8) !bool {
    const expected_action = try expectedTaskFingerprint(allocator, helper_path, codex_home);
    defer allocator.free(expected_action);
    const expected_fingerprint = try expectedTaskDefinitionFingerprint(allocator, expected_action);
    defer allocator.free(expected_fingerprint);
    const task_xml = windows_task_scheduler.readTaskXmlAlloc(allocator, service_defs.windows_task_name) catch return false;
    const xml = task_xml orelse return false;
    defer allocator.free(xml);

    const actual_fingerprint = (try taskDefinitionFingerprintFromXml(allocator, xml)) orelse return false;
    defer allocator.free(actual_fingerprint);
    return std.mem.eql(u8, actual_fingerprint, expected_fingerprint);
}

fn expectedTaskFingerprint(allocator: std.mem.Allocator, helper_path: []const u8, codex_home: []const u8) ![]u8 {
    const args = try service_defs.windowsTaskArguments(allocator, codex_home);
    defer allocator.free(args);
    return try std.fmt.allocPrint(allocator, "{s} {s}", .{ helper_path, args });
}

fn expectedTaskDefinitionFingerprint(allocator: std.mem.Allocator, action: []const u8) ![]u8 {
    return taskDefinitionFingerprint(
        allocator,
        action,
        service_defs.windows_task_trigger_kind,
        service_defs.windows_task_restart_count,
        service_defs.windows_task_restart_interval_xml,
        service_defs.windows_task_execution_time_limit_xml,
    );
}

fn taskDefinitionFingerprint(
    allocator: std.mem.Allocator,
    action: []const u8,
    trigger_kind: []const u8,
    restart_count: []const u8,
    restart_interval: []const u8,
    execution_time_limit: []const u8,
) ![]u8 {
    return try std.fmt.allocPrint(
        allocator,
        "{s}|TRIGGER:{s}|RESTART:{s},{s}|LIMIT:{s}",
        .{ action, trigger_kind, restart_count, restart_interval, execution_time_limit },
    );
}

fn taskDefinitionFingerprintFromXml(allocator: std.mem.Allocator, xml: []const u8) !?[]u8 {
    const command = (try xmlElementTextAlloc(allocator, xml, "Command")) orelse return null;
    defer allocator.free(command);

    const maybe_arguments = try xmlElementTextAlloc(allocator, xml, "Arguments");
    defer if (maybe_arguments) |arguments| allocator.free(arguments);

    const triggers = xmlElementContents(xml, "Triggers") orelse return null;
    const trigger_kind = xmlSingleChildElementName(triggers) orelse return null;

    const restart_on_failure = xmlElementContents(xml, "RestartOnFailure") orelse return null;
    const restart_count = (try xmlElementTextAlloc(allocator, restart_on_failure, "Count")) orelse return null;
    defer allocator.free(restart_count);
    const restart_interval = (try xmlElementTextAlloc(allocator, restart_on_failure, "Interval")) orelse return null;
    defer allocator.free(restart_interval);
    const execution_time_limit = (try xmlElementTextAlloc(allocator, xml, "ExecutionTimeLimit")) orelse return null;
    defer allocator.free(execution_time_limit);

    const action = if (maybe_arguments) |arguments|
        if (arguments.len == 0)
            try allocator.dupe(u8, command)
        else
            try std.fmt.allocPrint(allocator, "{s} {s}", .{ command, arguments })
    else
        try allocator.dupe(u8, command);
    defer allocator.free(action);

    return try taskDefinitionFingerprint(
        allocator,
        action,
        trigger_kind,
        restart_count,
        restart_interval,
        execution_time_limit,
    );
}

fn xmlElementContents(xml: []const u8, tag: []const u8) ?[]const u8 {
    var open_buf: [64]u8 = undefined;
    var close_buf: [64]u8 = undefined;
    const open_tag = std.fmt.bufPrint(&open_buf, "<{s}>", .{tag}) catch return null;
    const close_tag = std.fmt.bufPrint(&close_buf, "</{s}>", .{tag}) catch return null;
    const open_idx = std.mem.indexOf(u8, xml, open_tag) orelse return null;
    const content_start = open_idx + open_tag.len;
    const close_idx = std.mem.indexOfPos(u8, xml, content_start, close_tag) orelse return null;
    return xml[content_start..close_idx];
}

fn xmlElementTextAlloc(allocator: std.mem.Allocator, xml: []const u8, tag: []const u8) !?[]u8 {
    const contents = xmlElementContents(xml, tag) orelse return null;
    return try xmlDecodeEntitiesAlloc(allocator, std.mem.trim(u8, contents, " \n\r\t"));
}

fn xmlDecodeEntitiesAlloc(allocator: std.mem.Allocator, text: []const u8) ![]u8 {
    var out = std.ArrayList(u8).empty;
    defer out.deinit(allocator);

    var idx: usize = 0;
    while (idx < text.len) {
        if (text[idx] != '&') {
            try out.append(allocator, text[idx]);
            idx += 1;
            continue;
        }
        if (std.mem.startsWith(u8, text[idx..], "&amp;")) {
            try out.append(allocator, '&');
            idx += "&amp;".len;
            continue;
        }
        if (std.mem.startsWith(u8, text[idx..], "&lt;")) {
            try out.append(allocator, '<');
            idx += "&lt;".len;
            continue;
        }
        if (std.mem.startsWith(u8, text[idx..], "&gt;")) {
            try out.append(allocator, '>');
            idx += "&gt;".len;
            continue;
        }
        if (std.mem.startsWith(u8, text[idx..], "&quot;")) {
            try out.append(allocator, '"');
            idx += "&quot;".len;
            continue;
        }
        if (std.mem.startsWith(u8, text[idx..], "&apos;")) {
            try out.append(allocator, '\'');
            idx += "&apos;".len;
            continue;
        }
        try out.append(allocator, text[idx]);
        idx += 1;
    }

    return try out.toOwnedSlice(allocator);
}

fn xmlSingleChildElementName(xml: []const u8) ?[]const u8 {
    var idx: usize = 0;
    var depth: usize = 0;
    var direct_child_name: ?[]const u8 = null;

    while (findBytePos(xml, idx, '<')) |lt_idx| {
        if (lt_idx + 1 >= xml.len) return null;
        const next = xml[lt_idx + 1];

        if (next == '/') {
            const close_idx = findBytePos(xml, lt_idx + 2, '>') orelse return null;
            if (depth == 0) return null;
            depth -= 1;
            idx = close_idx + 1;
            continue;
        }

        if (next == '!' or next == '?') {
            const close_idx = findBytePos(xml, lt_idx + 2, '>') orelse return null;
            idx = close_idx + 1;
            continue;
        }

        var name_end = lt_idx + 1;
        while (name_end < xml.len and isXmlTagNameChar(xml[name_end])) : (name_end += 1) {}
        if (name_end == lt_idx + 1) return null;

        const close_idx = findBytePos(xml, name_end, '>') orelse return null;
        const self_closing = tagIsSelfClosing(xml, name_end, close_idx);

        if (depth == 0) {
            if (direct_child_name != null) return null;
            direct_child_name = xml[lt_idx + 1 .. name_end];
        }

        if (!self_closing) depth += 1;
        idx = close_idx + 1;
    }

    if (depth != 0) return null;
    return direct_child_name;
}

fn findBytePos(haystack: []const u8, start: usize, needle: u8) ?usize {
    if (start >= haystack.len) return null;
    const rel = std.mem.indexOfScalar(u8, haystack[start..], needle) orelse return null;
    return start + rel;
}

fn tagIsSelfClosing(xml: []const u8, tag_name_end: usize, tag_close_idx: usize) bool {
    var idx = tag_close_idx;
    while (idx > tag_name_end and std.ascii.isWhitespace(xml[idx - 1])) : (idx -= 1) {}
    return idx > tag_name_end and xml[idx - 1] == '/';
}

fn isXmlTagNameChar(ch: u8) bool {
    return std.ascii.isAlphabetic(ch) or std.ascii.isDigit(ch) or ch == ':' or ch == '_' or ch == '-' or ch == '.';
}

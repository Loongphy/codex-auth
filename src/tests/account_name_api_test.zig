const std = @import("std");
const account_name_api = @import("../account_name_api.zig");

fn findEntryByAccountId(entries: []const account_name_api.AccountNameEntry, account_id: []const u8) ?*const account_name_api.AccountNameEntry {
    for (entries) |*entry| {
        if (std.mem.eql(u8, entry.account_id, account_id)) return entry;
    }
    return null;
}

fn freeEntries(allocator: std.mem.Allocator, entries: ?[]account_name_api.AccountNameEntry) void {
    if (entries) |owned_entries| {
        for (owned_entries) |*entry| entry.deinit(allocator);
        allocator.free(owned_entries);
    }
}

test "parse account names response ignores default and keeps one real account" {
    const gpa = std.testing.allocator;
    const body =
        \\{
        \\  "accounts": {
        \\    "default": {
        \\      "account": {
        \\        "account_id": "default-account",
        \\        "name": "Default"
        \\      }
        \\    },
        \\    "team-1": {
        \\      "account": {
        \\        "account_id": "67fe2bbb-0de6-49a4-b2b3-d1df366d1faf",
        \\        "name": "Primary Workspace"
        \\      }
        \\    }
        \\  },
        \\  "account_ordering": ["default", "team-1"]
        \\}
    ;

    const entries = try account_name_api.parseAccountNamesResponse(gpa, body);
    defer freeEntries(gpa, entries);

    try std.testing.expect(entries != null);
    try std.testing.expectEqual(@as(usize, 1), entries.?.len);
    try std.testing.expect(std.mem.eql(u8, entries.?[0].account_id, "67fe2bbb-0de6-49a4-b2b3-d1df366d1faf"));
    try std.testing.expect(entries.?[0].account_name != null);
    try std.testing.expect(std.mem.eql(u8, entries.?[0].account_name.?, "Primary Workspace"));
}

test "parse account names response keeps multiple non-default accounts" {
    const gpa = std.testing.allocator;
    const body =
        \\{
        \\  "accounts": {
        \\    "team-1": {
        \\      "account": {
        \\        "account_id": "67fe2bbb-0de6-49a4-b2b3-d1df366d1faf",
        \\        "name": "Primary Workspace"
        \\      }
        \\    },
        \\    "team-2": {
        \\      "account": {
        \\        "account_id": "518a44d9-ba75-4bad-87e5-ae9377042960",
        \\        "name": "Backup Workspace"
        \\      }
        \\    }
        \\  }
        \\}
    ;

    const entries = try account_name_api.parseAccountNamesResponse(gpa, body);
    defer freeEntries(gpa, entries);

    try std.testing.expect(entries != null);
    try std.testing.expectEqual(@as(usize, 2), entries.?.len);
    const primary = findEntryByAccountId(entries.?, "67fe2bbb-0de6-49a4-b2b3-d1df366d1faf") orelse return error.TestExpectedEqual;
    const backup = findEntryByAccountId(entries.?, "518a44d9-ba75-4bad-87e5-ae9377042960") orelse return error.TestExpectedEqual;
    try std.testing.expect(primary.account_name != null);
    try std.testing.expect(std.mem.eql(u8, primary.account_name.?, "Primary Workspace"));
    try std.testing.expect(backup.account_name != null);
    try std.testing.expect(std.mem.eql(u8, backup.account_name.?, "Backup Workspace"));
}

test "parse account names response normalizes null names to null" {
    const gpa = std.testing.allocator;
    const body =
        \\{
        \\  "accounts": {
        \\    "team-1": {
        \\      "account": {
        \\        "account_id": "67fe2bbb-0de6-49a4-b2b3-d1df366d1faf",
        \\        "name": null
        \\      }
        \\    }
        \\  }
        \\}
    ;

    const entries = try account_name_api.parseAccountNamesResponse(gpa, body);
    defer freeEntries(gpa, entries);

    try std.testing.expect(entries != null);
    try std.testing.expectEqual(@as(usize, 1), entries.?.len);
    try std.testing.expect(entries.?[0].account_name == null);
}

test "parse account names response normalizes empty names to null" {
    const gpa = std.testing.allocator;
    const body =
        \\{
        \\  "accounts": {
        \\    "team-1": {
        \\      "account": {
        \\        "account_id": "67fe2bbb-0de6-49a4-b2b3-d1df366d1faf",
        \\        "name": ""
        \\      }
        \\    }
        \\  }
        \\}
    ;

    const entries = try account_name_api.parseAccountNamesResponse(gpa, body);
    defer freeEntries(gpa, entries);

    try std.testing.expect(entries != null);
    try std.testing.expectEqual(@as(usize, 1), entries.?.len);
    try std.testing.expect(entries.?[0].account_name == null);
}

test "parse account names response treats malformed html as non-fatal failure" {
    const gpa = std.testing.allocator;
    const result = try account_name_api.parseAccountNamesResponse(gpa, "<html>not json</html>");
    try std.testing.expect(result == null);
}

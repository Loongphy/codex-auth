const std = @import("std");
const account_api = @import("../account_api.zig");

fn findEntryByAccountId(entries: []const account_api.AccountEntry, account_id: []const u8) ?*const account_api.AccountEntry {
    for (entries) |*entry| {
        if (std.mem.eql(u8, entry.account_id, account_id)) return entry;
    }
    return null;
}

fn freeEntries(allocator: std.mem.Allocator, entries: ?[]account_api.AccountEntry) void {
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
        \\    "67fe2bbb-0de6-49a4-b2b3-d1df366d1faf": {
        \\      "account": {
        \\        "account_id": "67fe2bbb-0de6-49a4-b2b3-d1df366d1faf",
        \\        "name": "Primary Workspace"
        \\      }
        \\    }
        \\  },
        \\  "account_ordering": ["67fe2bbb-0de6-49a4-b2b3-d1df366d1faf"]
        \\}
    ;

    const entries = try account_api.parseAccountsResponse(gpa, body);
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
        \\    "67fe2bbb-0de6-49a4-b2b3-d1df366d1faf": {
        \\      "account": {
        \\        "account_id": "67fe2bbb-0de6-49a4-b2b3-d1df366d1faf",
        \\        "name": "Primary Workspace"
        \\      }
        \\    },
        \\    "518a44d9-ba75-4bad-87e5-ae9377042960": {
        \\      "account": {
        \\        "account_id": "518a44d9-ba75-4bad-87e5-ae9377042960",
        \\        "name": "Backup Workspace"
        \\      }
        \\    }
        \\  },
        \\  "account_ordering": [
        \\    "67fe2bbb-0de6-49a4-b2b3-d1df366d1faf",
        \\    "518a44d9-ba75-4bad-87e5-ae9377042960"
        \\  ]
        \\}
    ;

    const entries = try account_api.parseAccountsResponse(gpa, body);
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

test "parse personal account response keeps null name as null" {
    const gpa = std.testing.allocator;
    const body =
        \\{
        \\  "accounts": {
        \\    "67fe2bbb-0de6-49a4-b2b3-d1df366d1faf": {
        \\      "account": {
        \\        "account_id": "67fe2bbb-0de6-49a4-b2b3-d1df366d1faf",
        \\        "name": null
        \\      }
        \\    }
        \\  },
        \\  "account_ordering": ["67fe2bbb-0de6-49a4-b2b3-d1df366d1faf"]
        \\}
    ;

    const entries = try account_api.parseAccountsResponse(gpa, body);
    defer freeEntries(gpa, entries);

    try std.testing.expect(entries != null);
    try std.testing.expectEqual(@as(usize, 1), entries.?.len);
    try std.testing.expect(entries.?[0].account_name == null);
}

test "parse personal account response normalizes empty name to null" {
    const gpa = std.testing.allocator;
    const body =
        \\{
        \\  "accounts": {
        \\    "67fe2bbb-0de6-49a4-b2b3-d1df366d1faf": {
        \\      "account": {
        \\        "account_id": "67fe2bbb-0de6-49a4-b2b3-d1df366d1faf",
        \\        "name": ""
        \\      }
        \\    }
        \\  },
        \\  "account_ordering": ["67fe2bbb-0de6-49a4-b2b3-d1df366d1faf"]
        \\}
    ;

    const entries = try account_api.parseAccountsResponse(gpa, body);
    defer freeEntries(gpa, entries);

    try std.testing.expect(entries != null);
    try std.testing.expectEqual(@as(usize, 1), entries.?.len);
    try std.testing.expect(entries.?[0].account_name == null);
}

test "parse account names response treats malformed html as non-fatal failure" {
    const gpa = std.testing.allocator;
    const result = try account_api.parseAccountsResponse(gpa, "<html>not json</html>");
    try std.testing.expect(result == null);
}

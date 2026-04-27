const std = @import("std");
const app_runtime = @import("runtime.zig");
const registry = @import("registry.zig");

pub const default_group_name = "default";
pub const manager_dir_name = "codex-auth";
pub const groups_dir_name = "groups";
pub const config_file_name = "groups.json";
pub const config_schema_version: u32 = 1;

pub const GroupRef = struct {
    name: []u8,
    codex_home: []u8,
    managed: bool,

    pub fn deinit(self: *GroupRef, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        allocator.free(self.codex_home);
    }
};

pub const GroupList = struct {
    items: std.ArrayList(GroupRef) = .empty,

    pub fn deinit(self: *GroupList, allocator: std.mem.Allocator) void {
        for (self.items.items) |*item| item.deinit(allocator);
        self.items.deinit(allocator);
    }
};

const ConfigGroupOut = struct {
    name: []const u8,
    codex_home: []const u8,
    managed: bool,
};

const ConfigOut = struct {
    schema_version: u32,
    groups: []const ConfigGroupOut,
};

fn readFileAlloc(file: std.Io.File, allocator: std.mem.Allocator, max_bytes: usize) ![]u8 {
    var read_buffer: [4096]u8 = undefined;
    var file_reader = file.reader(app_runtime.io(), &read_buffer);
    return try file_reader.interface.allocRemaining(allocator, .limited(max_bytes));
}

pub fn validateGroupName(name: []const u8) !void {
    if (name.len == 0) return error.InvalidGroupName;
    if (std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, "..")) return error.InvalidGroupName;
    for (name) |ch| {
        switch (ch) {
            'a'...'z', 'A'...'Z', '0'...'9', '-', '_' => {},
            else => return error.InvalidGroupName,
        }
    }
}

pub fn managerRootAlloc(allocator: std.mem.Allocator) ![]u8 {
    const home = try registry.resolveUserHome(allocator);
    defer allocator.free(home);
    return try std.fs.path.join(allocator, &[_][]const u8{ home, manager_dir_name });
}

pub fn groupsRootAlloc(allocator: std.mem.Allocator) ![]u8 {
    const root = try managerRootAlloc(allocator);
    defer allocator.free(root);
    return try std.fs.path.join(allocator, &[_][]const u8{ root, groups_dir_name });
}

pub fn configPathAlloc(allocator: std.mem.Allocator) ![]u8 {
    const root = try managerRootAlloc(allocator);
    defer allocator.free(root);
    return try std.fs.path.join(allocator, &[_][]const u8{ root, config_file_name });
}

pub fn defaultCodexHomeAlloc(allocator: std.mem.Allocator) ![]u8 {
    const home = try registry.resolveUserHome(allocator);
    defer allocator.free(home);
    return try std.fs.path.join(allocator, &[_][]const u8{ home, ".codex" });
}

pub fn managedGroupCodexHomeAlloc(allocator: std.mem.Allocator, name: []const u8) ![]u8 {
    try validateGroupName(name);
    const groups_root = try groupsRootAlloc(allocator);
    defer allocator.free(groups_root);
    return try std.fs.path.join(allocator, &[_][]const u8{ groups_root, name });
}

fn appendGroupRef(
    allocator: std.mem.Allocator,
    list: *GroupList,
    name: []const u8,
    codex_home: []const u8,
    managed: bool,
) !void {
    if (findGroupIndex(list, name) != null) return;
    try list.items.append(allocator, .{
        .name = try allocator.dupe(u8, name),
        .codex_home = try allocator.dupe(u8, codex_home),
        .managed = managed,
    });
}

pub fn findGroupIndex(list: *const GroupList, name: []const u8) ?usize {
    for (list.items.items, 0..) |item, idx| {
        if (std.mem.eql(u8, item.name, name)) return idx;
    }
    return null;
}

pub fn findGroupIndexByCodexHome(list: *const GroupList, codex_home: []const u8) ?usize {
    for (list.items.items, 0..) |item, idx| {
        if (std.mem.eql(u8, item.codex_home, codex_home)) return idx;
    }
    return null;
}

fn parseConfigGroups(allocator: std.mem.Allocator, list: *GroupList, root_obj: std.json.ObjectMap) !void {
    const groups_value = root_obj.get("groups") orelse return;
    const groups = switch (groups_value) {
        .array => |arr| arr,
        else => return,
    };
    for (groups.items) |item| {
        const obj = switch (item) {
            .object => |o| o,
            else => continue,
        };
        const name = switch (obj.get("name") orelse continue) {
            .string => |s| s,
            else => continue,
        };
        if (std.mem.eql(u8, name, default_group_name)) continue;
        validateGroupName(name) catch continue;
        const codex_home = switch (obj.get("codex_home") orelse continue) {
            .string => |s| s,
            else => continue,
        };
        const managed = switch (obj.get("managed") orelse std.json.Value{ .bool = true }) {
            .bool => |value| value,
            else => true,
        };
        try appendGroupRef(allocator, list, name, codex_home, managed);
    }
}

fn discoverManagedGroupFolders(allocator: std.mem.Allocator, list: *GroupList) !void {
    const groups_root = try groupsRootAlloc(allocator);
    defer allocator.free(groups_root);

    var dir = std.Io.Dir.cwd().openDir(app_runtime.io(), groups_root, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => return,
        else => return err,
    };
    defer dir.close(app_runtime.io());

    var it = dir.iterate();
    while (try it.next(app_runtime.io())) |entry| {
        if (entry.kind != .directory) continue;
        validateGroupName(entry.name) catch continue;
        if (std.mem.eql(u8, entry.name, default_group_name)) continue;
        const codex_home = try std.fs.path.join(allocator, &[_][]const u8{ groups_root, entry.name });
        defer allocator.free(codex_home);
        if (findGroupIndex(list, entry.name) != null) continue;
        if (findGroupIndexByCodexHome(list, codex_home) != null) continue;
        try appendGroupRef(allocator, list, entry.name, codex_home, true);
    }
}

fn loadConfiguredGroups(allocator: std.mem.Allocator) !GroupList {
    var list: GroupList = .{};
    errdefer list.deinit(allocator);

    const default_codex_home = try defaultCodexHomeAlloc(allocator);
    defer allocator.free(default_codex_home);
    try appendGroupRef(allocator, &list, default_group_name, default_codex_home, false);

    const config_path = try configPathAlloc(allocator);
    defer allocator.free(config_path);
    const data = blk: {
        var file = std.Io.Dir.cwd().openFile(app_runtime.io(), config_path, .{}) catch |err| switch (err) {
            error.FileNotFound => break :blk null,
            else => return err,
        };
        defer file.close(app_runtime.io());
        break :blk try readFileAlloc(file, allocator, 1024 * 1024);
    };
    if (data) |bytes| {
        defer allocator.free(bytes);
        var parsed = try std.json.parseFromSlice(std.json.Value, allocator, bytes, .{});
        defer parsed.deinit();
        switch (parsed.value) {
            .object => |obj| try parseConfigGroups(allocator, &list, obj),
            else => {},
        }
    }

    return list;
}

pub fn loadGroups(allocator: std.mem.Allocator) !GroupList {
    var list = try loadConfiguredGroups(allocator);
    errdefer list.deinit(allocator);
    try discoverManagedGroupFolders(allocator, &list);
    return list;
}

pub fn saveGroups(allocator: std.mem.Allocator, list: *const GroupList) !void {
    const root = try managerRootAlloc(allocator);
    defer allocator.free(root);
    try std.Io.Dir.cwd().createDirPath(app_runtime.io(), root);

    var out_groups = std.ArrayList(ConfigGroupOut).empty;
    defer out_groups.deinit(allocator);
    for (list.items.items) |item| {
        if (std.mem.eql(u8, item.name, default_group_name)) continue;
        try out_groups.append(allocator, .{
            .name = item.name,
            .codex_home = item.codex_home,
            .managed = item.managed,
        });
    }

    var aw: std.Io.Writer.Allocating = .init(allocator);
    defer aw.deinit();
    try std.json.Stringify.value(ConfigOut{
        .schema_version = config_schema_version,
        .groups = out_groups.items,
    }, .{ .whitespace = .indent_2 }, &aw.writer);

    const config_path = try configPathAlloc(allocator);
    defer allocator.free(config_path);
    var file = try std.Io.Dir.cwd().createFile(app_runtime.io(), config_path, .{ .truncate = true });
    defer file.close(app_runtime.io());
    try file.writeStreamingAll(app_runtime.io(), aw.written());
}

pub fn resolveGroupAlloc(allocator: std.mem.Allocator, name: []const u8) !GroupRef {
    var groups = try loadGroups(allocator);
    defer groups.deinit(allocator);
    const idx = findGroupIndex(&groups, name) orelse return error.GroupNotFound;
    return .{
        .name = try allocator.dupe(u8, groups.items.items[idx].name),
        .codex_home = try allocator.dupe(u8, groups.items.items[idx].codex_home),
        .managed = groups.items.items[idx].managed,
    };
}

pub fn ensureManagedGroupAlloc(allocator: std.mem.Allocator, name: []const u8) !GroupRef {
    try validateGroupName(name);
    if (std.mem.eql(u8, name, default_group_name)) {
        return try resolveGroupAlloc(allocator, default_group_name);
    }

    var groups = try loadGroups(allocator);
    defer groups.deinit(allocator);
    if (findGroupIndex(&groups, name)) |idx| {
        try std.Io.Dir.cwd().createDirPath(app_runtime.io(), groups.items.items[idx].codex_home);
        return .{
            .name = try allocator.dupe(u8, groups.items.items[idx].name),
            .codex_home = try allocator.dupe(u8, groups.items.items[idx].codex_home),
            .managed = groups.items.items[idx].managed,
        };
    }

    const codex_home = try managedGroupCodexHomeAlloc(allocator, name);
    defer allocator.free(codex_home);
    try std.Io.Dir.cwd().createDirPath(app_runtime.io(), codex_home);
    try appendGroupRef(allocator, &groups, name, codex_home, true);
    try saveGroups(allocator, &groups);

    return .{
        .name = try allocator.dupe(u8, name),
        .codex_home = try allocator.dupe(u8, codex_home),
        .managed = true,
    };
}

test "group names allow simple shell-safe identifiers" {
    try validateGroupName("work");
    try validateGroupName("team_1");
    try validateGroupName("personal-alpha");
}

test "group names reject path-like or empty identifiers" {
    try std.testing.expectError(error.InvalidGroupName, validateGroupName(""));
    try std.testing.expectError(error.InvalidGroupName, validateGroupName("."));
    try std.testing.expectError(error.InvalidGroupName, validateGroupName(".."));
    try std.testing.expectError(error.InvalidGroupName, validateGroupName("../work"));
    try std.testing.expectError(error.InvalidGroupName, validateGroupName("work/group"));
}

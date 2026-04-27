const std = @import("std");
const app_runtime = @import("runtime.zig");
const registry = @import("registry.zig");

pub const default_group_name = "default";
pub const manager_dir_name = "codex-auth";
pub const groups_dir_name = "groups";
pub const archive_dir_name = "archive";
pub const config_file_name = "groups.json";
pub const projects_file_name = "projects.json";
pub const config_schema_version: u32 = 1;
pub const default_group_display_color = "gray";
pub const display_color_palette = [_][]const u8{
    "blue",
    "cyan",
    "green",
    "magenta",
    "yellow",
    "red",
};

pub const GroupRef = struct {
    name: []u8,
    codex_home: []u8,
    managed: bool,
    display_color: []u8,

    pub fn deinit(self: *GroupRef, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        allocator.free(self.codex_home);
        allocator.free(self.display_color);
    }
};

pub const GroupList = struct {
    items: std.ArrayList(GroupRef) = .empty,

    pub fn deinit(self: *GroupList, allocator: std.mem.Allocator) void {
        for (self.items.items) |*item| item.deinit(allocator);
        self.items.deinit(allocator);
    }
};

pub const FolderList = struct {
    items: std.ArrayList([]u8) = .empty,

    pub fn deinit(self: *FolderList, allocator: std.mem.Allocator) void {
        for (self.items.items) |item| allocator.free(item);
        self.items.deinit(allocator);
    }
};

pub const ProjectGroup = struct {
    root: []u8,
    group: []u8,

    fn deinit(self: *ProjectGroup, allocator: std.mem.Allocator) void {
        allocator.free(self.root);
        allocator.free(self.group);
    }
};

pub const ProjectGroupList = struct {
    items: std.ArrayList(ProjectGroup) = .empty,

    pub fn deinit(self: *ProjectGroupList, allocator: std.mem.Allocator) void {
        for (self.items.items) |*item| item.deinit(allocator);
        self.items.deinit(allocator);
    }
};

const ConfigGroupOut = struct {
    name: []const u8,
    codex_home: []const u8,
    managed: bool,
    display_color: []const u8,
};

const ConfigOut = struct {
    schema_version: u32,
    groups: []const ConfigGroupOut,
};

const ProjectGroupOut = struct {
    root: []const u8,
    group: []const u8,
};

const ProjectConfigOut = struct {
    schema_version: u32,
    projects: []const ProjectGroupOut,
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

pub fn archiveRootAlloc(allocator: std.mem.Allocator) ![]u8 {
    const root = try managerRootAlloc(allocator);
    defer allocator.free(root);
    return try std.fs.path.join(allocator, &[_][]const u8{ root, archive_dir_name });
}

pub fn configPathAlloc(allocator: std.mem.Allocator) ![]u8 {
    const root = try managerRootAlloc(allocator);
    defer allocator.free(root);
    return try std.fs.path.join(allocator, &[_][]const u8{ root, config_file_name });
}

pub fn projectsPathAlloc(allocator: std.mem.Allocator) ![]u8 {
    const root = try managerRootAlloc(allocator);
    defer allocator.free(root);
    return try std.fs.path.join(allocator, &[_][]const u8{ root, projects_file_name });
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
    requested_display_color: ?[]const u8,
) !void {
    if (findGroupIndex(list, name) != null) return;
    const display_color = resolveDisplayColorForAppend(list, name, requested_display_color);
    try list.items.append(allocator, .{
        .name = try allocator.dupe(u8, name),
        .codex_home = try allocator.dupe(u8, codex_home),
        .managed = managed,
        .display_color = try allocator.dupe(u8, display_color),
    });
}

fn displayColorIsPaletteColor(color: []const u8) bool {
    for (display_color_palette) |candidate| {
        if (std.mem.eql(u8, color, candidate)) return true;
    }
    return false;
}

fn displayColorIsUsed(list: *const GroupList, color: []const u8) bool {
    for (list.items.items) |item| {
        if (std.mem.eql(u8, item.display_color, color)) return true;
    }
    return false;
}

fn chooseDisplayColor(list: *const GroupList, name: []const u8) []const u8 {
    const start = std.hash.Wyhash.hash(0, name) % display_color_palette.len;
    var offset: usize = 0;
    while (offset < display_color_palette.len) : (offset += 1) {
        const candidate = display_color_palette[(start + offset) % display_color_palette.len];
        if (!displayColorIsUsed(list, candidate)) return candidate;
    }
    return display_color_palette[start];
}

fn resolveDisplayColorForAppend(
    list: *const GroupList,
    name: []const u8,
    requested_display_color: ?[]const u8,
) []const u8 {
    if (std.mem.eql(u8, name, default_group_name)) return default_group_display_color;
    if (requested_display_color) |color| {
        if (displayColorIsPaletteColor(color) and !displayColorIsUsed(list, color)) return color;
    }
    return chooseDisplayColor(list, name);
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
        const display_color: ?[]const u8 = if (obj.get("display_color")) |value| switch (value) {
            .string => |s| s,
            else => null,
        } else null;
        try appendGroupRef(allocator, list, name, codex_home, managed, display_color);
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
        try appendGroupRef(allocator, list, entry.name, codex_home, true, null);
    }
}

pub fn listAvailableManagedFolderNamesAlloc(allocator: std.mem.Allocator) !FolderList {
    var folders: FolderList = .{};
    errdefer folders.deinit(allocator);

    var groups = try loadConfiguredGroups(allocator);
    defer groups.deinit(allocator);

    const groups_root = try groupsRootAlloc(allocator);
    defer allocator.free(groups_root);

    var dir = std.Io.Dir.cwd().openDir(app_runtime.io(), groups_root, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => return folders,
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
        if (findGroupIndexByCodexHome(&groups, codex_home) != null) continue;
        try folders.items.append(allocator, try allocator.dupe(u8, entry.name));
    }
    return folders;
}

fn loadConfiguredGroups(allocator: std.mem.Allocator) !GroupList {
    var list: GroupList = .{};
    errdefer list.deinit(allocator);

    const default_codex_home = try defaultCodexHomeAlloc(allocator);
    defer allocator.free(default_codex_home);
    try appendGroupRef(allocator, &list, default_group_name, default_codex_home, false, default_group_display_color);

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
            .display_color = item.display_color,
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

fn appendProjectGroup(
    allocator: std.mem.Allocator,
    list: *ProjectGroupList,
    root: []const u8,
    group: []const u8,
) !void {
    for (list.items.items, 0..) |*item, idx| {
        if (!std.mem.eql(u8, item.root, root)) continue;
        item.deinit(allocator);
        list.items.items[idx] = .{
            .root = try allocator.dupe(u8, root),
            .group = try allocator.dupe(u8, group),
        };
        return;
    }
    try list.items.append(allocator, .{
        .root = try allocator.dupe(u8, root),
        .group = try allocator.dupe(u8, group),
    });
}

fn parseProjectGroups(allocator: std.mem.Allocator, list: *ProjectGroupList, root_obj: std.json.ObjectMap) !void {
    const projects_value = root_obj.get("projects") orelse return;
    const projects = switch (projects_value) {
        .array => |arr| arr,
        else => return,
    };
    for (projects.items) |item| {
        const obj = switch (item) {
            .object => |o| o,
            else => continue,
        };
        const root = switch (obj.get("root") orelse continue) {
            .string => |s| s,
            else => continue,
        };
        const group = switch (obj.get("group") orelse continue) {
            .string => |s| s,
            else => continue,
        };
        validateGroupName(group) catch continue;
        if (root.len == 0) continue;
        try appendProjectGroup(allocator, list, root, group);
    }
}

pub fn loadProjectGroups(allocator: std.mem.Allocator) !ProjectGroupList {
    var list: ProjectGroupList = .{};
    errdefer list.deinit(allocator);

    const projects_path = try projectsPathAlloc(allocator);
    defer allocator.free(projects_path);
    const data = blk: {
        var file = std.Io.Dir.cwd().openFile(app_runtime.io(), projects_path, .{}) catch |err| switch (err) {
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
            .object => |obj| try parseProjectGroups(allocator, &list, obj),
            else => {},
        }
    }
    return list;
}

pub fn saveProjectGroups(allocator: std.mem.Allocator, list: *const ProjectGroupList) !void {
    const root = try managerRootAlloc(allocator);
    defer allocator.free(root);
    try std.Io.Dir.cwd().createDirPath(app_runtime.io(), root);

    var out_projects = std.ArrayList(ProjectGroupOut).empty;
    defer out_projects.deinit(allocator);
    for (list.items.items) |item| {
        try out_projects.append(allocator, .{
            .root = item.root,
            .group = item.group,
        });
    }

    var aw: std.Io.Writer.Allocating = .init(allocator);
    defer aw.deinit();
    try std.json.Stringify.value(ProjectConfigOut{
        .schema_version = config_schema_version,
        .projects = out_projects.items,
    }, .{ .whitespace = .indent_2 }, &aw.writer);

    const projects_path = try projectsPathAlloc(allocator);
    defer allocator.free(projects_path);
    var file = try std.Io.Dir.cwd().createFile(app_runtime.io(), projects_path, .{ .truncate = true });
    defer file.close(app_runtime.io());
    try file.writeStreamingAll(app_runtime.io(), aw.written());
}

fn cwdAlloc(allocator: std.mem.Allocator) ![]u8 {
    return try app_runtime.realPathFileAlloc(allocator, std.Io.Dir.cwd(), ".");
}

pub fn rememberCurrentProjectGroup(allocator: std.mem.Allocator, group_name: []const u8) !void {
    try validateGroupName(group_name);
    const cwd = try cwdAlloc(allocator);
    defer allocator.free(cwd);

    var projects = try loadProjectGroups(allocator);
    defer projects.deinit(allocator);
    try appendProjectGroup(allocator, &projects, cwd, group_name);
    try saveProjectGroups(allocator, &projects);
}

fn pathIsSameOrChild(path: []const u8, root: []const u8) bool {
    if (std.mem.eql(u8, path, root)) return true;
    if (!std.mem.startsWith(u8, path, root)) return false;
    if (path.len <= root.len) return false;
    return path[root.len] == '/' or path[root.len] == '\\';
}

pub fn currentProjectGroupAlloc(allocator: std.mem.Allocator) !?[]u8 {
    const cwd = try cwdAlloc(allocator);
    defer allocator.free(cwd);

    var projects = try loadProjectGroups(allocator);
    defer projects.deinit(allocator);

    var best_idx: ?usize = null;
    var best_len: usize = 0;
    for (projects.items.items, 0..) |item, idx| {
        if (!pathIsSameOrChild(cwd, item.root)) continue;
        if (item.root.len <= best_len) continue;
        best_idx = idx;
        best_len = item.root.len;
    }
    const idx = best_idx orelse return null;
    return try allocator.dupe(u8, projects.items.items[idx].group);
}

pub fn clearCurrentProjectGroup(allocator: std.mem.Allocator) !bool {
    const cwd = try cwdAlloc(allocator);
    defer allocator.free(cwd);

    var projects = try loadProjectGroups(allocator);
    defer projects.deinit(allocator);

    var idx: usize = 0;
    while (idx < projects.items.items.len) {
        if (!std.mem.eql(u8, projects.items.items[idx].root, cwd)) {
            idx += 1;
            continue;
        }
        projects.items.items[idx].deinit(allocator);
        _ = projects.items.orderedRemove(idx);
        try saveProjectGroups(allocator, &projects);
        return true;
    }
    return false;
}

pub fn removeProjectMappingsForGroup(allocator: std.mem.Allocator, group_name: []const u8) !void {
    var projects = try loadProjectGroups(allocator);
    defer projects.deinit(allocator);

    var idx: usize = 0;
    var changed = false;
    while (idx < projects.items.items.len) {
        if (!std.mem.eql(u8, projects.items.items[idx].group, group_name)) {
            idx += 1;
            continue;
        }
        projects.items.items[idx].deinit(allocator);
        _ = projects.items.orderedRemove(idx);
        changed = true;
    }
    if (changed) try saveProjectGroups(allocator, &projects);
}

pub fn resolveGroupAlloc(allocator: std.mem.Allocator, name: []const u8) !GroupRef {
    var groups = try loadGroups(allocator);
    defer groups.deinit(allocator);
    const idx = findGroupIndex(&groups, name) orelse return error.GroupNotFound;
    return .{
        .name = try allocator.dupe(u8, groups.items.items[idx].name),
        .codex_home = try allocator.dupe(u8, groups.items.items[idx].codex_home),
        .managed = groups.items.items[idx].managed,
        .display_color = try allocator.dupe(u8, groups.items.items[idx].display_color),
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
            .display_color = try allocator.dupe(u8, groups.items.items[idx].display_color),
        };
    }

    const codex_home = try managedGroupCodexHomeAlloc(allocator, name);
    defer allocator.free(codex_home);
    try std.Io.Dir.cwd().createDirPath(app_runtime.io(), codex_home);
    try appendGroupRef(allocator, &groups, name, codex_home, true, null);
    try saveGroups(allocator, &groups);

    return .{
        .name = try allocator.dupe(u8, name),
        .codex_home = try allocator.dupe(u8, codex_home),
        .managed = true,
        .display_color = try allocator.dupe(u8, groups.items.items[findGroupIndex(&groups, name).?].display_color),
    };
}

pub fn ensureManagedGroupWithFolderAlloc(
    allocator: std.mem.Allocator,
    name: []const u8,
    folder_name: []const u8,
) !GroupRef {
    try validateGroupName(name);
    try validateGroupName(folder_name);
    if (std.mem.eql(u8, name, default_group_name)) {
        return try resolveGroupAlloc(allocator, default_group_name);
    }

    var groups = try loadConfiguredGroups(allocator);
    defer groups.deinit(allocator);
    if (findGroupIndex(&groups, name)) |idx| {
        try std.Io.Dir.cwd().createDirPath(app_runtime.io(), groups.items.items[idx].codex_home);
        return .{
            .name = try allocator.dupe(u8, groups.items.items[idx].name),
            .codex_home = try allocator.dupe(u8, groups.items.items[idx].codex_home),
            .managed = groups.items.items[idx].managed,
            .display_color = try allocator.dupe(u8, groups.items.items[idx].display_color),
        };
    }

    const groups_root = try groupsRootAlloc(allocator);
    defer allocator.free(groups_root);
    const codex_home = try std.fs.path.join(allocator, &[_][]const u8{ groups_root, folder_name });
    defer allocator.free(codex_home);

    if (findGroupIndexByCodexHome(&groups, codex_home) != null) {
        return error.GroupAlreadyExists;
    }

    try std.Io.Dir.cwd().createDirPath(app_runtime.io(), codex_home);
    try appendGroupRef(allocator, &groups, name, codex_home, true, null);
    try saveGroups(allocator, &groups);

    return .{
        .name = try allocator.dupe(u8, name),
        .codex_home = try allocator.dupe(u8, codex_home),
        .managed = true,
        .display_color = try allocator.dupe(u8, groups.items.items[findGroupIndex(&groups, name).?].display_color),
    };
}

pub fn removeManagedGroupConfig(allocator: std.mem.Allocator, name: []const u8) !void {
    if (std.mem.eql(u8, name, default_group_name)) return error.InvalidGroupName;

    var groups = try loadConfiguredGroups(allocator);
    defer groups.deinit(allocator);
    const idx = findGroupIndex(&groups, name) orelse {
        try removeProjectMappingsForGroup(allocator, name);
        return;
    };
    groups.items.items[idx].deinit(allocator);
    _ = groups.items.orderedRemove(idx);
    try saveGroups(allocator, &groups);
    try removeProjectMappingsForGroup(allocator, name);
}

pub fn deleteManagedGroupFolder(allocator: std.mem.Allocator, name: []const u8) ![]u8 {
    var group = try resolveGroupAlloc(allocator, name);
    defer group.deinit(allocator);
    if (std.mem.eql(u8, group.name, default_group_name)) return error.InvalidGroupName;
    const deleted_path = try allocator.dupe(u8, group.codex_home);
    errdefer allocator.free(deleted_path);
    try std.Io.Dir.cwd().deleteTree(app_runtime.io(), group.codex_home);
    try removeManagedGroupConfig(allocator, group.name);
    return deleted_path;
}

pub fn archiveManagedGroupFolder(allocator: std.mem.Allocator, name: []const u8, timestamp_ms: i64) ![]u8 {
    var group = try resolveGroupAlloc(allocator, name);
    defer group.deinit(allocator);
    if (std.mem.eql(u8, group.name, default_group_name)) return error.InvalidGroupName;

    const archive_root = try archiveRootAlloc(allocator);
    defer allocator.free(archive_root);
    try std.Io.Dir.cwd().createDirPath(app_runtime.io(), archive_root);

    const archive_name = try std.fmt.allocPrint(allocator, "{s}-{d}", .{ group.name, timestamp_ms });
    defer allocator.free(archive_name);
    const archive_path = try std.fs.path.join(allocator, &[_][]const u8{ archive_root, archive_name });
    errdefer allocator.free(archive_path);

    try std.Io.Dir.renameAbsolute(group.codex_home, archive_path, app_runtime.io());
    try removeManagedGroupConfig(allocator, group.name);
    return archive_path;
}

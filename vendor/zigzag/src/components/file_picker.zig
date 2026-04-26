//! File picker component for file system navigation.
//! Allows browsing directories and selecting files.

const std = @import("std");
const builtin = @import("builtin");
const keys = @import("../input/keys.zig");
const style_mod = @import("../style/style.zig");
const Color = @import("../style/color.zig").Color;
const measure = @import("../layout/measure.zig");
const fs = std.fs;

pub const FilePicker = struct {
    allocator: std.mem.Allocator,

    // State
    current_path: std.array_list.Managed(u8),
    entries: std.array_list.Managed(Entry),
    cursor: usize,
    y_offset: usize,

    // Selection
    selected_path: ?[]const u8,

    // Options
    height: u16,
    show_hidden: bool,
    show_size: bool,
    show_permissions: bool,
    dir_only: bool,
    file_only: bool,
    allowed_extensions: ?[]const []const u8,

    // Styling
    dir_style: style_mod.Style,
    file_style: style_mod.Style,
    cursor_style: style_mod.Style,
    size_style: style_mod.Style,
    path_style: style_mod.Style,

    // Focus
    focused: bool,

    // Symbols
    dir_icon: []const u8,
    file_icon: []const u8,
    link_icon: []const u8,
    parent_icon: []const u8,

    pub const Entry = struct {
        name: []const u8,
        entry_type: EntryType,
        size: u64,
        is_hidden: bool,

        pub const EntryType = enum {
            file,
            directory,
            symlink,
            parent,
        };
    };

    pub fn init(allocator: std.mem.Allocator) FilePicker {
        return .{
            .allocator = allocator,
            .current_path = std.array_list.Managed(u8).init(allocator),
            .entries = std.array_list.Managed(Entry).init(allocator),
            .cursor = 0,
            .y_offset = 0,
            .selected_path = null,
            .height = 15,
            .show_hidden = false,
            .show_size = true,
            .show_permissions = false,
            .dir_only = false,
            .file_only = false,
            .allowed_extensions = null,
            .dir_style = blk: {
                var s = style_mod.Style{};
                s = s.bold(true);
                s = s.fg(Color.blue());
                s = s.inline_style(true);
                break :blk s;
            },
            .file_style = blk: {
                var s = style_mod.Style{};
                s = s.inline_style(true);
                break :blk s;
            },
            .cursor_style = blk: {
                var s = style_mod.Style{};
                s = s.bold(true);
                s = s.fg(Color.cyan());
                s = s.inline_style(true);
                break :blk s;
            },
            .size_style = blk: {
                var s = style_mod.Style{};
                s = s.fg(Color.gray(12));
                s = s.inline_style(true);
                break :blk s;
            },
            .path_style = blk: {
                var s = style_mod.Style{};
                s = s.bold(true);
                s = s.fg(Color.yellow());
                s = s.inline_style(true);
                break :blk s;
            },
            .focused = true,
            .dir_icon = "📁 ",
            .file_icon = "📄 ",
            .link_icon = "🔗 ",
            .parent_icon = "📂 ",
        };
    }

    pub fn deinit(self: *FilePicker) void {
        self.current_path.deinit();
        for (self.entries.items) |entry| {
            self.allocator.free(entry.name);
        }
        self.entries.deinit();
        if (self.selected_path) |path| {
            self.allocator.free(path);
        }
    }

    /// Navigate to a directory
    pub fn navigate(self: *FilePicker, path: []const u8) !void {
        // Update current path
        self.current_path.clearRetainingCapacity();
        try self.current_path.appendSlice(path);

        // Clear old entries
        for (self.entries.items) |entry| {
            self.allocator.free(entry.name);
        }
        self.entries.clearRetainingCapacity();

        // Add parent directory entry
        if (!std.mem.eql(u8, path, "/")) {
            const parent_name = try self.allocator.dupe(u8, "..");
            try self.entries.append(.{
                .name = parent_name,
                .entry_type = .parent,
                .size = 0,
                .is_hidden = false,
            });
        }

        // Read directory
        var dir = fs.openDirAbsolute(path, .{ .iterate = true }) catch {
            return;
        };
        defer dir.close();

        var iter = dir.iterate();
        while (iter.next() catch null) |entry| {
            // Skip hidden files if not showing them
            const is_hidden = entry.name.len > 0 and entry.name[0] == '.';
            if (is_hidden and !self.show_hidden) continue;

            // Skip files if dir_only
            if (self.dir_only and entry.kind != .directory) continue;

            // Skip directories if file_only
            if (self.file_only and entry.kind == .directory) continue;

            // Check extensions if specified
            if (self.allowed_extensions) |exts| {
                if (entry.kind != .directory) {
                    const ext = std.fs.path.extension(entry.name);
                    var found = false;
                    for (exts) |allowed_ext| {
                        if (std.mem.eql(u8, ext, allowed_ext)) {
                            found = true;
                            break;
                        }
                    }
                    if (!found) continue;
                }
            }

            // Get file size
            var size: u64 = 0;
            if (entry.kind == .file) {
                const stat = dir.statFile(entry.name) catch null;
                if (stat) |s| {
                    size = s.size;
                }
            }

            const name_copy = try self.allocator.dupe(u8, entry.name);
            try self.entries.append(.{
                .name = name_copy,
                .entry_type = switch (entry.kind) {
                    .directory => .directory,
                    .sym_link => .symlink,
                    else => .file,
                },
                .size = size,
                .is_hidden = is_hidden,
            });
        }

        // Sort entries (directories first, then alphabetically)
        std.mem.sort(Entry, self.entries.items, {}, struct {
            fn lessThan(_: void, a: Entry, b: Entry) bool {
                // Parent always first
                if (a.entry_type == .parent) return true;
                if (b.entry_type == .parent) return false;

                // Directories before files
                if (a.entry_type == .directory and b.entry_type != .directory) return true;
                if (b.entry_type == .directory and a.entry_type != .directory) return false;

                // Alphabetical
                return std.mem.lessThan(u8, a.name, b.name);
            }
        }.lessThan);

        self.cursor = 0;
        self.y_offset = 0;
    }

    /// Navigate to home directory
    pub fn navigateHome(self: *FilePicker) !void {
        if (comptime builtin.os.tag == .windows) {
            var env_map = try std.process.getEnvMap(self.allocator);
            defer env_map.deinit();
            const home = env_map.get("USERPROFILE") orelse "C:\\";
            try self.navigate(home);
        } else {
            const home = std.posix.getenv("HOME") orelse "/";
            try self.navigate(home);
        }
    }

    /// Move cursor up
    pub fn cursorUp(self: *FilePicker) void {
        if (self.cursor > 0) {
            self.cursor -= 1;
            self.ensureVisible();
        }
    }

    /// Move cursor down
    pub fn cursorDown(self: *FilePicker) void {
        if (self.cursor < self.entries.items.len -| 1) {
            self.cursor += 1;
            self.ensureVisible();
        }
    }

    /// Select current entry
    pub fn selectCurrent(self: *FilePicker) !bool {
        if (self.cursor >= self.entries.items.len) return false;

        const entry = self.entries.items[self.cursor];

        if (entry.entry_type == .directory or entry.entry_type == .parent) {
            // Navigate into directory
            if (entry.entry_type == .parent) {
                const parent = std.fs.path.dirname(self.current_path.items) orelse "/";
                const parent_copy = try self.allocator.dupe(u8, parent);
                defer self.allocator.free(parent_copy);
                try self.navigate(parent_copy);
            } else {
                const new_path = try std.fs.path.join(self.allocator, &.{ self.current_path.items, entry.name });
                defer self.allocator.free(new_path);
                try self.navigate(new_path);
            }
            return false;
        } else {
            // Select file
            if (self.selected_path) |path| {
                self.allocator.free(path);
            }
            self.selected_path = try std.fs.path.join(self.allocator, &.{ self.current_path.items, entry.name });
            return true;
        }
    }

    /// Set focused state (for use with FocusGroup).
    pub fn focus(self: *FilePicker) void {
        self.focused = true;
    }

    /// Clear focused state (for use with FocusGroup).
    pub fn blur(self: *FilePicker) void {
        self.focused = false;
    }

    /// Handle key event
    pub fn handleKey(self: *FilePicker, key: keys.KeyEvent) !bool {
        if (!self.focused) return false;
        switch (key.key) {
            .up => self.cursorUp(),
            .down => self.cursorDown(),
            .enter => return try self.selectCurrent(),
            .backspace => {
                const parent = std.fs.path.dirname(self.current_path.items) orelse "/";
                const parent_copy = try self.allocator.dupe(u8, parent);
                defer self.allocator.free(parent_copy);
                try self.navigate(parent_copy);
            },
            .char => |c| {
                switch (c) {
                    'j' => self.cursorDown(),
                    'k' => self.cursorUp(),
                    'h' => self.showHidden(),
                    '~' => try self.navigateHome(),
                    else => {},
                }
            },
            else => {},
        }
        return false;
    }

    fn showHidden(self: *FilePicker) void {
        self.show_hidden = !self.show_hidden;
        const path_copy = self.allocator.dupe(u8, self.current_path.items) catch return;
        defer self.allocator.free(path_copy);
        self.navigate(path_copy) catch {};
    }

    fn ensureVisible(self: *FilePicker) void {
        if (self.cursor < self.y_offset) {
            self.y_offset = self.cursor;
        } else if (self.cursor >= self.y_offset + self.height) {
            self.y_offset = self.cursor - self.height + 1;
        }
    }

    /// Get selected path
    pub fn getSelected(self: *const FilePicker) ?[]const u8 {
        return self.selected_path;
    }

    /// Format file size for display
    fn formatSize(self: *const FilePicker, allocator: std.mem.Allocator, size: u64) ![]const u8 {
        _ = self;
        if (size < 1024) {
            return try std.fmt.allocPrint(allocator, "{d}B", .{size});
        } else if (size < 1024 * 1024) {
            return try std.fmt.allocPrint(allocator, "{d:.1}K", .{@as(f64, @floatFromInt(size)) / 1024.0});
        } else if (size < 1024 * 1024 * 1024) {
            return try std.fmt.allocPrint(allocator, "{d:.1}M", .{@as(f64, @floatFromInt(size)) / (1024.0 * 1024.0)});
        } else {
            return try std.fmt.allocPrint(allocator, "{d:.1}G", .{@as(f64, @floatFromInt(size)) / (1024.0 * 1024.0 * 1024.0)});
        }
    }

    /// Render the file picker
    pub fn view(self: *const FilePicker, allocator: std.mem.Allocator) ![]const u8 {
        var result = std.array_list.Managed(u8).init(allocator);
        const writer = result.writer();

        // Current path header
        const path_styled = try self.path_style.render(allocator, self.current_path.items);
        try writer.writeAll(path_styled);
        try writer.writeByte('\n');
        try writer.writeByte('\n');

        // Entries
        var rendered: usize = 0;
        while (rendered < self.height -| 2) : (rendered += 1) {
            if (rendered > 0) try writer.writeByte('\n');

            const idx = self.y_offset + rendered;
            if (idx >= self.entries.items.len) continue;

            const entry = self.entries.items[idx];
            const is_selected = idx == self.cursor;

            // Cursor indicator
            if (is_selected) {
                try writer.writeAll("> ");
            } else {
                try writer.writeAll("  ");
            }

            // Icon
            const icon = switch (entry.entry_type) {
                .directory => self.dir_icon,
                .parent => self.parent_icon,
                .symlink => self.link_icon,
                .file => self.file_icon,
            };
            try writer.writeAll(icon);

            // Name
            const name_style = if (is_selected)
                self.cursor_style
            else switch (entry.entry_type) {
                .directory, .parent => self.dir_style,
                else => self.file_style,
            };
            const name_styled = try name_style.render(allocator, entry.name);
            try writer.writeAll(name_styled);

            // Size (for files)
            if (self.show_size and entry.entry_type == .file) {
                const size_str = try self.formatSize(allocator, entry.size);
                try writer.writeAll("  ");
                const size_styled = try self.size_style.render(allocator, size_str);
                try writer.writeAll(size_styled);
            }
        }

        return result.toOwnedSlice();
    }
};

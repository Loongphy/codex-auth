//! Paginator component for pagination controls.
//! Displays page indicators and handles navigation.

const std = @import("std");
const keys = @import("../input/keys.zig");
const style_mod = @import("../style/style.zig");
const Color = @import("../style/color.zig").Color;

pub const Paginator = struct {
    // State
    current_page: usize,
    total_pages: usize,
    per_page: usize,
    total_items: usize,

    // Appearance
    paginator_type: Type,
    active_dot: []const u8,
    inactive_dot: []const u8,

    // Styling
    active_style: style_mod.Style,
    inactive_style: style_mod.Style,

    pub const Type = enum {
        dots,
        arabic, // 1/5, 2/5, etc.
        compact, // [1] 2 3 4 5
    };

    pub fn init() Paginator {
        return .{
            .current_page = 0,
            .total_pages = 1,
            .per_page = 10,
            .total_items = 0,
            .paginator_type = .dots,
            .active_dot = "●",
            .inactive_dot = "○",
            .active_style = blk: {
                var s = style_mod.Style{};
                s = s.fg(Color.cyan());
                s = s.inline_style(true);
                break :blk s;
            },
            .inactive_style = blk: {
                var s = style_mod.Style{};
                s = s.fg(Color.gray(12));
                s = s.inline_style(true);
                break :blk s;
            },
        };
    }

    /// Set total items and calculate pages
    pub fn setTotalItems(self: *Paginator, total: usize) void {
        self.total_items = total;
        self.total_pages = if (total == 0) 1 else (total + self.per_page - 1) / self.per_page;
        self.current_page = @min(self.current_page, self.total_pages -| 1);
    }

    /// Set items per page
    pub fn setPerPage(self: *Paginator, per_page: usize) void {
        self.per_page = @max(1, per_page);
        self.setTotalItems(self.total_items);
    }

    /// Set total pages directly
    pub fn setTotalPages(self: *Paginator, pages: usize) void {
        self.total_pages = @max(1, pages);
        self.current_page = @min(self.current_page, self.total_pages - 1);
    }

    /// Go to specific page
    pub fn gotoPage(self: *Paginator, page: usize) void {
        self.current_page = @min(page, self.total_pages -| 1);
    }

    /// Go to next page
    pub fn nextPage(self: *Paginator) void {
        if (self.current_page < self.total_pages - 1) {
            self.current_page += 1;
        }
    }

    /// Go to previous page
    pub fn prevPage(self: *Paginator) void {
        if (self.current_page > 0) {
            self.current_page -= 1;
        }
    }

    /// Go to first page
    pub fn firstPage(self: *Paginator) void {
        self.current_page = 0;
    }

    /// Go to last page
    pub fn lastPage(self: *Paginator) void {
        self.current_page = self.total_pages -| 1;
    }

    /// Check if on first page
    pub fn onFirstPage(self: *const Paginator) bool {
        return self.current_page == 0;
    }

    /// Check if on last page
    pub fn onLastPage(self: *const Paginator) bool {
        return self.current_page >= self.total_pages -| 1;
    }

    /// Get start index for current page
    pub fn startIndex(self: *const Paginator) usize {
        return self.current_page * self.per_page;
    }

    /// Get end index for current page (exclusive)
    pub fn endIndex(self: *const Paginator) usize {
        return @min(self.startIndex() + self.per_page, self.total_items);
    }

    /// Get items on current page
    pub fn itemsOnPage(self: *const Paginator) usize {
        return self.endIndex() - self.startIndex();
    }

    /// Handle key event
    pub fn handleKey(self: *Paginator, key: keys.KeyEvent) void {
        switch (key.key) {
            .left => self.prevPage(),
            .right => self.nextPage(),
            .home => self.firstPage(),
            .end => self.lastPage(),
            .char => |c| {
                switch (c) {
                    'h' => self.prevPage(),
                    'l' => self.nextPage(),
                    else => {},
                }
            },
            else => {},
        }
    }

    /// Render the paginator
    pub fn view(self: *const Paginator, allocator: std.mem.Allocator) ![]const u8 {
        return switch (self.paginator_type) {
            .dots => self.viewDots(allocator),
            .arabic => self.viewArabic(allocator),
            .compact => self.viewCompact(allocator),
        };
    }

    fn viewDots(self: *const Paginator, allocator: std.mem.Allocator) ![]const u8 {
        var result = std.array_list.Managed(u8).init(allocator);
        const writer = result.writer();

        for (0..self.total_pages) |i| {
            if (i > 0) try writer.writeByte(' ');

            if (i == self.current_page) {
                const styled = try self.active_style.render(allocator, self.active_dot);
                try writer.writeAll(styled);
            } else {
                const styled = try self.inactive_style.render(allocator, self.inactive_dot);
                try writer.writeAll(styled);
            }
        }

        return result.toOwnedSlice();
    }

    fn viewArabic(self: *const Paginator, allocator: std.mem.Allocator) ![]const u8 {
        const text = try std.fmt.allocPrint(allocator, "{d}/{d}", .{ self.current_page + 1, self.total_pages });
        return self.active_style.render(allocator, text);
    }

    fn viewCompact(self: *const Paginator, allocator: std.mem.Allocator) ![]const u8 {
        var result = std.array_list.Managed(u8).init(allocator);
        const writer = result.writer();

        // Show limited range of pages
        const max_visible = 5;
        var start: usize = 0;
        var end = self.total_pages;

        if (self.total_pages > max_visible) {
            const half = max_visible / 2;
            if (self.current_page <= half) {
                end = max_visible;
            } else if (self.current_page >= self.total_pages - half) {
                start = self.total_pages - max_visible;
            } else {
                start = self.current_page - half;
                end = self.current_page + half + 1;
            }
        }

        // Previous indicator
        if (start > 0) {
            try writer.writeAll("< ");
        }

        for (start..end) |i| {
            if (i > start) try writer.writeByte(' ');

            const page_str = try std.fmt.allocPrint(allocator, "{d}", .{i + 1});
            if (i == self.current_page) {
                const styled = try self.active_style.render(allocator, page_str);
                try writer.writeAll(styled);
            } else {
                const styled = try self.inactive_style.render(allocator, page_str);
                try writer.writeAll(styled);
            }
        }

        // Next indicator
        if (end < self.total_pages) {
            try writer.writeAll(" >");
        }

        return result.toOwnedSlice();
    }
};

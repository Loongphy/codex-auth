//! Selectable list component.
//! Displays a list of items with selection and optional filtering.

const std = @import("std");
const keys = @import("../input/keys.zig");
const style_mod = @import("../style/style.zig");
const Color = @import("../style/color.zig").Color;

pub fn List(comptime T: type) type {
    return struct {
        allocator: std.mem.Allocator,

        // Items
        items: std.array_list.Managed(Item),
        filtered_indices: std.array_list.Managed(usize),

        // Selection
        cursor: usize,
        selected: std.AutoHashMap(usize, void),

        // Filtering
        filter_text: std.array_list.Managed(u8),
        filter_enabled: bool,

        // Appearance
        height: u16,
        y_offset: usize,

        // Styling
        item_style: style_mod.Style,
        selected_style: style_mod.Style,
        cursor_style: style_mod.Style,
        filter_style: style_mod.Style,

        // Symbols
        cursor_symbol: []const u8,
        selected_symbol: []const u8,
        unselected_symbol: []const u8,

        // Focus
        focused: bool,

        // Behavior
        multi_select: bool,
        wrap_around: bool,

        // Status
        status_message: ?[]const u8,
        show_item_count: bool,

        const Self = @This();

        pub const Item = struct {
            value: T,
            title: []const u8,
            description: []const u8,
            enabled: bool,

            pub fn init(value: T, title: []const u8) Item {
                return .{
                    .value = value,
                    .title = title,
                    .description = "",
                    .enabled = true,
                };
            }

            pub fn withDescription(value: T, title: []const u8, desc: []const u8) Item {
                return .{
                    .value = value,
                    .title = title,
                    .description = desc,
                    .enabled = true,
                };
            }
        };

        pub fn init(allocator: std.mem.Allocator) Self {
            return .{
                .allocator = allocator,
                .items = std.array_list.Managed(Item).init(allocator),
                .filtered_indices = std.array_list.Managed(usize).init(allocator),
                .cursor = 0,
                .selected = std.AutoHashMap(usize, void).init(allocator),
                .filter_text = std.array_list.Managed(u8).init(allocator),
                .filter_enabled = false,
                .height = 10,
                .y_offset = 0,
                .item_style = blk: {
                    var s = style_mod.Style{};
                    s = s.inline_style(true);
                    break :blk s;
                },
                .selected_style = blk: {
                    var s = style_mod.Style{};
                    s = s.fg(Color.cyan());
                    s = s.inline_style(true);
                    break :blk s;
                },
                .cursor_style = blk: {
                    var s = style_mod.Style{};
                    s = s.bold(true);
                    s = s.fg(Color.magenta());
                    s = s.inline_style(true);
                    break :blk s;
                },
                .filter_style = blk: {
                    var s = style_mod.Style{};
                    s = s.fg(Color.yellow());
                    s = s.inline_style(true);
                    break :blk s;
                },
                .cursor_symbol = "> ",
                .selected_symbol = "[x] ",
                .unselected_symbol = "[ ] ",
                .focused = true,
                .multi_select = false,
                .wrap_around = true,
                .status_message = null,
                .show_item_count = false,
            };
        }

        pub fn deinit(self: *Self) void {
            self.items.deinit();
            self.filtered_indices.deinit();
            self.selected.deinit();
            self.filter_text.deinit();
        }

        /// Add an item to the list
        pub fn addItem(self: *Self, item: Item) !void {
            try self.items.append(item);
            try self.updateFilter();
        }

        /// Add multiple items
        pub fn addItems(self: *Self, items: []const Item) !void {
            try self.items.appendSlice(items);
            try self.updateFilter();
        }

        /// Set items (replaces all)
        pub fn setItems(self: *Self, items: []const Item) !void {
            self.items.clearRetainingCapacity();
            try self.items.appendSlice(items);
            self.cursor = 0;
            self.y_offset = 0;
            try self.updateFilter();
        }

        /// Clear all items
        pub fn clear(self: *Self) void {
            self.items.clearRetainingCapacity();
            self.filtered_indices.clearRetainingCapacity();
            self.selected.clearRetainingCapacity();
            self.cursor = 0;
            self.y_offset = 0;
        }

        /// Get selected item
        pub fn selectedItem(self: *const Self) ?*const Item {
            const visible = self.visibleItems();
            if (self.cursor < visible.len) {
                const idx = visible[self.cursor];
                return &self.items.items[idx];
            }
            return null;
        }

        /// Get selected value
        pub fn selectedValue(self: *const Self) ?T {
            if (self.selectedItem()) |item| {
                return item.value;
            }
            return null;
        }

        /// Get all selected items (for multi-select)
        pub fn selectedItems(self: *const Self, allocator: std.mem.Allocator) ![]const *const Item {
            var result = std.array_list.Managed(*const Item).init(allocator);
            var iter = self.selected.keyIterator();
            while (iter.next()) |idx| {
                if (idx.* < self.items.items.len) {
                    try result.append(&self.items.items[idx.*]);
                }
            }
            return result.toOwnedSlice();
        }

        /// Move cursor up
        pub fn cursorUp(self: *Self) void {
            const visible = self.visibleItems();
            if (visible.len == 0) return;

            if (self.cursor > 0) {
                self.cursor -= 1;
            } else if (self.wrap_around) {
                self.cursor = visible.len - 1;
            }

            self.ensureVisible();
        }

        /// Move cursor down
        pub fn cursorDown(self: *Self) void {
            const visible = self.visibleItems();
            if (visible.len == 0) return;

            if (self.cursor < visible.len - 1) {
                self.cursor += 1;
            } else if (self.wrap_around) {
                self.cursor = 0;
            }

            self.ensureVisible();
        }

        /// Page up
        pub fn pageUp(self: *Self) void {
            if (self.cursor >= self.height) {
                self.cursor -= self.height;
            } else {
                self.cursor = 0;
            }
            self.ensureVisible();
        }

        /// Page down
        pub fn pageDown(self: *Self) void {
            const visible = self.visibleItems();
            if (self.cursor + self.height < visible.len) {
                self.cursor += self.height;
            } else if (visible.len > 0) {
                self.cursor = visible.len - 1;
            }
            self.ensureVisible();
        }

        /// Go to first item
        pub fn gotoFirst(self: *Self) void {
            self.cursor = 0;
            self.y_offset = 0;
        }

        /// Go to last item
        pub fn gotoLast(self: *Self) void {
            const visible = self.visibleItems();
            if (visible.len > 0) {
                self.cursor = visible.len - 1;
                self.ensureVisible();
            }
        }

        /// Toggle selection of current item
        pub fn toggleSelection(self: *Self) void {
            const visible = self.visibleItems();
            if (self.cursor >= visible.len) return;

            const idx = visible[self.cursor];

            if (self.multi_select) {
                if (self.selected.contains(idx)) {
                    _ = self.selected.remove(idx);
                } else {
                    self.selected.put(idx, {}) catch {};
                }
            } else {
                self.selected.clearRetainingCapacity();
                self.selected.put(idx, {}) catch {};
            }
        }

        /// Select current item
        pub fn selectCurrent(self: *Self) void {
            const visible = self.visibleItems();
            if (self.cursor >= visible.len) return;

            const idx = visible[self.cursor];
            if (!self.multi_select) {
                self.selected.clearRetainingCapacity();
            }
            self.selected.put(idx, {}) catch {};
        }

        /// Enable filtering
        pub fn enableFilter(self: *Self) void {
            self.filter_enabled = true;
        }

        /// Disable filtering
        pub fn disableFilter(self: *Self) void {
            self.filter_enabled = false;
            self.filter_text.clearRetainingCapacity();
            self.updateFilter() catch {};
        }

        /// Set filter text
        pub fn setFilter(self: *Self, text: []const u8) !void {
            self.filter_text.clearRetainingCapacity();
            try self.filter_text.appendSlice(text);
            try self.updateFilter();
        }

        /// Set focused state (for use with FocusGroup).
        pub fn focus(self: *Self) void {
            self.focused = true;
        }

        /// Clear focused state (for use with FocusGroup).
        pub fn blur(self: *Self) void {
            self.focused = false;
        }

        /// Handle key event
        pub fn handleKey(self: *Self, key: keys.KeyEvent) void {
            if (!self.focused) return;
            if (self.filter_enabled and key.key == .char and !key.modifiers.ctrl) {
                // Add to filter
                const c = key.key.char;
                var buf: [4]u8 = undefined;
                const len = std.unicode.utf8Encode(c, &buf) catch return;
                self.filter_text.appendSlice(buf[0..len]) catch {};
                self.updateFilter() catch {};
                return;
            }

            if (self.filter_enabled and key.key == .backspace) {
                if (self.filter_text.items.len > 0) {
                    _ = self.filter_text.pop();
                    self.updateFilter() catch {};
                }
                return;
            }

            switch (key.key) {
                .up => self.cursorUp(),
                .down => self.cursorDown(),
                .page_up => self.pageUp(),
                .page_down => self.pageDown(),
                .home => self.gotoFirst(),
                .end => self.gotoLast(),
                .space => if (self.multi_select) self.toggleSelection(),
                .enter => self.selectCurrent(),
                .char => |c| {
                    switch (c) {
                        'j' => self.cursorDown(),
                        'k' => self.cursorUp(),
                        'g' => self.gotoFirst(),
                        'G' => self.gotoLast(),
                        '/' => self.enableFilter(),
                        else => {},
                    }
                },
                .escape => if (self.filter_enabled) self.disableFilter(),
                else => {},
            }
        }

        fn visibleItems(self: *const Self) []const usize {
            return self.filtered_indices.items;
        }

        const ScoredIndex = struct {
            index: usize,
            score: i32,
        };

        pub fn updateFilter(self: *Self) !void {
            self.filtered_indices.clearRetainingCapacity();

            if (self.filter_text.items.len == 0) {
                // No filter - show all
                for (0..self.items.items.len) |i| {
                    try self.filtered_indices.append(i);
                }
            } else {
                // Fuzzy match by title
                const filter_lower = try self.toLower(self.allocator, self.filter_text.items);
                defer self.allocator.free(filter_lower);

                var scored = std.array_list.Managed(ScoredIndex).init(self.allocator);
                defer scored.deinit();

                for (self.items.items, 0..) |item, i| {
                    const title_lower = try self.toLower(self.allocator, item.title);
                    defer self.allocator.free(title_lower);

                    const score = fuzzyScore(title_lower, filter_lower);
                    if (score > 0) {
                        try scored.append(.{ .index = i, .score = score });
                    }
                }

                // Sort by score descending
                std.mem.sort(ScoredIndex, scored.items, {}, struct {
                    pub fn lessThan(_: void, a: ScoredIndex, b: ScoredIndex) bool {
                        return a.score > b.score;
                    }
                }.lessThan);

                for (scored.items) |s| {
                    try self.filtered_indices.append(s.index);
                }
            }

            // Adjust cursor
            if (self.cursor >= self.filtered_indices.items.len and self.filtered_indices.items.len > 0) {
                self.cursor = self.filtered_indices.items.len - 1;
            }
            self.ensureVisible();
        }

        fn fuzzyScore(text: []const u8, pattern: []const u8) i32 {
            if (pattern.len == 0) return 1;
            if (text.len == 0) return 0;

            var score: i32 = 0;
            var pi: usize = 0; // pattern index
            var consecutive: i32 = 0;

            for (text, 0..) |c, ti| {
                if (pi < pattern.len and c == pattern[pi]) {
                    score += 1;
                    consecutive += 1;
                    // Consecutive bonus
                    score += consecutive;
                    // Word start bonus
                    if (ti == 0 or text[ti - 1] == ' ' or text[ti - 1] == '_' or text[ti - 1] == '-') {
                        score += 5;
                    }
                    pi += 1;
                } else {
                    consecutive = 0;
                }
            }

            // All pattern chars must match
            if (pi < pattern.len) return 0;
            return score;
        }

        fn toLower(self: *const Self, allocator: std.mem.Allocator, str: []const u8) ![]u8 {
            _ = self;
            const result = try allocator.alloc(u8, str.len);
            for (str, 0..) |c, i| {
                result[i] = if (c >= 'A' and c <= 'Z') c + 32 else c;
            }
            return result;
        }

        fn ensureVisible(self: *Self) void {
            if (self.cursor < self.y_offset) {
                self.y_offset = self.cursor;
            } else if (self.cursor >= self.y_offset + self.height) {
                self.y_offset = self.cursor - self.height + 1;
            }
        }

        /// Render the list
        pub fn view(self: *const Self, allocator: std.mem.Allocator) ![]const u8 {
            var result = std.array_list.Managed(u8).init(allocator);
            const writer = result.writer();

            // Filter line
            if (self.filter_enabled) {
                const filter_line = try std.fmt.allocPrint(allocator, "Filter: {s}", .{self.filter_text.items});
                const styled = try self.filter_style.render(allocator, filter_line);
                try writer.writeAll(styled);
                try writer.writeByte('\n');
            }

            const visible = self.visibleItems();

            // Render visible items
            var rendered: usize = 0;
            while (rendered < self.height) : (rendered += 1) {
                if (rendered > 0) try writer.writeByte('\n');

                const idx = self.y_offset + rendered;
                if (idx < visible.len) {
                    const item_idx = visible[idx];
                    const item = self.items.items[item_idx];

                    // Cursor
                    if (idx == self.cursor) {
                        const cursor_styled = try self.cursor_style.render(allocator, self.cursor_symbol);
                        try writer.writeAll(cursor_styled);
                    } else {
                        for (0..self.cursor_symbol.len) |_| {
                            try writer.writeByte(' ');
                        }
                    }

                    // Selection indicator (multi-select)
                    if (self.multi_select) {
                        if (self.selected.contains(item_idx)) {
                            const sel_styled = try self.selected_style.render(allocator, self.selected_symbol);
                            try writer.writeAll(sel_styled);
                        } else {
                            try writer.writeAll(self.unselected_symbol);
                        }
                    }

                    // Item text
                    const item_rendered = if (idx == self.cursor)
                        try self.cursor_style.render(allocator, item.title)
                    else if (self.selected.contains(item_idx))
                        try self.selected_style.render(allocator, item.title)
                    else
                        try self.item_style.render(allocator, item.title);

                    try writer.writeAll(item_rendered);

                    // Description
                    if (item.description.len > 0) {
                        try writer.writeAll(" - ");
                        try writer.writeAll(item.description);
                    }
                }
            }

            // Status bar
            if (self.show_item_count or self.status_message != null) {
                try writer.writeAll("\n");
                if (self.show_item_count) {
                    const count_str = try std.fmt.allocPrint(allocator, "{d}/{d} items", .{
                        visible.len,
                        self.items.items.len,
                    });
                    const count_styled = try self.filter_style.render(allocator, count_str);
                    try writer.writeAll(count_styled);
                }
                if (self.status_message) |msg| {
                    if (self.show_item_count) try writer.writeAll(" ");
                    try writer.writeAll(msg);
                }
            }

            return result.toOwnedSlice();
        }
    };
}

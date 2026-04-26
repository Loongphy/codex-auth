//! Scrollable content viewport component.

const std = @import("std");
const keys = @import("../input/keys.zig");
const measure = @import("../layout/measure.zig");
const style = @import("../style/style.zig");
const ansi = @import("../terminal/ansi.zig");
const unicode = @import("../unicode.zig");

pub const Viewport = struct {
    allocator: std.mem.Allocator,

    // Content
    content: []const u8,
    owned_content: ?[]u8,
    lines: std.array_list.Managed([]const u8),

    // Dimensions
    width: u16,
    height: u16,

    // Scroll position (visual rows, display columns)
    y_offset: usize,
    x_offset: usize,

    // Styling
    viewport_style: style.Style,
    scrollbar_track_style: style.Style,
    scrollbar_thumb_style: style.Style,

    // Options
    wrap: bool,
    show_scrollbar: bool,
    empty_char: []const u8,
    scrollbar_track_char: []const u8,
    scrollbar_thumb_char: []const u8,

    pub fn init(allocator: std.mem.Allocator, width: u16, height: u16) Viewport {
        return .{
            .allocator = allocator,
            .content = "",
            .owned_content = null,
            .lines = std.array_list.Managed([]const u8).init(allocator),
            .width = width,
            .height = height,
            .y_offset = 0,
            .x_offset = 0,
            .viewport_style = blk: {
                var s = style.Style{};
                break :blk s.inline_style(true);
            },
            .scrollbar_track_style = blk: {
                var s = style.Style{};
                break :blk s.inline_style(true);
            },
            .scrollbar_thumb_style = blk: {
                var s = style.Style{};
                break :blk s.inline_style(true);
            },
            .wrap = false,
            .show_scrollbar = true,
            .empty_char = " ",
            .scrollbar_track_char = "░",
            .scrollbar_thumb_char = "█",
        };
    }

    pub fn deinit(self: *Viewport) void {
        if (self.owned_content) |content| self.allocator.free(content);
        self.lines.deinit();
    }

    pub fn setContent(self: *Viewport, content: []const u8) !void {
        if (self.owned_content) |existing| self.allocator.free(existing);
        const owned = try self.allocator.dupe(u8, content);
        self.owned_content = owned;
        self.content = owned;
        self.lines.clearRetainingCapacity();

        var iter = std.mem.splitScalar(u8, self.content, '\n');
        while (iter.next()) |line| {
            try self.lines.append(line);
        }

        self.clampScroll();
    }

    pub fn setSize(self: *Viewport, width: u16, height: u16) void {
        self.width = width;
        self.height = height;
        self.clampScroll();
    }

    pub fn setWrap(self: *Viewport, wrap: bool) void {
        self.wrap = wrap;
        if (wrap) self.x_offset = 0;
        self.clampScroll();
    }

    pub fn setShowScrollbar(self: *Viewport, show_scrollbar: bool) void {
        self.show_scrollbar = show_scrollbar;
        self.clampScroll();
    }

    pub fn setStyle(self: *Viewport, viewport_style: style.Style) void {
        self.viewport_style = viewport_style.inline_style(true);
    }

    pub fn setScrollbarStyle(self: *Viewport, track_style: style.Style, thumb_style: style.Style) void {
        self.scrollbar_track_style = track_style.inline_style(true);
        self.scrollbar_thumb_style = thumb_style.inline_style(true);
    }

    pub fn setScrollbarChars(self: *Viewport, track_char: []const u8, thumb_char: []const u8) void {
        self.scrollbar_track_char = track_char;
        self.scrollbar_thumb_char = thumb_char;
    }

    pub fn setEmptyChar(self: *Viewport, empty_char: []const u8) void {
        self.empty_char = empty_char;
    }

    pub fn scrollDown(self: *Viewport, n: usize) void {
        self.y_offset = std.math.add(usize, self.y_offset, n) catch std.math.maxInt(usize);
        self.clampScroll();
    }

    pub fn scrollUp(self: *Viewport, n: usize) void {
        self.y_offset -|= n;
    }

    pub fn scrollRight(self: *Viewport, n: usize) void {
        if (self.wrap) return;
        self.x_offset = std.math.add(usize, self.x_offset, n) catch std.math.maxInt(usize);
        self.clampScroll();
    }

    pub fn scrollLeft(self: *Viewport, n: usize) void {
        self.x_offset -|= n;
    }

    pub fn scrollTo(self: *Viewport, y_offset: usize, x_offset: usize) void {
        self.y_offset = y_offset;
        self.x_offset = if (self.wrap) 0 else x_offset;
        self.clampScroll();
    }

    pub fn gotoTop(self: *Viewport) void {
        self.y_offset = 0;
    }

    pub fn gotoBottom(self: *Viewport) void {
        const total = self.totalVisualLines();
        if (total > self.height) {
            self.y_offset = total - self.height;
        } else {
            self.y_offset = 0;
        }
    }

    pub fn pageDown(self: *Viewport) void {
        self.scrollDown(self.height);
    }

    pub fn pageUp(self: *Viewport) void {
        self.scrollUp(self.height);
    }

    pub fn halfPageDown(self: *Viewport) void {
        self.scrollDown(self.height / 2);
    }

    pub fn halfPageUp(self: *Viewport) void {
        self.scrollUp(self.height / 2);
    }

    pub fn scrollPercent(self: *const Viewport) u8 {
        const total = self.totalVisualLines();
        if (total <= self.height) return 100;
        const max_offset = total - self.height;
        return @intCast(@min(100, (self.y_offset * 100) / max_offset));
    }

    pub fn atTop(self: *const Viewport) bool {
        return self.y_offset == 0;
    }

    pub fn atBottom(self: *const Viewport) bool {
        const total = self.totalVisualLines();
        if (total <= self.height) return true;
        return self.y_offset >= total - self.height;
    }

    pub fn totalLines(self: *const Viewport) usize {
        return self.lines.items.len;
    }

    pub fn totalVisualLines(self: *const Viewport) usize {
        return self.totalVisualLinesForWidth(self.visibleWidth());
    }

    fn totalVisualLinesForWidth(self: *const Viewport, visible_width: usize) usize {
        if (self.lines.items.len == 0) return 0;
        if (visible_width == 0) return 0;

        if (!self.wrap) return self.lines.items.len;

        var total: usize = 0;
        for (self.lines.items) |line| {
            const line_width = measure.width(line);
            total += @max(@as(usize, 1), std.math.divCeil(usize, line_width, visible_width) catch 1);
        }
        return total;
    }

    pub fn contentWidth(self: *const Viewport) usize {
        var max_width: usize = 0;
        for (self.lines.items) |line| {
            max_width = @max(max_width, measure.width(line));
        }
        return max_width;
    }

    pub fn handleKey(self: *Viewport, key: keys.KeyEvent) void {
        switch (key.key) {
            .up => self.scrollUp(1),
            .down => self.scrollDown(1),
            .left => self.scrollLeft(1),
            .right => self.scrollRight(1),
            .page_up => self.pageUp(),
            .page_down => self.pageDown(),
            .home => self.gotoTop(),
            .end => self.gotoBottom(),
            .char => |c| switch (c) {
                'j' => self.scrollDown(1),
                'k' => self.scrollUp(1),
                'h' => self.scrollLeft(1),
                'l' => self.scrollRight(1),
                'g' => self.gotoTop(),
                'G' => self.gotoBottom(),
                'd' => self.halfPageDown(),
                'u' => self.halfPageUp(),
                else => {},
            },
            else => {},
        }
    }

    fn clampScroll(self: *Viewport) void {
        const total_visual_lines = self.totalVisualLines();
        if (total_visual_lines > self.height) {
            self.y_offset = @min(self.y_offset, total_visual_lines - self.height);
        } else {
            self.y_offset = 0;
        }

        if (self.wrap) {
            self.x_offset = 0;
            return;
        }

        const visible_width = self.visibleWidth();
        const total_width = self.contentWidth();
        if (total_width > visible_width) {
            self.x_offset = @min(self.x_offset, total_width - visible_width);
        } else {
            self.x_offset = 0;
        }
    }

    pub fn view(self: *const Viewport, allocator: std.mem.Allocator) ![]const u8 {
        var result = std.array_list.Managed(u8).init(allocator);
        const writer = result.writer();

        const visible_width = self.visibleWidth();

        var row: usize = 0;
        while (row < self.height) : (row += 1) {
            if (row > 0) try writer.writeByte('\n');

            const line_text = try self.lineForVisualRow(allocator, self.y_offset + row, visible_width);
            defer allocator.free(line_text);

            const padded = try self.padLine(allocator, line_text, visible_width);
            defer allocator.free(padded);

            const rendered = try self.viewport_style.render(allocator, padded);
            defer allocator.free(rendered);
            try writer.writeAll(rendered);

            if (self.show_scrollbar and self.totalVisualLines() > self.height) {
                const scrollbar = try self.renderScrollbar(allocator, row);
                defer allocator.free(scrollbar);
                try writer.writeAll(scrollbar);
            }
        }

        return result.toOwnedSlice();
    }

    fn visibleWidth(self: *const Viewport) usize {
        if (!self.show_scrollbar) return self.width;
        const with_scrollbar = self.width -| 1;
        if (self.totalVisualLinesForWidth(@max(@as(usize, 1), with_scrollbar)) > self.height) {
            return with_scrollbar;
        }
        return self.width;
    }

    fn lineForVisualRow(self: *const Viewport, allocator: std.mem.Allocator, visual_row: usize, visible_width: usize) ![]const u8 {
        if (visible_width == 0 or self.lines.items.len == 0) {
            return try allocator.dupe(u8, "");
        }

        if (!self.wrap) {
            if (visual_row >= self.lines.items.len) return try allocator.dupe(u8, "");
            const line = self.lines.items[visual_row];
            if (self.x_offset >= measure.width(line)) return try allocator.dupe(u8, "");
            return try self.getSubstring(allocator, line, self.x_offset, visible_width);
        }

        var remaining = visual_row;
        for (self.lines.items) |line| {
            const line_width = measure.width(line);
            const segments = @max(@as(usize, 1), std.math.divCeil(usize, line_width, visible_width) catch 1);
            if (remaining < segments) {
                return try self.getSubstring(allocator, line, remaining * visible_width, visible_width);
            }
            remaining -= segments;
        }

        return try allocator.dupe(u8, "");
    }

    fn padLine(self: *const Viewport, allocator: std.mem.Allocator, line: []const u8, visible_width: usize) ![]const u8 {
        const current_width = measure.width(line);
        if (current_width >= visible_width) return try allocator.dupe(u8, line);

        var out = std.array_list.Managed(u8).init(allocator);
        try out.appendSlice(line);
        for (0..(visible_width - current_width)) |_| {
            try out.appendSlice(self.empty_char);
        }
        return out.toOwnedSlice();
    }

    fn getSubstring(self: *const Viewport, allocator: std.mem.Allocator, line: []const u8, start_col: usize, max_width: usize) ![]const u8 {
        _ = self;
        var result = std.array_list.Managed(u8).init(allocator);

        var col: usize = 0;
        var i: usize = 0;
        var wrote_escape = false;

        while (i < line.len and col < start_col) {
            if (line[i] == 0x1b) {
                const seq_end = ansiSequenceEnd(line, i);
                if (seq_end > i) {
                    try result.appendSlice(line[i..seq_end]);
                    wrote_escape = true;
                    i = seq_end;
                    continue;
                }
            }

            const byte_len = std.unicode.utf8ByteSequenceLength(line[i]) catch 1;
            if (i + byte_len <= line.len) {
                const cp = std.unicode.utf8Decode(line[i..][0..byte_len]) catch {
                    i += 1;
                    col += 1;
                    continue;
                };
                col += unicode.charWidth(cp);
            }
            i += byte_len;
        }

        var output_width: usize = 0;
        while (i < line.len and output_width < max_width) {
            if (line[i] == 0x1b) {
                const seq_end = ansiSequenceEnd(line, i);
                if (seq_end > i) {
                    try result.appendSlice(line[i..seq_end]);
                    wrote_escape = true;
                    i = seq_end;
                    continue;
                }
            }

            const byte_len = std.unicode.utf8ByteSequenceLength(line[i]) catch 1;
            if (i + byte_len <= line.len) {
                const cp = std.unicode.utf8Decode(line[i..][0..byte_len]) catch {
                    try result.append(line[i]);
                    i += 1;
                    output_width += 1;
                    continue;
                };
                const cw = unicode.charWidth(cp);
                if (output_width + cw > max_width) break;
                try result.appendSlice(line[i..][0..byte_len]);
                output_width += cw;
            }
            i += byte_len;
        }

        if (wrote_escape and !std.mem.endsWith(u8, result.items, ansi.reset)) {
            try result.appendSlice(ansi.reset);
        }

        return result.toOwnedSlice();
    }

    fn renderScrollbar(self: *const Viewport, allocator: std.mem.Allocator, row: usize) ![]const u8 {
        const total = self.totalVisualLines();
        const visible = self.height;

        if (total <= visible) return try allocator.dupe(u8, "");

        const scrollbar_height = @max(1, (visible * visible) / total);
        const max_offset = total - visible;
        const scrollbar_pos = if (max_offset == 0) 0 else (self.y_offset * (visible - scrollbar_height)) / max_offset;

        const glyph = if (row >= scrollbar_pos and row < scrollbar_pos + scrollbar_height)
            try self.scrollbar_thumb_style.render(allocator, self.scrollbar_thumb_char)
        else
            try self.scrollbar_track_style.render(allocator, self.scrollbar_track_char);

        return glyph;
    }
};

fn ansiSequenceEnd(line: []const u8, start: usize) usize {
    if (start >= line.len or line[start] != 0x1b or start + 1 >= line.len) return start;

    const second = line[start + 1];
    if (second == '[') {
        var i = start + 2;
        while (i < line.len) : (i += 1) {
            const c = line[i];
            if ((c >= 'A' and c <= 'Z') or (c >= 'a' and c <= 'z')) return i + 1;
        }
        return line.len;
    }

    if (second == ']') {
        var i = start + 2;
        while (i < line.len) : (i += 1) {
            if (line[i] == 0x07) return i + 1;
            if (line[i] == 0x1b and i + 1 < line.len and line[i + 1] == '\\') return i + 2;
        }
        return line.len;
    }

    return @min(line.len, start + 2);
}

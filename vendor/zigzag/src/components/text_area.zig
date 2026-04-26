//! Multi-line text area component.
//! Provides text editing with multiple lines, cursor navigation, and scrolling.

const std = @import("std");
const keys = @import("../input/keys.zig");
const style_mod = @import("../style/style.zig");
const Color = @import("../style/color.zig").Color;
const unicode = @import("../unicode.zig");

pub const TextArea = struct {
    allocator: std.mem.Allocator,

    // Content
    lines: std.array_list.Managed(std.array_list.Managed(u8)),

    // Cursor position
    cursor_row: usize,
    cursor_col: usize,

    // Viewport
    viewport_row: usize,
    viewport_col: usize,
    width: u16,
    height: u16,

    // Appearance
    placeholder: []const u8,
    line_numbers: bool,
    word_wrap: bool,

    // Styling
    text_style: style_mod.Style,
    cursor_style: style_mod.Style,
    line_number_style: style_mod.Style,
    placeholder_style: style_mod.Style,

    // State
    focused: bool,

    // Limits
    max_lines: ?usize,
    max_cols: ?usize,
    char_limit: ?usize,

    const WrappedSegment = struct {
        start: usize,
        end: usize,
        is_last: bool,
    };

    const WrappedRow = struct {
        line_idx: usize,
        start: usize,
        end: usize,
        is_first_segment: bool,
    };

    const CursorWrappedSegment = struct {
        current_start: usize,
        current_end: usize,
        prev_start: ?usize,
        is_last: bool,
    };

    pub fn init(allocator: std.mem.Allocator) TextArea {
        var lines = std.array_list.Managed(std.array_list.Managed(u8)).init(allocator);
        lines.append(std.array_list.Managed(u8).init(allocator)) catch {};

        return .{
            .allocator = allocator,
            .lines = lines,
            .cursor_row = 0,
            .cursor_col = 0,
            .viewport_row = 0,
            .viewport_col = 0,
            .width = 80,
            .height = 10,
            .placeholder = "",
            .line_numbers = false,
            .word_wrap = false,
            .text_style = blk: {
                var s = style_mod.Style{};
                s = s.inline_style(true);
                break :blk s;
            },
            .cursor_style = blk: {
                var s = style_mod.Style{};
                s = s.reverse(true);
                s = s.inline_style(true);
                break :blk s;
            },
            .line_number_style = blk: {
                var s = style_mod.Style{};
                s = s.fg(Color.gray(12));
                s = s.inline_style(true);
                break :blk s;
            },
            .placeholder_style = blk: {
                var s = style_mod.Style{};
                s = s.fg(Color.gray(12));
                s = s.inline_style(true);
                break :blk s;
            },
            .focused = true,
            .max_lines = null,
            .max_cols = null,
            .char_limit = null,
        };
    }

    pub fn deinit(self: *TextArea) void {
        for (self.lines.items) |*line| {
            line.deinit();
        }
        self.lines.deinit();
    }

    /// Set the content
    pub fn setValue(self: *TextArea, text: []const u8) !void {
        // Clear existing lines
        for (self.lines.items) |*line| {
            line.deinit();
        }
        self.lines.clearRetainingCapacity();

        // Parse lines
        var iter = std.mem.splitScalar(u8, text, '\n');
        while (iter.next()) |line_text| {
            var line = std.array_list.Managed(u8).init(self.allocator);
            try line.appendSlice(line_text);
            try self.lines.append(line);
        }

        if (self.lines.items.len == 0) {
            try self.lines.append(std.array_list.Managed(u8).init(self.allocator));
        }

        // Reset cursor
        self.cursor_row = 0;
        self.cursor_col = 0;
        self.viewport_row = 0;
    }

    /// Get the content as a string
    pub fn getValue(self: *const TextArea, allocator: std.mem.Allocator) ![]const u8 {
        var result = std.array_list.Managed(u8).init(allocator);

        for (self.lines.items, 0..) |line, i| {
            if (i > 0) try result.append('\n');
            try result.appendSlice(line.items);
        }

        return result.toOwnedSlice();
    }

    /// Get total character count
    pub fn charCount(self: *const TextArea) usize {
        var count: usize = 0;
        for (self.lines.items, 0..) |line, i| {
            if (i > 0) count += 1; // Newline
            count += line.items.len;
        }
        return count;
    }

    /// Get line count
    pub fn lineCount(self: *const TextArea) usize {
        return self.lines.items.len;
    }

    /// Set dimensions
    pub fn setSize(self: *TextArea, width: u16, height: u16) void {
        self.width = width;
        self.height = height;
        self.ensureVisible();
    }

    /// Focus the text area
    pub fn focus(self: *TextArea) void {
        self.focused = true;
    }

    /// Blur the text area
    pub fn blur(self: *TextArea) void {
        self.focused = false;
    }

    /// Handle key event
    pub fn handleKey(self: *TextArea, key: keys.KeyEvent) void {
        if (!self.focused) return;

        if (key.modifiers.ctrl) {
            switch (key.key) {
                .char => |c| switch (c) {
                    'a' => self.cursor_col = 0, // Home
                    'e' => self.cursor_col = self.currentLine().items.len, // End
                    'k' => self.killToEndOfLine(), // Kill line
                    'u' => self.killToStartOfLine(), // Kill to start
                    'd' => self.deleteLine(), // Delete line
                    else => {},
                },
                else => {},
            }
            return;
        }

        switch (key.key) {
            .char => |c| self.insertChar(c),
            .paste => |text| self.insertText(text),
            .enter => self.insertNewline(),
            .backspace => self.deleteBackward(),
            .delete => self.deleteForward(),
            .up => self.moveCursorUp(),
            .down => self.moveCursorDown(),
            .left => self.moveCursorLeft(),
            .right => self.moveCursorRight(),
            .home => self.cursor_col = 0,
            .end => self.cursor_col = self.currentLine().items.len,
            .page_up => self.pageUp(),
            .page_down => self.pageDown(),
            .tab => self.insertTab(),
            else => {},
        }

        self.ensureVisible();
    }

    fn currentLine(self: *TextArea) *std.array_list.Managed(u8) {
        return &self.lines.items[self.cursor_row];
    }

    fn insertChar(self: *TextArea, c: u21) void {
        // Check char limit
        if (self.char_limit) |limit| {
            if (self.charCount() >= limit) return;
        }

        var buf: [4]u8 = undefined;
        const len = std.unicode.utf8Encode(c, &buf) catch return;

        const line = self.currentLine();
        const pos = @min(self.cursor_col, line.items.len);
        line.insertSlice(pos, buf[0..len]) catch return;
        self.cursor_col = pos + len;
    }

    fn insertText(self: *TextArea, text: []const u8) void {
        var i: usize = 0;
        while (i < text.len) {
            if (text[i] == '\r') {
                self.insertNewline();
                if (i + 1 < text.len and text[i + 1] == '\n') i += 1;
                i += 1;
                continue;
            }
            if (text[i] == '\n') {
                self.insertNewline();
                i += 1;
                continue;
            }

            const len = std.unicode.utf8ByteSequenceLength(text[i]) catch {
                self.insertChar(text[i]);
                i += 1;
                continue;
            };
            if (i + len > text.len) {
                self.insertChar(text[i]);
                i += 1;
                continue;
            }

            const codepoint = std.unicode.utf8Decode(text[i .. i + len]) catch {
                self.insertChar(text[i]);
                i += 1;
                continue;
            };
            self.insertChar(codepoint);
            i += len;
        }
    }

    fn insertNewline(self: *TextArea) void {
        if (self.max_lines) |max| {
            if (self.lines.items.len >= max) return;
        }

        self.clampCursorToLineBoundary();
        const line = self.currentLine();
        const rest = line.items[self.cursor_col..];

        // Create new line with rest of content
        var new_line = std.array_list.Managed(u8).init(self.allocator);
        new_line.appendSlice(rest) catch return;

        // Truncate current line
        line.shrinkRetainingCapacity(self.cursor_col);

        // Insert new line
        self.lines.insert(self.cursor_row + 1, new_line) catch return;

        self.cursor_row += 1;
        self.cursor_col = 0;
    }

    fn insertTab(self: *TextArea) void {
        // Insert spaces for tab
        for (0..4) |_| {
            self.insertChar(' ');
        }
    }

    fn deleteBackward(self: *TextArea) void {
        if (self.cursor_col > 0) {
            // Delete character before cursor
            const line = self.currentLine();
            var pos = self.cursor_col - 1;

            // Find start of UTF-8 sequence
            while (pos > 0 and (line.items[pos] & 0xC0) == 0x80) {
                pos -= 1;
            }

            const len = self.cursor_col - pos;
            for (0..len) |_| {
                _ = line.orderedRemove(pos);
            }
            self.cursor_col = pos;
        } else if (self.cursor_row > 0) {
            // Join with previous line
            const current = self.lines.orderedRemove(self.cursor_row);
            self.cursor_row -= 1;
            const prev_line = self.currentLine();
            self.cursor_col = prev_line.items.len;
            prev_line.appendSlice(current.items) catch {};
            @constCast(&current).deinit();
        }
    }

    fn deleteForward(self: *TextArea) void {
        const line = self.currentLine();
        self.clampCursorToLineBoundary();
        if (self.cursor_col < line.items.len) {
            // Delete character at cursor
            const byte_len = std.unicode.utf8ByteSequenceLength(line.items[self.cursor_col]) catch 1;
            for (0..byte_len) |_| {
                if (self.cursor_col < line.items.len) {
                    _ = line.orderedRemove(self.cursor_col);
                }
            }
        } else if (self.cursor_row < self.lines.items.len - 1) {
            // Join with next line
            const next = self.lines.orderedRemove(self.cursor_row + 1);
            line.appendSlice(next.items) catch {};
            @constCast(&next).deinit();
        }
    }

    fn killToEndOfLine(self: *TextArea) void {
        self.clampCursorToLineBoundary();
        const line = self.currentLine();
        line.shrinkRetainingCapacity(self.cursor_col);
    }

    fn killToStartOfLine(self: *TextArea) void {
        self.clampCursorToLineBoundary();
        const line = self.currentLine();
        std.mem.copyForwards(u8, line.items[0..], line.items[self.cursor_col..]);
        line.shrinkRetainingCapacity(line.items.len - self.cursor_col);
        self.cursor_col = 0;
    }

    fn deleteLine(self: *TextArea) void {
        if (self.lines.items.len > 1) {
            var removed = self.lines.orderedRemove(self.cursor_row);
            removed.deinit();
            if (self.cursor_row >= self.lines.items.len) {
                self.cursor_row = self.lines.items.len - 1;
            }
            self.cursor_col = @min(self.cursor_col, self.currentLine().items.len);
            self.clampCursorToLineBoundary();
        } else {
            self.currentLine().clearRetainingCapacity();
            self.cursor_col = 0;
        }
    }

    fn moveCursorUp(self: *TextArea) void {
        if (self.word_wrap) {
            const max_width = self.textWidth();
            const line = self.currentLine().items;
            const segment = self.findCursorWrappedSegment(line, max_width);
            const target_col = displayWidthInRange(line, segment.current_start, self.cursor_col, max_width);

            if (segment.prev_start) |prev_start| {
                const prev = wrappedSegmentAt(line, max_width, prev_start);
                self.cursor_col = byteOffsetForDisplayCol(line, prev.start, prev.end, target_col, max_width);
                return;
            }

            if (self.cursor_row > 0) {
                self.cursor_row -= 1;
                const prev_line = self.currentLine().items;
                const prev_start = lastWrappedSegmentStart(prev_line, max_width);
                const prev = wrappedSegmentAt(prev_line, max_width, prev_start);
                self.cursor_col = byteOffsetForDisplayCol(prev_line, prev.start, prev.end, target_col, max_width);
            }
            return;
        }

        if (self.cursor_row > 0) {
            self.cursor_row -= 1;
            self.cursor_col = @min(self.cursor_col, self.currentLine().items.len);
            self.clampCursorToLineBoundary();
        }
    }

    fn moveCursorDown(self: *TextArea) void {
        if (self.word_wrap) {
            const max_width = self.textWidth();
            const line = self.currentLine().items;
            const segment = self.findCursorWrappedSegment(line, max_width);
            const target_col = displayWidthInRange(line, segment.current_start, self.cursor_col, max_width);

            if (!segment.is_last) {
                const next = wrappedSegmentAt(line, max_width, segment.current_end);
                self.cursor_col = byteOffsetForDisplayCol(line, next.start, next.end, target_col, max_width);
                return;
            }

            if (self.cursor_row < self.lines.items.len - 1) {
                self.cursor_row += 1;
                const next_line = self.currentLine().items;
                const next = wrappedSegmentAt(next_line, max_width, 0);
                self.cursor_col = byteOffsetForDisplayCol(next_line, next.start, next.end, target_col, max_width);
            }
            return;
        }

        if (self.cursor_row < self.lines.items.len - 1) {
            self.cursor_row += 1;
            self.cursor_col = @min(self.cursor_col, self.currentLine().items.len);
            self.clampCursorToLineBoundary();
        }
    }

    fn moveCursorLeft(self: *TextArea) void {
        self.clampCursorToLineBoundary();
        if (self.cursor_col > 0) {
            self.cursor_col -= 1;
            // Handle UTF-8 continuation bytes
            const line = self.currentLine();
            while (self.cursor_col > 0 and (line.items[self.cursor_col] & 0xC0) == 0x80) {
                self.cursor_col -= 1;
            }
        } else if (self.cursor_row > 0) {
            self.cursor_row -= 1;
            self.cursor_col = self.currentLine().items.len;
        }
    }

    fn moveCursorRight(self: *TextArea) void {
        const line = self.currentLine();
        self.clampCursorToLineBoundary();
        if (self.cursor_col < line.items.len) {
            const byte_len = std.unicode.utf8ByteSequenceLength(line.items[self.cursor_col]) catch 1;
            self.cursor_col = @min(self.cursor_col + byte_len, line.items.len);
        } else if (self.cursor_row < self.lines.items.len - 1) {
            self.cursor_row += 1;
            self.cursor_col = 0;
        }
    }

    fn pageUp(self: *TextArea) void {
        if (self.word_wrap) {
            for (0..@max(@as(usize, 1), @as(usize, self.height))) |_| {
                self.moveCursorUp();
            }
            return;
        }

        if (self.cursor_row >= self.height) {
            self.cursor_row -= self.height;
        } else {
            self.cursor_row = 0;
        }
        self.cursor_col = @min(self.cursor_col, self.currentLine().items.len);
        self.clampCursorToLineBoundary();
    }

    fn pageDown(self: *TextArea) void {
        if (self.word_wrap) {
            for (0..@max(@as(usize, 1), @as(usize, self.height))) |_| {
                self.moveCursorDown();
            }
            return;
        }

        if (self.cursor_row + self.height < self.lines.items.len) {
            self.cursor_row += self.height;
        } else {
            self.cursor_row = self.lines.items.len - 1;
        }
        self.cursor_col = @min(self.cursor_col, self.currentLine().items.len);
        self.clampCursorToLineBoundary();
    }

    fn ensureVisible(self: *TextArea) void {
        const visible_rows: usize = @max(@as(usize, 1), @as(usize, self.height));

        if (self.word_wrap) {
            const cursor_visual_row = self.cursorVisualRow(self.textWidth());
            if (cursor_visual_row < self.viewport_row) {
                self.viewport_row = cursor_visual_row;
            } else if (cursor_visual_row >= self.viewport_row + visible_rows) {
                self.viewport_row = cursor_visual_row - visible_rows + 1;
            }
            self.viewport_col = 0;
            return;
        }

        // Vertical scrolling
        if (self.cursor_row < self.viewport_row) {
            self.viewport_row = self.cursor_row;
        } else if (self.cursor_row >= self.viewport_row + visible_rows) {
            self.viewport_row = self.cursor_row - visible_rows + 1;
        }

        // Horizontal scrolling using display columns
        const effective_width = self.width -| (if (self.line_numbers) @as(u16, 5) else 0);
        const display_col = self.cursorDisplayCol();
        if (display_col < self.viewport_col) {
            self.viewport_col = display_col;
        } else if (display_col >= self.viewport_col + effective_width) {
            self.viewport_col = display_col - effective_width + 1;
        }
    }

    /// Cursor column in terminal cells (display width), 0-indexed.
    pub fn cursorDisplayColumn(self: *const TextArea) usize {
        return self.cursorDisplayCol();
    }

    /// Render the text area
    pub fn view(self: *const TextArea, allocator: std.mem.Allocator) ![]const u8 {
        var result = std.array_list.Managed(u8).init(allocator);
        const writer = result.writer();

        const line_num_width: usize = if (self.line_numbers) 5 else 0;
        const text_width = self.width -| @as(u16, @intCast(line_num_width));

        // Check for empty content
        const is_empty = self.lines.items.len == 1 and self.lines.items[0].items.len == 0;

        if (self.word_wrap) {
            for (0..self.height) |row| {
                if (row > 0) try writer.writeByte('\n');

                const visual_row = self.viewport_row + row;
                const wrapped_row = self.wrappedRowAt(visual_row, text_width);

                // Line numbers (only on first wrapped segment of a physical line)
                if (self.line_numbers) {
                    if (wrapped_row) |r| {
                        if (r.is_first_segment) {
                            const num_str = try std.fmt.allocPrint(allocator, "{d:>4} ", .{r.line_idx + 1});
                            defer allocator.free(num_str);
                            const styled = try self.line_number_style.render(allocator, num_str);
                            defer allocator.free(styled);
                            try writer.writeAll(styled);
                        } else {
                            try writer.writeAll("     ");
                        }
                    } else {
                        try writer.writeAll("     ");
                    }
                }

                if (wrapped_row) |r| {
                    const line = self.lines.items[r.line_idx];

                    // Show placeholder on first empty line
                    if (is_empty and r.line_idx == 0 and r.is_first_segment and self.placeholder.len > 0) {
                        try self.renderPlaceholder(writer, allocator, text_width);
                        continue;
                    }

                    try self.renderWrappedLineSegment(
                        writer,
                        allocator,
                        line.items,
                        r.line_idx,
                        r.start,
                        r.end,
                        text_width,
                    );
                } else {
                    for (0..text_width) |_| {
                        try writer.writeByte(' ');
                    }
                }
            }

            return result.toOwnedSlice();
        }

        for (0..self.height) |row| {
            if (row > 0) try writer.writeByte('\n');

            const line_idx = self.viewport_row + row;

            // Line numbers
            if (self.line_numbers) {
                if (line_idx < self.lines.items.len) {
                    const num_str = try std.fmt.allocPrint(allocator, "{d:>4} ", .{line_idx + 1});
                    defer allocator.free(num_str);
                    const styled = try self.line_number_style.render(allocator, num_str);
                    defer allocator.free(styled);
                    try writer.writeAll(styled);
                } else {
                    try writer.writeAll("     ");
                }
            }

            if (line_idx < self.lines.items.len) {
                const line = self.lines.items[line_idx];

                // Show placeholder on first empty line
                if (is_empty and line_idx == 0 and self.placeholder.len > 0) {
                    try self.renderPlaceholder(writer, allocator, text_width);
                    continue;
                }

                // Render line content with cursor
                try self.renderLine(writer, allocator, line.items, line_idx, text_width);
            } else {
                // Pad empty rows to full width
                var i: usize = 0;
                while (i < text_width) : (i += 1) {
                    try writer.writeByte(' ');
                }
            }
        }

        return result.toOwnedSlice();
    }

    fn renderPlaceholder(self: *const TextArea, writer: anytype, allocator: std.mem.Allocator, max_width: u16) !void {
        const width_limit: usize = max_width;
        if (width_limit == 0) return;

        var rendered_width: usize = 0;
        var byte_idx: usize = 0;
        while (byte_idx < self.placeholder.len and rendered_width < width_limit) {
            const byte_len = std.unicode.utf8ByteSequenceLength(self.placeholder[byte_idx]) catch 1;
            if (byte_idx + byte_len > self.placeholder.len) break;
            const char_slice = self.placeholder[byte_idx..][0..byte_len];

            const cp = std.unicode.utf8Decode(char_slice) catch {
                byte_idx += 1;
                rendered_width += 1;
                continue;
            };
            const cw = wrapDisplayWidth(unicode.charWidth(cp), width_limit);
            if (rendered_width + cw > width_limit) break;

            const styled = try self.placeholder_style.render(allocator, char_slice);
            defer allocator.free(styled);
            try writer.writeAll(styled);
            byte_idx += byte_len;
            rendered_width += cw;
        }

        while (rendered_width < width_limit) {
            try writer.writeByte(' ');
            rendered_width += 1;
        }
    }

    fn renderWrappedLineSegment(
        self: *const TextArea,
        writer: anytype,
        allocator: std.mem.Allocator,
        line: []const u8,
        line_idx: usize,
        start: usize,
        end: usize,
        max_width: u16,
    ) !void {
        const is_cursor_line = line_idx == self.cursor_row;
        const width_limit: usize = max_width;

        if (width_limit == 0) return;

        var rendered_width: usize = 0;
        var byte_idx = start;
        while (byte_idx < end and rendered_width < width_limit) {
            const is_cursor = is_cursor_line and self.focused and byte_idx == self.cursor_col;

            const byte_len = std.unicode.utf8ByteSequenceLength(line[byte_idx]) catch 1;
            if (byte_idx + byte_len > line.len) break;
            const char_slice = line[byte_idx..][0..byte_len];

            const cp = std.unicode.utf8Decode(char_slice) catch {
                byte_idx += 1;
                rendered_width += 1;
                continue;
            };
            const cw = wrapDisplayWidth(unicode.charWidth(cp), width_limit);
            if (rendered_width + cw > width_limit) break;

            if (is_cursor) {
                const styled = try self.cursor_style.render(allocator, char_slice);
                defer allocator.free(styled);
                try writer.writeAll(styled);
            } else {
                const styled = try self.text_style.render(allocator, char_slice);
                defer allocator.free(styled);
                try writer.writeAll(styled);
            }

            byte_idx += byte_len;
            rendered_width += cw;
        }

        // Cursor at segment end
        if (is_cursor_line and self.focused and self.cursor_col == end and end == line.len and rendered_width < width_limit) {
            const styled = try self.cursor_style.render(allocator, " ");
            defer allocator.free(styled);
            try writer.writeAll(styled);
            rendered_width += 1;
        }

        while (rendered_width < width_limit) {
            try writer.writeByte(' ');
            rendered_width += 1;
        }
    }

    fn renderLine(self: *const TextArea, writer: anytype, allocator: std.mem.Allocator, line: []const u8, line_idx: usize, max_width: u16) !void {
        const is_cursor_line = line_idx == self.cursor_row;

        // Apply horizontal scroll
        var col: usize = 0;
        var byte_idx: usize = 0;

        // Skip to viewport_col (using display columns)
        while (col < self.viewport_col and byte_idx < line.len) {
            const byte_len = std.unicode.utf8ByteSequenceLength(line[byte_idx]) catch 1;
            if (byte_idx + byte_len <= line.len) {
                const cp = std.unicode.utf8Decode(line[byte_idx..][0..byte_len]) catch {
                    byte_idx += 1;
                    col += 1;
                    continue;
                };
                col += unicode.charWidth(cp);
            }
            byte_idx += byte_len;
        }

        // Render visible portion
        var rendered_width: usize = 0;
        while (byte_idx < line.len and rendered_width < max_width) {
            const is_cursor = is_cursor_line and self.focused and byte_idx == self.cursor_col;

            const byte_len = std.unicode.utf8ByteSequenceLength(line[byte_idx]) catch 1;
            if (byte_idx + byte_len > line.len) break;
            const char_slice = line[byte_idx..][0..byte_len];

            const cp = std.unicode.utf8Decode(line[byte_idx..][0..byte_len]) catch {
                byte_idx += 1;
                rendered_width += 1;
                continue;
            };
            const cw = unicode.charWidth(cp);

            // Wide char won't fit — stop
            if (rendered_width + cw > max_width) break;

            if (is_cursor) {
                const styled = try self.cursor_style.render(allocator, char_slice);
                defer allocator.free(styled);
                try writer.writeAll(styled);
            } else {
                const styled = try self.text_style.render(allocator, char_slice);
                defer allocator.free(styled);
                try writer.writeAll(styled);
            }

            byte_idx += byte_len;
            col += cw;
            rendered_width += cw;
        }

        // Cursor at end of line
        if (is_cursor_line and self.focused and byte_idx == self.cursor_col and rendered_width < max_width) {
            const styled = try self.cursor_style.render(allocator, " ");
            defer allocator.free(styled);
            try writer.writeAll(styled);
            rendered_width += 1;
        }

        // Pad remaining width
        while (rendered_width < max_width) {
            try writer.writeByte(' ');
            rendered_width += 1;
        }
    }

    /// Convert byte-offset cursor_col to display column width.
    fn cursorDisplayCol(self: *const TextArea) usize {
        const line = self.lines.items[self.cursor_row];
        var display_col: usize = 0;
        var byte_idx: usize = 0;
        while (byte_idx < self.cursor_col and byte_idx < line.items.len) {
            const byte_len = std.unicode.utf8ByteSequenceLength(line.items[byte_idx]) catch 1;
            if (byte_idx + byte_len <= line.items.len) {
                const cp = std.unicode.utf8Decode(line.items[byte_idx..][0..byte_len]) catch {
                    byte_idx += 1;
                    display_col += 1;
                    continue;
                };
                display_col += unicode.charWidth(cp);
            }
            byte_idx += byte_len;
        }
        return display_col;
    }

    fn textWidth(self: *const TextArea) usize {
        const line_num_width: usize = if (self.line_numbers) 5 else 0;
        return self.width -| @as(u16, @intCast(line_num_width));
    }

    fn cursorVisualRow(self: *const TextArea, max_width: usize) usize {
        var row: usize = 0;
        for (0..self.cursor_row) |idx| {
            row += wrappedRowCount(self.lines.items[idx].items, max_width);
        }
        row += wrappedRowIndexForCursor(self.lines.items[self.cursor_row].items, self.cursor_col, max_width);
        return row;
    }

    fn wrappedRowAt(self: *const TextArea, visual_row: usize, max_width: u16) ?WrappedRow {
        var row_index: usize = 0;
        const width: usize = max_width;

        for (self.lines.items, 0..) |line, line_idx| {
            const line_bytes = line.items;
            if (line_bytes.len == 0) {
                if (row_index == visual_row) {
                    return .{
                        .line_idx = line_idx,
                        .start = 0,
                        .end = 0,
                        .is_first_segment = true,
                    };
                }
                row_index += 1;
                continue;
            }

            var segment_start: usize = 0;
            var first = true;
            while (true) {
                const segment = wrappedSegmentAt(line_bytes, width, segment_start);
                if (row_index == visual_row) {
                    return .{
                        .line_idx = line_idx,
                        .start = segment.start,
                        .end = segment.end,
                        .is_first_segment = first,
                    };
                }

                row_index += 1;
                if (segment.is_last) break;
                segment_start = segment.end;
                first = false;
            }
        }
        return null;
    }

    fn findCursorWrappedSegment(self: *const TextArea, line: []const u8, max_width: usize) CursorWrappedSegment {
        const clamped_cursor = clampToUtf8Boundary(line, self.cursor_col);
        var segment_start: usize = 0;
        var prev_start: ?usize = null;
        while (true) {
            const segment = wrappedSegmentAt(line, max_width, segment_start);
            if (clamped_cursor < segment.end or segment.is_last) {
                return .{
                    .current_start = segment.start,
                    .current_end = segment.end,
                    .prev_start = prev_start,
                    .is_last = segment.is_last,
                };
            }

            if (segment.is_last) break;
            prev_start = segment_start;
            segment_start = segment.end;
        }

        return .{
            .current_start = 0,
            .current_end = line.len,
            .prev_start = null,
            .is_last = true,
        };
    }

    fn wrappedRowCount(line: []const u8, max_width: usize) usize {
        if (line.len == 0) return 1;
        if (max_width == 0) return 1;

        var count: usize = 0;
        var segment_start: usize = 0;
        while (true) {
            const segment = wrappedSegmentAt(line, max_width, segment_start);
            count += 1;
            if (segment.is_last) break;
            segment_start = segment.end;
        }
        return count;
    }

    fn wrappedRowIndexForCursor(line: []const u8, cursor_col: usize, max_width: usize) usize {
        if (line.len == 0) return 0;
        if (max_width == 0) return 0;

        const clamped_cursor = clampToUtf8Boundary(line, cursor_col);
        var index: usize = 0;
        var segment_start: usize = 0;
        while (true) {
            const segment = wrappedSegmentAt(line, max_width, segment_start);
            if (clamped_cursor < segment.end or segment.is_last) return index;
            if (segment.is_last) return index;
            index += 1;
            segment_start = segment.end;
        }
    }

    fn lastWrappedSegmentStart(line: []const u8, max_width: usize) usize {
        if (line.len == 0 or max_width == 0) return 0;
        var segment_start: usize = 0;
        while (true) {
            const segment = wrappedSegmentAt(line, max_width, segment_start);
            if (segment.is_last) return segment_start;
            segment_start = segment.end;
        }
    }

    fn wrappedSegmentAt(line: []const u8, max_width: usize, start: usize) WrappedSegment {
        if (line.len == 0 or max_width == 0 or start >= line.len) {
            return .{
                .start = @min(start, line.len),
                .end = @min(start, line.len),
                .is_last = true,
            };
        }

        var i = start;
        var segment_width: usize = 0;

        while (i < line.len) {
            const byte_len = std.unicode.utf8ByteSequenceLength(line[i]) catch 1;
            if (i + byte_len > line.len) break;

            const cp = std.unicode.utf8Decode(line[i..][0..byte_len]) catch {
                if (segment_width > 0 and segment_width + 1 > max_width) break;
                segment_width += 1;
                i += 1;
                continue;
            };

            const char_width = wrapDisplayWidth(unicode.charWidth(cp), max_width);
            if (segment_width > 0 and segment_width + char_width > max_width) break;

            segment_width += char_width;
            i += byte_len;
        }

        return .{
            .start = start,
            .end = i,
            .is_last = i >= line.len,
        };
    }

    fn displayWidthInRange(line: []const u8, start: usize, end: usize, max_width: usize) usize {
        if (max_width == 0) return 0;
        const clamped_end = clampToUtf8Boundary(line, @min(end, line.len));
        var width: usize = 0;
        var i = @min(start, clamped_end);
        while (i < clamped_end) {
            const byte_len = std.unicode.utf8ByteSequenceLength(line[i]) catch 1;
            if (i + byte_len > line.len) break;
            const cp = std.unicode.utf8Decode(line[i..][0..byte_len]) catch {
                width += 1;
                i += 1;
                continue;
            };
            width += wrapDisplayWidth(unicode.charWidth(cp), max_width);
            i += byte_len;
        }
        return width;
    }

    fn byteOffsetForDisplayCol(line: []const u8, start: usize, end: usize, target_col: usize, max_width: usize) usize {
        if (max_width == 0) return @min(start, line.len);

        const clamped_start = clampToUtf8Boundary(line, @min(start, line.len));
        const clamped_end = clampToUtf8Boundary(line, @min(end, line.len));
        var col: usize = 0;
        var i = clamped_start;
        while (i < clamped_end) {
            if (col >= target_col) return i;

            const byte_len = std.unicode.utf8ByteSequenceLength(line[i]) catch 1;
            if (i + byte_len > line.len) break;
            const cp = std.unicode.utf8Decode(line[i..][0..byte_len]) catch {
                if (col + 1 > target_col) return i;
                col += 1;
                i += 1;
                continue;
            };

            const char_width = wrapDisplayWidth(unicode.charWidth(cp), max_width);
            if (col + char_width > target_col) return i;

            col += char_width;
            i += byte_len;
        }
        return clamped_end;
    }

    fn wrapDisplayWidth(char_width: usize, max_width: usize) usize {
        if (max_width == 0) return 0;
        if (char_width == 0) return 0;
        return @min(char_width, max_width);
    }

    fn clampCursorToLineBoundary(self: *TextArea) void {
        const line = self.currentLine();
        self.cursor_col = clampToUtf8Boundary(line.items, self.cursor_col);
    }

    fn clampToUtf8Boundary(line: []const u8, pos: usize) usize {
        var clamped = @min(pos, line.len);
        while (clamped > 0 and clamped < line.len and (line[clamped] & 0xC0) == 0x80) {
            clamped -= 1;
        }
        return clamped;
    }
};

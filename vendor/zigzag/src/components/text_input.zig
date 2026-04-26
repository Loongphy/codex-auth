//! Single-line text input component.
//! Provides cursor navigation, text editing, and optional validation.

const std = @import("std");
const keys = @import("../input/keys.zig");
const style = @import("../style/style.zig");
const Color = @import("../style/color.zig").Color;

pub const TextInput = struct {
    allocator: std.mem.Allocator,

    // Content
    value: std.array_list.Managed(u8),
    cursor: usize,

    // Appearance
    placeholder: []const u8,
    prompt: []const u8,
    width: ?u16,
    char_limit: ?usize,
    echo_mode: EchoMode,

    // Styling
    text_style: style.Style,
    placeholder_style: style.Style,
    cursor_style: style.Style,
    prompt_style: style.Style,

    // State
    focused: bool,

    // Validation
    validate_fn: ?*const fn ([]const u8) bool,

    // Suggestions/autocomplete
    suggestions: []const []const u8,
    current_suggestion_idx: usize,
    show_suggestions: bool,
    suggestion_style: style.Style,

    pub const EchoMode = enum {
        normal,
        password,
        none,
    };

    pub fn init(allocator: std.mem.Allocator) TextInput {
        return .{
            .allocator = allocator,
            .value = std.array_list.Managed(u8).init(allocator),
            .cursor = 0,
            .placeholder = "",
            .prompt = "",
            .width = null,
            .char_limit = null,
            .echo_mode = .normal,
            .text_style = blk: {
                var s = style.Style{};
                s = s.inline_style(true);
                break :blk s;
            },
            .placeholder_style = blk: {
                var s = style.Style{};
                s = s.fg(Color.gray(12));
                s = s.inline_style(true);
                break :blk s;
            },
            .cursor_style = blk: {
                var s = style.Style{};
                s = s.reverse(true);
                s = s.inline_style(true);
                break :blk s;
            },
            .prompt_style = blk: {
                var s = style.Style{};
                s = s.inline_style(true);
                break :blk s;
            },
            .focused = true,
            .validate_fn = null,
            .suggestions = &.{},
            .current_suggestion_idx = 0,
            .show_suggestions = true,
            .suggestion_style = blk2: {
                var s2 = style.Style{};
                s2 = s2.dim(true);
                s2 = s2.inline_style(true);
                break :blk2 s2;
            },
        };
    }

    pub fn deinit(self: *TextInput) void {
        self.value.deinit();
    }

    /// Set the input value
    pub fn setValue(self: *TextInput, text: []const u8) !void {
        self.value.clearRetainingCapacity();
        try self.value.appendSlice(text);
        self.cursor = @min(self.cursor, self.value.items.len);
    }

    /// Get the current value
    pub fn getValue(self: *const TextInput) []const u8 {
        return self.value.items;
    }

    /// Set placeholder text
    pub fn setPlaceholder(self: *TextInput, text: []const u8) void {
        self.placeholder = text;
    }

    /// Set prompt text
    pub fn setPrompt(self: *TextInput, text: []const u8) void {
        self.prompt = text;
    }

    /// Set width limit
    pub fn setWidth(self: *TextInput, w: u16) void {
        self.width = w;
    }

    /// Set character limit
    pub fn setCharLimit(self: *TextInput, limit: usize) void {
        self.char_limit = limit;
    }

    /// Set echo mode
    pub fn setEchoMode(self: *TextInput, mode: EchoMode) void {
        self.echo_mode = mode;
    }

    /// Set validation function
    pub fn setValidation(self: *TextInput, validate: *const fn ([]const u8) bool) void {
        self.validate_fn = validate;
    }

    /// Focus the input
    pub fn focus(self: *TextInput) void {
        self.focused = true;
    }

    /// Blur the input
    pub fn blur(self: *TextInput) void {
        self.focused = false;
    }

    /// Check if input is valid
    pub fn isValid(self: *const TextInput) bool {
        if (self.validate_fn) |validate| {
            return validate(self.value.items);
        }
        return true;
    }

    /// Set suggestion list
    pub fn setSuggestions(self: *TextInput, list: []const []const u8) void {
        self.suggestions = list;
        self.current_suggestion_idx = 0;
    }

    /// Get current matching suggestion
    pub fn currentSuggestion(self: *const TextInput) ?[]const u8 {
        if (self.suggestions.len == 0 or self.value.items.len == 0) return null;
        const val = self.value.items;
        var match_count: usize = 0;
        for (self.suggestions) |s| {
            if (s.len > val.len and std.mem.startsWith(u8, s, val)) {
                if (match_count == self.current_suggestion_idx) {
                    return s;
                }
                match_count += 1;
            }
        }
        return null;
    }

    /// Handle a key event
    pub fn handleKey(self: *TextInput, key: keys.KeyEvent) void {
        if (!self.focused) return;

        // Alt+arrow for word movement
        if (key.modifiers.alt) {
            switch (key.key) {
                .left => {
                    self.moveCursorWordLeft();
                    return;
                },
                .right => {
                    self.moveCursorWordRight();
                    return;
                },
                else => {},
            }
        }

        if (key.modifiers.ctrl) {
            switch (key.key) {
                .char => |c| switch (c) {
                    'a' => self.cursor = 0, // Home
                    'e' => self.cursor = self.value.items.len, // End
                    'k' => self.value.shrinkRetainingCapacity(self.cursor), // Kill to end
                    'u' => { // Kill to start
                        std.mem.copyForwards(u8, self.value.items[0..], self.value.items[self.cursor..]);
                        self.value.shrinkRetainingCapacity(self.value.items.len - self.cursor);
                        self.cursor = 0;
                    },
                    'w' => self.deleteWordBackward(), // Delete word backward
                    else => {},
                },
                else => {},
            }
            return;
        }

        switch (key.key) {
            .char => |c| self.insertChar(c),
            .paste => |text| self.insertText(text),
            .backspace => self.deleteBackward(),
            .delete => self.deleteForward(),
            .left => self.moveCursorLeft(),
            .right => self.moveCursorRight(),
            .home => self.cursor = 0,
            .end => self.cursor = self.value.items.len,
            .tab => {
                // Accept current suggestion
                if (self.currentSuggestion()) |suggestion| {
                    self.value.clearRetainingCapacity();
                    self.value.appendSlice(suggestion) catch {};
                    self.cursor = self.value.items.len;
                }
            },
            else => {},
        }
    }

    fn insertChar(self: *TextInput, c: u21) void {
        // Check char limit
        if (self.char_limit) |limit| {
            if (self.charCount() >= limit) return;
        }

        var buf: [4]u8 = undefined;
        const len = std.unicode.utf8Encode(c, &buf) catch return;

        // Insert at cursor position
        self.value.insertSlice(self.cursor, buf[0..len]) catch return;
        self.cursor += len;
    }

    fn insertText(self: *TextInput, text: []const u8) void {
        var i: usize = 0;
        while (i < text.len) {
            if (text[i] == '\r' or text[i] == '\n') {
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

    fn deleteBackward(self: *TextInput) void {
        if (self.cursor == 0) return;

        // Find start of previous character
        var start = self.cursor - 1;
        while (start > 0 and (self.value.items[start] & 0xC0) == 0x80) {
            start -= 1;
        }

        const len = self.cursor - start;
        _ = self.value.orderedRemove(start);
        for (1..len) |_| {
            if (start < self.value.items.len) {
                _ = self.value.orderedRemove(start);
            }
        }
        self.cursor = start;
    }

    fn deleteForward(self: *TextInput) void {
        if (self.cursor >= self.value.items.len) return;

        // Find length of current character
        const byte_len = std.unicode.utf8ByteSequenceLength(self.value.items[self.cursor]) catch 1;

        for (0..byte_len) |_| {
            if (self.cursor < self.value.items.len) {
                _ = self.value.orderedRemove(self.cursor);
            }
        }
    }

    fn deleteWordBackward(self: *TextInput) void {
        if (self.cursor == 0) return;

        // Skip trailing spaces
        while (self.cursor > 0 and self.value.items[self.cursor - 1] == ' ') {
            self.deleteBackward();
        }

        // Delete until space or start
        while (self.cursor > 0 and self.value.items[self.cursor - 1] != ' ') {
            self.deleteBackward();
        }
    }

    fn moveCursorLeft(self: *TextInput) void {
        if (self.cursor == 0) return;

        self.cursor -= 1;
        while (self.cursor > 0 and (self.value.items[self.cursor] & 0xC0) == 0x80) {
            self.cursor -= 1;
        }
    }

    fn moveCursorRight(self: *TextInput) void {
        if (self.cursor >= self.value.items.len) return;

        const byte_len = std.unicode.utf8ByteSequenceLength(self.value.items[self.cursor]) catch 1;
        self.cursor = @min(self.cursor + byte_len, self.value.items.len);
    }

    fn moveCursorWordLeft(self: *TextInput) void {
        if (self.cursor == 0) return;
        // Skip whitespace
        while (self.cursor > 0 and self.value.items[self.cursor - 1] == ' ') {
            self.cursor -= 1;
        }
        // Skip word chars
        while (self.cursor > 0 and self.value.items[self.cursor - 1] != ' ') {
            self.cursor -= 1;
        }
    }

    fn moveCursorWordRight(self: *TextInput) void {
        if (self.cursor >= self.value.items.len) return;
        // Skip word chars
        while (self.cursor < self.value.items.len and self.value.items[self.cursor] != ' ') {
            self.cursor += 1;
        }
        // Skip whitespace
        while (self.cursor < self.value.items.len and self.value.items[self.cursor] == ' ') {
            self.cursor += 1;
        }
    }

    fn charCount(self: *const TextInput) usize {
        var count: usize = 0;
        var i: usize = 0;
        while (i < self.value.items.len) {
            const byte_len = std.unicode.utf8ByteSequenceLength(self.value.items[i]) catch 1;
            i += byte_len;
            count += 1;
        }
        return count;
    }

    /// Render the input to a string
    pub fn view(self: *const TextInput, allocator: std.mem.Allocator) ![]const u8 {
        var result = std.array_list.Managed(u8).init(allocator);
        const writer = result.writer();

        // Write prompt
        if (self.prompt.len > 0) {
            const rendered_prompt = try self.prompt_style.render(allocator, self.prompt);
            try writer.writeAll(rendered_prompt);
        }

        // Get display text
        if (self.value.items.len == 0) {
            // Show placeholder
            if (self.placeholder.len > 0) {
                const rendered = try self.placeholder_style.render(allocator, self.placeholder);
                try writer.writeAll(rendered);
            }
        } else {
            // Show value (possibly masked)
            switch (self.echo_mode) {
                .normal => {
                    // Render with cursor
                    if (self.focused) {
                        try self.renderWithCursor(writer, allocator);
                    } else {
                        const rendered = try self.text_style.render(allocator, self.value.items);
                        try writer.writeAll(rendered);
                    }
                },
                .password => {
                    // Show asterisks
                    const char_count = self.charCount();
                    const masked = try allocator.alloc(u8, char_count);
                    @memset(masked, '*');
                    const rendered = try self.text_style.render(allocator, masked);
                    try writer.writeAll(rendered);
                },
                .none => {
                    // Show nothing
                },
            }
        }

        return result.toOwnedSlice();
    }

    fn renderWithCursor(self: *const TextInput, writer: anytype, allocator: std.mem.Allocator) !void {
        // Text before cursor
        if (self.cursor > 0) {
            const before = try self.text_style.render(allocator, self.value.items[0..self.cursor]);
            try writer.writeAll(before);
        }

        // Cursor character
        if (self.cursor < self.value.items.len) {
            const byte_len = std.unicode.utf8ByteSequenceLength(self.value.items[self.cursor]) catch 1;
            const cursor_char = self.value.items[self.cursor..][0..byte_len];
            const cursor_rendered = try self.cursor_style.render(allocator, cursor_char);
            try writer.writeAll(cursor_rendered);

            // Text after cursor
            if (self.cursor + byte_len < self.value.items.len) {
                const after = try self.text_style.render(allocator, self.value.items[self.cursor + byte_len ..]);
                try writer.writeAll(after);
            }
        } else {
            // Cursor at end - show cursor on space
            const cursor_rendered = try self.cursor_style.render(allocator, " ");
            try writer.writeAll(cursor_rendered);
        }

        // Show ghost text for current suggestion
        if (self.show_suggestions) {
            if (self.currentSuggestion()) |suggestion| {
                if (suggestion.len > self.value.items.len) {
                    const ghost = suggestion[self.value.items.len..];
                    const ghost_rendered = try self.suggestion_style.render(allocator, ghost);
                    try writer.writeAll(ghost_rendered);
                }
            }
        }
    }
};

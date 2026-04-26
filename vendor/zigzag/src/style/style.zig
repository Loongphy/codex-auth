//! Style struct for terminal text styling (Lipgloss equivalent).
//! Provides a builder pattern for composing styles.

const std = @import("std");
const color_mod = @import("color.zig");
const border_mod = @import("border.zig");
const ansi = @import("../terminal/ansi.zig");
const measure = @import("../layout/measure.zig");

pub const Color = color_mod.Color;
pub const Border = border_mod.Border;
pub const BorderChars = border_mod.BorderChars;
pub const Sides = border_mod.Sides;

/// Padding/Margin specification
pub const Spacing = struct {
    top: u16 = 0,
    right: u16 = 0,
    bottom: u16 = 0,
    left: u16 = 0,

    pub fn all(n: u16) Spacing {
        return .{ .top = n, .right = n, .bottom = n, .left = n };
    }

    pub fn symmetric(vert: u16, horiz: u16) Spacing {
        return .{ .top = vert, .right = horiz, .bottom = vert, .left = horiz };
    }

    pub fn horizontal(n: u16) Spacing {
        return .{ .left = n, .right = n };
    }

    pub fn vertical(n: u16) Spacing {
        return .{ .top = n, .bottom = n };
    }
};

/// Text alignment
pub const Align = enum {
    left,
    center,
    right,
};

/// Vertical alignment
pub const VAlign = enum {
    top,
    middle,
    bottom,
};

/// Built-in text transform functions
pub const transforms = struct {
    pub fn uppercase(allocator: std.mem.Allocator, text: []const u8) []const u8 {
        const result = allocator.alloc(u8, text.len) catch return text;
        for (text, 0..) |c, i| {
            result[i] = std.ascii.toUpper(c);
        }
        return result;
    }

    pub fn lowercase(allocator: std.mem.Allocator, text: []const u8) []const u8 {
        const result = allocator.alloc(u8, text.len) catch return text;
        for (text, 0..) |c, i| {
            result[i] = std.ascii.toLower(c);
        }
        return result;
    }
};

/// Style definition with builder pattern
pub const Style = struct {
    // Colors
    foreground: Color = .none,
    background: Color = .none,

    // Text attributes (nullable for unset semantics)
    bold_attr: ?bool = null,
    dim_attr: ?bool = null,
    italic_attr: ?bool = null,
    underline_attr: ?bool = null,
    blink_attr: ?bool = null,
    reverse_attr: ?bool = null,
    strikethrough_attr: ?bool = null,

    // Spacing
    padding_val: Spacing = .{},
    margin_val: Spacing = .{},

    // Border
    border_style: BorderChars = Border.none,
    border_sides: Sides = Sides.none,
    border_fg: Color = .none,
    border_bg: Color = .none,

    // Per-side border colors
    border_top_fg: Color = .none,
    border_top_bg: Color = .none,
    border_right_fg: Color = .none,
    border_right_bg: Color = .none,
    border_bottom_fg: Color = .none,
    border_bottom_bg: Color = .none,
    border_left_fg: Color = .none,
    border_left_bg: Color = .none,

    // Margin background
    margin_bg: Color = .none,

    // Tab width
    tab_width_val: ?u8 = null,

    // Size constraints
    width_val: ?u16 = null,
    height_val: ?u16 = null,
    max_width_val: ?u16 = null,
    max_height_val: ?u16 = null,

    // Alignment
    align_horizontal: Align = .left,
    align_vertical: VAlign = .top,

    // Inline (no newlines)
    inline_mode: bool = false,

    // Transform function
    transform_fn: ?*const fn (std.mem.Allocator, []const u8) []const u8 = null,

    // Whitespace formatting controls
    underline_spaces: bool = false,
    strikethrough_spaces: bool = false,
    color_whitespace: bool = true,

    const Self = @This();

    // Color setters
    pub fn foreground_color(self: Self, c: Color) Self {
        var s = self;
        s.foreground = c;
        return s;
    }

    pub fn background_color(self: Self, c: Color) Self {
        var s = self;
        s.background = c;
        return s;
    }

    pub fn fg(self: Self, c: Color) Self {
        return self.foreground_color(c);
    }

    pub fn bg(self: Self, c: Color) Self {
        return self.background_color(c);
    }

    // Text attribute setters
    pub fn bold(self: Self, v: bool) Self {
        var s = self;
        s.bold_attr = v;
        return s;
    }

    pub fn dim(self: Self, v: bool) Self {
        var s = self;
        s.dim_attr = v;
        return s;
    }

    pub fn italic(self: Self, v: bool) Self {
        var s = self;
        s.italic_attr = v;
        return s;
    }

    pub fn underline(self: Self, v: bool) Self {
        var s = self;
        s.underline_attr = v;
        return s;
    }

    pub fn blink(self: Self, v: bool) Self {
        var s = self;
        s.blink_attr = v;
        return s;
    }

    pub fn reverse(self: Self, v: bool) Self {
        var s = self;
        s.reverse_attr = v;
        return s;
    }

    pub fn strikethrough(self: Self, v: bool) Self {
        var s = self;
        s.strikethrough_attr = v;
        return s;
    }

    // Unset methods
    pub fn unsetBold(self: Self) Self {
        var s = self;
        s.bold_attr = null;
        return s;
    }

    pub fn unsetDim(self: Self) Self {
        var s = self;
        s.dim_attr = null;
        return s;
    }

    pub fn unsetItalic(self: Self) Self {
        var s = self;
        s.italic_attr = null;
        return s;
    }

    pub fn unsetUnderline(self: Self) Self {
        var s = self;
        s.underline_attr = null;
        return s;
    }

    pub fn unsetBlink(self: Self) Self {
        var s = self;
        s.blink_attr = null;
        return s;
    }

    pub fn unsetReverse(self: Self) Self {
        var s = self;
        s.reverse_attr = null;
        return s;
    }

    pub fn unsetStrikethrough(self: Self) Self {
        var s = self;
        s.strikethrough_attr = null;
        return s;
    }

    pub fn unsetFg(self: Self) Self {
        var s = self;
        s.foreground = .none;
        return s;
    }

    pub fn unsetBg(self: Self) Self {
        var s = self;
        s.background = .none;
        return s;
    }

    pub fn unsetPadding(self: Self) Self {
        var s = self;
        s.padding_val = .{};
        return s;
    }

    pub fn unsetMargin(self: Self) Self {
        var s = self;
        s.margin_val = .{};
        return s;
    }

    pub fn unsetBorder(self: Self) Self {
        var s = self;
        s.border_style = Border.none;
        s.border_sides = Sides.none;
        s.border_fg = .none;
        s.border_bg = .none;
        s.border_top_fg = .none;
        s.border_top_bg = .none;
        s.border_right_fg = .none;
        s.border_right_bg = .none;
        s.border_bottom_fg = .none;
        s.border_bottom_bg = .none;
        s.border_left_fg = .none;
        s.border_left_bg = .none;
        return s;
    }

    pub fn unsetWidth(self: Self) Self {
        var s = self;
        s.width_val = null;
        return s;
    }

    pub fn unsetHeight(self: Self) Self {
        var s = self;
        s.height_val = null;
        return s;
    }

    pub fn unsetMaxWidth(self: Self) Self {
        var s = self;
        s.max_width_val = null;
        return s;
    }

    pub fn unsetMaxHeight(self: Self) Self {
        var s = self;
        s.max_height_val = null;
        return s;
    }

    // Spacing setters
    pub fn padding(self: Self, p: Spacing) Self {
        var s = self;
        s.padding_val = p;
        return s;
    }

    pub fn paddingAll(self: Self, n: u16) Self {
        return self.padding(Spacing.all(n));
    }

    pub fn paddingLeft(self: Self, n: u16) Self {
        var s = self;
        s.padding_val.left = n;
        return s;
    }

    pub fn paddingRight(self: Self, n: u16) Self {
        var s = self;
        s.padding_val.right = n;
        return s;
    }

    pub fn paddingTop(self: Self, n: u16) Self {
        var s = self;
        s.padding_val.top = n;
        return s;
    }

    pub fn paddingBottom(self: Self, n: u16) Self {
        var s = self;
        s.padding_val.bottom = n;
        return s;
    }

    pub fn margin(self: Self, m: Spacing) Self {
        var s = self;
        s.margin_val = m;
        return s;
    }

    pub fn marginAll(self: Self, n: u16) Self {
        return self.margin(Spacing.all(n));
    }

    pub fn marginLeft(self: Self, n: u16) Self {
        var s = self;
        s.margin_val.left = n;
        return s;
    }

    pub fn marginRight(self: Self, n: u16) Self {
        var s = self;
        s.margin_val.right = n;
        return s;
    }

    pub fn marginTop(self: Self, n: u16) Self {
        var s = self;
        s.margin_val.top = n;
        return s;
    }

    pub fn marginBottom(self: Self, n: u16) Self {
        var s = self;
        s.margin_val.bottom = n;
        return s;
    }

    // Border setters
    pub fn border(self: Self, chars: BorderChars, sides: Sides) Self {
        var s = self;
        s.border_style = chars;
        s.border_sides = sides;
        return s;
    }

    pub fn borderAll(self: Self, chars: BorderChars) Self {
        return self.border(chars, Sides.all);
    }

    pub fn borderForeground(self: Self, c: Color) Self {
        var s = self;
        s.border_fg = c;
        return s;
    }

    pub fn borderBackground(self: Self, c: Color) Self {
        var s = self;
        s.border_bg = c;
        return s;
    }

    pub fn borderTopForeground(self: Self, c: Color) Self {
        var s = self;
        s.border_top_fg = c;
        return s;
    }

    pub fn borderTopBackground(self: Self, c: Color) Self {
        var s = self;
        s.border_top_bg = c;
        return s;
    }

    pub fn borderRightForeground(self: Self, c: Color) Self {
        var s = self;
        s.border_right_fg = c;
        return s;
    }

    pub fn borderRightBackground(self: Self, c: Color) Self {
        var s = self;
        s.border_right_bg = c;
        return s;
    }

    pub fn borderBottomForeground(self: Self, c: Color) Self {
        var s = self;
        s.border_bottom_fg = c;
        return s;
    }

    pub fn borderBottomBackground(self: Self, c: Color) Self {
        var s = self;
        s.border_bottom_bg = c;
        return s;
    }

    pub fn borderLeftForeground(self: Self, c: Color) Self {
        var s = self;
        s.border_left_fg = c;
        return s;
    }

    pub fn borderLeftBackground(self: Self, c: Color) Self {
        var s = self;
        s.border_left_bg = c;
        return s;
    }

    pub fn marginBackground(self: Self, c: Color) Self {
        var s = self;
        s.margin_bg = c;
        return s;
    }

    pub fn tabWidth(self: Self, n: u8) Self {
        var s = self;
        s.tab_width_val = n;
        return s;
    }

    // Size setters
    pub fn width(self: Self, w: u16) Self {
        var s = self;
        s.width_val = w;
        return s;
    }

    pub fn height(self: Self, h: u16) Self {
        var s = self;
        s.height_val = h;
        return s;
    }

    pub fn maxWidth(self: Self, w: u16) Self {
        var s = self;
        s.max_width_val = w;
        return s;
    }

    pub fn maxHeight(self: Self, h: u16) Self {
        var s = self;
        s.max_height_val = h;
        return s;
    }

    // Alignment setters
    pub fn alignH(self: Self, a: Align) Self {
        var s = self;
        s.align_horizontal = a;
        return s;
    }

    pub fn valign(self: Self, a: VAlign) Self {
        var s = self;
        s.align_vertical = a;
        return s;
    }

    // Inline mode
    pub fn inline_style(self: Self, v: bool) Self {
        var s = self;
        s.inline_mode = v;
        return s;
    }

    // Transform setter
    pub fn transform(self: Self, func: *const fn (std.mem.Allocator, []const u8) []const u8) Self {
        var s = self;
        s.transform_fn = func;
        return s;
    }

    // Whitespace formatting control setters
    pub fn setUnderlineSpaces(self: Self, v: bool) Self {
        var s = self;
        s.underline_spaces = v;
        return s;
    }

    pub fn setStrikethroughSpaces(self: Self, v: bool) Self {
        var s = self;
        s.strikethrough_spaces = v;
        return s;
    }

    pub fn setColorWhitespace(self: Self, v: bool) Self {
        var s = self;
        s.color_whitespace = v;
        return s;
    }

    /// Inherit unset values from another style
    pub fn inherit(self: Self, other: Self) Self {
        var s = self;
        if (s.foreground == .none) s.foreground = other.foreground;
        if (s.background == .none) s.background = other.background;
        if (s.bold_attr == null) s.bold_attr = other.bold_attr;
        if (s.dim_attr == null) s.dim_attr = other.dim_attr;
        if (s.italic_attr == null) s.italic_attr = other.italic_attr;
        if (s.underline_attr == null) s.underline_attr = other.underline_attr;
        if (s.blink_attr == null) s.blink_attr = other.blink_attr;
        if (s.reverse_attr == null) s.reverse_attr = other.reverse_attr;
        if (s.strikethrough_attr == null) s.strikethrough_attr = other.strikethrough_attr;
        if (s.padding_val.top == 0 and s.padding_val.bottom == 0 and s.padding_val.left == 0 and s.padding_val.right == 0) {
            s.padding_val = other.padding_val;
        }
        if (s.margin_val.top == 0 and s.margin_val.bottom == 0 and s.margin_val.left == 0 and s.margin_val.right == 0) {
            s.margin_val = other.margin_val;
        }
        if (s.border_fg == .none) s.border_fg = other.border_fg;
        if (s.border_bg == .none) s.border_bg = other.border_bg;
        if (s.width_val == null) s.width_val = other.width_val;
        if (s.height_val == null) s.height_val = other.height_val;
        if (s.max_width_val == null) s.max_width_val = other.max_width_val;
        if (s.max_height_val == null) s.max_height_val = other.max_height_val;
        if (s.margin_bg == .none) s.margin_bg = other.margin_bg;
        if (s.tab_width_val == null) s.tab_width_val = other.tab_width_val;
        if (s.transform_fn == null) s.transform_fn = other.transform_fn;
        return s;
    }

    /// Render styled text
    pub fn render(self: Self, allocator: std.mem.Allocator, text: []const u8) ![]const u8 {
        var result = std.array_list.Managed(u8).init(allocator);
        const writer = result.writer();

        // Preprocess tabs if tab_width is set
        var processed_text = text;
        if (self.tab_width_val) |tw| {
            var buf = std.array_list.Managed(u8).init(allocator);
            for (text) |c| {
                if (c == '\t') {
                    for (0..tw) |_| {
                        try buf.append(' ');
                    }
                } else {
                    try buf.append(c);
                }
            }
            processed_text = try buf.toOwnedSlice();
        }

        // Apply transform function
        if (self.transform_fn) |tf| {
            processed_text = tf(allocator, processed_text);
        }

        // Calculate content dimensions
        const content_width = measure.width(processed_text);
        const content_height = measure.height(processed_text);

        // Apply size constraints
        var target_width = content_width;
        var target_height = content_height;

        if (self.width_val) |w| target_width = w;
        if (self.height_val) |h| target_height = h;
        if (self.max_width_val) |mw| target_width = @min(target_width, mw);
        if (self.max_height_val) |mh| target_height = @min(target_height, mh);

        // Add padding to target dimensions
        target_width += self.padding_val.left + self.padding_val.right;
        target_height += self.padding_val.top + self.padding_val.bottom;

        // Add border width
        if (self.border_sides.left) target_width += 1;
        if (self.border_sides.right) target_width += 1;
        if (self.border_sides.top) target_height += 1;
        if (self.border_sides.bottom) target_height += 1;

        // Write margin top
        for (0..self.margin_val.top) |_| {
            try self.writeMarginLeft(writer);
            if (!self.margin_bg.isNone()) {
                try self.margin_bg.writeBg(writer);
                for (0..target_width) |_| {
                    try writer.writeByte(' ');
                }
                try self.writeMarginRight(writer, target_width);
                try writer.writeAll(ansi.reset);
            }
            try writer.writeByte('\n');
        }

        // Build styled content
        try self.writeStyledContent(writer, processed_text, target_width, target_height);

        // Write margin bottom
        for (0..self.margin_val.bottom) |_| {
            try writer.writeByte('\n');
            try self.writeMarginLeft(writer);
            if (!self.margin_bg.isNone()) {
                try self.margin_bg.writeBg(writer);
                for (0..target_width) |_| {
                    try writer.writeByte(' ');
                }
                try self.writeMarginRight(writer, target_width);
                try writer.writeAll(ansi.reset);
            }
        }

        if (!self.inline_mode and result.items.len > 0 and result.items[result.items.len - 1] == '\n') {
            _ = result.pop();
        }

        return result.toOwnedSlice();
    }

    fn writeStyledContent(self: Self, writer: anytype, text: []const u8, target_width: usize, target_height: usize) !void {
        const inner_width = target_width -|
            self.padding_val.left -| self.padding_val.right -|
            @as(usize, if (self.border_sides.left) 1 else 0) -|
            @as(usize, if (self.border_sides.right) 1 else 0);

        const inner_height = target_height -|
            self.padding_val.top -| self.padding_val.bottom -|
            @as(usize, if (self.border_sides.top) 1 else 0) -|
            @as(usize, if (self.border_sides.bottom) 1 else 0);

        _ = inner_height;

        // Start style
        try self.writeStyleStart(writer);

        // Top border
        if (self.border_sides.top) {
            try self.writeMarginLeft(writer);
            try self.writeBorderColorSide(writer, .top);
            if (self.border_sides.left) try writer.writeAll(self.border_style.top_left);
            for (0..inner_width + self.padding_val.left + self.padding_val.right) |_| {
                try writer.writeAll(self.border_style.horizontal);
            }
            if (self.border_sides.right) try writer.writeAll(self.border_style.top_right);
            try writer.writeAll(ansi.reset);
            try self.writeMarginRight(writer, target_width);
            if (!self.inline_mode) try writer.writeByte('\n');
        }

        // Padding top
        for (0..self.padding_val.top) |_| {
            try self.writeContentLine(writer, "", inner_width);
        }

        // Content lines
        var lines = std.mem.splitScalar(u8, text, '\n');
        while (lines.next()) |line| {
            try self.writeContentLine(writer, line, inner_width);
        }

        // Padding bottom
        for (0..self.padding_val.bottom) |_| {
            try self.writeContentLine(writer, "", inner_width);
        }

        // Bottom border
        if (self.border_sides.bottom) {
            try self.writeMarginLeft(writer);
            try self.writeBorderColorSide(writer, .bottom);
            if (self.border_sides.left) try writer.writeAll(self.border_style.bottom_left);
            for (0..inner_width + self.padding_val.left + self.padding_val.right) |_| {
                try writer.writeAll(self.border_style.horizontal);
            }
            if (self.border_sides.right) try writer.writeAll(self.border_style.bottom_right);
            try writer.writeAll(ansi.reset);
            try self.writeMarginRight(writer, target_width);
        }
    }

    /// Check if whitespace-aware rendering is needed
    fn needsWhitespaceAwareRendering(self: Self) bool {
        return (!self.color_whitespace and !self.background.isNone()) or
            (self.underline_spaces and (self.underline_attr orelse false)) or
            (self.strikethrough_spaces and (self.strikethrough_attr orelse false));
    }

    fn writeContentLine(self: Self, writer: anytype, line: []const u8, inner_width: usize) !void {
        try self.writeMarginLeft(writer);

        // Left border
        if (self.border_sides.left) {
            try self.writeBorderColorSide(writer, .left);
            try writer.writeAll(self.border_style.vertical);
            try writer.writeAll(ansi.reset);
        }

        // Start content style
        try self.writeStyleStart(writer);

        // Left padding
        for (0..self.padding_val.left) |_| {
            try writer.writeByte(' ');
        }

        // Content with alignment
        const line_width = measure.width(line);
        const content_pad = if (inner_width > line_width) inner_width - line_width else 0;

        if (self.needsWhitespaceAwareRendering()) {
            // Whitespace-aware rendering: toggle attributes around spaces
            switch (self.align_horizontal) {
                .left => {
                    try self.writeWithWhitespaceControl(writer, line);
                    try self.writeSpacesWithControl(writer, content_pad);
                },
                .center => {
                    const left_pad = content_pad / 2;
                    const right_pad = content_pad - left_pad;
                    try self.writeSpacesWithControl(writer, left_pad);
                    try self.writeWithWhitespaceControl(writer, line);
                    try self.writeSpacesWithControl(writer, right_pad);
                },
                .right => {
                    try self.writeSpacesWithControl(writer, content_pad);
                    try self.writeWithWhitespaceControl(writer, line);
                },
            }
        } else {
            switch (self.align_horizontal) {
                .left => {
                    try writer.writeAll(line);
                    for (0..content_pad) |_| {
                        try writer.writeByte(' ');
                    }
                },
                .center => {
                    const left_pad = content_pad / 2;
                    const right_pad = content_pad - left_pad;
                    for (0..left_pad) |_| {
                        try writer.writeByte(' ');
                    }
                    try writer.writeAll(line);
                    for (0..right_pad) |_| {
                        try writer.writeByte(' ');
                    }
                },
                .right => {
                    for (0..content_pad) |_| {
                        try writer.writeByte(' ');
                    }
                    try writer.writeAll(line);
                },
            }
        }

        // Right padding
        for (0..self.padding_val.right) |_| {
            try writer.writeByte(' ');
        }

        // Reset style
        try writer.writeAll(ansi.reset);

        // Right border
        if (self.border_sides.right) {
            try self.writeBorderColorSide(writer, .right);
            try writer.writeAll(self.border_style.vertical);
            try writer.writeAll(ansi.reset);
        }

        // Right margin
        const total_content_width = inner_width + self.padding_val.left + self.padding_val.right +
            @as(usize, if (self.border_sides.left) 1 else 0) +
            @as(usize, if (self.border_sides.right) 1 else 0);
        try self.writeMarginRight(writer, total_content_width);

        if (!self.inline_mode) try writer.writeByte('\n');
    }

    /// Write text with per-character whitespace attribute control
    fn writeWithWhitespaceControl(self: Self, writer: anytype, text: []const u8) !void {
        var i: usize = 0;
        while (i < text.len) {
            const byte_len = std.unicode.utf8ByteSequenceLength(text[i]) catch 1;
            const end = @min(i + byte_len, text.len);
            const ch = text[i..end];
            const is_space = ch.len == 1 and ch[0] == ' ';

            if (is_space) {
                // For spaces: conditionally disable/enable attributes
                if (!self.color_whitespace and !self.background.isNone()) {
                    try writer.writeAll(ansi.reset);
                    // Re-emit attributes that should apply to spaces
                    if (self.underline_spaces and (self.underline_attr orelse false)) {
                        try writer.print(ansi.CSI ++ "{d}m", .{ansi.SGR.underline});
                    }
                    if (self.strikethrough_spaces and (self.strikethrough_attr orelse false)) {
                        try writer.print(ansi.CSI ++ "{d}m", .{ansi.SGR.strikethrough});
                    }
                    try writer.writeByte(' ');
                    // Restore full style
                    try self.writeStyleStart(writer);
                } else {
                    // Color whitespace is on, but check underline/strikethrough
                    if (!self.underline_spaces and (self.underline_attr orelse false)) {
                        try writer.print(ansi.CSI ++ "{d}m", .{ansi.SGR.no_underline});
                    }
                    if (!self.strikethrough_spaces and (self.strikethrough_attr orelse false)) {
                        try writer.print(ansi.CSI ++ "{d}m", .{ansi.SGR.no_strikethrough});
                    }
                    try writer.writeByte(' ');
                    // Restore
                    if (!self.underline_spaces and (self.underline_attr orelse false)) {
                        try writer.print(ansi.CSI ++ "{d}m", .{ansi.SGR.underline});
                    }
                    if (!self.strikethrough_spaces and (self.strikethrough_attr orelse false)) {
                        try writer.print(ansi.CSI ++ "{d}m", .{ansi.SGR.strikethrough});
                    }
                }
            } else {
                try writer.writeAll(ch);
            }

            i = end;
        }
    }

    /// Write N spaces with whitespace control
    fn writeSpacesWithControl(self: Self, writer: anytype, count: usize) !void {
        if (count == 0) return;
        if (!self.color_whitespace and !self.background.isNone()) {
            try writer.writeAll(ansi.reset);
            if (self.underline_spaces and (self.underline_attr orelse false)) {
                try writer.print(ansi.CSI ++ "{d}m", .{ansi.SGR.underline});
            }
            if (self.strikethrough_spaces and (self.strikethrough_attr orelse false)) {
                try writer.print(ansi.CSI ++ "{d}m", .{ansi.SGR.strikethrough});
            }
            for (0..count) |_| {
                try writer.writeByte(' ');
            }
            try self.writeStyleStart(writer);
        } else {
            for (0..count) |_| {
                try writer.writeByte(' ');
            }
        }
    }

    fn writeMarginLeft(self: Self, writer: anytype) !void {
        if (!self.margin_bg.isNone() and self.margin_val.left > 0) {
            try self.margin_bg.writeBg(writer);
        }
        for (0..self.margin_val.left) |_| {
            try writer.writeByte(' ');
        }
        if (!self.margin_bg.isNone() and self.margin_val.left > 0) {
            try writer.writeAll(ansi.reset);
        }
    }

    fn writeMarginRight(self: Self, writer: anytype, content_width: usize) !void {
        _ = content_width;
        if (self.margin_val.right > 0) {
            if (!self.margin_bg.isNone()) {
                try self.margin_bg.writeBg(writer);
            }
            for (0..self.margin_val.right) |_| {
                try writer.writeByte(' ');
            }
            if (!self.margin_bg.isNone()) {
                try writer.writeAll(ansi.reset);
            }
        }
    }

    fn writeStyleStart(self: Self, writer: anytype) !void {
        if (self.bold_attr orelse false) try writer.print(ansi.CSI ++ "{d}m", .{ansi.SGR.bold});
        if (self.dim_attr orelse false) try writer.print(ansi.CSI ++ "{d}m", .{ansi.SGR.dim});
        if (self.italic_attr orelse false) try writer.print(ansi.CSI ++ "{d}m", .{ansi.SGR.italic});
        if (self.underline_attr orelse false) try writer.print(ansi.CSI ++ "{d}m", .{ansi.SGR.underline});
        if (self.blink_attr orelse false) try writer.print(ansi.CSI ++ "{d}m", .{ansi.SGR.blink});
        if (self.reverse_attr orelse false) try writer.print(ansi.CSI ++ "{d}m", .{ansi.SGR.reverse});
        if (self.strikethrough_attr orelse false) try writer.print(ansi.CSI ++ "{d}m", .{ansi.SGR.strikethrough});

        try self.foreground.writeFg(writer);
        try self.background.writeBg(writer);
    }

    const BorderSide = enum { top, right, bottom, left };

    fn writeBorderColorSide(self: Self, writer: anytype, side: BorderSide) !void {
        const side_fg = switch (side) {
            .top => self.border_top_fg,
            .right => self.border_right_fg,
            .bottom => self.border_bottom_fg,
            .left => self.border_left_fg,
        };
        const side_bg = switch (side) {
            .top => self.border_top_bg,
            .right => self.border_right_bg,
            .bottom => self.border_bottom_bg,
            .left => self.border_left_bg,
        };
        const resolved_fg = if (!side_fg.isNone()) side_fg else self.border_fg;
        const resolved_bg = if (!side_bg.isNone()) side_bg else self.border_bg;
        try resolved_fg.writeFg(writer);
        try resolved_bg.writeBg(writer);
    }

    fn writeBorderColor(self: Self, writer: anytype) !void {
        try self.border_fg.writeFg(writer);
        try self.border_bg.writeBg(writer);
    }

    /// Copy style
    pub fn copy(self: Self) Self {
        return self;
    }
};

/// Create a new empty style
pub fn newStyle() Style {
    return Style{};
}

/// Style range for applying different styles to byte ranges
pub const StyleRange = struct {
    start: usize,
    end: usize,
    s: Style,
};

/// Render text with different styles applied to specific byte ranges
pub fn renderWithRanges(allocator: std.mem.Allocator, text: []const u8, ranges: []const StyleRange) ![]const u8 {
    var result = std.array_list.Managed(u8).init(allocator);
    const writer = result.writer();

    var pos: usize = 0;
    while (pos < text.len) {
        // Find if this position is in a range
        var found_range: ?StyleRange = null;
        for (ranges) |r| {
            if (pos >= r.start and pos < r.end) {
                found_range = r;
                break;
            }
        }

        if (found_range) |r| {
            const end = @min(r.end, text.len);
            const chunk = text[pos..end];
            const styled = try r.s.render(allocator, chunk);
            try writer.writeAll(styled);
            pos = end;
        } else {
            // Find next range start or end of text
            var next_start: usize = text.len;
            for (ranges) |r| {
                if (r.start > pos and r.start < next_start) {
                    next_start = r.start;
                }
            }
            try writer.writeAll(text[pos..next_start]);
            pos = next_start;
        }
    }

    return result.toOwnedSlice();
}

/// Render text with specific byte positions highlighted
pub fn renderWithHighlights(
    allocator: std.mem.Allocator,
    text: []const u8,
    positions: []const usize,
    highlight_style: Style,
    base_style: Style,
) ![]const u8 {
    var result = std.array_list.Managed(u8).init(allocator);
    const writer = result.writer();

    var pos: usize = 0;
    var pi: usize = 0; // position index

    while (pos < text.len) {
        if (pi < positions.len and pos == positions[pi]) {
            // Highlighted character
            const byte_len = std.unicode.utf8ByteSequenceLength(text[pos]) catch 1;
            const end = @min(pos + byte_len, text.len);
            const ch = text[pos..end];
            const styled = try highlight_style.render(allocator, ch);
            try writer.writeAll(styled);
            pos = end;
            pi += 1;
        } else {
            // Find next highlight position or end of text
            var next_pos: usize = text.len;
            if (pi < positions.len) {
                next_pos = @min(positions[pi], text.len);
            }
            const chunk = text[pos..next_pos];
            if (chunk.len > 0) {
                const styled = try base_style.render(allocator, chunk);
                try writer.writeAll(styled);
            }
            pos = next_pos;
        }
    }

    return result.toOwnedSlice();
}

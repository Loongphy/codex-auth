//! Modal/Popup/Overlay component.
//! State-managed dialog that captures focus, renders on top, and returns a result.
//! Supports confirmation dialogs, input prompts, selection menus, error popups,
//! and fully custom content.
//!
//! ## Quick Start
//!
//! ```zig
//! // Create an info modal
//! var modal = Modal.info("Notice", "Operation completed successfully.");
//! modal.show();
//!
//! // In your update function:
//! modal.handleKey(key_event);
//! if (modal.getResult()) |res| {
//!     switch (res) {
//!         .button_pressed => |idx| { /* button at idx was pressed */ },
//!         .dismissed => { /* user pressed Escape */ },
//!     }
//! }
//!
//! // In your view function:
//! if (modal.isVisible()) {
//!     return modal.viewWithBackdrop(allocator, ctx.width, ctx.height);
//! }
//! ```
//!
//! ## Presets
//!
//! - `Modal.info(title, body)` — informational dialog with OK button (cyan border)
//! - `Modal.confirm(title, body)` — yes/no confirmation (yellow border)
//! - `Modal.warning(title, body)` — warning with OK button (yellow border)
//! - `Modal.err(title, body)` — error with OK button (red border)
//! - `Modal.init()` — blank modal for full custom configuration
//!
//! ## Focus Protocol
//!
//! Modal satisfies the focusable protocol (`focused`, `focus()`, `blur()`) and
//! can be registered with a `FocusGroup`.

const std = @import("std");
const keys = @import("../input/keys.zig");
const style_mod = @import("../style/style.zig");
const border_mod = @import("../style/border.zig");
const Color = @import("../style/color.zig").Color;
const measure = @import("../layout/measure.zig");
const place = @import("../layout/place.zig");

const max_buttons = 8;

pub const Modal = struct {
    // ── State ──────────────────────────────────────────────────────────

    visible: bool = false,
    focused: bool = false,
    result: ?Result = null,

    // ── Content ────────────────────────────────────────────────────────

    title: []const u8 = "",
    body: []const u8 = "",
    footer: ?[]const u8 = null,

    // ── Buttons ────────────────────────────────────────────────────────

    buttons: [max_buttons]?Button = [_]?Button{null} ** max_buttons,
    button_count: usize = 0,
    selected_button: usize = 0,

    // ── Layout ─────────────────────────────────────────────────────────

    width: Size = .{ .percent = 0.5 },
    height: Size = .auto,
    h_position: f32 = 0.5,
    v_position: f32 = 0.5,
    padding: Padding = .{ .top = 1, .right = 2, .bottom = 1, .left = 2 },
    button_align: ButtonAlign = .right,

    // ── Behavior ───────────────────────────────────────────────────────

    close_on_escape: bool = true,

    // ── Styling ────────────────────────────────────────────────────────

    border_chars: border_mod.BorderChars = border_mod.Border.rounded,
    border_fg: Color = Color.gray(18),
    content_bg: Color = .none,
    title_style: style_mod.Style = makeStyle(.{ .bold_v = true, .fg_color = Color.white() }),
    body_style: style_mod.Style = makeStyle(.{ .fg_color = Color.gray(20) }),
    footer_style: style_mod.Style = makeStyle(.{ .fg_color = Color.gray(12), .italic_v = true }),
    button_active_style: style_mod.Style = makeStyle(.{ .bold_v = true, .fg_color = Color.white(), .bg_color = Color.cyan() }),
    button_inactive_style: style_mod.Style = makeStyle(.{ .fg_color = Color.gray(14) }),
    backdrop: ?Backdrop = null,

    // ── Types ──────────────────────────────────────────────────────────

    pub const Result = union(enum) {
        button_pressed: usize,
        dismissed: void,
    };

    pub const Button = struct {
        label: []const u8,
        shortcut: ?keys.Key = null,
    };

    pub const Size = union(enum) {
        fixed: u16,
        percent: f32,
        auto: void,
    };

    pub const Padding = struct {
        top: u16 = 0,
        right: u16 = 0,
        bottom: u16 = 0,
        left: u16 = 0,

        pub fn all(n: u16) Padding {
            return .{ .top = n, .right = n, .bottom = n, .left = n };
        }

        pub fn symmetric(vert: u16, horiz: u16) Padding {
            return .{ .top = vert, .right = horiz, .bottom = vert, .left = horiz };
        }
    };

    pub const ButtonAlign = enum { left, center, right };

    pub const Backdrop = struct {
        /// Fill character (UTF-8 string, e.g. " ", "░", "▒", "▓", "█").
        char: []const u8 = " ",
        /// Style applied to the backdrop fill.
        style: style_mod.Style = makeStyle(.{ .bg_color = Color.gray(3) }),

        /// Dark semi-transparent backdrop (default).
        pub const dark = Backdrop{};

        /// Slightly lighter backdrop.
        pub const medium = Backdrop{
            .style = makeStyle(.{ .bg_color = Color.gray(5) }),
        };

        /// Light backdrop.
        pub const light = Backdrop{
            .style = makeStyle(.{ .bg_color = Color.gray(8) }),
        };

        /// Clear backdrop — uses the terminal's default background color.
        pub const clear = Backdrop{
            .style = makeStyle(.{}),
        };

        /// Light shade fill character (░).
        pub const shade_light = Backdrop{
            .char = "░",
            .style = makeStyle(.{ .fg_color = Color.gray(5) }),
        };

        /// Medium shade fill character (▒).
        pub const shade_medium = Backdrop{
            .char = "▒",
            .style = makeStyle(.{ .fg_color = Color.gray(5) }),
        };

        /// Dense shade fill character (▓).
        pub const shade_dense = Backdrop{
            .char = "▓",
            .style = makeStyle(.{ .fg_color = Color.gray(4) }),
        };

        /// Create a solid-color backdrop.
        pub fn solid(bg_color: Color) Backdrop {
            return .{ .style = makeStyle(.{ .bg_color = bg_color }) };
        }

        /// Create a backdrop with a custom fill character and foreground color.
        pub fn custom(char_str: []const u8, fg_color: Color, bg_color: Color) Backdrop {
            return .{
                .char = char_str,
                .style = makeStyle(.{ .fg_color = fg_color, .bg_color = bg_color }),
            };
        }
    };

    // ── Preset Constructors ────────────────────────────────────────────

    /// Informational dialog with a single OK button and cyan accent.
    pub fn info(title: []const u8, body: []const u8) Modal {
        var m: Modal = .{
            .title = title,
            .body = body,
            .border_fg = Color.cyan(),
            .title_style = makeStyle(.{ .bold_v = true, .fg_color = Color.cyan() }),
        };
        m.addButton("OK", .enter);
        return m;
    }

    /// Yes/No confirmation dialog with yellow accent.
    pub fn confirm(title: []const u8, body: []const u8) Modal {
        var m: Modal = .{
            .title = title,
            .body = body,
            .border_fg = Color.yellow(),
            .title_style = makeStyle(.{ .bold_v = true, .fg_color = Color.yellow() }),
        };
        m.addButton("Yes", .{ .char = 'y' });
        m.addButton("No", .{ .char = 'n' });
        return m;
    }

    /// Warning dialog with a single OK button and yellow accent.
    pub fn warning(title: []const u8, body: []const u8) Modal {
        var m: Modal = .{
            .title = title,
            .body = body,
            .border_fg = Color.yellow(),
            .title_style = makeStyle(.{ .bold_v = true, .fg_color = Color.yellow() }),
        };
        m.addButton("OK", .enter);
        return m;
    }

    /// Error dialog with a single OK button and red accent.
    pub fn err(title: []const u8, body: []const u8) Modal {
        var m: Modal = .{
            .title = title,
            .body = body,
            .border_fg = Color.red(),
            .title_style = makeStyle(.{ .bold_v = true, .fg_color = Color.red() }),
        };
        m.addButton("OK", .enter);
        return m;
    }

    /// Blank modal with no preset content — configure everything yourself.
    pub fn init() Modal {
        return .{};
    }

    // ── Button Management ──────────────────────────────────────────────

    /// Add a button with an optional keyboard shortcut.
    pub fn addButton(self: *Modal, label: []const u8, shortcut: ?keys.Key) void {
        if (self.button_count >= max_buttons) return;
        self.buttons[self.button_count] = .{
            .label = label,
            .shortcut = shortcut,
        };
        self.button_count += 1;
    }

    /// Remove all buttons.
    pub fn clearButtons(self: *Modal) void {
        self.buttons = [_]?Button{null} ** max_buttons;
        self.button_count = 0;
        self.selected_button = 0;
    }

    // ── State Management ───────────────────────────────────────────────

    /// Show the modal and reset its result.
    pub fn show(self: *Modal) void {
        self.visible = true;
        self.focused = true;
        self.result = null;
        self.selected_button = 0;
    }

    /// Hide the modal without setting a result.
    pub fn hide(self: *Modal) void {
        self.visible = false;
        self.focused = false;
    }

    pub fn isVisible(self: *const Modal) bool {
        return self.visible;
    }

    /// Returns the result once the modal has been closed.
    pub fn getResult(self: *const Modal) ?Result {
        return self.result;
    }

    /// Reset visibility, focus, and result.
    pub fn reset(self: *Modal) void {
        self.visible = false;
        self.focused = false;
        self.result = null;
        self.selected_button = 0;
    }

    // ── Focusable Protocol ─────────────────────────────────────────────

    pub fn focus(self: *Modal) void {
        self.focused = true;
    }

    pub fn blur(self: *Modal) void {
        self.focused = false;
    }

    // ── Input Handling ─────────────────────────────────────────────────

    /// Process a key event. Only acts when visible and focused.
    pub fn handleKey(self: *Modal, key: keys.KeyEvent) void {
        if (!self.visible or !self.focused) return;

        // Check button shortcuts first
        for (self.buttons[0..self.button_count], 0..) |maybe_btn, i| {
            if (maybe_btn) |btn| {
                if (btn.shortcut) |sc| {
                    if (sc.eql(key.key)) {
                        self.result = .{ .button_pressed = i };
                        self.visible = false;
                        return;
                    }
                }
            }
        }

        switch (key.key) {
            .escape => {
                if (self.close_on_escape) {
                    self.result = .dismissed;
                    self.visible = false;
                }
            },
            .enter => {
                if (self.button_count > 0) {
                    self.result = .{ .button_pressed = self.selected_button };
                    self.visible = false;
                }
            },
            .tab => {
                if (self.button_count > 1) {
                    if (key.modifiers.shift) {
                        self.selected_button = if (self.selected_button > 0)
                            self.selected_button - 1
                        else
                            self.button_count - 1;
                    } else {
                        self.selected_button = if (self.selected_button + 1 < self.button_count)
                            self.selected_button + 1
                        else
                            0;
                    }
                }
            },
            .left => {
                if (self.button_count > 1 and self.selected_button > 0) {
                    self.selected_button -= 1;
                }
            },
            .right => {
                if (self.button_count > 1 and self.selected_button + 1 < self.button_count) {
                    self.selected_button += 1;
                }
            },
            else => {},
        }
    }

    // ── Rendering ──────────────────────────────────────────────────────

    /// Render the modal box centered on a transparent (space-filled) canvas.
    /// Returns empty string if not visible.
    pub fn view(self: *const Modal, allocator: std.mem.Allocator, term_width: usize, term_height: usize) ![]const u8 {
        if (!self.visible) return try allocator.dupe(u8, "");

        const box = try self.renderBox(allocator, term_width, term_height);
        return try place.placeFloat(allocator, term_width, term_height, self.h_position, self.v_position, box);
    }

    /// Render the modal with a styled backdrop filling the entire terminal.
    /// Returns empty string if not visible.
    pub fn viewWithBackdrop(self: *const Modal, allocator: std.mem.Allocator, term_width: usize, term_height: usize) ![]const u8 {
        if (!self.visible) return try allocator.dupe(u8, "");

        const bd = self.backdrop orelse Backdrop{};
        const box = try self.renderBox(allocator, term_width, term_height);
        const box_w = measure.maxLineWidth(box);
        const box_h = measure.height(box);

        // Position
        const h_space = if (term_width > box_w) term_width - box_w else 0;
        const v_space = if (term_height > box_h) term_height - box_h else 0;
        const modal_x: usize = @intFromFloat(@as(f32, @floatFromInt(h_space)) * clamp01(self.h_position));
        const modal_y: usize = @intFromFloat(@as(f32, @floatFromInt(v_space)) * clamp01(self.v_position));

        // Collect modal lines
        var modal_lines_list = std.array_list.Managed([]const u8).init(allocator);
        defer modal_lines_list.deinit();
        var box_iter = std.mem.splitScalar(u8, box, '\n');
        while (box_iter.next()) |line| try modal_lines_list.append(line);
        const modal_lines = modal_lines_list.items;

        // Build full-screen output
        var result = std.array_list.Managed(u8).init(allocator);
        const writer = result.writer();

        for (0..term_height) |row| {
            if (row > 0) try writer.writeByte('\n');

            const in_modal = row >= modal_y and row < modal_y + box_h;
            if (in_modal) {
                const mline_idx = row - modal_y;
                if (mline_idx < modal_lines.len) {
                    // Left backdrop
                    if (modal_x > 0) {
                        try writer.writeAll(try renderBackdropSegment(allocator, bd, modal_x));
                    }
                    // Modal line
                    try writer.writeAll(modal_lines[mline_idx]);
                    // Right backdrop
                    const mline_w = measure.width(modal_lines[mline_idx]);
                    const right_start = modal_x + mline_w;
                    if (right_start < term_width) {
                        try writer.writeAll(try renderBackdropSegment(allocator, bd, term_width - right_start));
                    }
                } else {
                    try writer.writeAll(try renderBackdropSegment(allocator, bd, term_width));
                }
            } else {
                try writer.writeAll(try renderBackdropSegment(allocator, bd, term_width));
            }
        }

        return result.toOwnedSlice();
    }

    /// Render just the modal box (no positioning or backdrop).
    pub fn renderBox(self: *const Modal, allocator: std.mem.Allocator, term_width: usize, term_height: usize) ![]const u8 {
        const bc = self.border_chars;
        const box_w = self.computeWidth(term_width);
        const inner_w: usize = if (box_w >= 2) box_w - 2 else 0;
        const pad_h: usize = @as(usize, self.padding.left) + @as(usize, self.padding.right);
        const content_w: usize = if (inner_w >= pad_h) inner_w - pad_h else 0;

        // Compute height constraints
        const box_h = self.computeHeight(term_height, inner_w);
        const extras = self.computeExtras();
        const max_body_lines: usize = if (box_h > extras) box_h - extras else 0;

        // Inline styles for border and padding segments
        var bdr_s = style_mod.Style{};
        bdr_s = bdr_s.fg(self.border_fg).inline_style(true);
        if (!self.content_bg.isNone()) bdr_s = bdr_s.bg(self.content_bg);

        var pad_s = style_mod.Style{};
        pad_s = pad_s.inline_style(true);
        if (!self.content_bg.isNone()) pad_s = pad_s.bg(self.content_bg);

        var result = std.array_list.Managed(u8).init(allocator);
        const writer = result.writer();

        // ── Top border ──
        try writer.writeAll(try bdr_s.render(allocator, bc.top_left));
        if (self.title.len > 0) {
            const title_w = measure.width(self.title);
            // top + space + title + space + remaining top chars
            const used: usize = 3 + title_w; // 1 top + 1 space + title + 1 space
            const remaining: usize = if (inner_w > used) inner_w - used else 0;

            try writer.writeAll(try bdr_s.render(allocator, bc.horizontal));
            try writer.writeAll(try bdr_s.render(allocator, " "));
            try writer.writeAll(try self.title_style.inline_style(true).render(allocator, self.title));
            try writer.writeAll(try bdr_s.render(allocator, " "));
            try writer.writeAll(try repeatStr(allocator, bdr_s, bc.horizontal, remaining));
        } else {
            try writer.writeAll(try repeatStr(allocator, bdr_s, bc.horizontal, inner_w));
        }
        try writer.writeAll(try bdr_s.render(allocator, bc.top_right));

        // Helpers for inner lines
        const styled_left = try bdr_s.render(allocator, bc.vertical);
        const styled_right = try bdr_s.render(allocator, bc.vertical);

        // ── Top padding ──
        for (0..self.padding.top) |_| {
            try writer.writeByte('\n');
            try self.writeEmptyInnerLine(allocator, writer, styled_left, styled_right, pad_s, inner_w);
        }

        // ── Body lines ──
        var body_iter = std.mem.splitScalar(u8, self.body, '\n');
        var body_line_count: usize = 0;
        while (body_iter.next()) |line| {
            if (body_line_count >= max_body_lines) break;
            body_line_count += 1;

            try writer.writeByte('\n');
            try writer.writeAll(styled_left);

            // Left padding
            try writer.writeAll(try pad_s.render(allocator, try nSpaces(allocator, self.padding.left)));

            // Body text
            var merged_body = self.body_style.inline_style(true);
            if (!self.content_bg.isNone() and merged_body.background.isNone()) {
                merged_body = merged_body.bg(self.content_bg);
            }
            try writer.writeAll(try merged_body.render(allocator, line));

            // Right fill
            const line_w = measure.width(line);
            const fill: usize = if (content_w > line_w) content_w - line_w else 0;
            try writer.writeAll(try pad_s.render(allocator, try nSpaces(allocator, fill + self.padding.right)));

            try writer.writeAll(styled_right);
        }

        // Pad body if fixed/percent height has more room
        while (body_line_count < max_body_lines) : (body_line_count += 1) {
            try writer.writeByte('\n');
            try self.writeEmptyInnerLine(allocator, writer, styled_left, styled_right, pad_s, inner_w);
        }

        // ── Footer ──
        if (self.footer) |footer_text| {
            // Separator line
            try writer.writeByte('\n');
            try self.writeEmptyInnerLine(allocator, writer, styled_left, styled_right, pad_s, inner_w);

            try writer.writeByte('\n');
            try writer.writeAll(styled_left);
            try writer.writeAll(try pad_s.render(allocator, try nSpaces(allocator, self.padding.left)));

            var merged_footer = self.footer_style.inline_style(true);
            if (!self.content_bg.isNone() and merged_footer.background.isNone()) {
                merged_footer = merged_footer.bg(self.content_bg);
            }
            try writer.writeAll(try merged_footer.render(allocator, footer_text));

            const fw = measure.width(footer_text);
            const fill: usize = if (content_w > fw) content_w - fw else 0;
            try writer.writeAll(try pad_s.render(allocator, try nSpaces(allocator, fill + self.padding.right)));
            try writer.writeAll(styled_right);
        }

        // ── Buttons ──
        if (self.button_count > 0) {
            // Separator
            try writer.writeByte('\n');
            try self.writeEmptyInnerLine(allocator, writer, styled_left, styled_right, pad_s, inner_w);

            // Render button row content
            var btn_buf = std.array_list.Managed(u8).init(allocator);
            const btn_writer = btn_buf.writer();

            for (self.buttons[0..self.button_count], 0..) |maybe_btn, i| {
                if (maybe_btn) |btn| {
                    if (i > 0) {
                        try btn_writer.writeAll(try pad_s.render(allocator, "  "));
                    }
                    const label = try std.fmt.allocPrint(allocator, " {s} ", .{btn.label});
                    var btn_style = if (i == self.selected_button) self.button_active_style else self.button_inactive_style;
                    btn_style = btn_style.inline_style(true);
                    if (!self.content_bg.isNone() and i != self.selected_button and btn_style.background.isNone()) {
                        btn_style = btn_style.bg(self.content_bg);
                    }
                    try btn_writer.writeAll(try btn_style.render(allocator, label));
                }
            }
            const btn_row = try btn_buf.toOwnedSlice();
            const btn_row_w = measure.width(btn_row);

            try writer.writeByte('\n');
            try writer.writeAll(styled_left);

            // Align buttons within inner_w
            const left_spaces: usize = switch (self.button_align) {
                .left => self.padding.left,
                .center => if (inner_w > btn_row_w) (inner_w - btn_row_w) / 2 else 0,
                .right => if (inner_w > btn_row_w + self.padding.right)
                    inner_w - btn_row_w - self.padding.right
                else
                    0,
            };
            const right_spaces: usize = if (inner_w > left_spaces + btn_row_w)
                inner_w - left_spaces - btn_row_w
            else
                0;

            try writer.writeAll(try pad_s.render(allocator, try nSpaces(allocator, left_spaces)));
            try writer.writeAll(btn_row);
            try writer.writeAll(try pad_s.render(allocator, try nSpaces(allocator, right_spaces)));

            try writer.writeAll(styled_right);
        }

        // ── Bottom padding ──
        for (0..self.padding.bottom) |_| {
            try writer.writeByte('\n');
            try self.writeEmptyInnerLine(allocator, writer, styled_left, styled_right, pad_s, inner_w);
        }

        // ── Bottom border ──
        try writer.writeByte('\n');
        try writer.writeAll(try bdr_s.render(allocator, bc.bottom_left));
        try writer.writeAll(try repeatStr(allocator, bdr_s, bc.horizontal, inner_w));
        try writer.writeAll(try bdr_s.render(allocator, bc.bottom_right));

        return result.toOwnedSlice();
    }

    // ── Private Helpers ────────────────────────────────────────────────

    fn writeEmptyInnerLine(
        self: *const Modal,
        allocator: std.mem.Allocator,
        writer: anytype,
        styled_left: []const u8,
        styled_right: []const u8,
        pad_s: style_mod.Style,
        inner_w: usize,
    ) !void {
        _ = self;
        try writer.writeAll(styled_left);
        try writer.writeAll(try pad_s.render(allocator, try nSpaces(allocator, inner_w)));
        try writer.writeAll(styled_right);
    }

    fn computeWidth(self: *const Modal, term_width: usize) usize {
        return switch (self.width) {
            .fixed => |w| @min(@as(usize, w), term_width),
            .percent => |p| @intFromFloat(@as(f32, @floatFromInt(term_width)) * clamp01(p)),
            .auto => blk: {
                const pad_h: usize = @as(usize, self.padding.left) + @as(usize, self.padding.right);
                var max_inner: usize = 0;

                // Title (in border): needs title_w + 4
                if (self.title.len > 0) {
                    max_inner = @max(max_inner, measure.width(self.title) + 4);
                }

                // Content-area items need content_w + padding_h
                var max_content: usize = 0;

                var body_iter = std.mem.splitScalar(u8, self.body, '\n');
                while (body_iter.next()) |line| {
                    max_content = @max(max_content, measure.width(line));
                }

                if (self.footer) |ft| {
                    max_content = @max(max_content, measure.width(ft));
                }

                var btn_w: usize = 0;
                for (self.buttons[0..self.button_count]) |maybe_btn| {
                    if (maybe_btn) |btn| {
                        if (btn_w > 0) btn_w += 2; // gap
                        btn_w += measure.width(btn.label) + 2; // " Label "
                    }
                }
                max_content = @max(max_content, btn_w);

                max_inner = @max(max_inner, max_content + pad_h);
                break :blk @min(max_inner + 2, term_width); // +2 for borders
            },
        };
    }

    fn computeHeight(self: *const Modal, term_height: usize, inner_w: usize) usize {
        _ = inner_w;
        return switch (self.height) {
            .fixed => |h| @min(@as(usize, h), term_height),
            .percent => |p| @intFromFloat(@as(f32, @floatFromInt(term_height)) * clamp01(p)),
            .auto => blk: {
                var h: usize = 2; // top + bottom border
                h += self.padding.top;
                h += self.padding.bottom;

                // Body lines
                var body_lines: usize = 0;
                var iter = std.mem.splitScalar(u8, self.body, '\n');
                while (iter.next()) |_| body_lines += 1;
                h += body_lines;

                if (self.footer != null) h += 2; // separator + footer
                if (self.button_count > 0) h += 2; // separator + button row

                break :blk @min(h, term_height);
            },
        };
    }

    fn computeExtras(self: *const Modal) usize {
        var e: usize = 2; // borders
        e += self.padding.top;
        e += self.padding.bottom;
        if (self.footer != null) e += 2;
        if (self.button_count > 0) e += 2;
        return e;
    }

    fn renderBackdropSegment(allocator: std.mem.Allocator, bd: Backdrop, count: usize) ![]const u8 {
        if (count == 0) return try allocator.dupe(u8, "");
        const ch = bd.char;
        if (ch.len == 0) return try allocator.dupe(u8, "");
        const buf = try allocator.alloc(u8, ch.len * count);
        for (0..count) |i| {
            @memcpy(buf[i * ch.len ..][0..ch.len], ch);
        }
        return try bd.style.inline_style(true).render(allocator, buf);
    }

    fn repeatStr(allocator: std.mem.Allocator, s: style_mod.Style, str: []const u8, count: usize) ![]const u8 {
        if (count == 0 or str.len == 0) return try allocator.dupe(u8, "");
        // Build repeated plain string, then style once
        const buf = try allocator.alloc(u8, str.len * count);
        for (0..count) |i| {
            @memcpy(buf[i * str.len ..][0..str.len], str);
        }
        return try s.render(allocator, buf);
    }

    fn nSpaces(allocator: std.mem.Allocator, count: anytype) ![]const u8 {
        const n: usize = switch (@typeInfo(@TypeOf(count))) {
            .int, .comptime_int => @intCast(count),
            else => count,
        };
        if (n == 0) return try allocator.dupe(u8, "");
        const buf = try allocator.alloc(u8, n);
        @memset(buf, ' ');
        return buf;
    }

    fn nChars(allocator: std.mem.Allocator, ch: u8, count: usize) ![]const u8 {
        if (count == 0) return try allocator.dupe(u8, "");
        const buf = try allocator.alloc(u8, count);
        @memset(buf, ch);
        return buf;
    }

    fn clamp01(v: f32) f32 {
        return @max(0.0, @min(1.0, v));
    }

    // Comptime style builder to avoid runtime block initialization
    const StyleOpts = struct {
        bold_v: ?bool = null,
        dim_v: ?bool = null,
        italic_v: ?bool = null,
        fg_color: Color = .none,
        bg_color: Color = .none,
    };

    fn makeStyle(opts: StyleOpts) style_mod.Style {
        var s = style_mod.Style{};
        if (opts.bold_v) |v| s.bold_attr = v;
        if (opts.dim_v) |v| s.dim_attr = v;
        if (opts.italic_v) |v| s.italic_attr = v;
        if (!opts.fg_color.isNone()) s.foreground = opts.fg_color;
        if (!opts.bg_color.isNone()) s.background = opts.bg_color;
        s.inline_mode = true;
        return s;
    }
};

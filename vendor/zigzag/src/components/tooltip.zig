//! Tooltip component for displaying contextual hints near a target position.
//!
//! ## Quick Start
//!
//! ```zig
//! // Create a tooltip
//! var tip = Tooltip.init("Save the current document");
//!
//! // Position it relative to a target
//! tip.target_x = 10;
//! tip.target_y = 5;
//! tip.placement = .bottom;
//! tip.show();
//!
//! // In your view function:
//! const output = try tip.render(allocator, term_width, term_height);
//! ```
//!
//! ## Placements
//!
//! - `.top` — above the target, arrow pointing down
//! - `.bottom` — below the target, arrow pointing up
//! - `.left` — to the left of the target, arrow pointing right
//! - `.right` — to the right of the target, arrow pointing left
//!
//! ## Presets
//!
//! - `Tooltip.init(text)` — simple tooltip with default style
//! - `Tooltip.titled(title, text)` — tooltip with a bold title line
//! - `Tooltip.help(text)` — dim, italic help-style tooltip
//! - `Tooltip.shortcut(label, key)` — "Label  Ctrl+S" style tooltip

const std = @import("std");
const style_mod = @import("../style/style.zig");
const border_mod = @import("../style/border.zig");
const Color = @import("../style/color.zig").Color;
const AnsiColor = @import("../style/color.zig").AnsiColor;
const measure = @import("../layout/measure.zig");
const unicode = @import("../unicode.zig");

pub const Tooltip = struct {
    // ── State ──────────────────────────────────────────────────────────

    visible: bool = false,

    // ── Content ────────────────────────────────────────────────────────

    text: []const u8 = "",
    title: ?[]const u8 = null,

    // ── Position ──────────────────────────────────────────────────────

    /// X coordinate of the target element (display column).
    target_x: usize = 0,
    /// Y coordinate of the target element (display row).
    target_y: usize = 0,
    /// Width of the target element (used for centering arrows).
    target_width: usize = 1,
    /// Where to place the tooltip relative to the target.
    placement: Placement = .bottom,
    /// Gap between tooltip and target (in cells).
    gap: usize = 0,

    // ── Sizing ─────────────────────────────────────────────────────────

    /// Maximum width of the tooltip content area (excluding border/padding).
    max_width: usize = 40,
    /// Padding inside the tooltip box.
    padding: Padding = .{ .top = 0, .right = 1, .bottom = 0, .left = 1 },

    // ── Styling ────────────────────────────────────────────────────────

    border_chars: border_mod.BorderChars = border_mod.Border.rounded,
    border_fg: Color = Color.gray(14),
    /// Background for the content area (padding + text) inside the border.
    content_bg: Color = .none,
    /// Background for border characters. Three-state via `?Color`:
    /// - `null` (default) — falls back to `content_bg` (same bg everywhere).
    /// - `.none` — explicitly no bg; with `inherit_bg` the base shows through.
    /// - any color — use that color for borders only.
    border_bg: ?Color = null,
    text_style: style_mod.Style = makeStyle(.{ .fg_color = Color.gray(20) }),
    title_style: style_mod.Style = makeStyle(.{ .bold_v = true, .fg_color = Color.white() }),

    /// Show an arrow pointing from tooltip toward the target.
    show_arrow: bool = true,
    /// Color of the arrow character.
    arrow_fg: Color = Color.gray(14),
    /// Background for the arrow character. Three-state via `?Color`:
    /// - `null` (default) — no bg; with `inherit_bg` the base shows through.
    /// - `.none` — explicitly no bg, even when `inherit_bg` is on.
    /// - any color — use that color.
    arrow_bg: ?Color = null,
    /// Custom arrow characters per direction (what's shown when the tooltip
    /// is placed in that direction). Set to "" to hide a specific arrow.
    arrow_up: []const u8 = "▲",
    arrow_down: []const u8 = "▼",
    arrow_left: []const u8 = "◀",
    arrow_right: []const u8 = "▶",

    /// When true in overlay mode, tooltip elements (arrow, border) inherit
    /// the background color from the underlying base content.
    inherit_bg: bool = true,

    // ── Types ──────────────────────────────────────────────────────────

    pub const Placement = enum { top, bottom, left, right };

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

    // ── Preset Constructors ────────────────────────────────────────────

    /// Simple tooltip with text content.
    pub fn init(text: []const u8) Tooltip {
        return .{ .text = text };
    }

    /// Tooltip with a bold title line above the text.
    pub fn titled(title_text: []const u8, body: []const u8) Tooltip {
        return .{
            .text = body,
            .title = title_text,
        };
    }

    /// Help-style tooltip with dim italic text.
    pub fn help(text: []const u8) Tooltip {
        return .{
            .text = text,
            .text_style = makeStyle(.{ .dim_v = true, .italic_v = true, .fg_color = Color.gray(16) }),
            .border_fg = Color.gray(10),
            .arrow_fg = Color.gray(10),
        };
    }

    /// Shortcut tooltip showing "Label  Key".
    pub fn shortcut(label: []const u8, key: []const u8) Tooltip {
        return .{
            .text = key,
            .title = label,
            .title_style = makeStyle(.{ .fg_color = Color.gray(18) }),
            .text_style = makeStyle(.{ .bold_v = true, .fg_color = Color.cyan() }),
        };
    }

    // ── State Management ───────────────────────────────────────────────

    pub fn show(self: *Tooltip) void {
        self.visible = true;
    }

    pub fn hide(self: *Tooltip) void {
        self.visible = false;
    }

    pub fn toggle(self: *Tooltip) void {
        self.visible = !self.visible;
    }

    pub fn isVisible(self: *const Tooltip) bool {
        return self.visible;
    }

    // ── Rendering ──────────────────────────────────────────────────────

    /// Render the tooltip box (no positioning). Returns the box string.
    pub fn renderBox(self: *const Tooltip, allocator: std.mem.Allocator) ![]const u8 {
        const bc = self.border_chars;

        // Compute content lines
        var content_lines = std.array_list.Managed([]const u8).init(allocator);
        defer content_lines.deinit();

        if (self.title) |t| {
            try content_lines.append(t);
        }

        var text_iter = std.mem.splitScalar(u8, self.text, '\n');
        while (text_iter.next()) |line| {
            try content_lines.append(line);
        }

        // Compute inner width
        var max_content_w: usize = 0;
        for (content_lines.items) |line| {
            max_content_w = @max(max_content_w, measure.width(line));
        }
        max_content_w = @min(max_content_w, self.max_width);

        const pad_h: usize = @as(usize, self.padding.left) + @as(usize, self.padding.right);
        const inner_w: usize = max_content_w + pad_h;

        // Inline styles
        // border_bg: null → fall back to content_bg (backward compat)
        //            .none → explicitly no bg (transparent)
        //            color → use that color
        const effective_border_bg = if (self.border_bg) |b| b else self.content_bg;
        var bdr_s = style_mod.Style{};
        bdr_s = bdr_s.fg(self.border_fg).inline_style(true);
        if (!effective_border_bg.isNone()) bdr_s = bdr_s.bg(effective_border_bg);

        var pad_s = style_mod.Style{};
        pad_s = pad_s.inline_style(true);
        if (!self.content_bg.isNone()) pad_s = pad_s.bg(self.content_bg);

        var result = std.array_list.Managed(u8).init(allocator);
        const writer = result.writer();

        // ── Top border ──
        try writer.writeAll(try bdr_s.render(allocator, bc.top_left));
        try writer.writeAll(try repeatStr(allocator, bdr_s, bc.horizontal, inner_w));
        try writer.writeAll(try bdr_s.render(allocator, bc.top_right));

        const styled_left = try bdr_s.render(allocator, bc.vertical);
        const styled_right = try bdr_s.render(allocator, bc.vertical);

        // ── Top padding ──
        for (0..self.padding.top) |_| {
            try writer.writeByte('\n');
            try writeEmptyLine(allocator, writer, styled_left, styled_right, pad_s, inner_w);
        }

        // ── Content lines ──
        for (content_lines.items, 0..) |line, idx| {
            try writer.writeByte('\n');
            try writer.writeAll(styled_left);
            try writer.writeAll(try pad_s.render(allocator, try nSpaces(allocator, self.padding.left)));

            // Pick style: title or body
            const is_title_line = self.title != null and idx == 0;
            var line_style = if (is_title_line) self.title_style else self.text_style;
            line_style = line_style.inline_style(true);
            if (!self.content_bg.isNone() and line_style.background.isNone()) {
                line_style = line_style.bg(self.content_bg);
            }
            try writer.writeAll(try line_style.render(allocator, line));

            const line_w = measure.width(line);
            const fill: usize = if (max_content_w > line_w) max_content_w - line_w else 0;
            try writer.writeAll(try pad_s.render(allocator, try nSpaces(allocator, fill + self.padding.right)));
            try writer.writeAll(styled_right);
        }

        // ── Bottom padding ──
        for (0..self.padding.bottom) |_| {
            try writer.writeByte('\n');
            try writeEmptyLine(allocator, writer, styled_left, styled_right, pad_s, inner_w);
        }

        // ── Bottom border ──
        try writer.writeByte('\n');
        try writer.writeAll(try bdr_s.render(allocator, bc.bottom_left));
        try writer.writeAll(try repeatStr(allocator, bdr_s, bc.horizontal, inner_w));
        try writer.writeAll(try bdr_s.render(allocator, bc.bottom_right));

        return result.toOwnedSlice();
    }

    /// Render the tooltip positioned on a full-screen canvas.
    /// Returns empty string if not visible.
    pub fn render(self: *const Tooltip, allocator: std.mem.Allocator, term_width: usize, term_height: usize) ![]const u8 {
        if (!self.visible) return try allocator.dupe(u8, "");

        const box = try self.renderBox(allocator);
        const box_w = measure.maxLineWidth(box);
        const box_h = measure.height(box);

        // Compute arrow position and tooltip position
        const pos = self.computePosition(box_w, box_h, term_width, term_height);

        // Build full-screen output line by line
        var result = std.array_list.Managed(u8).init(allocator);
        const wr = result.writer();

        // Collect box lines
        var box_lines = std.array_list.Managed([]const u8).init(allocator);
        defer box_lines.deinit();
        var box_iter = std.mem.splitScalar(u8, box, '\n');
        while (box_iter.next()) |line| try box_lines.append(line);

        const is_horizontal = self.placement == .left or self.placement == .right;

        for (0..term_height) |row| {
            if (row > 0) try wr.writeByte('\n');

            const in_box = row >= pos.box_y and row < pos.box_y + box_h;
            const is_arrow_row = self.show_arrow and row == pos.arrow_y;

            if (in_box) {
                const box_line_idx = row - pos.box_y;
                const box_line = if (box_line_idx < box_lines.items.len) box_lines.items[box_line_idx] else "";
                // For left/right placement, include arrow on the same row as the box
                if (is_arrow_row and is_horizontal) {
                    try self.writeBoxRowWithSideArrow(allocator, wr, pos, box_line, term_width);
                } else {
                    try wr.writeAll(try nSpaces(allocator, pos.box_x));
                    try wr.writeAll(box_line);
                    const right = pos.box_x + measure.width(box_line);
                    if (right < term_width) try wr.writeAll(try nSpaces(allocator, term_width - right));
                }
            } else if (is_arrow_row) {
                // Top/bottom arrow on its own row
                try self.writeArrowOnlyRow(allocator, wr, pos, term_width);
            } else {
                try wr.writeAll(try nSpaces(allocator, term_width));
            }
        }

        return result.toOwnedSlice();
    }

    /// Render the tooltip composited onto the given base content.
    ///
    /// Uses **cell-based compositing** (like Ratatui, Textual, Cursive):
    /// both base and tooltip are parsed into a cell grid, tooltip cells are
    /// painted on top, then the grid is serialized back to an ANSI string.
    /// This completely avoids ANSI-splice style bleeding.
    pub fn overlay(self: *const Tooltip, allocator: std.mem.Allocator, base: []const u8, term_width: usize, term_height: usize) ![]const u8 {
        if (!self.visible) return try allocator.dupe(u8, base);

        const box = try self.renderBox(allocator);
        const box_w = measure.maxLineWidth(box);
        const box_h = measure.height(box);
        const pos = self.computePosition(box_w, box_h, term_width, term_height);

        // 1. Parse base content into cell grid
        var grid = try CellGrid.parse(allocator, base, term_width, term_height);

        // 2. Parse tooltip box into cell grid
        var box_grid = try CellGrid.parse(allocator, box, box_w, box_h);

        // 3. Paint tooltip box cells onto base grid
        for (0..box_h) |r| {
            const dst_r = pos.box_y + r;
            if (dst_r >= term_height) break;
            var c: usize = 0;
            while (c < box_w) {
                const dst_c = pos.box_x + c;
                if (dst_c >= term_width) break;

                const src_cell = box_grid.get(r, c);
                if (self.inherit_bg and src_cell.style.bg.eql(.none)) {
                    // Tooltip cell has no bg → inherit from base
                    var merged = src_cell;
                    merged.style.bg = grid.get(dst_r, dst_c).style.bg;
                    grid.set(dst_r, dst_c, merged);
                } else {
                    grid.set(dst_r, dst_c, src_cell);
                }

                // Skip continuation cells of wide characters
                const w = if (src_cell.width > 1) src_cell.width else 1;
                c += w;
            }
        }

        // 4. Paint arrow cell
        if (self.show_arrow) {
            const arrow_ch = self.arrowChar();
            if (arrow_ch.len > 0 and pos.arrow_y < term_height and pos.arrow_x < term_width) {
                const aw = self.arrowDisplayWidth();
                var arrow_style = CellStyle{};
                arrow_style.fg = colorToCellColor(self.arrow_fg);
                if (self.arrow_bg) |abg| {
                    // Explicitly set → use it (even .none = explicitly no bg)
                    if (!abg.isNone()) arrow_style.bg = colorToCellColor(abg);
                } else if (self.inherit_bg) {
                    // Not specified → inherit from base when enabled
                    arrow_style.bg = grid.get(pos.arrow_y, pos.arrow_x).style.bg;
                }
                grid.set(pos.arrow_y, pos.arrow_x, .{
                    .char = arrow_ch,
                    .style = arrow_style,
                    .width = @intCast(aw),
                });
                // Clear continuation cells for wide arrow
                for (1..aw) |dx| {
                    if (pos.arrow_x + dx < term_width) {
                        grid.set(pos.arrow_y, pos.arrow_x + dx, .{
                            .char = "",
                            .style = arrow_style,
                            .width = 0,
                        });
                    }
                }
            }
        }

        // 5. Serialize cell grid back to ANSI string
        return grid.render(allocator);
    }

    // ── Position Computation ──────────────────────────────────────────

    const Position = struct {
        box_x: usize,
        box_y: usize,
        arrow_x: usize,
        arrow_y: usize,
    };

    fn computePosition(self: *const Tooltip, box_w: usize, box_h: usize, tw: usize, th: usize) Position {
        var pos: Position = .{ .box_x = 0, .box_y = 0, .arrow_x = 0, .arrow_y = 0 };

        const arrow_offset: usize = if (self.show_arrow) 1 else 0;

        switch (self.placement) {
            .bottom => {
                // Box below target
                pos.arrow_y = self.target_y + 1 + self.gap;
                pos.box_y = pos.arrow_y + arrow_offset;
                // Center horizontally on target
                const target_center = self.target_x + self.target_width / 2;
                pos.box_x = if (target_center >= box_w / 2) target_center - box_w / 2 else 0;
                pos.arrow_x = target_center;
            },
            .top => {
                // Box above target
                const total_h = box_h + arrow_offset;
                pos.box_y = if (self.target_y >= total_h + self.gap) self.target_y - total_h - self.gap else 0;
                pos.arrow_y = pos.box_y + box_h;
                const target_center = self.target_x + self.target_width / 2;
                pos.box_x = if (target_center >= box_w / 2) target_center - box_w / 2 else 0;
                pos.arrow_x = target_center;
            },
            .right => {
                // Box to the right of target
                pos.box_x = self.target_x + self.target_width + self.gap + arrow_offset;
                pos.arrow_x = self.target_x + self.target_width + self.gap;
                // Center vertically on target
                pos.box_y = if (self.target_y >= box_h / 2) self.target_y - box_h / 2 else 0;
                pos.arrow_y = self.target_y;
            },
            .left => {
                // Box to the left of target
                const total_w = box_w + arrow_offset;
                pos.box_x = if (self.target_x >= total_w + self.gap) self.target_x - total_w - self.gap else 0;
                pos.arrow_x = pos.box_x + box_w;
                pos.box_y = if (self.target_y >= box_h / 2) self.target_y - box_h / 2 else 0;
                pos.arrow_y = self.target_y;
            },
        }

        // Clamp to terminal bounds
        if (pos.box_x + box_w > tw) pos.box_x = if (tw >= box_w) tw - box_w else 0;
        if (pos.box_y + box_h > th) pos.box_y = if (th >= box_h) th - box_h else 0;
        if (pos.arrow_x >= tw) pos.arrow_x = tw -| 1;
        if (pos.arrow_y >= th) pos.arrow_y = th -| 1;

        return pos;
    }

    fn arrowChar(self: *const Tooltip) []const u8 {
        return switch (self.placement) {
            .bottom => self.arrow_up,
            .top => self.arrow_down,
            .left => self.arrow_right,
            .right => self.arrow_left,
        };
    }

    fn renderStyledArrow(self: *const Tooltip, allocator: std.mem.Allocator) ![]const u8 {
        const ch = self.arrowChar();
        if (ch.len == 0) return try allocator.dupe(u8, "");
        var arrow_s = style_mod.Style{};
        arrow_s = arrow_s.fg(self.arrow_fg).inline_style(true);
        return try arrow_s.render(allocator, ch);
    }

    fn arrowDisplayWidth(self: *const Tooltip) usize {
        const ch = self.arrowChar();
        if (ch.len == 0) return 0;
        return measure.width(ch);
    }

    // ── Render helpers (full-screen canvas) ────────────────────────────

    /// Arrow on its own row (top/bottom placement).
    fn writeArrowOnlyRow(self: *const Tooltip, allocator: std.mem.Allocator, writer: anytype, pos: Position, tw: usize) !void {
        try writer.writeAll(try nSpaces(allocator, pos.arrow_x));
        try writer.writeAll(try self.renderStyledArrow(allocator));
        const aw = self.arrowDisplayWidth();
        const used = pos.arrow_x + aw;
        if (used < tw) try writer.writeAll(try nSpaces(allocator, tw - used));
    }

    /// Box row that also has a side arrow (left/right placement).
    fn writeBoxRowWithSideArrow(self: *const Tooltip, allocator: std.mem.Allocator, writer: anytype, pos: Position, box_line: []const u8, tw: usize) !void {
        const box_line_w = measure.width(box_line);
        const aw = self.arrowDisplayWidth();
        const styled_arrow = try self.renderStyledArrow(allocator);

        if (self.placement == .right) {
            // Layout: [spaces] [arrow] [box_line] [spaces]
            try writer.writeAll(try nSpaces(allocator, pos.arrow_x));
            try writer.writeAll(styled_arrow);
            const gap_between = if (pos.box_x > pos.arrow_x + aw) pos.box_x - pos.arrow_x - aw else 0;
            try writer.writeAll(try nSpaces(allocator, gap_between));
            try writer.writeAll(box_line);
            const used = pos.arrow_x + aw + gap_between + box_line_w;
            if (used < tw) try writer.writeAll(try nSpaces(allocator, tw - used));
        } else {
            // .left — Layout: [spaces] [box_line] [arrow] [spaces]
            try writer.writeAll(try nSpaces(allocator, pos.box_x));
            try writer.writeAll(box_line);
            const gap_between = if (pos.arrow_x > pos.box_x + box_line_w) pos.arrow_x - pos.box_x - box_line_w else 0;
            try writer.writeAll(try nSpaces(allocator, gap_between));
            try writer.writeAll(styled_arrow);
            const used = pos.box_x + box_line_w + gap_between + aw;
            if (used < tw) try writer.writeAll(try nSpaces(allocator, tw - used));
        }
    }

    // ── Private Helpers ───────────────────────────────────────────────

    fn writeEmptyLine(allocator: std.mem.Allocator, writer: anytype, styled_left: []const u8, styled_right: []const u8, pad_s: style_mod.Style, inner_w: usize) !void {
        try writer.writeAll(styled_left);
        try writer.writeAll(try pad_s.render(allocator, try nSpaces(allocator, inner_w)));
        try writer.writeAll(styled_right);
    }

    fn repeatStr(allocator: std.mem.Allocator, s: style_mod.Style, str: []const u8, count: usize) ![]const u8 {
        if (count == 0 or str.len == 0) return try allocator.dupe(u8, "");
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

    // Comptime style builder
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

    /// Convert a framework Color to a CellColor for cell-based compositing.
    fn colorToCellColor(c: Color) CellColor {
        return switch (c) {
            .none => .none,
            .ansi => |a| .{ .ansi = a },
            .ansi256 => |n| .{ .ansi256 = n },
            .rgb => |v| .{ .rgb = .{ v.r, v.g, v.b } },
        };
    }
};

// ═══════════════════════════════════════════════════════════════════════
// Cell-based compositing types (à la Ratatui Buffer / Textual Segment)
// ═══════════════════════════════════════════════════════════════════════

/// Color as parsed from raw ANSI SGR — independent of the framework Color type.
const CellColor = union(enum) {
    none,
    ansi: AnsiColor,
    ansi256: u8,
    rgb: [3]u8,

    fn eql(a: CellColor, b: CellColor) bool {
        const tag_a = @intFromEnum(std.meta.activeTag(a));
        const tag_b = @intFromEnum(std.meta.activeTag(b));
        if (tag_a != tag_b) return false;
        return switch (a) {
            .none => true,
            .ansi => |va| va == b.ansi,
            .ansi256 => |va| va == b.ansi256,
            .rgb => |va| va[0] == b.rgb[0] and va[1] == b.rgb[1] and va[2] == b.rgb[2],
        };
    }

    fn writeFg(self: CellColor, wr: anytype) !void {
        switch (self) {
            .none => try wr.writeAll("\x1b[39m"),
            .ansi => |a| try wr.print("\x1b[{d}m", .{a.fgCode()}),
            .ansi256 => |n| try wr.print("\x1b[38;5;{d}m", .{n}),
            .rgb => |c| try wr.print("\x1b[38;2;{d};{d};{d}m", .{ c[0], c[1], c[2] }),
        }
    }

    fn writeBg(self: CellColor, wr: anytype) !void {
        switch (self) {
            .none => try wr.writeAll("\x1b[49m"),
            .ansi => |a| try wr.print("\x1b[{d}m", .{a.bgCode()}),
            .ansi256 => |n| try wr.print("\x1b[48;5;{d}m", .{n}),
            .rgb => |c| try wr.print("\x1b[48;2;{d};{d};{d}m", .{ c[0], c[1], c[2] }),
        }
    }
};

/// Per-cell style parsed from ANSI SGR sequences.
const CellStyle = struct {
    fg: CellColor = .none,
    bg: CellColor = .none,
    bold: bool = false,
    dim: bool = false,
    italic: bool = false,
    underline: bool = false,
    strikethrough: bool = false,

    fn eql(a: CellStyle, b: CellStyle) bool {
        return a.fg.eql(b.fg) and a.bg.eql(b.bg) and
            a.bold == b.bold and a.dim == b.dim and
            a.italic == b.italic and a.underline == b.underline and
            a.strikethrough == b.strikethrough;
    }
};

/// A single terminal cell.
const Cell = struct {
    char: []const u8 = " ",
    style: CellStyle = .{},
    width: u8 = 1, // display width; 0 = continuation cell of wide char
};

/// 2D grid of cells — the intermediate buffer for compositing.
const CellGrid = struct {
    cells: []Cell,
    w: usize,
    h: usize,

    fn get(self: *const CellGrid, row: usize, col: usize) Cell {
        if (row >= self.h or col >= self.w) return Cell{};
        return self.cells[row * self.w + col];
    }

    fn set(self: *CellGrid, row: usize, col: usize, cell: Cell) void {
        if (row >= self.h or col >= self.w) return;
        self.cells[row * self.w + col] = cell;
    }

    /// Parse an ANSI-encoded string into a cell grid.
    fn parse(allocator: std.mem.Allocator, str: []const u8, width: usize, height: usize) !CellGrid {
        const total = width * height;
        const cells = try allocator.alloc(Cell, total);
        for (cells) |*c| c.* = Cell{};

        var cur_style = CellStyle{};
        var row: usize = 0;
        var col: usize = 0;
        var i: usize = 0;

        while (i < str.len) {
            const c = str[i];

            // Newline → next row
            if (c == '\n') {
                row += 1;
                col = 0;
                i += 1;
                continue;
            }

            // ESC sequence
            if (c == 0x1b and i + 1 < str.len and str[i + 1] == '[') {
                i += 2; // skip ESC [
                const params_start = i;
                // Scan to final byte (letter)
                while (i < str.len and !isCSIFinal(str[i])) : (i += 1) {}
                if (i < str.len) {
                    const final = str[i];
                    i += 1;
                    if (final == 'm') {
                        // SGR — update current style
                        const params = str[params_start .. i - 1];
                        applySgr(&cur_style, params);
                    }
                    // Other CSI sequences are silently consumed
                }
                continue;
            }

            // Bare ESC (non-CSI)
            if (c == 0x1b) {
                i += 1;
                continue;
            }

            // Control chars (except newline handled above)
            if (c < 0x20) {
                i += 1;
                continue;
            }

            // Visible character
            if (row >= height) {
                i += 1;
                continue;
            }

            const byte_len = std.unicode.utf8ByteSequenceLength(c) catch 1;
            const end = @min(i + byte_len, str.len);
            const ch_slice = str[i..end];

            var cw: usize = 1;
            if (i + byte_len <= str.len) {
                if (std.unicode.utf8Decode(str[i..][0..byte_len])) |cp| {
                    cw = unicode.charWidth(cp);
                } else |_| {}
            }

            if (col < width) {
                cells[row * width + col] = .{
                    .char = ch_slice,
                    .style = cur_style,
                    .width = @intCast(cw),
                };
                // Mark continuation cells for wide characters
                for (1..cw) |dx| {
                    if (col + dx < width) {
                        cells[row * width + col + dx] = .{
                            .char = "",
                            .style = cur_style,
                            .width = 0,
                        };
                    }
                }
                col += cw;
            }

            i = end;
        }

        return .{ .cells = cells, .w = width, .h = height };
    }

    /// Serialize the cell grid back to an ANSI string.
    /// Emits SGR sequences only when the style changes between cells
    /// (like Ratatui's Buffer::diff), producing minimal output.
    fn render(self: *const CellGrid, allocator: std.mem.Allocator) ![]const u8 {
        var buf = std.array_list.Managed(u8).init(allocator);
        const wr = buf.writer();

        var prev_style = CellStyle{};

        for (0..self.h) |row| {
            if (row > 0) try wr.writeByte('\n');

            // Track trailing spaces to avoid emitting them
            for (0..self.w) |col| {
                const cell = self.cells[row * self.w + col];

                // Skip continuation cells
                if (cell.width == 0) continue;

                // Emit style change if needed
                if (!cell.style.eql(prev_style)) {
                    try emitStyleDiff(wr, prev_style, cell.style);
                    prev_style = cell.style;
                }

                // Emit character
                if (cell.char.len > 0) {
                    try wr.writeAll(cell.char);
                }
            }
        }

        // Final reset
        try wr.writeAll("\x1b[0m");

        return buf.toOwnedSlice();
    }
};

/// Check if a byte is a CSI final byte (letter).
fn isCSIFinal(c: u8) bool {
    return (c >= 'A' and c <= 'Z') or (c >= 'a' and c <= 'z');
}

/// Apply an SGR parameter string to a CellStyle.
fn applySgr(style: *CellStyle, params: []const u8) void {
    // Empty params = reset
    if (params.len == 0) {
        style.* = CellStyle{};
        return;
    }

    var iter = std.mem.splitScalar(u8, params, ';');
    while (iter.next()) |param| {
        const n = std.fmt.parseInt(u32, param, 10) catch continue;
        switch (n) {
            0 => style.* = CellStyle{},
            1 => style.bold = true,
            2 => style.dim = true,
            3 => style.italic = true,
            4 => style.underline = true,
            9 => style.strikethrough = true,
            22 => {
                style.bold = false;
                style.dim = false;
            },
            23 => style.italic = false,
            24 => style.underline = false,
            29 => style.strikethrough = false,
            // Foreground basic colors
            30...37 => {
                style.fg = .{ .ansi = @enumFromInt(n - 30) };
            },
            39 => style.fg = .none,
            // Background basic colors
            40...47 => {
                style.bg = .{ .ansi = @enumFromInt(n - 40) };
            },
            49 => style.bg = .none,
            // Extended foreground
            38 => {
                const sub_str = iter.next() orelse return;
                const sub = std.fmt.parseInt(u32, sub_str, 10) catch return;
                if (sub == 5) {
                    const ci_str = iter.next() orelse return;
                    const ci = std.fmt.parseInt(u8, ci_str, 10) catch return;
                    style.fg = .{ .ansi256 = ci };
                } else if (sub == 2) {
                    const r = std.fmt.parseInt(u8, iter.next() orelse return, 10) catch return;
                    const g = std.fmt.parseInt(u8, iter.next() orelse return, 10) catch return;
                    const b = std.fmt.parseInt(u8, iter.next() orelse return, 10) catch return;
                    style.fg = .{ .rgb = .{ r, g, b } };
                }
            },
            // Extended background
            48 => {
                const sub_str = iter.next() orelse return;
                const sub = std.fmt.parseInt(u32, sub_str, 10) catch return;
                if (sub == 5) {
                    const ci_str = iter.next() orelse return;
                    const ci = std.fmt.parseInt(u8, ci_str, 10) catch return;
                    style.bg = .{ .ansi256 = ci };
                } else if (sub == 2) {
                    const r = std.fmt.parseInt(u8, iter.next() orelse return, 10) catch return;
                    const g = std.fmt.parseInt(u8, iter.next() orelse return, 10) catch return;
                    const b = std.fmt.parseInt(u8, iter.next() orelse return, 10) catch return;
                    style.bg = .{ .rgb = .{ r, g, b } };
                }
            },
            // Bright foreground
            90...97 => {
                style.fg = .{ .ansi = @enumFromInt(n - 90 + 8) };
            },
            // Bright background
            100...107 => {
                style.bg = .{ .ansi = @enumFromInt(n - 100 + 8) };
            },
            else => {},
        }
    }
}

/// Emit the minimal SGR diff to transition from one style to another.
fn emitStyleDiff(wr: anytype, prev: CellStyle, next: CellStyle) !void {
    // If the new style is default, just reset
    const default_style = CellStyle{};
    if (next.eql(default_style)) {
        try wr.writeAll("\x1b[0m");
        return;
    }

    // If any attribute was turned off (true→false), we need a reset first
    // since SGR doesn't have individual "off" codes for all attributes reliably.
    const needs_reset = (prev.bold and !next.bold) or
        (prev.dim and !next.dim) or
        (prev.italic and !next.italic) or
        (prev.underline and !next.underline) or
        (prev.strikethrough and !next.strikethrough);

    if (needs_reset) {
        try wr.writeAll("\x1b[0m");
        // After reset, emit all attributes of the new style
        if (next.bold) try wr.writeAll("\x1b[1m");
        if (next.dim) try wr.writeAll("\x1b[2m");
        if (next.italic) try wr.writeAll("\x1b[3m");
        if (next.underline) try wr.writeAll("\x1b[4m");
        if (next.strikethrough) try wr.writeAll("\x1b[9m");
        if (!next.fg.eql(.none)) try next.fg.writeFg(wr);
        if (!next.bg.eql(.none)) try next.bg.writeBg(wr);
        return;
    }

    // Otherwise, emit only what changed
    if (!prev.fg.eql(next.fg)) try next.fg.writeFg(wr);
    if (!prev.bg.eql(next.bg)) try next.bg.writeBg(wr);
    if (!prev.bold and next.bold) try wr.writeAll("\x1b[1m");
    if (!prev.dim and next.dim) try wr.writeAll("\x1b[2m");
    if (!prev.italic and next.italic) try wr.writeAll("\x1b[3m");
    if (!prev.underline and next.underline) try wr.writeAll("\x1b[4m");
    if (!prev.strikethrough and next.strikethrough) try wr.writeAll("\x1b[9m");
}

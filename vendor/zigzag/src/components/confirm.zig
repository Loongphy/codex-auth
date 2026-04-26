//! Confirmation dialog component.
//! Simple yes/no prompt with keyboard navigation.

const std = @import("std");
const keys = @import("../input/keys.zig");
const style_mod = @import("../style/style.zig");
const Color = @import("../style/color.zig").Color;

pub const Confirm = struct {
    prompt_text: []const u8,
    selected: Selection,
    confirmed: ?bool,
    active: bool,
    focused: bool,

    // Styling
    prompt_style: style_mod.Style,
    active_style: style_mod.Style,
    inactive_style: style_mod.Style,

    pub const Selection = enum {
        yes,
        no,
    };

    pub fn init(prompt_text: []const u8) Confirm {
        return .{
            .prompt_text = prompt_text,
            .selected = .yes,
            .confirmed = null,
            .active = false,
            .focused = true,
            .prompt_style = blk: {
                var s = style_mod.Style{};
                s = s.bold(true);
                s = s.inline_style(true);
                break :blk s;
            },
            .active_style = blk: {
                var s = style_mod.Style{};
                s = s.bold(true);
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

    /// Show the confirmation dialog
    pub fn show(self: *Confirm) void {
        self.active = true;
        self.confirmed = null;
        self.selected = .yes;
    }

    /// Hide the dialog
    pub fn hide(self: *Confirm) void {
        self.active = false;
    }

    /// Check if confirmed (returns true for yes, false for no, null if not yet confirmed)
    pub fn result(self: *const Confirm) ?bool {
        return self.confirmed;
    }

    /// Set focused state (for use with FocusGroup).
    pub fn focus(self: *Confirm) void {
        self.focused = true;
    }

    /// Clear focused state (for use with FocusGroup).
    pub fn blur(self: *Confirm) void {
        self.focused = false;
    }

    /// Handle a key event
    pub fn handleKey(self: *Confirm, key: keys.KeyEvent) void {
        if (!self.active or !self.focused) return;

        switch (key.key) {
            .left, .right, .tab => {
                self.selected = if (self.selected == .yes) .no else .yes;
            },
            .char => |c| switch (c) {
                'y', 'Y' => {
                    self.confirmed = true;
                    self.active = false;
                },
                'n', 'N' => {
                    self.confirmed = false;
                    self.active = false;
                },
                'h' => self.selected = .yes,
                'l' => self.selected = .no,
                else => {},
            },
            .enter => {
                self.confirmed = (self.selected == .yes);
                self.active = false;
            },
            .escape => {
                self.confirmed = false;
                self.active = false;
            },
            else => {},
        }
    }

    /// Render the confirmation dialog
    pub fn view(self: *const Confirm, allocator: std.mem.Allocator) ![]const u8 {
        if (!self.active) {
            return try allocator.dupe(u8, "");
        }

        var result_buf = std.array_list.Managed(u8).init(allocator);
        const writer = result_buf.writer();

        // Prompt
        const styled_prompt = try self.prompt_style.render(allocator, self.prompt_text);
        try writer.writeAll(styled_prompt);
        try writer.writeAll(" ");

        // Yes option
        const yes_style = if (self.selected == .yes) self.active_style else self.inactive_style;
        if (self.selected == .yes) {
            const styled = try yes_style.render(allocator, "[Yes]");
            try writer.writeAll(styled);
        } else {
            const styled = try yes_style.render(allocator, " Yes ");
            try writer.writeAll(styled);
        }

        try writer.writeAll(" ");

        // No option
        const no_style = if (self.selected == .no) self.active_style else self.inactive_style;
        if (self.selected == .no) {
            const styled = try no_style.render(allocator, "[No]");
            try writer.writeAll(styled);
        } else {
            const styled = try no_style.render(allocator, " No ");
            try writer.writeAll(styled);
        }

        return result_buf.toOwnedSlice();
    }
};

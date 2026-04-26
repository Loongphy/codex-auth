//! Key definitions for keyboard input handling.
//! Provides a comprehensive set of key types for terminal input.

const std = @import("std");

/// Modifier keys that can be combined with other keys
pub const Modifiers = packed struct {
    shift: bool = false,
    alt: bool = false,
    ctrl: bool = false,
    super: bool = false,

    pub const none = Modifiers{};

    pub fn eql(self: Modifiers, other: Modifiers) bool {
        return self.shift == other.shift and
            self.alt == other.alt and
            self.ctrl == other.ctrl and
            self.super == other.super;
    }

    pub fn any(self: Modifiers) bool {
        return self.shift or self.alt or self.ctrl or self.super;
    }
};

/// Represents a keyboard key
pub const Key = union(enum) {
    // Character keys
    char: u21,

    // Function keys
    f1,
    f2,
    f3,
    f4,
    f5,
    f6,
    f7,
    f8,
    f9,
    f10,
    f11,
    f12,

    // Navigation keys
    up,
    down,
    left,
    right,
    home,
    end,
    page_up,
    page_down,

    // Editing keys
    insert,
    delete,
    backspace,

    // Control keys
    enter,
    tab,
    escape,
    space,

    // Paste (bracketed paste content)
    paste: []const u8,

    // Special
    null_key,
    unknown: []const u8,

    pub fn eql(self: Key, other: Key) bool {
        const self_tag = std.meta.activeTag(self);
        const other_tag = std.meta.activeTag(other);
        if (self_tag != other_tag) return false;

        return switch (self) {
            .char => |c| c == other.char,
            .paste => |s| std.mem.eql(u8, s, other.paste),
            .unknown => |s| std.mem.eql(u8, s, other.unknown),
            else => true,
        };
    }

    /// Returns the character if this is a char key, null otherwise
    pub fn toChar(self: Key) ?u21 {
        return switch (self) {
            .char => |c| c,
            .space => ' ',
            .enter => '\n',
            .tab => '\t',
            else => null,
        };
    }

    /// Returns a human-readable string for the key
    pub fn name(self: Key) []const u8 {
        return switch (self) {
            .char => "char",
            .f1 => "f1",
            .f2 => "f2",
            .f3 => "f3",
            .f4 => "f4",
            .f5 => "f5",
            .f6 => "f6",
            .f7 => "f7",
            .f8 => "f8",
            .f9 => "f9",
            .f10 => "f10",
            .f11 => "f11",
            .f12 => "f12",
            .up => "up",
            .down => "down",
            .left => "left",
            .right => "right",
            .home => "home",
            .end => "end",
            .page_up => "page_up",
            .page_down => "page_down",
            .insert => "insert",
            .delete => "delete",
            .backspace => "backspace",
            .enter => "enter",
            .tab => "tab",
            .escape => "escape",
            .space => "space",
            .paste => "paste",
            .null_key => "null",
            .unknown => "unknown",
        };
    }
};

/// Key event type (for Kitty keyboard protocol)
pub const KeyEventType = enum {
    press,
    repeat,
    release,
};

/// A key event with modifiers
pub const KeyEvent = struct {
    key: Key,
    modifiers: Modifiers = .{},
    event_type: KeyEventType = .press,

    pub fn eql(self: KeyEvent, other: KeyEvent) bool {
        return self.key.eql(other.key) and self.modifiers.eql(other.modifiers);
    }

    /// Create a key event from a character
    pub fn char(c: u21) KeyEvent {
        return .{ .key = .{ .char = c } };
    }

    /// Create a key event with ctrl modifier
    pub fn ctrl(c: u21) KeyEvent {
        return .{
            .key = .{ .char = c },
            .modifiers = .{ .ctrl = true },
        };
    }

    /// Create a key event with alt modifier
    pub fn alt(c: u21) KeyEvent {
        return .{
            .key = .{ .char = c },
            .modifiers = .{ .alt = true },
        };
    }

    /// Format the key event for display
    pub fn format(
        self: KeyEvent,
        comptime fmt: []const u8,
        options: std.fmt.FormatOptions,
        writer: anytype,
    ) !void {
        _ = fmt;
        _ = options;

        if (self.modifiers.ctrl) try writer.writeAll("ctrl+");
        if (self.modifiers.alt) try writer.writeAll("alt+");
        if (self.modifiers.shift) try writer.writeAll("shift+");
        if (self.modifiers.super) try writer.writeAll("super+");

        switch (self.key) {
            .char => |c| {
                var buf: [4]u8 = undefined;
                const len = std.unicode.utf8Encode(c, &buf) catch 0;
                try writer.writeAll(buf[0..len]);
            },
            else => try writer.writeAll(self.key.name()),
        }
    }
};

//! Mouse event handling for terminal applications.
//! Supports standard terminal mouse protocols.

const std = @import("std");
const keys = @import("keys.zig");

/// Mouse button types
pub const Button = enum {
    left,
    middle,
    right,
    wheel_up,
    wheel_down,
    wheel_left,
    wheel_right,
    button_8,
    button_9,
    button_10,
    button_11,
    none,
};

/// Mouse event types
pub const EventType = enum {
    press,
    release,
    drag,
    move,
};

/// A mouse event
pub const MouseEvent = struct {
    x: u16,
    y: u16,
    button: Button,
    event_type: EventType,
    modifiers: keys.Modifiers = .{},

    pub fn format(
        self: MouseEvent,
        comptime fmt: []const u8,
        options: std.fmt.FormatOptions,
        writer: anytype,
    ) !void {
        _ = fmt;
        _ = options;

        try writer.print("{s} {s} at ({d}, {d})", .{
            @tagName(self.event_type),
            @tagName(self.button),
            self.x,
            self.y,
        });

        if (self.modifiers.any()) {
            try writer.writeAll(" with ");
            if (self.modifiers.ctrl) try writer.writeAll("ctrl ");
            if (self.modifiers.alt) try writer.writeAll("alt ");
            if (self.modifiers.shift) try writer.writeAll("shift ");
        }
    }
};

/// Mouse tracking modes
pub const TrackingMode = enum {
    /// No mouse tracking
    none,
    /// Report button press events only
    normal,
    /// Report button press and release events
    button,
    /// Report all mouse events including motion
    all,
};

/// Generate ANSI sequence to enable mouse tracking
pub fn enableSequence(mode: TrackingMode) []const u8 {
    return switch (mode) {
        .none => "",
        .normal => "\x1b[?1000h\x1b[?1006h",
        .button => "\x1b[?1002h\x1b[?1006h",
        .all => "\x1b[?1003h\x1b[?1006h",
    };
}

/// Generate ANSI sequence to disable mouse tracking
pub fn disableSequence(mode: TrackingMode) []const u8 {
    return switch (mode) {
        .none => "",
        .normal => "\x1b[?1006l\x1b[?1000l",
        .button => "\x1b[?1006l\x1b[?1002l",
        .all => "\x1b[?1006l\x1b[?1003l",
    };
}

/// Parse SGR mouse event (\x1b[<...M or \x1b[<...m)
pub fn parseSgr(data: []const u8) ?struct { event: MouseEvent, consumed: usize } {
    // Format: \x1b[<Cb;Cx;CyM or \x1b[<Cb;Cx;Cym
    if (data.len < 6) return null;
    if (!std.mem.startsWith(u8, data, "\x1b[<")) return null;

    var idx: usize = 3;
    var params: [3]u16 = .{ 0, 0, 0 };
    var param_idx: usize = 0;

    while (idx < data.len and param_idx < 3) {
        const c = data[idx];
        if (c >= '0' and c <= '9') {
            params[param_idx] = params[param_idx] * 10 + @as(u16, @intCast(c - '0'));
            idx += 1;
        } else if (c == ';') {
            param_idx += 1;
            idx += 1;
        } else if (c == 'M' or c == 'm') {
            idx += 1;
            break;
        } else {
            return null;
        }
    }

    if (param_idx < 2) return null;
    if (idx == 0 or (data[idx - 1] != 'M' and data[idx - 1] != 'm')) return null;

    const cb = params[0];
    const is_release = data[idx - 1] == 'm';

    var modifiers = keys.Modifiers{};
    if (cb & 4 != 0) modifiers.shift = true;
    if (cb & 8 != 0) modifiers.alt = true;
    if (cb & 16 != 0) modifiers.ctrl = true;

    const button_bits = cb & 0b11000011;
    const is_motion = cb & 32 != 0;

    const button: Button = switch (button_bits) {
        0 => .left,
        1 => .middle,
        2 => .right,
        3 => .none,
        64 => .wheel_up,
        65 => .wheel_down,
        66 => .wheel_left,
        67 => .wheel_right,
        128 => .button_8,
        129 => .button_9,
        130 => .button_10,
        131 => .button_11,
        else => .none,
    };

    const event_type: EventType = if (is_release)
        .release
    else if (is_motion and button == .none)
        .move
    else if (is_motion)
        .drag
    else
        .press;

    return .{
        .event = .{
            .x = if (params[1] > 0) params[1] - 1 else 0,
            .y = if (params[2] > 0) params[2] - 1 else 0,
            .button = button,
            .event_type = event_type,
            .modifiers = modifiers,
        },
        .consumed = idx,
    };
}

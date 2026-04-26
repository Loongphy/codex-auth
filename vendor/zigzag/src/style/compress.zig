//! ANSI output compression utilities.
//! Reduces ANSI escape sequence overhead by tracking terminal state and emitting only diffs.

const std = @import("std");
const ansi = @import("../terminal/ansi.zig");

/// Tracks the current terminal style state for efficient transitions
pub const StyleState = struct {
    bold: bool = false,
    dim: bool = false,
    italic: bool = false,
    underline: bool = false,
    blink: bool = false,
    reverse: bool = false,
    strikethrough: bool = false,
    fg_set: bool = false,
    bg_set: bool = false,
    fg_r: u8 = 0,
    fg_g: u8 = 0,
    fg_b: u8 = 0,
    bg_r: u8 = 0,
    bg_g: u8 = 0,
    bg_b: u8 = 0,
    fg_ansi: ?u8 = null,
    bg_ansi: ?u8 = null,

    /// Reset to default state
    pub fn reset(self: *StyleState) void {
        self.* = .{};
    }

    /// Emit only the ANSI escape sequences needed to transition to the target state
    pub fn transitionTo(self: *StyleState, writer: anytype, target: StyleState) !void {
        // If target is fully default, just emit reset
        if (!target.bold and !target.dim and !target.italic and !target.underline and
            !target.blink and !target.reverse and !target.strikethrough and
            !target.fg_set and !target.bg_set)
        {
            if (self.bold or self.dim or self.italic or self.underline or
                self.blink or self.reverse or self.strikethrough or
                self.fg_set or self.bg_set)
            {
                try writer.writeAll(ansi.reset);
                self.reset();
            }
            return;
        }

        // Check if we need a full reset first (any attribute going from on to off)
        const needs_reset = (self.bold and !target.bold) or
            (self.dim and !target.dim) or
            (self.italic and !target.italic) or
            (self.underline and !target.underline) or
            (self.blink and !target.blink) or
            (self.reverse and !target.reverse) or
            (self.strikethrough and !target.strikethrough);

        if (needs_reset) {
            try writer.writeAll(ansi.reset);
            self.reset();
        }

        // Now emit only the attributes that need to be turned on
        if (target.bold and !self.bold) try writer.print(ansi.CSI ++ "{d}m", .{ansi.SGR.bold});
        if (target.dim and !self.dim) try writer.print(ansi.CSI ++ "{d}m", .{ansi.SGR.dim});
        if (target.italic and !self.italic) try writer.print(ansi.CSI ++ "{d}m", .{ansi.SGR.italic});
        if (target.underline and !self.underline) try writer.print(ansi.CSI ++ "{d}m", .{ansi.SGR.underline});
        if (target.blink and !self.blink) try writer.print(ansi.CSI ++ "{d}m", .{ansi.SGR.blink});
        if (target.reverse and !self.reverse) try writer.print(ansi.CSI ++ "{d}m", .{ansi.SGR.reverse});
        if (target.strikethrough and !self.strikethrough) try writer.print(ansi.CSI ++ "{d}m", .{ansi.SGR.strikethrough});

        // Foreground color
        if (target.fg_set) {
            const fg_changed = !self.fg_set or
                self.fg_r != target.fg_r or self.fg_g != target.fg_g or self.fg_b != target.fg_b or
                (self.fg_ansi != target.fg_ansi);
            if (fg_changed) {
                if (target.fg_ansi) |a| {
                    try writer.print(ansi.CSI ++ "{d}m", .{a});
                } else {
                    try writer.print(ansi.CSI ++ "38;2;{d};{d};{d}m", .{ target.fg_r, target.fg_g, target.fg_b });
                }
            }
        } else if (self.fg_set) {
            try writer.print(ansi.CSI ++ "{d}m", .{ansi.SGR.fg_default});
        }

        // Background color
        if (target.bg_set) {
            const bg_changed = !self.bg_set or
                self.bg_r != target.bg_r or self.bg_g != target.bg_g or self.bg_b != target.bg_b or
                (self.bg_ansi != target.bg_ansi);
            if (bg_changed) {
                if (target.bg_ansi) |a| {
                    try writer.print(ansi.CSI ++ "{d}m", .{a});
                } else {
                    try writer.print(ansi.CSI ++ "48;2;{d};{d};{d}m", .{ target.bg_r, target.bg_g, target.bg_b });
                }
            }
        } else if (self.bg_set) {
            try writer.print(ansi.CSI ++ "{d}m", .{ansi.SGR.bg_default});
        }

        // Update state
        self.* = target;
    }
};

/// Post-process an ANSI string to remove redundant escape sequences.
/// Strips consecutive resets and duplicate attribute settings.
pub fn compressAnsi(allocator: std.mem.Allocator, input: []const u8) ![]const u8 {
    var result = std.array_list.Managed(u8).init(allocator);
    const writer = result.writer();

    var i: usize = 0;
    var last_was_reset = false;

    while (i < input.len) {
        // Check for ESC[
        if (i + 1 < input.len and input[i] == 0x1b and input[i + 1] == '[') {
            // Find the end of the CSI sequence
            var seq_end = i + 2;
            while (seq_end < input.len) {
                const c = input[seq_end];
                if ((c >= 'A' and c <= 'Z') or (c >= 'a' and c <= 'z')) {
                    seq_end += 1;
                    break;
                }
                seq_end += 1;
            }

            const seq = input[i..seq_end];

            // Check for reset sequence
            if (std.mem.eql(u8, seq, ansi.reset)) {
                if (!last_was_reset) {
                    try writer.writeAll(seq);
                    last_was_reset = true;
                }
                // Skip duplicate resets
            } else {
                try writer.writeAll(seq);
                last_was_reset = false;
            }

            i = seq_end;
        } else {
            try writer.writeByte(input[i]);
            last_was_reset = false;
            i += 1;
        }
    }

    return result.toOwnedSlice();
}

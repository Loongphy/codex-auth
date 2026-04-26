//! Message types for the ZigZag TUI framework.
//! Messages represent events that can occur in the application.

const std = @import("std");
const keyboard = @import("../input/keyboard.zig");
const mouse = @import("../input/mouse.zig");

/// Key event message
pub const Key = keyboard.KeyEvent;

/// Mouse event message
pub const Mouse = mouse.MouseEvent;

/// Window size change message
pub const WindowSize = struct {
    width: u16,
    height: u16,
};

/// Tick message for timer-based updates
pub const Tick = struct {
    /// Monotonic timestamp in nanoseconds since program start.
    timestamp: i64,
    delta: u64, // nanoseconds since last tick
};

/// Focus change message
pub const Focus = enum {
    gained,
    lost,
};

/// Batch of messages
pub const Batch = struct {
    messages: []const SystemMsg,
};

/// System messages that the framework generates
pub const SystemMsg = union(enum) {
    /// Keyboard input
    key: Key,
    /// Mouse input
    mouse: Mouse,
    /// Window was resized
    window_size: WindowSize,
    /// Timer tick
    tick: Tick,
    /// Focus change
    focus: Focus,
    /// Batch of messages
    batch: Batch,
    /// No message
    none,

    pub fn isQuit(self: SystemMsg) bool {
        return switch (self) {
            .key => |k| k.key == .{ .char = 'c' } and k.modifiers.ctrl,
            else => false,
        };
    }
};

/// Convert a key to a character if possible
pub fn keyToChar(key: Key) ?u21 {
    return key.key.toChar();
}

/// Check if a key matches a specific character
pub fn isChar(key: Key, c: u21) bool {
    return switch (key.key) {
        .char => |ch| ch == c and !key.modifiers.any(),
        else => false,
    };
}

/// Check if a key is a specific character with ctrl modifier
pub fn isCtrl(key: Key, c: u21) bool {
    return switch (key.key) {
        .char => |ch| ch == c and key.modifiers.ctrl and !key.modifiers.alt and !key.modifiers.shift,
        else => false,
    };
}

/// Check if a key is a specific character with alt modifier
pub fn isAlt(key: Key, c: u21) bool {
    return switch (key.key) {
        .char => |ch| ch == c and key.modifiers.alt and !key.modifiers.ctrl and !key.modifiers.shift,
        else => false,
    };
}

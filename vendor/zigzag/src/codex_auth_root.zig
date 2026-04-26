pub const ansi = @import("terminal/ansi.zig");

pub const input = struct {
    pub const keyboard = @import("input/keyboard.zig");
    pub const keys = @import("input/keys.zig");
    pub const mouse = @import("input/mouse.zig");
};

pub const Key = input.keys.Key;
pub const KeyEvent = input.keys.KeyEvent;
pub const Modifiers = input.keys.Modifiers;
pub const MouseEvent = input.mouse.MouseEvent;

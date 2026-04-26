//! Keybinding management component.
//! Provides structured key binding definitions with matching and help integration.

const std = @import("std");
const keys = @import("../input/keys.zig");
const Key = keys.Key;
const KeyEvent = keys.KeyEvent;
const Modifiers = keys.Modifiers;
const Help = @import("help.zig").Help;

/// A single key binding with description and enabled state
pub const KeyBinding = struct {
    key_event: KeyEvent,
    description: []const u8,
    short_desc: ?[]const u8 = null,
    enabled: bool = true,

    /// Check if a key event matches this binding
    pub fn matches(self: *const KeyBinding, event: KeyEvent) bool {
        if (!self.enabled) return false;
        return self.key_event.eql(event);
    }

    /// Get a display string for the key
    pub fn keyDisplay(self: *const KeyBinding, allocator: std.mem.Allocator) ![]const u8 {
        var result = std.array_list.Managed(u8).init(allocator);
        const writer = result.writer();

        if (self.key_event.modifiers.ctrl) try writer.writeAll("ctrl+");
        if (self.key_event.modifiers.alt) try writer.writeAll("alt+");
        if (self.key_event.modifiers.shift) try writer.writeAll("shift+");
        if (self.key_event.modifiers.super) try writer.writeAll("super+");

        switch (self.key_event.key) {
            .char => |c| {
                var buf: [4]u8 = undefined;
                const len = std.unicode.utf8Encode(c, &buf) catch 0;
                try writer.writeAll(buf[0..len]);
            },
            else => try writer.writeAll(self.key_event.key.name()),
        }

        return result.toOwnedSlice();
    }
};

/// A collection of key bindings with matching and management
pub const KeyMap = struct {
    bindings: std.array_list.Managed(KeyBinding),

    pub fn init(allocator: std.mem.Allocator) KeyMap {
        return .{
            .bindings = std.array_list.Managed(KeyBinding).init(allocator),
        };
    }

    pub fn deinit(self: *KeyMap) void {
        self.bindings.deinit();
    }

    /// Add a key binding
    pub fn add(self: *KeyMap, binding: KeyBinding) !void {
        try self.bindings.append(binding);
    }

    /// Add a simple character binding
    pub fn addChar(self: *KeyMap, c: u21, description: []const u8) !void {
        try self.bindings.append(.{
            .key_event = KeyEvent.char(c),
            .description = description,
        });
    }

    /// Add a ctrl+character binding
    pub fn addCtrl(self: *KeyMap, c: u21, description: []const u8) !void {
        try self.bindings.append(.{
            .key_event = KeyEvent.ctrl(c),
            .description = description,
        });
    }

    /// Find the first matching binding for an event
    pub fn match(self: *const KeyMap, event: KeyEvent) ?*const KeyBinding {
        for (self.bindings.items) |*binding| {
            if (binding.matches(event)) return binding;
        }
        return null;
    }

    /// Enable or disable a binding by description
    pub fn setEnabled(self: *KeyMap, description: []const u8, enabled: bool) void {
        for (self.bindings.items) |*binding| {
            if (std.mem.eql(u8, binding.description, description)) {
                binding.enabled = enabled;
            }
        }
    }

    /// Convert to Help.Binding format for use with Help component
    pub fn toHelpBindings(self: *const KeyMap, allocator: std.mem.Allocator) ![]Help.Binding {
        var result = std.array_list.Managed(Help.Binding).init(allocator);
        for (self.bindings.items) |*binding| {
            if (!binding.enabled) continue;
            const key_str = try binding.keyDisplay(allocator);
            try result.append(.{
                .key = key_str,
                .description = binding.description,
                .short_desc = binding.short_desc,
            });
        }
        return result.toOwnedSlice();
    }
};

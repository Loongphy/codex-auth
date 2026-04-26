//! Focus management for ZigZag TUI applications.
//! Provides Tab/Shift+Tab cycling between focusable components and
//! focus-aware style helpers for rendering focus indicators.
//!
//! A component is "focusable" if it has:
//!   - a `focused: bool` field
//!   - a `pub fn focus(*Self) void` method
//!   - a `pub fn blur(*Self) void` method
//!
//! TextInput, TextArea, Table, List, Confirm, and FilePicker all satisfy
//! this protocol out of the box.

const std = @import("std");
const keys = @import("../input/keys.zig");
const style_mod = @import("../style/style.zig");
const border_mod = @import("../style/border.zig");
const Color = @import("../style/color.zig").Color;

/// Comptime check: returns true if `T` satisfies the focusable protocol.
pub fn isFocusable(comptime T: type) bool {
    return @hasField(T, "focused") and
        @hasDecl(T, "focus") and
        @hasDecl(T, "blur");
}

/// Maximum number of key bindings per action (next / prev).
const max_binds = 4;

/// A key binding slot: a key plus optional modifiers.
pub const KeyBind = struct {
    key: keys.Key,
    modifiers: keys.Modifiers = .{},

    /// Check if a KeyEvent matches this binding.
    pub fn matches(self: KeyBind, event: keys.KeyEvent) bool {
        return self.key.eql(event.key) and self.modifiers.eql(event.modifiers);
    }
};

/// Default "next" bindings: Tab (no modifiers), Down arrow, 'j'.
pub const default_next_keys = [max_binds]?KeyBind{
    .{ .key = .tab },
    null,
    null,
    null,
};

/// Default "prev" bindings: Shift+Tab, Up arrow, 'k'.
pub const default_prev_keys = [max_binds]?KeyBind{
    .{ .key = .tab, .modifiers = .{ .shift = true } },
    null,
    null,
    null,
};

/// A group of focusable components with customizable key-driven cycling.
///
/// `max_items` is the maximum number of components that can be registered.
/// The group uses a fixed-size array so it requires no allocation and can
/// be embedded directly in a Model struct.
///
/// By default, Tab moves forward and Shift+Tab moves backward.
/// Override `next_keys` / `prev_keys` or call `addNextKey()` / `addPrevKey()`
/// to use any keys you want (arrows, vim j/k, etc.).
///
/// Usage:
/// ```
/// var fg: FocusGroup(3) = .{};
/// fg.add(&self.input_a);
/// fg.add(&self.input_b);
/// fg.add(&self.table);
/// fg.initFocus(); // focus first, blur the rest
///
/// // Optional: add extra navigation keys
/// fg.addNextKey(.{ .key = .down });          // Down arrow
/// fg.addNextKey(.{ .key = .{ .char = 'j' } }); // vim j
/// fg.addPrevKey(.{ .key = .up });            // Up arrow
/// fg.addPrevKey(.{ .key = .{ .char = 'k' } }); // vim k
/// ```
pub fn FocusGroup(comptime max_items: usize) type {
    return struct {
        const Self = @This();

        /// Type-erased handle to a focusable component.
        pub const FocusItem = struct {
            focus_fn: *const fn (*anyopaque) void,
            blur_fn: *const fn (*anyopaque) void,
            is_focused_fn: *const fn (*const anyopaque) bool,
            ptr: *anyopaque,
        };

        items: [max_items]?FocusItem = [_]?FocusItem{null} ** max_items,
        count: usize = 0,
        active: usize = 0,
        /// Whether cycling wraps from last to first (and vice versa).
        wrap: bool = true,
        /// Key bindings that trigger focusNext(). Up to 4 bindings.
        next_keys: [max_binds]?KeyBind = default_next_keys,
        /// Key bindings that trigger focusPrev(). Up to 4 bindings.
        prev_keys: [max_binds]?KeyBind = default_prev_keys,

        /// Register a focusable component.
        ///
        /// The component must satisfy the focusable protocol
        /// (`focused: bool`, `focus()`, `blur()`). A compile error is
        /// emitted if the protocol is not satisfied.
        ///
        /// The pointer must remain valid for the lifetime of the FocusGroup
        /// (which is naturally the case for fields in the same Model struct).
        pub fn add(self: *Self, item_ptr: anytype) void {
            const Ptr = @TypeOf(item_ptr);
            const T = @typeInfo(Ptr).pointer.child;

            comptime {
                if (!@hasField(T, "focused"))
                    @compileError("FocusGroup item must have a 'focused: bool' field. " ++
                        "Type '" ++ @typeName(T) ++ "' does not satisfy the focusable protocol.");
                if (!@hasDecl(T, "focus"))
                    @compileError("FocusGroup item must have a 'pub fn focus(*Self) void' method. " ++
                        "Type '" ++ @typeName(T) ++ "' does not satisfy the focusable protocol.");
                if (!@hasDecl(T, "blur"))
                    @compileError("FocusGroup item must have a 'pub fn blur(*Self) void' method. " ++
                        "Type '" ++ @typeName(T) ++ "' does not satisfy the focusable protocol.");
            }

            if (self.count >= max_items) return;

            self.items[self.count] = .{
                .focus_fn = @ptrCast(&struct {
                    fn call(raw_ptr: *anyopaque) void {
                        const ptr: *T = @ptrCast(@alignCast(raw_ptr));
                        ptr.focus();
                    }
                }.call),
                .blur_fn = @ptrCast(&struct {
                    fn call(raw_ptr: *anyopaque) void {
                        const ptr: *T = @ptrCast(@alignCast(raw_ptr));
                        ptr.blur();
                    }
                }.call),
                .is_focused_fn = @ptrCast(&struct {
                    fn call(raw_ptr: *const anyopaque) bool {
                        const ptr: *const T = @ptrCast(@alignCast(raw_ptr));
                        return ptr.focused;
                    }
                }.call),
                .ptr = @ptrCast(item_ptr),
            };
            self.count += 1;
        }

        /// Focus the item at `index`, blurring all others.
        /// Does nothing if `index` is out of range.
        pub fn focusAt(self: *Self, index: usize) void {
            if (index >= self.count) return;
            for (0..self.count) |i| {
                if (self.items[i]) |item| {
                    if (i == index) {
                        item.focus_fn(item.ptr);
                    } else {
                        item.blur_fn(item.ptr);
                    }
                }
            }
            self.active = index;
        }

        /// Move focus to the next item (Tab behavior).
        pub fn focusNext(self: *Self) void {
            if (self.count == 0) return;
            if (self.active + 1 < self.count) {
                self.focusAt(self.active + 1);
            } else if (self.wrap) {
                self.focusAt(0);
            }
        }

        /// Move focus to the previous item (Shift+Tab behavior).
        pub fn focusPrev(self: *Self) void {
            if (self.count == 0) return;
            if (self.active > 0) {
                self.focusAt(self.active - 1);
            } else if (self.wrap) {
                self.focusAt(self.count - 1);
            }
        }

        /// Handle a key event for focus cycling.
        ///
        /// Checks the event against `next_keys` and `prev_keys`.
        /// Returns `true` if the key was consumed (matched a binding),
        /// `false` if it should be forwarded to the active component.
        pub fn handleKey(self: *Self, key: keys.KeyEvent) bool {
            for (self.next_keys) |maybe_bind| {
                if (maybe_bind) |bind| {
                    if (bind.matches(key)) {
                        self.focusNext();
                        return true;
                    }
                }
            }
            for (self.prev_keys) |maybe_bind| {
                if (maybe_bind) |bind| {
                    if (bind.matches(key)) {
                        self.focusPrev();
                        return true;
                    }
                }
            }
            return false;
        }

        /// Add an extra key binding for "focus next".
        /// Returns false if all 4 slots are full.
        pub fn addNextKey(self: *Self, bind: KeyBind) bool {
            for (&self.next_keys) |*slot| {
                if (slot.* == null) {
                    slot.* = bind;
                    return true;
                }
            }
            return false;
        }

        /// Add an extra key binding for "focus prev".
        /// Returns false if all 4 slots are full.
        pub fn addPrevKey(self: *Self, bind: KeyBind) bool {
            for (&self.prev_keys) |*slot| {
                if (slot.* == null) {
                    slot.* = bind;
                    return true;
                }
            }
            return false;
        }

        /// Replace all "next" bindings with a single key.
        pub fn setNextKey(self: *Self, bind: KeyBind) void {
            self.next_keys = .{ bind, null, null, null };
        }

        /// Replace all "prev" bindings with a single key.
        pub fn setPrevKey(self: *Self, bind: KeyBind) void {
            self.prev_keys = .{ bind, null, null, null };
        }

        /// Clear all "next" key bindings.
        pub fn clearNextKeys(self: *Self) void {
            self.next_keys = .{ null, null, null, null };
        }

        /// Clear all "prev" key bindings.
        pub fn clearPrevKeys(self: *Self) void {
            self.prev_keys = .{ null, null, null, null };
        }

        /// Get the index of the currently focused item.
        pub fn focused(self: *const Self) usize {
            return self.active;
        }

        /// Check if the item at `index` is the currently focused one.
        pub fn isFocused(self: *const Self, index: usize) bool {
            return self.active == index;
        }

        /// Initialize focus: focuses the first item and blurs all others.
        /// Call this after adding all components.
        pub fn initFocus(self: *Self) void {
            if (self.count > 0) {
                self.focusAt(0);
            }
        }

        /// Blur all items (none focused).
        pub fn blurAll(self: *Self) void {
            for (0..self.count) |i| {
                if (self.items[i]) |item| {
                    item.blur_fn(item.ptr);
                }
            }
        }

        /// Returns the total number of registered items.
        pub fn len(self: *const Self) usize {
            return self.count;
        }
    };
}

/// Style helper for rendering focus-aware borders.
///
/// Apply to a base `Style` in your `view()` function to get a border
/// that changes color depending on focus state.
///
/// ```
/// const fs = FocusStyle{};
/// var style = zz.Style{};
/// style = style.paddingAll(1);
/// style = fs.apply(style, is_focused);
/// const rendered = style.render(allocator, content);
/// ```
pub const FocusStyle = struct {
    /// Border color when focused (default: cyan).
    focused_border_fg: Color = Color.cyan(),
    /// Border color when not focused (default: dark gray).
    blurred_border_fg: Color = Color.gray(12),
    /// Border character set (default: rounded).
    border_chars: border_mod.BorderChars = border_mod.Border.rounded,

    /// Apply focus-aware border styling to `base`.
    /// Returns a new Style with the appropriate border and color.
    pub fn apply(self: FocusStyle, base: style_mod.Style, is_focused: bool) style_mod.Style {
        var s = base;
        s = s.borderAll(self.border_chars);
        if (is_focused) {
            s = s.borderForeground(self.focused_border_fg);
        } else {
            s = s.borderForeground(self.blurred_border_fg);
        }
        return s;
    }
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "isFocusable positive" {
    const Focusable = struct {
        focused: bool = false,
        pub fn focus(self: *@This()) void {
            self.focused = true;
        }
        pub fn blur(self: *@This()) void {
            self.focused = false;
        }
    };
    try std.testing.expect(isFocusable(Focusable));
}

test "isFocusable negative — missing field" {
    const NotFocusable = struct {
        pub fn focus(_: *@This()) void {}
        pub fn blur(_: *@This()) void {}
    };
    try std.testing.expect(!isFocusable(NotFocusable));
}

test "isFocusable negative — missing method" {
    const NotFocusable = struct {
        focused: bool = false,
        pub fn focus(_: *@This()) void {}
    };
    try std.testing.expect(!isFocusable(NotFocusable));
}

test "FocusGroup — basic cycling" {
    const Item = struct {
        focused: bool = false,
        pub fn focus(self: *@This()) void {
            self.focused = true;
        }
        pub fn blur(self: *@This()) void {
            self.focused = false;
        }
    };

    var a = Item{};
    var b = Item{};
    var c = Item{};

    var fg: FocusGroup(3) = .{};
    fg.add(&a);
    fg.add(&b);
    fg.add(&c);
    fg.initFocus();

    // After init: first item focused
    try std.testing.expect(a.focused);
    try std.testing.expect(!b.focused);
    try std.testing.expect(!c.focused);
    try std.testing.expectEqual(@as(usize, 0), fg.focused());

    // focusNext
    fg.focusNext();
    try std.testing.expect(!a.focused);
    try std.testing.expect(b.focused);
    try std.testing.expect(!c.focused);
    try std.testing.expectEqual(@as(usize, 1), fg.focused());

    // focusNext again
    fg.focusNext();
    try std.testing.expectEqual(@as(usize, 2), fg.focused());
    try std.testing.expect(c.focused);

    // focusNext wraps
    fg.focusNext();
    try std.testing.expectEqual(@as(usize, 0), fg.focused());
    try std.testing.expect(a.focused);
    try std.testing.expect(!c.focused);
}

test "FocusGroup — prev cycling" {
    const Item = struct {
        focused: bool = false,
        pub fn focus(self: *@This()) void {
            self.focused = true;
        }
        pub fn blur(self: *@This()) void {
            self.focused = false;
        }
    };

    var a = Item{};
    var b = Item{};

    var fg: FocusGroup(2) = .{};
    fg.add(&a);
    fg.add(&b);
    fg.initFocus();

    // focusPrev wraps from 0 to last
    fg.focusPrev();
    try std.testing.expectEqual(@as(usize, 1), fg.focused());
    try std.testing.expect(b.focused);
    try std.testing.expect(!a.focused);

    // focusPrev goes back
    fg.focusPrev();
    try std.testing.expectEqual(@as(usize, 0), fg.focused());
    try std.testing.expect(a.focused);
}

test "FocusGroup — no wrap" {
    const Item = struct {
        focused: bool = false,
        pub fn focus(self: *@This()) void {
            self.focused = true;
        }
        pub fn blur(self: *@This()) void {
            self.focused = false;
        }
    };

    var a = Item{};
    var b = Item{};

    var fg: FocusGroup(2) = .{ .wrap = false };
    fg.add(&a);
    fg.add(&b);
    fg.initFocus();

    // At first item, prev should NOT wrap
    fg.focusPrev();
    try std.testing.expectEqual(@as(usize, 0), fg.focused());

    // At last item, next should NOT wrap
    fg.focusAt(1);
    fg.focusNext();
    try std.testing.expectEqual(@as(usize, 1), fg.focused());
}

test "FocusGroup — handleKey Tab" {
    const Item = struct {
        focused: bool = false,
        pub fn focus(self: *@This()) void {
            self.focused = true;
        }
        pub fn blur(self: *@This()) void {
            self.focused = false;
        }
    };

    var a = Item{};
    var b = Item{};

    var fg: FocusGroup(2) = .{};
    fg.add(&a);
    fg.add(&b);
    fg.initFocus();

    // Tab moves forward
    const tab_event = keys.KeyEvent{ .key = .tab, .modifiers = .{} };
    const consumed = fg.handleKey(tab_event);
    try std.testing.expect(consumed);
    try std.testing.expectEqual(@as(usize, 1), fg.focused());

    // Shift+Tab moves backward
    const shift_tab = keys.KeyEvent{ .key = .tab, .modifiers = .{ .shift = true } };
    const consumed2 = fg.handleKey(shift_tab);
    try std.testing.expect(consumed2);
    try std.testing.expectEqual(@as(usize, 0), fg.focused());

    // Other keys not consumed
    const other = keys.KeyEvent{ .key = .{ .char = 'a' }, .modifiers = .{} };
    const consumed3 = fg.handleKey(other);
    try std.testing.expect(!consumed3);
}

test "FocusGroup — focusAt and isFocused" {
    const Item = struct {
        focused: bool = false,
        pub fn focus(self: *@This()) void {
            self.focused = true;
        }
        pub fn blur(self: *@This()) void {
            self.focused = false;
        }
    };

    var a = Item{};
    var b = Item{};
    var c = Item{};

    var fg: FocusGroup(3) = .{};
    fg.add(&a);
    fg.add(&b);
    fg.add(&c);

    fg.focusAt(2);
    try std.testing.expect(!fg.isFocused(0));
    try std.testing.expect(!fg.isFocused(1));
    try std.testing.expect(fg.isFocused(2));
    try std.testing.expect(!a.focused);
    try std.testing.expect(!b.focused);
    try std.testing.expect(c.focused);
}

test "FocusGroup — blurAll" {
    const Item = struct {
        focused: bool = false,
        pub fn focus(self: *@This()) void {
            self.focused = true;
        }
        pub fn blur(self: *@This()) void {
            self.focused = false;
        }
    };

    var a = Item{};
    var b = Item{};

    var fg: FocusGroup(2) = .{};
    fg.add(&a);
    fg.add(&b);
    fg.initFocus();
    try std.testing.expect(a.focused);

    fg.blurAll();
    try std.testing.expect(!a.focused);
    try std.testing.expect(!b.focused);
}

//! Tab group and multi-view routing component.
//! Provides tab-strip rendering, key-driven navigation, and optional
//! type-erased view routing for multi-screen applications.

const std = @import("std");
const keys = @import("../input/keys.zig");
const measure = @import("../layout/measure.zig");
const style_mod = @import("../style/style.zig");
const Color = @import("../style/color.zig").Color;

/// Maximum number of key bindings tracked per action.
const max_binds = 8;

/// A single key binding (key + optional modifiers).
pub const KeyBind = struct {
    key: keys.Key,
    modifiers: keys.Modifiers = .{},

    pub fn matches(self: KeyBind, event: keys.KeyEvent) bool {
        return self.key.eql(event.key) and self.modifiers.eql(event.modifiers);
    }
};

/// Default next-tab bindings: Right, Tab.
pub const default_next_keys = [max_binds]?KeyBind{
    .{ .key = .right },
    .{ .key = .tab },
    null,
    null,
    null,
    null,
    null,
    null,
};

/// Default previous-tab bindings: Left, Shift+Tab.
pub const default_prev_keys = [max_binds]?KeyBind{
    .{ .key = .left },
    .{ .key = .tab, .modifiers = .{ .shift = true } },
    null,
    null,
    null,
    null,
    null,
    null,
};

/// Default "first tab" bindings: Home.
pub const default_first_keys = [max_binds]?KeyBind{
    .{ .key = .home },
    null,
    null,
    null,
    null,
    null,
    null,
    null,
};

/// Default "last tab" bindings: End.
pub const default_last_keys = [max_binds]?KeyBind{
    .{ .key = .end },
    null,
    null,
    null,
    null,
    null,
    null,
    null,
};

/// Default activation bindings (manual activation mode): Enter, Space.
pub const default_activate_keys = [max_binds]?KeyBind{
    .{ .key = .enter },
    .{ .key = .space },
    null,
    null,
    null,
    null,
    null,
    null,
};

/// Why active tab changed.
pub const ChangeReason = enum {
    init,
    set_active,
    next,
    prev,
    first,
    last,
    number_shortcut,
    activate,
    remove,
    disable,
    hide,
    clear,
};

pub const Change = struct {
    previous: ?usize,
    current: ?usize,
    reason: ChangeReason,
};

/// Result of handling a key event.
pub const KeyResult = struct {
    consumed: bool = false,
    change: ?Change = null,
    routed: bool = false,
};

/// Tab label rendering context.
pub const LabelState = struct {
    index: usize,
    active: bool,
    focused: bool,
    enabled: bool,
    visible: bool,
};

pub const OverflowMode = enum {
    /// Render all tabs (no clipping).
    none,
    /// Render all tabs then truncate final output.
    clip,
    /// Keep active/focused tab visible and show scroll markers.
    scroll,
};

pub const LabelRenderer = *const fn (ctx: *anyopaque, allocator: std.mem.Allocator, tab: Tab, state: LabelState) anyerror![]const u8;
pub const RouteRenderer = *const fn (ctx: *anyopaque, allocator: std.mem.Allocator) anyerror![]const u8;
pub const RouteKeyHandler = *const fn (ctx: *anyopaque, event: keys.KeyEvent) bool;
pub const RouteHook = *const fn (ctx: *anyopaque) void;

/// Optional route callbacks attached to a tab.
pub const Route = struct {
    ctx: *anyopaque,
    render_fn: RouteRenderer,
    key_fn: ?RouteKeyHandler = null,
    on_enter_fn: ?RouteHook = null,
    on_leave_fn: ?RouteHook = null,
};

pub const Tab = struct {
    id: []const u8,
    title: []const u8,
    short_title: ?[]const u8 = null,
    enabled: bool = true,
    visible: bool = true,
    closable: bool = false,
    route: ?Route = null,
    user_data: ?*anyopaque = null,
};

/// Tab strip + multi-view routing container.
pub const TabGroup = struct {
    allocator: std.mem.Allocator,
    tabs: std.array_list.Managed(Tab),

    active_index: ?usize,
    focus_index: ?usize,

    // Focus protocol compatibility
    focused: bool = true,

    // Navigation behavior
    wrap: bool = true,
    activate_on_focus: bool = true,
    number_shortcuts: bool = true,
    focus_disabled_tabs: bool = false,

    // Key maps
    next_keys: [max_binds]?KeyBind = default_next_keys,
    prev_keys: [max_binds]?KeyBind = default_prev_keys,
    first_keys: [max_binds]?KeyBind = default_first_keys,
    last_keys: [max_binds]?KeyBind = default_last_keys,
    activate_keys: [max_binds]?KeyBind = default_activate_keys,

    // Rendering options
    bar_style: style_mod.Style,
    tab_style: style_mod.Style,
    active_tab_style: style_mod.Style,
    focused_tab_style: style_mod.Style,
    disabled_tab_style: style_mod.Style,
    separator_style: style_mod.Style,
    overflow_style: style_mod.Style,

    separator: []const u8 = " ",
    tab_prefix: []const u8 = " ",
    tab_suffix: []const u8 = " ",
    show_numbers: bool = false,
    number_separator: []const u8 = ":",

    max_width: ?usize = null,
    overflow_mode: OverflowMode = .scroll,
    overflow_left: []const u8 = "… ",
    overflow_right: []const u8 = " …",

    label_renderer: ?LabelRenderer = null,
    label_renderer_ctx: ?*anyopaque = null,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) Self {
        var tab_style = style_mod.Style{};
        tab_style = tab_style.fg(Color.gray(15));
        tab_style = tab_style.inline_style(true);

        var active_style = style_mod.Style{};
        active_style = active_style.fg(Color.cyan());
        active_style = active_style.bold(true);
        active_style = active_style.inline_style(true);

        var focused_style = style_mod.Style{};
        focused_style = focused_style.fg(Color.yellow());
        focused_style = focused_style.bold(true);
        focused_style = focused_style.inline_style(true);

        var disabled_style = style_mod.Style{};
        disabled_style = disabled_style.fg(Color.gray(9));
        disabled_style = disabled_style.dim(true);
        disabled_style = disabled_style.inline_style(true);

        var sep_style = style_mod.Style{};
        sep_style = sep_style.fg(Color.gray(11));
        sep_style = sep_style.inline_style(true);

        var overflow_style = style_mod.Style{};
        overflow_style = overflow_style.fg(Color.gray(12));
        overflow_style = overflow_style.inline_style(true);

        return .{
            .allocator = allocator,
            .tabs = std.array_list.Managed(Tab).init(allocator),
            .active_index = null,
            .focus_index = null,
            .bar_style = blk: {
                var s = style_mod.Style{};
                s = s.inline_style(true);
                break :blk s;
            },
            .tab_style = tab_style,
            .active_tab_style = active_style,
            .focused_tab_style = focused_style,
            .disabled_tab_style = disabled_style,
            .separator_style = sep_style,
            .overflow_style = overflow_style,
        };
    }

    pub fn deinit(self: *Self) void {
        self.tabs.deinit();
    }

    pub fn focus(self: *Self) void {
        self.focused = true;
    }

    pub fn blur(self: *Self) void {
        self.focused = false;
    }

    pub fn len(self: *const Self) usize {
        return self.tabs.items.len;
    }

    pub fn hasTabs(self: *const Self) bool {
        return self.tabs.items.len > 0;
    }

    pub fn clear(self: *Self) ?Change {
        const prev = self.active_index;
        self.leaveActiveRoute();
        self.tabs.clearRetainingCapacity();
        self.active_index = null;
        self.focus_index = null;
        if (prev == null) return null;
        return .{
            .previous = prev,
            .current = null,
            .reason = .clear,
        };
    }

    pub fn addTab(self: *Self, tab: Tab) !usize {
        try self.tabs.append(tab);
        const idx = self.tabs.items.len - 1;

        if (self.focus_index == null) self.focus_index = idx;

        if (self.active_index == null and self.isActivatableIndex(idx)) {
            _ = self.setActive(idx, .init);
        }

        return idx;
    }

    pub fn insertTab(self: *Self, index: usize, tab: Tab) !void {
        const idx = @min(index, self.tabs.items.len);
        try self.tabs.insert(idx, tab);

        if (self.active_index) |active| {
            if (active >= idx) self.active_index = active + 1;
        }
        if (self.focus_index) |focus_idx| {
            if (focus_idx >= idx) self.focus_index = focus_idx + 1;
        }

        if (self.focus_index == null) self.focus_index = idx;
        if (self.active_index == null and self.isActivatableIndex(idx)) {
            _ = self.setActive(idx, .init);
        }
    }

    pub fn removeTabAt(self: *Self, index: usize) ?Change {
        if (index >= self.tabs.items.len) return null;

        const prev_active = self.active_index;
        const removed_was_active = prev_active != null and prev_active.? == index;

        if (removed_was_active) {
            self.leaveActiveRoute();
            self.active_index = null;
        }

        _ = self.tabs.orderedRemove(index);

        if (self.tabs.items.len == 0) {
            self.active_index = null;
            self.focus_index = null;
            if (prev_active == null) return null;
            return .{
                .previous = prev_active,
                .current = null,
                .reason = .remove,
            };
        }

        if (self.active_index) |active_idx| {
            if (active_idx > index) self.active_index = active_idx - 1;
        }
        if (self.focus_index) |focus_idx| {
            if (focus_idx > index) {
                self.focus_index = focus_idx - 1;
            } else if (focus_idx == index) {
                self.focus_index = self.pickFallbackFocusIndex(index);
            }
        } else {
            self.focus_index = self.firstVisibleIndex() orelse self.firstIndex();
        }

        if (removed_was_active) {
            const fallback = self.pickFallbackActiveIndex(index) orelse self.firstActivatableIndex();
            if (fallback) |new_active| {
                return self.setActive(new_active, .remove);
            }
            self.active_index = null;
            return .{
                .previous = prev_active,
                .current = null,
                .reason = .remove,
            };
        }

        self.ensureValidSelection();
        return null;
    }

    pub fn removeTabById(self: *Self, id: []const u8) ?Change {
        const idx = self.indexOf(id) orelse return null;
        return self.removeTabAt(idx);
    }

    pub fn indexOf(self: *const Self, id: []const u8) ?usize {
        for (self.tabs.items, 0..) |tab, i| {
            if (std.mem.eql(u8, tab.id, id)) return i;
        }
        return null;
    }

    pub fn getTab(self: *Self, index: usize) ?*Tab {
        if (index >= self.tabs.items.len) return null;
        return &self.tabs.items[index];
    }

    pub fn getTabConst(self: *const Self, index: usize) ?*const Tab {
        if (index >= self.tabs.items.len) return null;
        return &self.tabs.items[index];
    }

    pub fn activeIndex(self: *const Self) ?usize {
        return self.active_index;
    }

    pub fn focusedIndex(self: *const Self) ?usize {
        return self.focus_index;
    }

    pub fn activeTab(self: *const Self) ?*const Tab {
        const idx = self.active_index orelse return null;
        return &self.tabs.items[idx];
    }

    pub fn activeRoute(self: *const Self) ?Route {
        const idx = self.active_index orelse return null;
        return self.tabs.items[idx].route;
    }

    pub fn isActive(self: *const Self, index: usize) bool {
        return self.active_index != null and self.active_index.? == index;
    }

    pub fn isFocused(self: *const Self, index: usize) bool {
        return self.focus_index != null and self.focus_index.? == index;
    }

    pub fn setLabelRenderer(self: *Self, ctx: *anyopaque, renderer: LabelRenderer) void {
        self.label_renderer_ctx = ctx;
        self.label_renderer = renderer;
    }

    pub fn clearLabelRenderer(self: *Self) void {
        self.label_renderer_ctx = null;
        self.label_renderer = null;
    }

    pub fn setRoute(self: *Self, index: usize, route: ?Route) void {
        if (index >= self.tabs.items.len) return;
        self.tabs.items[index].route = route;
    }

    pub fn setEnabled(self: *Self, index: usize, enabled: bool) ?Change {
        if (index >= self.tabs.items.len) return null;
        self.tabs.items[index].enabled = enabled;
        if (enabled) {
            if (self.active_index == null and self.isActivatableIndex(index)) {
                return self.setActive(index, .set_active);
            }
            return null;
        }

        const was_active = self.active_index != null and self.active_index.? == index;
        if (!was_active) return null;

        const next_idx = self.pickFallbackActiveIndex(index) orelse self.firstActivatableIndex();
        if (next_idx) |i| {
            return self.setActive(i, .disable);
        }

        const prev = self.active_index;
        self.leaveActiveRoute();
        self.active_index = null;
        return .{
            .previous = prev,
            .current = null,
            .reason = .disable,
        };
    }

    pub fn setVisible(self: *Self, index: usize, visible: bool) ?Change {
        if (index >= self.tabs.items.len) return null;
        self.tabs.items[index].visible = visible;

        if (!visible) {
            const was_active = self.active_index != null and self.active_index.? == index;
            if (was_active) {
                const fallback = self.pickFallbackActiveIndex(index) orelse self.firstActivatableIndex();
                if (fallback) |i| {
                    return self.setActive(i, .hide);
                }
                const prev = self.active_index;
                self.leaveActiveRoute();
                self.active_index = null;
                return .{
                    .previous = prev,
                    .current = null,
                    .reason = .hide,
                };
            }

            if (self.focus_index != null and self.focus_index.? == index) {
                self.focus_index = self.pickFallbackFocusIndex(index) orelse self.firstVisibleIndex();
            }
        } else if (self.focus_index == null) {
            self.focus_index = index;
        }

        self.ensureValidSelection();
        return null;
    }

    pub fn setActive(self: *Self, index: usize, reason: ChangeReason) ?Change {
        if (!self.isActivatableIndex(index)) return null;

        const prev = self.active_index;
        if (prev != null and prev.? == index) {
            self.focus_index = index;
            return null;
        }

        self.leaveRoute(prev);
        self.active_index = index;
        self.focus_index = index;
        self.enterRoute(index);

        return .{
            .previous = prev,
            .current = index,
            .reason = reason,
        };
    }

    pub fn setActiveById(self: *Self, id: []const u8, reason: ChangeReason) ?Change {
        const idx = self.indexOf(id) orelse return null;
        return self.setActive(idx, reason);
    }

    pub fn focusTab(self: *Self, index: usize) bool {
        if (index >= self.tabs.items.len) return false;
        if (!self.tabs.items[index].visible) return false;
        if (!self.focus_disabled_tabs and !self.tabs.items[index].enabled) return false;
        self.focus_index = index;
        return true;
    }

    pub fn focusFirst(self: *Self) bool {
        const idx = self.firstFocusableIndex() orelse return false;
        self.focus_index = idx;
        if (self.activate_on_focus) _ = self.setActive(idx, .first);
        return true;
    }

    pub fn focusLast(self: *Self) bool {
        const idx = self.lastFocusableIndex() orelse return false;
        self.focus_index = idx;
        if (self.activate_on_focus) _ = self.setActive(idx, .last);
        return true;
    }

    pub fn focusNext(self: *Self) bool {
        const start = self.focus_index orelse self.active_index orelse return self.focusFirst();
        const idx = self.findNextFocusable(start) orelse return false;
        self.focus_index = idx;
        if (self.activate_on_focus) _ = self.setActive(idx, .next);
        return true;
    }

    pub fn focusPrev(self: *Self) bool {
        const start = self.focus_index orelse self.active_index orelse return self.focusLast();
        const idx = self.findPrevFocusable(start) orelse return false;
        self.focus_index = idx;
        if (self.activate_on_focus) _ = self.setActive(idx, .prev);
        return true;
    }

    pub fn activateFocused(self: *Self) ?Change {
        const idx = self.focus_index orelse return null;
        return self.setActive(idx, .activate);
    }

    pub fn handleKey(self: *Self, event: keys.KeyEvent) KeyResult {
        if (!self.focused) return .{};

        if (self.matchAny(event, self.next_keys)) {
            const prev = self.active_index;
            if (self.focusNext()) {
                return .{
                    .consumed = true,
                    .change = self.diffChange(prev, .next),
                };
            }
            return .{ .consumed = true };
        }
        if (self.matchAny(event, self.prev_keys)) {
            const prev = self.active_index;
            if (self.focusPrev()) {
                return .{
                    .consumed = true,
                    .change = self.diffChange(prev, .prev),
                };
            }
            return .{ .consumed = true };
        }
        if (self.matchAny(event, self.first_keys)) {
            const prev = self.active_index;
            if (self.focusFirst()) {
                return .{
                    .consumed = true,
                    .change = self.diffChange(prev, .first),
                };
            }
            return .{ .consumed = true };
        }
        if (self.matchAny(event, self.last_keys)) {
            const prev = self.active_index;
            if (self.focusLast()) {
                return .{
                    .consumed = true,
                    .change = self.diffChange(prev, .last),
                };
            }
            return .{ .consumed = true };
        }

        if (!self.activate_on_focus and self.matchAny(event, self.activate_keys)) {
            return .{
                .consumed = true,
                .change = self.activateFocused(),
            };
        }

        if (self.number_shortcuts and !event.modifiers.any()) {
            if (event.key == .char) {
                const c = event.key.char;
                if (c >= '1' and c <= '9') {
                    const ordinal: usize = @intCast(c - '1');
                    if (self.setActiveByVisibleOrdinal(ordinal)) |chg| {
                        return .{
                            .consumed = true,
                            .change = chg,
                        };
                    }
                    return .{ .consumed = true };
                }
            }
        }

        return .{};
    }

    /// Handle tab navigation keys; if not consumed, forward key to active route.
    pub fn handleKeyAndRoute(self: *Self, event: keys.KeyEvent) KeyResult {
        var res = self.handleKey(event);
        if (!res.consumed) {
            res.routed = self.routeKey(event);
            res.consumed = res.routed;
        }
        return res;
    }

    /// Route a key event to active tab route (if it has a key handler).
    pub fn routeKey(self: *Self, event: keys.KeyEvent) bool {
        const idx = self.active_index orelse return false;
        const route = self.tabs.items[idx].route orelse return false;
        const key_fn = route.key_fn orelse return false;
        return key_fn(route.ctx, event);
    }

    /// Render only the tab strip.
    pub fn view(self: *const Self, allocator: std.mem.Allocator) ![]const u8 {
        return self.renderStrip(allocator);
    }

    /// Render only the active route content (if any).
    pub fn viewActiveContent(self: *const Self, allocator: std.mem.Allocator) !?[]const u8 {
        const idx = self.active_index orelse return null;
        const route = self.tabs.items[idx].route orelse return null;
        return try route.render_fn(route.ctx, allocator);
    }

    /// Render `tabs + content`, with optional fallback content when route is missing.
    pub fn viewWithContent(self: *const Self, allocator: std.mem.Allocator, fallback_content: ?[]const u8) ![]const u8 {
        const tabs = try self.renderStrip(allocator);
        const content = (try self.viewActiveContent(allocator)) orelse fallback_content orelse "";

        if (content.len == 0) return tabs;
        return std.fmt.allocPrint(allocator, "{s}\n{s}", .{ tabs, content });
    }

    fn renderStrip(self: *const Self, allocator: std.mem.Allocator) ![]const u8 {
        var pieces = std.array_list.Managed([]const u8).init(allocator);
        defer pieces.deinit();

        var visible_indices = std.array_list.Managed(usize).init(allocator);
        defer visible_indices.deinit();

        for (self.tabs.items, 0..) |tab, i| {
            if (tab.visible) try visible_indices.append(i);
        }

        if (visible_indices.items.len == 0) return allocator.dupe(u8, "");

        for (visible_indices.items) |tab_idx| {
            const piece = try self.renderTabLabel(allocator, tab_idx);
            try pieces.append(piece);
        }

        const sep = try self.separator_style.render(allocator, self.separator);

        const strip = switch (self.overflow_mode) {
            .none => try joinPieces(allocator, pieces.items, sep),
            .clip => blk: {
                const raw = try joinPieces(allocator, pieces.items, sep);
                if (self.max_width) |w| {
                    break :blk try measure.truncate(allocator, raw, w);
                }
                break :blk raw;
            },
            .scroll => try self.renderScrolledStrip(allocator, pieces.items, visible_indices.items, sep),
        };

        return self.bar_style.render(allocator, strip);
    }

    fn renderScrolledStrip(self: *const Self, allocator: std.mem.Allocator, pieces: []const []const u8, visible_indices: []const usize, sep: []const u8) ![]const u8 {
        const max_w = self.max_width orelse return joinPieces(allocator, pieces, sep);

        const total_w = joinedWidth(pieces, sep);
        if (total_w <= max_w) return joinPieces(allocator, pieces, sep);

        const left_marker = try self.overflow_style.render(allocator, self.overflow_left);
        const right_marker = try self.overflow_style.render(allocator, self.overflow_right);
        const left_w = measure.width(left_marker);
        const right_w = measure.width(right_marker);

        const target_tab_idx = self.focus_index orelse self.active_index orelse visible_indices[0];
        var target_pos: usize = 0;
        for (visible_indices, 0..) |idx, i| {
            if (idx == target_tab_idx) {
                target_pos = i;
                break;
            }
        }

        var start = target_pos;
        var end = target_pos + 1;

        while (true) {
            var grew = false;

            if (start > 0) {
                const cand_start = start - 1;
                const width = rangeWidthWithMarkers(pieces, sep, cand_start, end, left_w, right_w, cand_start > 0, end < pieces.len);
                if (width <= max_w) {
                    start = cand_start;
                    grew = true;
                }
            }

            if (end < pieces.len) {
                const cand_end = end + 1;
                const width = rangeWidthWithMarkers(pieces, sep, start, cand_end, left_w, right_w, start > 0, cand_end < pieces.len);
                if (width <= max_w) {
                    end = cand_end;
                    grew = true;
                }
            }

            if (!grew) break;
        }

        var truncated_single: ?[]const u8 = null;

        // Degenerate case: marker + single tab still wider than max.
        const single_range_w = rangeWidthWithMarkers(pieces, sep, start, end, left_w, right_w, start > 0, end < pieces.len);
        if (single_range_w > max_w and end == start + 1) {
            const reserved = (if (start > 0) left_w else 0) + (if (end < pieces.len) right_w else 0);
            if (reserved < max_w) {
                const allow = max_w - reserved;
                truncated_single = try measure.truncate(allocator, pieces[start], allow);
            }
        }

        var out = std.array_list.Managed(u8).init(allocator);
        const writer = out.writer();

        if (start > 0) try writer.writeAll(left_marker);
        for (start..end) |i| {
            if (i > start) try writer.writeAll(sep);
            if (truncated_single != null and i == start) {
                try writer.writeAll(truncated_single.?);
            } else {
                try writer.writeAll(pieces[i]);
            }
        }
        if (end < pieces.len) try writer.writeAll(right_marker);

        return out.toOwnedSlice();
    }

    fn renderTabLabel(self: *const Self, allocator: std.mem.Allocator, tab_index: usize) ![]const u8 {
        const tab = self.tabs.items[tab_index];
        const state = LabelState{
            .index = tab_index,
            .active = self.isActive(tab_index),
            .focused = self.isFocused(tab_index),
            .enabled = tab.enabled,
            .visible = tab.visible,
        };

        if (self.label_renderer) |renderer| {
            const ctx = self.label_renderer_ctx orelse return error.MissingLabelRendererContext;
            return renderer(ctx, allocator, tab, state);
        }

        var base = std.array_list.Managed(u8).init(allocator);
        const writer = base.writer();

        try writer.writeAll(self.tab_prefix);
        if (self.show_numbers) {
            const number = try std.fmt.allocPrint(allocator, "{d}{s}", .{ self.visibleOrdinal(tab_index) + 1, self.number_separator });
            try writer.writeAll(number);
        }
        try writer.writeAll(tab.title);
        try writer.writeAll(self.tab_suffix);

        const raw = try base.toOwnedSlice();

        if (!tab.enabled) return self.disabled_tab_style.render(allocator, raw);
        if (state.active) return self.active_tab_style.render(allocator, raw);
        if (!self.activate_on_focus and state.focused) return self.focused_tab_style.render(allocator, raw);
        return self.tab_style.render(allocator, raw);
    }

    fn setActiveByVisibleOrdinal(self: *Self, ordinal: usize) ?Change {
        var seen: usize = 0;
        for (self.tabs.items, 0..) |tab, i| {
            if (!tab.visible or !tab.enabled) continue;
            if (seen == ordinal) {
                return self.setActive(i, .number_shortcut);
            }
            seen += 1;
        }
        return null;
    }

    fn visibleOrdinal(self: *const Self, index: usize) usize {
        var ordinal: usize = 0;
        for (self.tabs.items, 0..) |tab, i| {
            if (!tab.visible) continue;
            if (i == index) return ordinal;
            ordinal += 1;
        }
        return ordinal;
    }

    fn ensureValidSelection(self: *Self) void {
        if (self.tabs.items.len == 0) {
            self.active_index = null;
            self.focus_index = null;
            return;
        }

        if (self.active_index) |idx| {
            if (!self.isActivatableIndex(idx)) {
                const fallback = self.pickFallbackActiveIndex(idx) orelse self.firstActivatableIndex();
                if (fallback) |new_idx| {
                    _ = self.setActive(new_idx, .set_active);
                } else {
                    self.active_index = null;
                }
            }
        } else if (self.firstActivatableIndex()) |idx| {
            _ = self.setActive(idx, .init);
        }

        if (self.focus_index) |idx| {
            if (!self.isFocusableIndex(idx)) {
                self.focus_index = self.firstFocusableIndex() orelse self.firstVisibleIndex() orelse self.firstIndex();
            }
        } else {
            self.focus_index = self.firstFocusableIndex() orelse self.firstVisibleIndex() orelse self.firstIndex();
        }
    }

    fn firstIndex(self: *const Self) ?usize {
        if (self.tabs.items.len == 0) return null;
        return 0;
    }

    fn firstVisibleIndex(self: *const Self) ?usize {
        for (self.tabs.items, 0..) |tab, i| {
            if (tab.visible) return i;
        }
        return null;
    }

    fn firstActivatableIndex(self: *const Self) ?usize {
        for (self.tabs.items, 0..) |tab, i| {
            if (tab.visible and tab.enabled) return i;
        }
        return null;
    }

    fn firstFocusableIndex(self: *const Self) ?usize {
        for (self.tabs.items, 0..) |tab, i| {
            if (!tab.visible) continue;
            if (!self.focus_disabled_tabs and !tab.enabled) continue;
            return i;
        }
        return null;
    }

    fn lastFocusableIndex(self: *const Self) ?usize {
        if (self.tabs.items.len == 0) return null;
        var i = self.tabs.items.len;
        while (i > 0) {
            i -= 1;
            const tab = self.tabs.items[i];
            if (!tab.visible) continue;
            if (!self.focus_disabled_tabs and !tab.enabled) continue;
            return i;
        }
        return null;
    }

    fn isActivatableIndex(self: *const Self, index: usize) bool {
        if (index >= self.tabs.items.len) return false;
        const tab = self.tabs.items[index];
        return tab.visible and tab.enabled;
    }

    fn isFocusableIndex(self: *const Self, index: usize) bool {
        if (index >= self.tabs.items.len) return false;
        const tab = self.tabs.items[index];
        if (!tab.visible) return false;
        if (!self.focus_disabled_tabs and !tab.enabled) return false;
        return true;
    }

    fn pickFallbackActiveIndex(self: *const Self, removed_index: usize) ?usize {
        if (self.tabs.items.len == 0) return null;

        var i = removed_index;
        while (i < self.tabs.items.len) : (i += 1) {
            if (self.isActivatableIndex(i)) return i;
        }

        i = removed_index;
        while (i > 0) {
            i -= 1;
            if (self.isActivatableIndex(i)) return i;
        }

        return null;
    }

    fn pickFallbackFocusIndex(self: *const Self, removed_index: usize) ?usize {
        if (self.tabs.items.len == 0) return null;

        var i = removed_index;
        while (i < self.tabs.items.len) : (i += 1) {
            if (self.isFocusableIndex(i)) return i;
        }

        i = removed_index;
        while (i > 0) {
            i -= 1;
            if (self.isFocusableIndex(i)) return i;
        }

        return self.firstVisibleIndex();
    }

    fn findNextFocusable(self: *const Self, start: usize) ?usize {
        if (self.tabs.items.len == 0) return null;

        var i = start + 1;
        while (i < self.tabs.items.len) : (i += 1) {
            if (self.isFocusableIndex(i)) return i;
        }

        if (!self.wrap) return null;

        i = 0;
        while (i <= start and i < self.tabs.items.len) : (i += 1) {
            if (self.isFocusableIndex(i)) return i;
        }

        return null;
    }

    fn findPrevFocusable(self: *const Self, start: usize) ?usize {
        if (self.tabs.items.len == 0) return null;
        if (start > self.tabs.items.len - 1) return self.lastFocusableIndex();

        var i = start;
        while (i > 0) {
            i -= 1;
            if (self.isFocusableIndex(i)) return i;
        }

        if (!self.wrap) return null;

        i = self.tabs.items.len;
        while (i > start + 1) {
            i -= 1;
            if (self.isFocusableIndex(i)) return i;
        }

        return null;
    }

    fn diffChange(self: *Self, previous_active: ?usize, reason: ChangeReason) ?Change {
        if (previous_active == self.active_index) return null;
        return .{
            .previous = previous_active,
            .current = self.active_index,
            .reason = reason,
        };
    }

    fn matchAny(_: *Self, event: keys.KeyEvent, binds: [max_binds]?KeyBind) bool {
        for (binds) |maybe_bind| {
            if (maybe_bind) |bind| {
                if (bind.matches(event)) return true;
            }
        }
        return false;
    }

    fn leaveActiveRoute(self: *const Self) void {
        self.leaveRoute(self.active_index);
    }

    fn leaveRoute(self: *const Self, idx: ?usize) void {
        if (idx) |i| {
            if (i < self.tabs.items.len) {
                if (self.tabs.items[i].route) |route| {
                    if (route.on_leave_fn) |f| f(route.ctx);
                }
            }
        }
    }

    fn enterRoute(self: *const Self, idx: usize) void {
        if (idx >= self.tabs.items.len) return;
        if (self.tabs.items[idx].route) |route| {
            if (route.on_enter_fn) |f| f(route.ctx);
        }
    }
};

fn joinedWidth(parts: []const []const u8, separator: []const u8) usize {
    if (parts.len == 0) return 0;

    const sep_w = measure.width(separator);
    var w: usize = 0;
    for (parts, 0..) |part, i| {
        if (i > 0) w += sep_w;
        w += measure.width(part);
    }
    return w;
}

fn rangeWidthWithMarkers(parts: []const []const u8, separator: []const u8, start: usize, end: usize, left_marker_w: usize, right_marker_w: usize, show_left: bool, show_right: bool) usize {
    const slice = parts[start..end];
    var w = joinedWidth(slice, separator);
    if (show_left) w += left_marker_w;
    if (show_right) w += right_marker_w;
    return w;
}

fn joinPieces(allocator: std.mem.Allocator, parts: []const []const u8, separator: []const u8) ![]const u8 {
    if (parts.len == 0) return allocator.dupe(u8, "");

    var out = std.array_list.Managed(u8).init(allocator);
    const writer = out.writer();
    for (parts, 0..) |part, i| {
        if (i > 0) try writer.writeAll(separator);
        try writer.writeAll(part);
    }
    return out.toOwnedSlice();
}

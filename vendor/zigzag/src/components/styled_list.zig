//! Styled list component for rendering lists with various enumerators.
//! Non-interactive rendering-only list with bullet, numbered, roman, alphabet enumerators.

const std = @import("std");
const style_mod = @import("../style/style.zig");
const Color = @import("../style/color.zig").Color;

/// Enumerator type for list items
pub const EnumeratorType = enum {
    bullet,
    arabic,
    roman,
    alphabet,
    dash,
    asterisk,
    none,
};

pub const StyledList = struct {
    allocator: std.mem.Allocator,
    items: std.array_list.Managed(ListItem),
    enumerator_type: EnumeratorType,
    item_style: style_mod.Style,
    enumerator_style: style_mod.Style,

    pub const ListItem = struct {
        text: []const u8,
        depth: usize,
        style_override: ?style_mod.Style,
    };

    pub fn init(allocator: std.mem.Allocator) StyledList {
        return .{
            .allocator = allocator,
            .items = std.array_list.Managed(ListItem).init(allocator),
            .enumerator_type = .bullet,
            .item_style = blk: {
                var s = style_mod.Style{};
                s = s.inline_style(true);
                break :blk s;
            },
            .enumerator_style = blk: {
                var s = style_mod.Style{};
                s = s.inline_style(true);
                break :blk s;
            },
        };
    }

    pub fn deinit(self: *StyledList) void {
        self.items.deinit();
    }

    /// Add an item at depth 0
    pub fn addItem(self: *StyledList, text: []const u8) !void {
        try self.items.append(.{
            .text = text,
            .depth = 0,
            .style_override = null,
        });
    }

    /// Add an item at specified depth
    pub fn addItemNested(self: *StyledList, text: []const u8, depth: usize) !void {
        try self.items.append(.{
            .text = text,
            .depth = depth,
            .style_override = null,
        });
    }

    /// Set the enumerator type
    pub fn setEnumerator(self: *StyledList, e: EnumeratorType) void {
        self.enumerator_type = e;
    }

    /// Render the list
    pub fn view(self: *const StyledList, allocator: std.mem.Allocator) ![]const u8 {
        var result = std.array_list.Managed(u8).init(allocator);
        const writer = result.writer();

        // Track counters per depth level
        var counters: [16]usize = .{0} ** 16;

        for (self.items.items, 0..) |item, i| {
            if (i > 0) try writer.writeAll("\n");

            // Reset deeper counters when going to a shallower depth
            const depth = @min(item.depth, 15);
            for (depth + 1..16) |d| {
                counters[d] = 0;
            }
            counters[depth] += 1;

            // Indent
            for (0..depth) |_| {
                try writer.writeAll("  ");
            }

            // Enumerator
            const enum_str = try self.formatEnumerator(allocator, counters[depth]);
            const styled_enum = try self.enumerator_style.render(allocator, enum_str);
            try writer.writeAll(styled_enum);

            // Item text
            const active_style = item.style_override orelse self.item_style;
            const styled_text = try active_style.render(allocator, item.text);
            try writer.writeAll(styled_text);
        }

        return result.toOwnedSlice();
    }

    fn formatEnumerator(self: *const StyledList, allocator: std.mem.Allocator, counter: usize) ![]const u8 {
        return switch (self.enumerator_type) {
            .bullet => try allocator.dupe(u8, "\u{2022} "),
            .arabic => try std.fmt.allocPrint(allocator, "{d}. ", .{counter}),
            .roman => blk: {
                const roman = try toRoman(allocator, counter);
                break :blk try std.fmt.allocPrint(allocator, "{s}. ", .{roman});
            },
            .alphabet => blk: {
                const alpha = try toAlpha(allocator, counter);
                break :blk try std.fmt.allocPrint(allocator, "{s}. ", .{alpha});
            },
            .dash => try allocator.dupe(u8, "- "),
            .asterisk => try allocator.dupe(u8, "* "),
            .none => try allocator.dupe(u8, ""),
        };
    }
};

/// Convert number to Roman numerals
pub fn toRoman(allocator: std.mem.Allocator, n: usize) ![]const u8 {
    if (n == 0) return try allocator.dupe(u8, "0");

    var result = std.array_list.Managed(u8).init(allocator);

    const values = [_]usize{ 1000, 900, 500, 400, 100, 90, 50, 40, 10, 9, 5, 4, 1 };
    const symbols = [_][]const u8{ "M", "CM", "D", "CD", "C", "XC", "L", "XL", "X", "IX", "V", "IV", "I" };

    var num = n;
    for (values, symbols) |val, sym| {
        while (num >= val) {
            try result.appendSlice(sym);
            num -= val;
        }
    }

    return result.toOwnedSlice();
}

/// Convert number to alphabetical representation (1=a, 2=b, ..., 26=z, 27=aa)
pub fn toAlpha(allocator: std.mem.Allocator, n: usize) ![]const u8 {
    if (n == 0) return try allocator.dupe(u8, "?");

    var result = std.array_list.Managed(u8).init(allocator);
    var num = n - 1;

    while (true) {
        const c: u8 = @intCast('a' + @as(u8, @intCast(num % 26)));
        try result.insert(0, c);
        if (num < 26) break;
        num = num / 26 - 1;
    }

    return result.toOwnedSlice();
}

//! Tree component for displaying hierarchical data.
//! Renders a tree structure with expandable nodes and customizable enumerators.

const std = @import("std");
const style_mod = @import("../style/style.zig");
const Color = @import("../style/color.zig").Color;

/// Enumerator defines the prefix characters for tree rendering
pub const Enumerator = struct {
    item_prefix: []const u8,
    last_prefix: []const u8,
    indent_prefix: []const u8,
    empty_prefix: []const u8,
};

/// Default tree enumerator with box-drawing characters
pub const DefaultEnumerator = Enumerator{
    .item_prefix = "├── ",
    .last_prefix = "└── ",
    .indent_prefix = "│   ",
    .empty_prefix = "    ",
};

/// Rounded tree enumerator
pub const RoundedEnumerator = Enumerator{
    .item_prefix = "├── ",
    .last_prefix = "╰── ",
    .indent_prefix = "│   ",
    .empty_prefix = "    ",
};

pub fn Tree(comptime T: type) type {
    return struct {
        allocator: std.mem.Allocator,
        nodes: std.array_list.Managed(Node),
        root_indices: std.array_list.Managed(usize),
        enumerator: Enumerator,
        node_style: style_mod.Style,
        label_style: style_mod.Style,

        const Self = @This();

        pub const Node = struct {
            value: T,
            label: []const u8,
            children: std.array_list.Managed(usize),
            expanded: bool,
            style_override: ?style_mod.Style,

            pub fn deinit(self: *Node) void {
                self.children.deinit();
            }
        };

        pub fn init(allocator: std.mem.Allocator) Self {
            return .{
                .allocator = allocator,
                .nodes = std.array_list.Managed(Node).init(allocator),
                .root_indices = std.array_list.Managed(usize).init(allocator),
                .enumerator = DefaultEnumerator,
                .node_style = blk: {
                    var s = style_mod.Style{};
                    s = s.inline_style(true);
                    break :blk s;
                },
                .label_style = blk: {
                    var s = style_mod.Style{};
                    s = s.inline_style(true);
                    break :blk s;
                },
            };
        }

        pub fn deinit(self: *Self) void {
            for (self.nodes.items) |*node| {
                node.deinit();
            }
            self.nodes.deinit();
            self.root_indices.deinit();
        }

        /// Add a root node, returns its index
        pub fn addRoot(self: *Self, value: T, label: []const u8) !usize {
            const idx = self.nodes.items.len;
            try self.nodes.append(.{
                .value = value,
                .label = label,
                .children = std.array_list.Managed(usize).init(self.allocator),
                .expanded = true,
                .style_override = null,
            });
            try self.root_indices.append(idx);
            return idx;
        }

        /// Add a child node to a parent, returns child index
        pub fn addChild(self: *Self, parent: usize, value: T, label: []const u8) !usize {
            const idx = self.nodes.items.len;
            try self.nodes.append(.{
                .value = value,
                .label = label,
                .children = std.array_list.Managed(usize).init(self.allocator),
                .expanded = true,
                .style_override = null,
            });
            try self.nodes.items[parent].children.append(idx);
            return idx;
        }

        /// Toggle expand/collapse of a node
        pub fn toggleNode(self: *Self, idx: usize) void {
            if (idx < self.nodes.items.len) {
                self.nodes.items[idx].expanded = !self.nodes.items[idx].expanded;
            }
        }

        /// Set enumerator style
        pub fn setEnumerator(self: *Self, e: Enumerator) void {
            self.enumerator = e;
        }

        /// Render the tree
        pub fn view(self: *const Self, allocator: std.mem.Allocator) ![]const u8 {
            var result = std.array_list.Managed(u8).init(allocator);
            const writer = result.writer();

            for (self.root_indices.items, 0..) |root_idx, i| {
                if (i > 0) try writer.writeAll("\n");
                try self.renderNode(writer, allocator, root_idx, "", true);
            }

            return result.toOwnedSlice();
        }

        fn renderNode(
            self: *const Self,
            writer: anytype,
            allocator: std.mem.Allocator,
            node_idx: usize,
            prefix: []const u8,
            is_root: bool,
        ) !void {
            const node = self.nodes.items[node_idx];
            const active_style = node.style_override orelse self.label_style;

            // Write prefix
            try writer.writeAll(prefix);

            // Write label
            const styled_label = try active_style.render(allocator, node.label);
            try writer.writeAll(styled_label);

            // Render children if expanded
            if (node.expanded and node.children.items.len > 0) {
                const children = node.children.items;
                for (children, 0..) |child_idx, ci| {
                    try writer.writeAll("\n");
                    const is_last = (ci == children.len - 1);
                    const connector = if (is_last) self.enumerator.last_prefix else self.enumerator.item_prefix;
                    const child_prefix = if (is_last) self.enumerator.empty_prefix else self.enumerator.indent_prefix;

                    // Build new prefix for children
                    var new_prefix = std.array_list.Managed(u8).init(allocator);
                    if (!is_root) {
                        try new_prefix.appendSlice(prefix);
                    }
                    try new_prefix.appendSlice(child_prefix);
                    const new_prefix_str = try new_prefix.toOwnedSlice();

                    // Write connector and recurse
                    var connector_prefix = std.array_list.Managed(u8).init(allocator);
                    if (!is_root) {
                        try connector_prefix.appendSlice(prefix);
                    }
                    try connector_prefix.appendSlice(connector);
                    const connector_str = try connector_prefix.toOwnedSlice();

                    try self.renderNode(writer, allocator, child_idx, connector_str, false);
                    _ = new_prefix_str;
                }
            }
        }
    };
}

//! ZigZag - A TUI library for Zig inspired by Bubble Tea and Lipgloss
//!
//! ZigZag provides a framework for building terminal user interfaces using
//! the Elm architecture (Model-Update-View pattern).
//!
//! ## Quick Start
//!
//! ```zig
//! const std = @import("std");
//! const zz = @import("zigzag");
//!
//! const Model = struct {
//!     count: i32,
//!
//!     pub const Msg = union(enum) {
//!         key: zz.msg.Key,
//!     };
//!
//!     pub fn init(self: *Model, _: *zz.Context) zz.Cmd(Msg) {
//!         self.* = .{ .count = 0 };
//!         return .none;
//!     }
//!
//!     pub fn update(self: *Model, msg: Msg, _: *zz.Context) zz.Cmd(Msg) {
//!         switch (msg) {
//!             .key => |k| switch (k.key) {
//!                 .char => |c| if (c == 'q') return .quit,
//!                 .up => self.count += 1,
//!                 .down => self.count -= 1,
//!                 else => {},
//!             },
//!         }
//!         return .none;
//!     }
//!
//!     pub fn view(self: *const Model, ctx: *const zz.Context) []const u8 {
//!         return std.fmt.allocPrint(ctx.allocator, "Count: {d}\n\nPress q to quit", .{self.count}) catch "Error";
//!     }
//! };
//!
//! pub fn main() !void {
//!     var gpa = std.heap.GeneralPurposeAllocator(.{}){};
//!     defer _ = gpa.deinit();
//!
//!     var program = try zz.Program(Model).init(gpa.allocator());
//!     defer program.deinit();
//!     try program.run();
//! }
//! ```

const std = @import("std");

// Core
pub const program = @import("core/program.zig");
pub const Program = program.Program;
pub const Cmd = program.Cmd;
pub const command = @import("core/command.zig");
pub const Context = @import("core/context.zig").Context;
pub const Options = @import("core/context.zig").Options;
pub const msg = @import("core/message.zig");
pub const log = @import("core/log.zig");
pub const Logger = log.Logger;

// Terminal
pub const terminal = @import("terminal/terminal.zig");
pub const Terminal = terminal.Terminal;
pub const ansi = terminal.ansi;
pub const screen = terminal.screen;

// Input
pub const input = struct {
    pub const keyboard = @import("input/keyboard.zig");
    pub const mouse = @import("input/mouse.zig");
    pub const keys = @import("input/keys.zig");
};
pub const Key = input.keys.Key;
pub const KeyEvent = input.keys.KeyEvent;
pub const Modifiers = input.keys.Modifiers;
pub const MouseEvent = input.mouse.MouseEvent;

// Style
pub const style = @import("style/style.zig");
pub const Style = style.Style;
pub const color = @import("style/color.zig");
pub const Color = color.Color;
pub const border = @import("style/border.zig");
pub const Border = border.Border;

// Layout
pub const layout = @import("layout/layout.zig");
pub const measure = @import("layout/measure.zig");
pub const join = @import("layout/join.zig");
pub const place = @import("layout/place.zig");

// Unicode
pub const unicode = @import("unicode.zig");

// Components
pub const components = struct {
    pub const TextInput = @import("components/text_input.zig").TextInput;
    pub const TextArea = @import("components/text_area.zig").TextArea;
    pub const List = @import("components/list.zig").List;
    pub const Viewport = @import("components/viewport.zig").Viewport;
    pub const Progress = @import("components/progress.zig").Progress;
    pub const Spinner = @import("components/spinner.zig").Spinner;
    pub const Table = @import("components/table.zig").Table;
    pub const Paginator = @import("components/paginator.zig").Paginator;
    pub const Help = @import("components/help.zig").Help;
    pub const Timer = @import("components/timer.zig").Timer;
    pub const FilePicker = @import("components/file_picker.zig").FilePicker;
    pub const Tree = @import("components/tree.zig").Tree;
    pub const StyledList = @import("components/styled_list.zig").StyledList;
    pub const Sparkline = @import("components/sparkline.zig").Sparkline;
    pub const charting = @import("components/charting.zig");
    pub const canvas = @import("components/canvas.zig");
    pub const Canvas = canvas.Canvas;
    pub const chart = @import("components/chart.zig");
    pub const Chart = chart.Chart;
    pub const BarChart = @import("components/bar_chart.zig").BarChart;
    pub const notification = @import("components/notification.zig");
    pub const Notification = notification.Notification;
    pub const Confirm = @import("components/confirm.zig").Confirm;
    pub const modal = @import("components/modal.zig");
    pub const Modal = modal.Modal;
    pub const tooltip = @import("components/tooltip.zig");
    pub const Tooltip = tooltip.Tooltip;
    pub const focus = @import("components/focus.zig");
    pub const tab_group = @import("components/tab_group.zig");
    pub const TabGroup = tab_group.TabGroup;
};

// Re-export commonly used components at top level
pub const TextInput = components.TextInput;
pub const TextArea = components.TextArea;
pub const List = components.List;
pub const Viewport = components.Viewport;
pub const Progress = components.Progress;
pub const Spinner = components.Spinner;
pub const Table = components.Table;
pub const Tree = components.Tree;
pub const StyledList = components.StyledList;
pub const Sparkline = components.Sparkline;
pub const Canvas = components.Canvas;
pub const Chart = components.Chart;
pub const BarChart = components.BarChart;
pub const Notification = components.Notification;
pub const Confirm = components.Confirm;
pub const Modal = components.Modal;
pub const Tooltip = components.Tooltip;
pub const TabGroup = components.TabGroup;

// Focus management
pub const FocusGroup = components.focus.FocusGroup;
pub const FocusStyle = components.focus.FocusStyle;
pub const KeyBind = components.focus.KeyBind;
pub const isFocusable = components.focus.isFocusable;
pub const TabChange = components.tab_group.Change;
pub const TabChangeReason = components.tab_group.ChangeReason;
pub const TabKeyResult = components.tab_group.KeyResult;
pub const TabKeyBind = components.tab_group.KeyBind;

// Keybinding management
pub const keybinding = @import("components/keybinding.zig");
pub const KeyBinding = keybinding.KeyBinding;
pub const KeyMap = keybinding.KeyMap;

// Utility functions
pub fn joinHorizontal(allocator: std.mem.Allocator, parts: []const []const u8) ![]const u8 {
    return join.horizontal(allocator, .top, parts);
}

pub fn joinVertical(allocator: std.mem.Allocator, parts: []const []const u8) ![]const u8 {
    return join.vertical(allocator, .left, parts);
}

pub fn width(str: []const u8) usize {
    return measure.width(str);
}

pub fn height(str: []const u8) usize {
    return measure.height(str);
}

pub fn placeHorizontal(allocator: std.mem.Allocator, w: usize, hpos: place.HPosition, content: []const u8) ![]const u8 {
    return place.placeHorizontal(allocator, w, hpos, content);
}

pub fn placeVertical(allocator: std.mem.Allocator, h: usize, vpos: place.VPosition, content: []const u8) ![]const u8 {
    return place.placeVertical(allocator, h, vpos, content);
}

pub fn placeFloat(allocator: std.mem.Allocator, w: usize, h: usize, hpos: f32, vpos: f32, content: []const u8) ![]const u8 {
    return place.placeFloat(allocator, w, h, hpos, vpos, content);
}

// Image types
pub const ImageFile = command.ImageFile;
pub const ImageData = command.ImageData;
pub const ImagePlacement = command.ImagePlacement;
pub const ImageProtocol = command.ImageProtocol;
pub const ImageFormat = command.ImageFormat;
pub const ImageSource = command.ImageSource;
pub const CacheImage = command.CacheImage;
pub const PlaceCachedImage = command.PlaceCachedImage;
pub const DeleteImage = command.DeleteImage;
pub const ImageCapabilities = terminal.ImageCapabilities;
pub const Osc52Target = terminal.Osc52Target;
pub const Osc52Passthrough = terminal.Osc52Passthrough;
pub const Osc52Config = terminal.Osc52Config;
pub const Osc52WriteOptions = terminal.Osc52WriteOptions;
pub const Osc52ReadOptions = terminal.Osc52ReadOptions;
pub const OscTerminator = terminal.ansi.OscTerminator;

// Color utilities
pub const ColorProfile = color.ColorProfile;
pub const AdaptiveColor = color.AdaptiveColor;
pub const CompleteColor = color.CompleteColor;
pub const CompleteAdaptiveColor = color.CompleteAdaptiveColor;

// Style utilities
pub const StyleRange = style.StyleRange;
pub const renderWithRanges = style.renderWithRanges;
pub const renderWithHighlights = style.renderWithHighlights;
pub const transforms = style.transforms;
pub const compress = @import("style/compress.zig");
pub const StyleState = compress.StyleState;
pub const compressAnsi = compress.compressAnsi;

// Progress helpers
pub const interpolateColor = @import("components/progress.zig").interpolateColor;
pub const PlotPoint = components.charting.Point;
pub const PlotRange = components.charting.DataRange;
pub const PlotMarker = components.charting.Marker;
pub const GraphType = components.chart.GraphType;
pub const ChartInterpolation = components.chart.Interpolation;
pub const Axis = components.chart.Axis;
pub const AxisLabel = components.chart.AxisLabel;
pub const ChartDataset = components.chart.Dataset;
pub const LegendPosition = components.chart.LegendPosition;
pub const Bar = @import("components/bar_chart.zig").Bar;
pub const ChartOrientation = components.charting.Orientation;
pub const SparkSummary = @import("components/sparkline.zig").Summary;

test {
    std.testing.refAllDecls(@This());
}

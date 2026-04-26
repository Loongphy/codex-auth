//! Animated loading spinner component.
//! Provides various spinner styles and customization options.

const std = @import("std");
const style = @import("../style/style.zig");
const Color = @import("../style/color.zig").Color;

pub const Spinner = struct {
    // Spinner configuration
    frames: []const []const u8,
    frame_index: usize,
    fps: u32,

    // Styling
    spinner_style: style.Style,

    // State
    last_tick: i64,

    /// Predefined spinner styles
    pub const Styles = struct {
        pub const line = &[_][]const u8{ "|", "/", "-", "\\" };
        pub const dots = &[_][]const u8{ "⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏" };
        pub const dots2 = &[_][]const u8{ "⣾", "⣽", "⣻", "⢿", "⡿", "⣟", "⣯", "⣷" };
        pub const dots3 = &[_][]const u8{ "⠋", "⠙", "⠚", "⠞", "⠖", "⠦", "⠴", "⠲", "⠳", "⠓" };
        pub const globe = &[_][]const u8{ "🌍", "🌎", "🌏" };
        pub const moon = &[_][]const u8{ "🌑", "🌒", "🌓", "🌔", "🌕", "🌖", "🌗", "🌘" };
        pub const circle = &[_][]const u8{ "◐", "◓", "◑", "◒" };
        pub const square = &[_][]const u8{ "◰", "◳", "◲", "◱" };
        pub const arrow = &[_][]const u8{ "←", "↖", "↑", "↗", "→", "↘", "↓", "↙" };
        pub const bounce = &[_][]const u8{ "⠁", "⠂", "⠄", "⠂" };
        pub const box_bounce = &[_][]const u8{ "▖", "▘", "▝", "▗" };
        pub const triangle = &[_][]const u8{ "◢", "◣", "◤", "◥" };
        pub const arc = &[_][]const u8{ "◜", "◠", "◝", "◞", "◡", "◟" };
        pub const pipe = &[_][]const u8{ "┤", "┘", "┴", "└", "├", "┌", "┬", "┐" };
        pub const simple_dots = &[_][]const u8{ ".  ", ".. ", "...", " ..", "  .", "   " };
        pub const pulse = &[_][]const u8{ "█", "▓", "▒", "░", "▒", "▓" };
    };

    pub fn init() Spinner {
        return .{
            .frames = Styles.dots,
            .frame_index = 0,
            .fps = 10,
            .spinner_style = blk: {
                var s = style.Style{};
                s = s.fg(Color.cyan());
                s = s.inline_style(true);
                break :blk s;
            },
            .last_tick = 0,
        };
    }

    /// Set spinner frames
    pub fn setFrames(self: *Spinner, frames: []const []const u8) void {
        self.frames = frames;
        self.frame_index = 0;
    }

    /// Set spinner style
    pub fn setStyle(self: *Spinner, s: style.Style) void {
        self.spinner_style = s;
    }

    /// Set frames per second
    pub fn setFps(self: *Spinner, fps: u32) void {
        self.fps = fps;
    }

    /// Advance to next frame
    pub fn tick(self: *Spinner) void {
        self.frame_index = (self.frame_index + 1) % self.frames.len;
    }

    /// Update based on elapsed time (in nanoseconds)
    pub fn update(self: *Spinner, elapsed_ns: i64) bool {
        const frame_ns = @as(i64, @intCast(std.time.ns_per_s / self.fps));

        if (elapsed_ns - self.last_tick >= frame_ns) {
            self.tick();
            self.last_tick = elapsed_ns;
            return true; // Frame changed
        }
        return false;
    }

    /// Get current frame
    pub fn currentFrame(self: *const Spinner) []const u8 {
        return self.frames[self.frame_index];
    }

    /// Render the spinner
    pub fn view(self: *const Spinner, allocator: std.mem.Allocator) ![]const u8 {
        return self.spinner_style.render(allocator, self.currentFrame());
    }

    /// Render spinner with title
    pub fn viewWithTitle(self: *const Spinner, allocator: std.mem.Allocator, title: []const u8) ![]const u8 {
        var result = std.array_list.Managed(u8).init(allocator);
        const writer = result.writer();

        const rendered_spinner = try self.view(allocator);
        try writer.writeAll(rendered_spinner);
        try writer.writeByte(' ');
        try writer.writeAll(title);

        return result.toOwnedSlice();
    }
};

/// Create a spinner with the given style
pub fn newSpinner(frames: []const []const u8) Spinner {
    var s = Spinner.init();
    s.setFrames(frames);
    return s;
}

/// Create a dots spinner
pub fn dots() Spinner {
    return Spinner.init();
}

/// Create a line spinner
pub fn line() Spinner {
    var s = Spinner.init();
    s.setFrames(Spinner.Styles.line);
    return s;
}

/// Create a globe spinner
pub fn globe() Spinner {
    var s = Spinner.init();
    s.setFrames(Spinner.Styles.globe);
    s.setFps(4);
    return s;
}

/// Create a moon spinner
pub fn moon() Spinner {
    var s = Spinner.init();
    s.setFrames(Spinner.Styles.moon);
    s.setFps(6);
    return s;
}

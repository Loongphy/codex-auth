//! Color types for terminal styling.
//! Supports ANSI 16, 256, and TrueColor (24-bit) colors.

const std = @import("std");
const builtin = @import("builtin");
const ansi = @import("../terminal/ansi.zig");

/// Color representation supporting multiple color modes
pub const Color = union(enum) {
    /// No color (use terminal default)
    none,

    /// Basic ANSI colors (0-15)
    ansi: AnsiColor,

    /// 256-color palette (0-255)
    ansi256: u8,

    /// True color (24-bit RGB)
    rgb: RGB,

    pub const RGB = struct {
        r: u8,
        g: u8,
        b: u8,
    };

    // Basic ANSI colors
    pub fn black() Color {
        return .{ .ansi = .black };
    }
    pub fn red() Color {
        return .{ .ansi = .red };
    }
    pub fn green() Color {
        return .{ .ansi = .green };
    }
    pub fn yellow() Color {
        return .{ .ansi = .yellow };
    }
    pub fn blue() Color {
        return .{ .ansi = .blue };
    }
    pub fn magenta() Color {
        return .{ .ansi = .magenta };
    }
    pub fn cyan() Color {
        return .{ .ansi = .cyan };
    }
    pub fn white() Color {
        return .{ .ansi = .white };
    }

    // Bright ANSI colors
    pub fn brightBlack() Color {
        return .{ .ansi = .bright_black };
    }
    pub fn brightRed() Color {
        return .{ .ansi = .bright_red };
    }
    pub fn brightGreen() Color {
        return .{ .ansi = .bright_green };
    }
    pub fn brightYellow() Color {
        return .{ .ansi = .bright_yellow };
    }
    pub fn brightBlue() Color {
        return .{ .ansi = .bright_blue };
    }
    pub fn brightMagenta() Color {
        return .{ .ansi = .bright_magenta };
    }
    pub fn brightCyan() Color {
        return .{ .ansi = .bright_cyan };
    }
    pub fn brightWhite() Color {
        return .{ .ansi = .bright_white };
    }

    /// Create a color from RGB values
    pub fn fromRgb(r: u8, g: u8, b: u8) Color {
        return .{ .rgb = .{ .r = r, .g = g, .b = b } };
    }

    /// Create a color from a hex string (e.g., "#FF5733" or "FF5733")
    pub fn hex(str: []const u8) Color {
        const s = if (str.len > 0 and str[0] == '#') str[1..] else str;

        if (s.len != 6) return .none;

        const r = std.fmt.parseInt(u8, s[0..2], 16) catch return .none;
        const g = std.fmt.parseInt(u8, s[2..4], 16) catch return .none;
        const b = std.fmt.parseInt(u8, s[4..6], 16) catch return .none;

        return .{ .rgb = .{ .r = r, .g = g, .b = b } };
    }

    /// Create a color from the 256-color palette
    pub fn color256(n: u8) Color {
        return .{ .ansi256 = n };
    }

    /// Create a grayscale color (0-23, where 0 is dark and 23 is light)
    pub fn gray(level: u8) Color {
        if (level > 23) return .{ .ansi256 = 255 };
        return .{ .ansi256 = 232 + level };
    }

    /// Check if this is a "no color" value
    pub fn isNone(self: Color) bool {
        return self == .none;
    }

    /// Convert to RGB (approximating ANSI colors)
    pub fn toRgb(self: Color) ?RGB {
        return switch (self) {
            .none => null,
            .rgb => |c| c,
            .ansi => |c| c.toRgb(),
            .ansi256 => |n| ansi256ToRgb(n),
        };
    }

    /// Write foreground color ANSI sequence
    pub fn writeFg(self: Color, writer: anytype) !void {
        switch (self) {
            .none => {},
            .ansi => |c| try writer.print(ansi.CSI ++ "{d}m", .{c.fgCode()}),
            .ansi256 => |n| try ansi.fg256(writer, n),
            .rgb => |c| try ansi.fgRgb(writer, c.r, c.g, c.b),
        }
    }

    /// Write background color ANSI sequence
    pub fn writeBg(self: Color, writer: anytype) !void {
        switch (self) {
            .none => {},
            .ansi => |c| try writer.print(ansi.CSI ++ "{d}m", .{c.bgCode()}),
            .ansi256 => |n| try ansi.bg256(writer, n),
            .rgb => |c| try ansi.bgRgb(writer, c.r, c.g, c.b),
        }
    }

    /// Calculate contrast ratio with another color
    pub fn contrastRatio(self: Color, other: Color) f32 {
        const rgb1 = self.toRgb() orelse return 1.0;
        const rgb2 = other.toRgb() orelse return 1.0;

        const l1 = relativeLuminance(rgb1);
        const l2 = relativeLuminance(rgb2);

        const lighter = @max(l1, l2);
        const darker = @min(l1, l2);

        return (lighter + 0.05) / (darker + 0.05);
    }

    fn relativeLuminance(c: RGB) f32 {
        const r = gammaCorrect(@as(f32, @floatFromInt(c.r)) / 255.0);
        const g = gammaCorrect(@as(f32, @floatFromInt(c.g)) / 255.0);
        const b = gammaCorrect(@as(f32, @floatFromInt(c.b)) / 255.0);
        return 0.2126 * r + 0.7152 * g + 0.0722 * b;
    }

    fn gammaCorrect(v: f32) f32 {
        return if (v <= 0.03928) v / 12.92 else std.math.pow(f32, (v + 0.055) / 1.055, 2.4);
    }
};

/// Basic ANSI colors
pub const AnsiColor = enum(u8) {
    black = 0,
    red = 1,
    green = 2,
    yellow = 3,
    blue = 4,
    magenta = 5,
    cyan = 6,
    white = 7,
    bright_black = 8,
    bright_red = 9,
    bright_green = 10,
    bright_yellow = 11,
    bright_blue = 12,
    bright_magenta = 13,
    bright_cyan = 14,
    bright_white = 15,

    pub fn fgCode(self: AnsiColor) u8 {
        const base: u8 = @intFromEnum(self);
        return if (base < 8) 30 + base else 90 + base - 8;
    }

    pub fn bgCode(self: AnsiColor) u8 {
        const base: u8 = @intFromEnum(self);
        return if (base < 8) 40 + base else 100 + base - 8;
    }

    pub fn toRgb(self: AnsiColor) Color.RGB {
        return switch (self) {
            .black => .{ .r = 0, .g = 0, .b = 0 },
            .red => .{ .r = 128, .g = 0, .b = 0 },
            .green => .{ .r = 0, .g = 128, .b = 0 },
            .yellow => .{ .r = 128, .g = 128, .b = 0 },
            .blue => .{ .r = 0, .g = 0, .b = 128 },
            .magenta => .{ .r = 128, .g = 0, .b = 128 },
            .cyan => .{ .r = 0, .g = 128, .b = 128 },
            .white => .{ .r = 192, .g = 192, .b = 192 },
            .bright_black => .{ .r = 128, .g = 128, .b = 128 },
            .bright_red => .{ .r = 255, .g = 0, .b = 0 },
            .bright_green => .{ .r = 0, .g = 255, .b = 0 },
            .bright_yellow => .{ .r = 255, .g = 255, .b = 0 },
            .bright_blue => .{ .r = 0, .g = 0, .b = 255 },
            .bright_magenta => .{ .r = 255, .g = 0, .b = 255 },
            .bright_cyan => .{ .r = 0, .g = 255, .b = 255 },
            .bright_white => .{ .r = 255, .g = 255, .b = 255 },
        };
    }
};

/// Convert 256-color index to RGB
fn ansi256ToRgb(n: u8) Color.RGB {
    if (n < 16) {
        // Standard colors
        return @as(AnsiColor, @enumFromInt(n)).toRgb();
    } else if (n < 232) {
        // 6x6x6 color cube
        const idx = n - 16;
        const r: u8 = @intCast((idx / 36) % 6);
        const g: u8 = @intCast((idx / 6) % 6);
        const b: u8 = @intCast(idx % 6);
        return .{
            .r = if (r == 0) 0 else r * 40 + 55,
            .g = if (g == 0) 0 else g * 40 + 55,
            .b = if (b == 0) 0 else b * 40 + 55,
        };
    } else {
        // Grayscale
        const gray: u8 = (n - 232) * 10 + 8;
        return .{ .r = gray, .g = gray, .b = gray };
    }
}

/// Adaptive color that changes based on terminal capabilities
pub const AdaptiveColor = struct {
    /// Color for terminals with true color support
    true_color: Color,
    /// Fallback for 256-color terminals
    color_256: Color,
    /// Fallback for basic 16-color terminals
    ansi: Color,

    pub fn resolve(self: AdaptiveColor, supports_true_color: bool, supports_256: bool) Color {
        if (supports_true_color) return self.true_color;
        if (supports_256) return self.color_256;
        return self.ansi;
    }
};

/// Complete color for foreground and background
pub const CompleteColor = struct {
    fg: Color = .none,
    bg: Color = .none,
};

/// Complete adaptive color that changes based on terminal background
pub const CompleteAdaptiveColor = struct {
    light: CompleteColor,
    dark: CompleteColor,

    pub fn resolve(self: CompleteAdaptiveColor, is_dark: bool) CompleteColor {
        return if (is_dark) self.dark else self.light;
    }
};

/// Color profile representing terminal color capabilities
pub const ColorProfile = enum {
    ascii,
    ansi,
    ansi256,
    true_color,

    /// Detect terminal color profile from environment
    pub fn detect() ColorProfile {
        if (comptime builtin.os.tag == .windows) {
            // Windows Terminal supports true color VT sequences
            return .true_color;
        }

        // Check NO_COLOR
        if (std.posix.getenv("NO_COLOR")) |_| {
            return .ascii;
        }

        // Check for true color support
        if (std.posix.getenv("COLORTERM")) |ct| {
            if (std.mem.eql(u8, ct, "truecolor") or std.mem.eql(u8, ct, "24bit")) {
                return .true_color;
            }
        }

        // Check for 256 color support
        if (std.posix.getenv("TERM")) |term| {
            if (std.mem.indexOf(u8, term, "256color") != null) {
                return .ansi256;
            }
        }

        return .ansi;
    }

    /// Check if this profile supports true color
    pub fn supportsTrueColor(self: ColorProfile) bool {
        return self == .true_color;
    }

    /// Check if this profile supports 256 colors
    pub fn supports256(self: ColorProfile) bool {
        return self == .true_color or self == .ansi256;
    }

    /// Check if this profile supports any color
    pub fn supportsColor(self: ColorProfile) bool {
        return self != .ascii;
    }
};

/// Detect if terminal has a dark background
pub fn hasDarkBackground() bool {
    if (comptime builtin.os.tag == .windows) {
        return true;
    }

    if (std.posix.getenv("COLORFGBG")) |val| {
        // Format: "foreground;background"
        if (std.mem.lastIndexOfScalar(u8, val, ';')) |idx| {
            const bg_str = val[idx + 1 ..];
            const bg_num = std.fmt.parseInt(u8, bg_str, 10) catch return true;
            // Low numbers typically mean dark background
            return bg_num < 8;
        }
    }
    return true; // Default to dark
}

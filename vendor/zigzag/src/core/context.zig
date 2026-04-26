//! Runtime context for ZigZag applications.
//! Provides access to terminal state and resources.

const std = @import("std");
const terminal_mod = @import("../terminal/terminal.zig");
const Terminal = terminal_mod.Terminal;
const ImageCapabilities = terminal_mod.ImageCapabilities;
const color_mod = @import("../style/color.zig");
const unicode_mod = @import("../unicode.zig");
const Logger = @import("log.zig").Logger;

/// Runtime context passed to init, update, and view functions
pub const Context = struct {
    /// Allocator for temporary allocations (reset each frame)
    allocator: std.mem.Allocator,

    /// Persistent allocator for model state (not reset between frames)
    persistent_allocator: std.mem.Allocator,

    /// Terminal width in columns
    width: u16,

    /// Terminal height in rows
    height: u16,

    /// Current frame number
    frame: u64,

    /// Time since program start (nanoseconds)
    elapsed: u64,

    /// Delta time since last frame (nanoseconds)
    delta: u64,

    /// Whether the terminal supports true color
    true_color: bool,

    /// Whether the terminal supports 256 colors
    color_256: bool,

    /// Color profile of the terminal
    color_profile: color_mod.ColorProfile,

    /// Whether the terminal has a dark background
    is_dark_background: bool,

    /// Active Unicode width strategy for text measurement
    unicode_width_strategy: unicode_mod.WidthStrategy,

    /// Whether DEC mode 2027 was successfully negotiated
    terminal_mode_2027: bool,

    /// Whether kitty text sizing support was detected
    kitty_text_sizing: bool,

    /// Access to internal state (for advanced use)
    _terminal: ?*Terminal,

    /// Logger for debug output
    _logger: ?*Logger = null,

    /// Log a debug message (writes to log file if configured)
    pub fn log(self: *const Context, comptime fmt: []const u8, args: anytype) void {
        if (self._logger) |logger| {
            logger.log(fmt, args);
        }
    }

    pub fn init(allocator: std.mem.Allocator, persistent_allocator: std.mem.Allocator) Context {
        const profile = color_mod.ColorProfile.detect();
        return .{
            .allocator = allocator,
            .persistent_allocator = persistent_allocator,
            .width = 80,
            .height = 24,
            .frame = 0,
            .elapsed = 0,
            .delta = 0,
            .true_color = profile.supportsTrueColor(),
            .color_256 = profile.supports256(),
            .color_profile = profile,
            .is_dark_background = color_mod.hasDarkBackground(),
            .unicode_width_strategy = unicode_mod.getWidthStrategy(),
            .terminal_mode_2027 = false,
            .kitty_text_sizing = false,
            ._terminal = null,
        };
    }

    /// Get the aspect ratio (width / height)
    pub fn aspectRatio(self: *const Context) f32 {
        if (self.height == 0) return 1.0;
        return @as(f32, @floatFromInt(self.width)) / @as(f32, @floatFromInt(self.height));
    }

    /// Get center coordinates
    pub fn center(self: *const Context) struct { x: u16, y: u16 } {
        return .{
            .x = self.width / 2,
            .y = self.height / 2,
        };
    }

    /// Check if a position is within bounds
    pub fn inBounds(self: *const Context, x: u16, y: u16) bool {
        return x < self.width and y < self.height;
    }

    /// Get elapsed time in seconds (floating point)
    pub fn elapsedSec(self: *const Context) f64 {
        return @as(f64, @floatFromInt(self.elapsed)) / @as(f64, @floatFromInt(std.time.ns_per_s));
    }

    /// Get delta time in seconds (floating point)
    pub fn deltaSec(self: *const Context) f64 {
        return @as(f64, @floatFromInt(self.delta)) / @as(f64, @floatFromInt(std.time.ns_per_s));
    }

    /// Get frames per second (based on delta)
    pub fn fps(self: *const Context) f64 {
        if (self.delta == 0) return 0.0;
        return @as(f64, @floatFromInt(std.time.ns_per_s)) / @as(f64, @floatFromInt(self.delta));
    }

    /// Clamp a value to screen bounds
    pub fn clampX(self: *const Context, x: i32) u16 {
        if (x < 0) return 0;
        if (x >= self.width) return self.width -| 1;
        return @intCast(x);
    }

    pub fn clampY(self: *const Context, y: i32) u16 {
        if (y < 0) return 0;
        if (y >= self.height) return self.height -| 1;
        return @intCast(y);
    }

    /// Returns whether Kitty graphics protocol is available.
    pub fn supportsKittyGraphics(self: *const Context) bool {
        if (self._terminal) |term| {
            return term.supportsKittyGraphics();
        }
        return false;
    }

    /// Returns whether iTerm2 inline images are available.
    pub fn supportsIterm2InlineImages(self: *const Context) bool {
        if (self._terminal) |term| {
            return term.supportsIterm2InlineImages();
        }
        return false;
    }

    /// Returns whether Sixel graphics are available.
    pub fn supportsSixel(self: *const Context) bool {
        if (self._terminal) |term| {
            return term.supportsSixel();
        }
        return false;
    }

    /// Returns whether any inline image protocol is available.
    pub fn supportsImages(self: *const Context) bool {
        if (self._terminal) |term| {
            return term.supportsImages();
        }
        return false;
    }

    /// Copy bytes to the system clipboard via OSC 52 using terminal defaults.
    /// Returns false when clipboard output is unavailable or disabled.
    pub fn setClipboard(self: *Context, bytes: []const u8) !bool {
        if (self._terminal) |term| {
            return term.setClipboard(bytes);
        }
        return false;
    }

    /// Copy bytes to the system clipboard via OSC 52 with per-call overrides.
    pub fn setClipboardWithOptions(self: *Context, bytes: []const u8, options: terminal_mod.Osc52WriteOptions) !bool {
        if (self._terminal) |term| {
            return term.setClipboardWithOptions(bytes, options);
        }
        return false;
    }

    /// Query clipboard bytes via OSC 52 using terminal defaults.
    /// Returns null when unavailable, blocked, or timed out.
    pub fn getClipboard(self: *Context, allocator: std.mem.Allocator) !?[]u8 {
        if (self._terminal) |term| {
            return term.getClipboard(allocator);
        }
        return null;
    }

    /// Query clipboard bytes via OSC 52 with per-call overrides.
    /// Returns null when unavailable, blocked, or timed out.
    pub fn getClipboardWithOptions(self: *Context, allocator: std.mem.Allocator, options: terminal_mod.Osc52ReadOptions) !?[]u8 {
        if (self._terminal) |term| {
            return term.getClipboardWithOptions(allocator, options);
        }
        return null;
    }

    /// Draw a PNG image file via Kitty graphics protocol (`t=f`).
    /// Returns false when unsupported or path is empty.
    pub fn drawKittyImageFromFile(self: *Context, path: []const u8, options: Terminal.KittyImageFileOptions) !bool {
        if (self._terminal) |term| {
            return term.drawKittyImageFromFile(path, options);
        }
        return false;
    }

    /// Draw in-memory image data via Kitty graphics protocol (`t=d`).
    /// Returns false when unsupported or data is empty.
    pub fn drawKittyImage(self: *Context, data: []const u8, options: Terminal.KittyImageOptions) !bool {
        if (self._terminal) |term| {
            return term.drawKittyImage(data, options);
        }
        return false;
    }

    /// Transmit an image to the Kitty cache without displaying.
    /// Use `placeCachedImage` later to display by ID.
    pub fn transmitKittyImage(self: *Context, payload: []const u8, options: Terminal.KittyTransmitOptions) !bool {
        if (self._terminal) |term| {
            return term.transmitKittyImage(payload, options);
        }
        return false;
    }

    /// Transmit a file to the Kitty cache without displaying.
    pub fn transmitKittyImageFromFile(self: *Context, path: []const u8, options: Terminal.KittyTransmitOptions) !bool {
        if (self._terminal) |term| {
            return term.transmitKittyImageFromFile(path, options);
        }
        return false;
    }

    /// Display a previously cached Kitty image by ID.
    pub fn placeKittyImage(self: *Context, options: Terminal.KittyPlaceOptions) !bool {
        if (self._terminal) |term| {
            return term.placeKittyImage(options);
        }
        return false;
    }

    /// Delete cached Kitty images/placements.
    pub fn deleteKittyImage(self: *Context, target: Terminal.KittyDeleteTarget) !bool {
        if (self._terminal) |term| {
            return term.deleteKittyImage(target);
        }
        return false;
    }

    /// Draw a Sixel image from file (or convert via `img2sixel` when available).
    /// Returns false when unsupported or path is empty.
    pub fn drawSixelFromFile(self: *Context, path: []const u8, options: Terminal.SixelImageFileOptions) !bool {
        if (self._terminal) |term| {
            return term.drawSixelFromFile(path, options);
        }
        return false;
    }

    /// Draw an image file using the best available protocol.
    /// Returns false when unsupported or path is empty.
    pub fn drawImageFromFile(self: *Context, path: []const u8, options: Terminal.ImageFileOptions) !bool {
        if (self._terminal) |term| {
            return term.drawImageFromFile(path, options);
        }
        return false;
    }

    /// Draw an image file using a specific protocol.
    pub fn drawImageFromFileWithProtocol(self: *Context, path: []const u8, options: Terminal.ImageFileOptions, protocol: Terminal.ImageProtocol) !bool {
        if (self._terminal) |term| {
            return term.drawImageFromFileWithProtocol(path, options, protocol);
        }
        return false;
    }

    /// Draw in-memory image data using the best available protocol.
    pub fn drawImageData(self: *Context, data: []const u8, options: Terminal.ImageDataOptions) !bool {
        if (self._terminal) |term| {
            return term.drawImageData(data, options);
        }
        return false;
    }

    /// Draw in-memory image data using a specific protocol.
    pub fn drawImageDataWithProtocol(self: *Context, data: []const u8, options: Terminal.ImageDataOptions, protocol: Terminal.ImageProtocol) !bool {
        if (self._terminal) |term| {
            return term.drawImageDataWithProtocol(data, options, protocol);
        }
        return false;
    }

    /// Draw in-memory image data via iTerm2 inline image protocol.
    pub fn drawIterm2ImageData(self: *Context, data: []const u8, options: Terminal.Iterm2ImageDataOptions) !bool {
        if (self._terminal) |term| {
            return term.drawIterm2ImageData(data, options);
        }
        return false;
    }

    /// Get the current image capabilities of the terminal.
    pub fn getImageCapabilities(self: *const Context) ImageCapabilities {
        if (self._terminal) |term| {
            return term.getImageCapabilities();
        }
        return .{};
    }
};

/// Options that can be modified during runtime
pub const Options = struct {
    /// Target frame rate (frames per second)
    fps: u32 = 60,

    /// Enable mouse tracking
    mouse: bool = false,

    /// Show cursor
    cursor: bool = false,

    /// Use alternate screen buffer
    alt_screen: bool = true,

    /// Enable bracketed paste mode
    bracketed_paste: bool = true,

    /// Window title
    title: ?[]const u8 = null,

    /// Custom input file (default: stdin)
    input: ?std.fs.File = null,

    /// Custom output file (default: stdout)
    output: ?std.fs.File = null,

    /// Log file path for debug output
    log_file: ?[]const u8 = null,

    /// Enable Kitty keyboard protocol
    kitty_keyboard: bool = false,

    /// OSC 52 clipboard configuration
    osc52: terminal_mod.Osc52Config = .{},

    /// Force Unicode width strategy (`null` = auto-detect)
    unicode_width_strategy: ?unicode_mod.WidthStrategy = null,

    /// Enable suspend/resume with Ctrl+Z
    suspend_enabled: bool = true,
};

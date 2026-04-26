//! Terminal abstraction layer providing cross-platform terminal control.
//! Handles raw mode, alternate screen, mouse tracking, and input/output.

const std = @import("std");
const builtin = @import("builtin");
pub const ansi = @import("ansi.zig");
pub const screen = @import("screen.zig");
const unicode = @import("../unicode.zig");

// Platform-specific implementation
const platform = if (builtin.os.tag == .windows)
    @import("platform/windows.zig")
else
    @import("platform/posix.zig");

pub const Size = platform.Size;
pub const TerminalError = platform.TerminalError;

pub const UnicodeWidthCapabilities = struct {
    mode_2027: bool = false,
    kitty_text_sizing: bool = false,
    strategy: unicode.WidthStrategy = .legacy_wcwidth,
};

pub const ImageCapabilities = struct {
    kitty_graphics: bool = false,
    iterm2_inline_image: bool = false,
    sixel: bool = false,
};

const Iterm2Capabilities = struct {
    inline_image: bool = false,
    sixel: bool = false,
};

pub const KittyImageFormat = enum(u16) {
    rgb = 24,
    rgba = 32,
    png = 100,
};

pub const KittyImageOptions = struct {
    format: KittyImageFormat = .png,
    width_cells: ?u16 = null,
    height_cells: ?u16 = null,
    image_id: ?u32 = null,
    placement_id: ?u32 = null,
    move_cursor: bool = true,
    quiet: bool = true,
    /// Z-index for layering. Negative = behind text, positive = above.
    z_index: ?i32 = null,
    /// Enable unicode placeholders for text-reflow participation.
    unicode_placeholder: bool = false,
    /// Pixel width of the image (required for RGB/RGBA direct data).
    pixel_width: ?u32 = null,
    /// Pixel height of the image (required for RGB/RGBA direct data).
    pixel_height: ?u32 = null,
};

pub const KittyImageFileOptions = struct {
    width_cells: ?u16 = null,
    height_cells: ?u16 = null,
    image_id: ?u32 = null,
    placement_id: ?u32 = null,
    move_cursor: bool = true,
    quiet: bool = true,
    z_index: ?i32 = null,
    unicode_placeholder: bool = false,
};

/// Options for transmitting an image to the Kitty cache without display.
pub const KittyTransmitOptions = struct {
    image_id: u32,
    format: KittyImageFormat = .png,
    quiet: bool = true,
    pixel_width: ?u32 = null,
    pixel_height: ?u32 = null,
};

/// Options for placing a previously cached Kitty image.
pub const KittyPlaceOptions = struct {
    image_id: u32,
    placement_id: ?u32 = null,
    width_cells: ?u16 = null,
    height_cells: ?u16 = null,
    move_cursor: bool = true,
    quiet: bool = true,
    z_index: ?i32 = null,
    unicode_placeholder: bool = false,
};

/// What to delete from the Kitty image cache.
pub const KittyDeleteTarget = union(enum) {
    by_id: u32,
    by_placement: struct { image_id: u32, placement_id: u32 },
    all,
};

pub const Iterm2ImageFileOptions = struct {
    width_cells: ?u16 = null,
    height_cells: ?u16 = null,
    preserve_aspect_ratio: bool = true,
    move_cursor: bool = true,
};

/// Options for in-memory iTerm2 image rendering.
pub const Iterm2ImageDataOptions = struct {
    width_cells: ?u16 = null,
    height_cells: ?u16 = null,
    preserve_aspect_ratio: bool = true,
    move_cursor: bool = true,
};

pub const ImageFileOptions = struct {
    width_cells: ?u16 = null,
    height_cells: ?u16 = null,
    preserve_aspect_ratio: bool = true,
    image_id: ?u32 = null,
    placement_id: ?u32 = null,
    move_cursor: bool = true,
    quiet: bool = true,
    z_index: ?i32 = null,
    unicode_placeholder: bool = false,
};

/// Options for rendering in-memory image data with auto protocol selection.
pub const ImageDataOptions = struct {
    format: KittyImageFormat = .png,
    pixel_width: ?u32 = null,
    pixel_height: ?u32 = null,
    width_cells: ?u16 = null,
    height_cells: ?u16 = null,
    preserve_aspect_ratio: bool = true,
    image_id: ?u32 = null,
    placement_id: ?u32 = null,
    move_cursor: bool = true,
    quiet: bool = true,
    z_index: ?i32 = null,
    unicode_placeholder: bool = false,
};

/// Preferred image protocol for protocol-selection overrides.
pub const ImageProtocol = enum {
    auto,
    kitty,
    iterm2,
    sixel,
};

pub const SixelImageFileOptions = struct {
    /// Optional max captured converter output (bytes).
    max_output_bytes: usize = 32 * 1024 * 1024,
    /// Optional pixel width hint for img2sixel (-w flag).
    width_pixels: ?u32 = null,
    /// Optional pixel height hint for img2sixel (-h flag).
    height_pixels: ?u32 = null,
};

/// OSC 52 clipboard target selector.
/// Standard values are `c`, `p`, `q`, `s`, or cut buffers `0`..`7`.
pub const Osc52Target = union(enum) {
    clipboard,
    primary,
    secondary,
    select,
    cut_buffer: u3,
    raw: []const u8,

    fn encode(self: Osc52Target, scratch: *[1]u8) []const u8 {
        return switch (self) {
            .clipboard => "c",
            .primary => "p",
            .secondary => "q",
            .select => "s",
            .cut_buffer => |n| blk: {
                scratch[0] = @as(u8, '0') + @as(u8, n);
                break :blk scratch[0..1];
            },
            .raw => |value| value,
        };
    }
};

/// OSC 52 passthrough strategy.
/// `tmux` and `dcs` wrap OSC inside DCS passthrough for multiplexers.
pub const Osc52Passthrough = enum {
    auto,
    none,
    tmux,
    dcs,
};

/// Default OSC 52 behavior for this terminal instance.
pub const Osc52Config = struct {
    /// Master switch for clipboard writes.
    enabled: bool = true,
    /// Allow OSC 52 clipboard queries (`?`) for reading clipboard content.
    query_enabled: bool = true,
    /// Require a TTY before sending OSC 52.
    require_tty: bool = true,
    /// Default target selection.
    target: Osc52Target = .clipboard,
    /// Sequence terminator (BEL is widely compatible).
    terminator: ansi.OscTerminator = .bel,
    /// Passthrough mode (`auto` detects tmux/screen-like environments).
    passthrough: Osc52Passthrough = .auto,
    /// Optional input payload limit (bytes). `null` = no library limit.
    max_bytes: ?usize = null,
    /// Query timeout for clipboard reads.
    query_timeout_ms: i32 = 180,
    /// Optional decoded output limit for clipboard reads.
    max_read_bytes: ?usize = null,
    /// Require selector match on responses (strict mode).
    strict_query_target: bool = false,
};

/// Per-call OSC 52 overrides.
pub const Osc52WriteOptions = struct {
    target: ?Osc52Target = null,
    terminator: ?ansi.OscTerminator = null,
    passthrough: ?Osc52Passthrough = null,
    require_tty: ?bool = null,
    max_bytes: ?usize = null,
};

/// Per-call OSC 52 clipboard query overrides.
pub const Osc52ReadOptions = struct {
    target: ?Osc52Target = null,
    terminator: ?ansi.OscTerminator = null,
    passthrough: ?Osc52Passthrough = null,
    require_tty: ?bool = null,
    timeout_ms: ?i32 = null,
    max_bytes: ?usize = null,
    strict_target: ?bool = null,
};

/// Terminal configuration options
pub const Config = struct {
    /// Use alternate screen buffer
    alt_screen: bool = true,
    /// Hide cursor during operation
    hide_cursor: bool = true,
    /// Enable mouse tracking
    mouse: bool = false,
    /// Enable bracketed paste mode
    bracketed_paste: bool = true,
    /// Custom input file (default: stdin)
    input: ?std.fs.File = null,
    /// Custom output file (default: stdout)
    output: ?std.fs.File = null,
    /// Enable Kitty keyboard protocol
    kitty_keyboard: bool = false,
    /// OSC 52 clipboard configuration
    osc52: Osc52Config = .{},
};

/// Terminal abstraction
pub const Terminal = struct {
    state: platform.State,
    config: Config,
    stdout: std.fs.File,
    stdin: std.fs.File,
    write_buffer: [4096]u8 = undefined,
    write_pos: usize = 0,
    pending_input: [8192]u8 = undefined,
    pending_input_len: usize = 0,
    unicode_width_caps: UnicodeWidthCapabilities = .{},
    image_caps: ImageCapabilities = .{},

    pub fn init(config: Config) !Terminal {
        const stdout = config.output orelse std.fs.File.stdout();
        const stdin = config.input orelse std.fs.File.stdin();

        var state = platform.State.init();
        // Apply custom fd overrides
        if (builtin.os.tag != .windows) {
            if (config.input) |inp| state.stdin_fd = inp.handle;
            if (config.output) |out| state.stdout_fd = out.handle;
        } else {
            if (config.input) |inp| state.stdin_handle = inp.handle;
            if (config.output) |out| state.stdout_handle = out.handle;
        }

        var term = Terminal{
            .state = state,
            .config = config,
            .stdout = stdout,
            .stdin = stdin,
        };

        try term.setup();
        return term;
    }

    pub fn deinit(self: *Terminal) void {
        self.cleanup();
    }

    pub fn setup(self: *Terminal) !void {
        // Setup signal handlers
        platform.setupSignals() catch {};

        // Enable raw mode
        try platform.enableRawMode(&self.state);

        // Enter alternate screen
        if (self.config.alt_screen) {
            try self.writeBytes(ansi.alt_screen_enter);
            self.state.in_alt_screen = true;
        }

        // Hide cursor
        if (self.config.hide_cursor) {
            try self.writeBytes(ansi.cursor_hide);
        }

        // Enable mouse
        if (self.config.mouse) {
            try self.writeBytes("\x1b[?1003h\x1b[?1006h");
            self.state.mouse_enabled = true;
        }

        // Enable bracketed paste
        if (self.config.bracketed_paste) {
            try self.writeBytes(ansi.bracketed_paste_enable);
        }

        // Enable Kitty keyboard protocol
        if (self.config.kitty_keyboard) {
            try self.writeBytes(ansi.kitty_keyboard_enable);
        }

        self.detectUnicodeWidthCapabilities();
        self.detectImageCapabilities();

        // Clear screen
        try self.writeBytes(ansi.screen_clear);
        try self.writeBytes(ansi.cursor_home);

        try self.flush();
    }

    pub fn cleanup(self: *Terminal) void {
        // Disable Kitty keyboard protocol
        if (self.config.kitty_keyboard) {
            self.writeBytes(ansi.kitty_keyboard_disable) catch {};
        }

        if (self.unicode_width_caps.mode_2027) {
            self.writeBytes(ansi.unicode_width_mode_disable) catch {};
            self.unicode_width_caps.mode_2027 = false;
        }

        // Disable bracketed paste
        if (self.config.bracketed_paste) {
            self.writeBytes(ansi.bracketed_paste_disable) catch {};
        }

        // Disable mouse
        if (self.state.mouse_enabled) {
            self.writeBytes("\x1b[?1006l\x1b[?1003l") catch {};
            self.state.mouse_enabled = false;
        }

        // Show cursor
        if (self.config.hide_cursor) {
            self.writeBytes(ansi.cursor_show) catch {};
        }

        // Exit alternate screen
        if (self.state.in_alt_screen) {
            self.writeBytes(ansi.alt_screen_exit) catch {};
            self.state.in_alt_screen = false;
        }

        // Reset attributes
        self.writeBytes(ansi.reset) catch {};

        self.flush() catch {};

        // Restore terminal mode — always runs even if writes above failed
        platform.disableRawMode(&self.state);
    }

    /// Write bytes to internal buffer
    fn writeBytes(self: *Terminal, bytes: []const u8) !void {
        for (bytes) |byte| {
            if (self.write_pos >= self.write_buffer.len) {
                try self.flush();
            }
            self.write_buffer[self.write_pos] = byte;
            self.write_pos += 1;
        }
    }

    /// Get terminal size
    pub fn getSize(self: *Terminal) !Size {
        return platform.getSize(if (builtin.os.tag == .windows)
            self.state.stdout_handle
        else
            self.state.stdout_fd);
    }

    /// Read input with timeout (in milliseconds)
    pub fn readInput(self: *Terminal, buffer: []u8, timeout_ms: i32) !usize {
        if (self.pending_input_len > 0) {
            const take = @min(buffer.len, self.pending_input_len);
            @memcpy(buffer[0..take], self.pending_input[0..take]);
            if (take < self.pending_input_len) {
                std.mem.copyForwards(u8, self.pending_input[0 .. self.pending_input_len - take], self.pending_input[take..self.pending_input_len]);
            }
            self.pending_input_len -= take;
            return take;
        }
        return self.readPlatformInput(buffer, timeout_ms);
    }

    /// Check if terminal was resized
    pub fn checkResize(self: *Terminal) bool {
        _ = self;
        return platform.checkResize();
    }

    /// Get a simple writer interface
    pub fn writer(self: *Terminal) Writer {
        return Writer{ .terminal = self };
    }

    /// Flush output buffer
    pub fn flush(self: *Terminal) !void {
        if (self.write_pos > 0) {
            self.stdout.writeAll(self.write_buffer[0..self.write_pos]) catch |err| {
                return switch (err) {
                    error.WouldBlock => error.WouldBlock,
                    else => error.BrokenPipe,
                };
            };
            self.write_pos = 0;
        }
    }

    /// Clear the screen
    pub fn clear(self: *Terminal) !void {
        try self.writeBytes(ansi.screen_clear);
        try self.writeBytes(ansi.cursor_home);
    }

    /// Move cursor to position (0-indexed)
    pub fn moveTo(self: *Terminal, row: u16, col: u16) !void {
        var buf: [32]u8 = undefined;
        const len = std.fmt.bufPrint(&buf, "\x1b[{d};{d}H", .{ row + 1, col + 1 }) catch return;
        try self.writeBytes(len);
    }

    /// Show the cursor
    pub fn showCursor(self: *Terminal) !void {
        try self.writeBytes(ansi.cursor_show);
    }

    /// Hide the cursor
    pub fn hideCursor(self: *Terminal) !void {
        try self.writeBytes(ansi.cursor_hide);
    }

    /// Enable mouse tracking
    pub fn enableMouse(self: *Terminal) !void {
        try self.writeBytes("\x1b[?1003h\x1b[?1006h");
        self.state.mouse_enabled = true;
    }

    /// Disable mouse tracking
    pub fn disableMouse(self: *Terminal) !void {
        try self.writeBytes("\x1b[?1006l\x1b[?1003l");
        self.state.mouse_enabled = false;
    }

    /// Set window title
    pub fn setTitle(self: *Terminal, title: []const u8) !void {
        try self.writeBytes("\x1b]0;");
        try self.writeBytes(title);
        try self.writeBytes("\x07");
    }

    /// Copy bytes to the system clipboard using OSC 52 with instance defaults.
    /// Returns `false` when disabled by config, rejected by local guardrails, or not suitable for this output.
    pub fn setClipboard(self: *Terminal, bytes: []const u8) !bool {
        return self.setClipboardWithOptions(bytes, .{});
    }

    /// Copy bytes to the system clipboard using OSC 52 with per-call overrides.
    pub fn setClipboardWithOptions(self: *Terminal, bytes: []const u8, options: Osc52WriteOptions) !bool {
        if (!self.config.osc52.enabled) return false;

        const require_tty = options.require_tty orelse self.config.osc52.require_tty;
        if (require_tty and !self.isTty()) return false;

        const max_bytes = options.max_bytes orelse self.config.osc52.max_bytes;
        if (max_bytes) |limit| {
            if (bytes.len > limit) return false;
        }

        const terminator = options.terminator orelse self.config.osc52.terminator;
        const passthrough_mode = options.passthrough orelse self.config.osc52.passthrough;
        const passthrough = self.resolveOsc52Passthrough(passthrough_mode);

        var target_scratch: [1]u8 = undefined;
        const target = (options.target orelse self.config.osc52.target).encode(&target_scratch);

        try ansi.osc52Start(self.writer(), target, passthrough);
        try self.writeBase64(bytes);
        try ansi.osc52End(self.writer(), terminator, passthrough);
        return true;
    }

    /// Query clipboard bytes via OSC 52 (`...?;?`).
    /// Returns `null` when unsupported, disabled, timed out, or rejected by guardrails.
    pub fn getClipboard(self: *Terminal, allocator: std.mem.Allocator) !?[]u8 {
        return self.getClipboardWithOptions(allocator, .{});
    }

    /// Query clipboard bytes via OSC 52 (`...?;?`) with per-call overrides.
    /// Returns `null` when unsupported, disabled, timed out, or rejected by guardrails.
    pub fn getClipboardWithOptions(self: *Terminal, allocator: std.mem.Allocator, options: Osc52ReadOptions) !?[]u8 {
        if (!self.config.osc52.enabled or !self.config.osc52.query_enabled) return null;

        const require_tty = options.require_tty orelse self.config.osc52.require_tty;
        if (require_tty and !self.isTty()) return null;

        const timeout_ms = options.timeout_ms orelse self.config.osc52.query_timeout_ms;
        const strict_target = options.strict_target orelse self.config.osc52.strict_query_target;
        const max_bytes = options.max_bytes orelse self.config.osc52.max_read_bytes;

        const terminator = options.terminator orelse self.config.osc52.terminator;
        const passthrough_mode = options.passthrough orelse self.config.osc52.passthrough;
        const passthrough = self.resolveOsc52Passthrough(passthrough_mode);

        var target_scratch: [1]u8 = undefined;
        const target = (options.target orelse self.config.osc52.target).encode(&target_scratch);

        try ansi.osc52Start(self.writer(), target, passthrough);
        try self.writeBytes("?");
        try ansi.osc52End(self.writer(), terminator, passthrough);
        try self.flush();

        var collected = std.array_list.Managed(u8).init(allocator);
        defer collected.deinit();

        const deadline_ms = std.time.milliTimestamp() + timeout_ms;
        while (std.time.milliTimestamp() < deadline_ms) {
            var chunk: [256]u8 = undefined;
            const n = self.readPlatformInput(&chunk, 30) catch 0;
            if (n == 0) continue;
            try collected.appendSlice(chunk[0..n]);

            if (parseOsc52Response(collected.items, target, strict_target)) |parsed| {
                const decoded = decodeOsc52Payload(allocator, parsed.payload_b64, max_bytes) catch null;
                self.queueInputExceptRange(collected.items, parsed.consume_start, parsed.consume_end);
                return decoded;
            }
        }

        self.queueInput(collected.items);
        return null;
    }

    /// Write a string at position
    pub fn writeAt(self: *Terminal, row: u16, col: u16, str: []const u8) !void {
        try self.moveTo(row, col);
        try self.writeBytes(str);
    }

    /// Check if stdin is a TTY
    pub fn isTty(self: *Terminal) bool {
        _ = self;
        return platform.isTty(if (builtin.os.tag == .windows)
            platform.State.init().stdin_handle
        else
            std.posix.STDIN_FILENO);
    }

    pub fn getUnicodeWidthCapabilities(self: *const Terminal) UnicodeWidthCapabilities {
        return self.unicode_width_caps;
    }

    pub fn getImageCapabilities(self: *const Terminal) ImageCapabilities {
        return self.image_caps;
    }

    pub fn supportsKittyGraphics(self: *const Terminal) bool {
        return self.image_caps.kitty_graphics;
    }

    pub fn supportsIterm2InlineImages(self: *const Terminal) bool {
        return self.image_caps.iterm2_inline_image;
    }

    pub fn supportsImages(self: *const Terminal) bool {
        return self.supportsKittyGraphics() or self.supportsIterm2InlineImages() or self.supportsSixel();
    }

    pub fn supportsSixel(self: *const Terminal) bool {
        return self.image_caps.sixel;
    }

    /// Draw image bytes using Kitty graphics protocol (`t=d`).
    /// Returns `false` when unsupported or no data is provided.
    pub fn drawKittyImage(self: *Terminal, image_data: []const u8, options: KittyImageOptions) !bool {
        if (!self.image_caps.kitty_graphics or image_data.len == 0) return false;

        var params_buf: [256]u8 = undefined;
        var stream = std.io.fixedBufferStream(&params_buf);
        const params_writer = stream.writer();

        try params_writer.print("a=T,t=d,f={d}", .{@intFromEnum(options.format)});
        if (options.quiet) try params_writer.writeAll(",q=2");
        if (options.width_cells) |cols| try params_writer.print(",c={d}", .{cols});
        if (options.height_cells) |rows| try params_writer.print(",r={d}", .{rows});
        if (options.image_id) |id| try params_writer.print(",i={d}", .{id});
        if (options.placement_id) |id| try params_writer.print(",p={d}", .{id});
        if (!options.move_cursor) try params_writer.writeAll(",C=1");
        if (options.z_index) |z| try params_writer.print(",z={d}", .{z});
        if (options.unicode_placeholder) try params_writer.writeAll(",U=1");
        if (options.pixel_width) |pw| try params_writer.print(",s={d}", .{pw});
        if (options.pixel_height) |ph| try params_writer.print(",v={d}", .{ph});

        try self.sendKittyGraphicsPayload(stream.getWritten(), image_data);
        return true;
    }

    /// Draw a PNG image by file path using Kitty graphics protocol (`t=f`).
    /// Returns `false` when unsupported or path is empty.
    pub fn drawKittyImageFromFile(self: *Terminal, path: []const u8, options: KittyImageFileOptions) !bool {
        if (!self.image_caps.kitty_graphics or path.len == 0) return false;

        var params_buf: [256]u8 = undefined;
        var stream = std.io.fixedBufferStream(&params_buf);
        const params_writer = stream.writer();

        try params_writer.writeAll("a=T,t=f,f=100");
        if (options.quiet) try params_writer.writeAll(",q=2");
        if (options.width_cells) |cols| try params_writer.print(",c={d}", .{cols});
        if (options.height_cells) |rows| try params_writer.print(",r={d}", .{rows});
        if (options.image_id) |id| try params_writer.print(",i={d}", .{id});
        if (options.placement_id) |id| try params_writer.print(",p={d}", .{id});
        if (!options.move_cursor) try params_writer.writeAll(",C=1");
        if (options.z_index) |z| try params_writer.print(",z={d}", .{z});
        if (options.unicode_placeholder) try params_writer.writeAll(",U=1");

        try self.sendKittyGraphicsPayload(stream.getWritten(), path);
        return true;
    }

    /// Transmit an image to the Kitty cache without displaying it (`a=t`).
    /// Use `placeKittyImage` later to display it by ID.
    pub fn transmitKittyImage(self: *Terminal, payload: []const u8, options: KittyTransmitOptions) !bool {
        if (!self.image_caps.kitty_graphics or payload.len == 0) return false;

        var params_buf: [256]u8 = undefined;
        var stream = std.io.fixedBufferStream(&params_buf);
        const params_writer = stream.writer();

        try params_writer.print("a=t,i={d}", .{options.image_id});
        if (options.quiet) try params_writer.writeAll(",q=2");

        switch (options.format) {
            .png => try params_writer.writeAll(",f=100"),
            .rgb => {
                try params_writer.writeAll(",f=24");
                if (options.pixel_width) |pw| try params_writer.print(",s={d}", .{pw});
                if (options.pixel_height) |ph| try params_writer.print(",v={d}", .{ph});
            },
            .rgba => {
                try params_writer.writeAll(",f=32");
                if (options.pixel_width) |pw| try params_writer.print(",s={d}", .{pw});
                if (options.pixel_height) |ph| try params_writer.print(",v={d}", .{ph});
            },
        }

        try self.sendKittyGraphicsPayload(stream.getWritten(), payload);
        return true;
    }

    /// Transmit an image file to the Kitty cache without displaying it (`a=t,t=f`).
    pub fn transmitKittyImageFromFile(self: *Terminal, path: []const u8, options: KittyTransmitOptions) !bool {
        if (!self.image_caps.kitty_graphics or path.len == 0) return false;
        if (!fileExists(path)) return false;

        var params_buf: [256]u8 = undefined;
        var stream = std.io.fixedBufferStream(&params_buf);
        const params_writer = stream.writer();

        try params_writer.print("a=t,t=f,f=100,i={d}", .{options.image_id});
        if (options.quiet) try params_writer.writeAll(",q=2");

        try self.sendKittyGraphicsPayload(stream.getWritten(), path);
        return true;
    }

    /// Display a previously cached image by ID (`a=p`).
    pub fn placeKittyImage(self: *Terminal, options: KittyPlaceOptions) !bool {
        if (!self.image_caps.kitty_graphics) return false;

        var params_buf: [256]u8 = undefined;
        var stream = std.io.fixedBufferStream(&params_buf);
        const params_writer = stream.writer();

        try params_writer.print("a=p,i={d}", .{options.image_id});
        if (options.quiet) try params_writer.writeAll(",q=2");
        if (options.placement_id) |id| try params_writer.print(",p={d}", .{id});
        if (options.width_cells) |cols| try params_writer.print(",c={d}", .{cols});
        if (options.height_cells) |rows| try params_writer.print(",r={d}", .{rows});
        if (!options.move_cursor) try params_writer.writeAll(",C=1");
        if (options.z_index) |z| try params_writer.print(",z={d}", .{z});
        if (options.unicode_placeholder) try params_writer.writeAll(",U=1");

        // Virtual placement has no payload.
        try ansi.kittyGraphics(self.writer(), stream.getWritten(), "");
        return true;
    }

    /// Delete images/placements from the Kitty cache (`a=d`).
    pub fn deleteKittyImage(self: *Terminal, target: KittyDeleteTarget) !bool {
        if (!self.image_caps.kitty_graphics) return false;

        var params_buf: [128]u8 = undefined;
        var stream = std.io.fixedBufferStream(&params_buf);
        const params_writer = stream.writer();

        try params_writer.writeAll("a=d,q=2");
        switch (target) {
            .by_id => |id| try params_writer.print(",d=I,i={d}", .{id}),
            .by_placement => |bp| try params_writer.print(",d=I,i={d},p={d}", .{ bp.image_id, bp.placement_id }),
            .all => try params_writer.writeAll(",d=A"),
        }

        try ansi.kittyGraphics(self.writer(), stream.getWritten(), "");
        return true;
    }

    /// Draw a file image via iTerm2 inline image protocol (`OSC 1337`).
    /// Returns `false` when unsupported or path is empty.
    pub fn drawIterm2ImageFromFile(self: *Terminal, path: []const u8, options: Iterm2ImageFileOptions) !bool {
        if (!self.image_caps.iterm2_inline_image or path.len == 0) return false;
        if (!fileExists(path)) return false;

        var file = try std.fs.cwd().openFile(path, .{});
        defer file.close();
        const stat = try file.stat();

        var params_buf: [256]u8 = undefined;
        var stream = std.io.fixedBufferStream(&params_buf);
        const params_writer = stream.writer();

        try params_writer.writeAll("inline=1");
        if (options.width_cells) |cols| try params_writer.print(";width={d}", .{cols});
        if (options.height_cells) |rows| try params_writer.print(";height={d}", .{rows});
        try params_writer.print(";preserveAspectRatio={d}", .{if (options.preserve_aspect_ratio) @as(u8, 1) else @as(u8, 0)});
        if (!options.move_cursor) try params_writer.writeAll(";doNotMoveCursor=1");
        try params_writer.print(";size={d}", .{stat.size});
        const file_name = std.fs.path.basename(path);
        const file_name_b64_len = std.base64.standard.Encoder.calcSize(file_name.len);
        if (file_name_b64_len <= 512) {
            var file_name_b64_buf: [512]u8 = undefined;
            const file_name_b64 = std.base64.standard.Encoder.encode(file_name_b64_buf[0..file_name_b64_len], file_name);
            try params_writer.print(";name={s}", .{file_name_b64});
        }

        try self.sendIterm2InlineImagePayload(stream.getWritten(), &file, stat.size);
        return true;
    }

    /// Draw in-memory image data via iTerm2 inline image protocol.
    /// Returns `false` when unsupported or data is empty.
    pub fn drawIterm2ImageData(self: *Terminal, data: []const u8, options: Iterm2ImageDataOptions) !bool {
        if (!self.image_caps.iterm2_inline_image or data.len == 0) return false;

        var params_buf: [256]u8 = undefined;
        var stream = std.io.fixedBufferStream(&params_buf);
        const params_writer = stream.writer();

        try params_writer.writeAll("inline=1");
        if (options.width_cells) |cols| try params_writer.print(";width={d}", .{cols});
        if (options.height_cells) |rows| try params_writer.print(";height={d}", .{rows});
        try params_writer.print(";preserveAspectRatio={d}", .{if (options.preserve_aspect_ratio) @as(u8, 1) else @as(u8, 0)});
        if (!options.move_cursor) try params_writer.writeAll(";doNotMoveCursor=1");
        try params_writer.print(";size={d}", .{data.len});

        try self.sendIterm2InlineImageDataPayload(stream.getWritten(), data);
        return true;
    }

    /// Draw an image file using the best available protocol.
    /// Prefers Kitty graphics, then iTerm2 inline images, then Sixel.
    /// Use `protocol` to override the auto-selection.
    pub fn drawImageFromFile(self: *Terminal, path: []const u8, options: ImageFileOptions) !bool {
        return self.drawImageFromFileWithProtocol(path, options, .auto);
    }

    /// Draw an image file using a specific or auto-selected protocol.
    pub fn drawImageFromFileWithProtocol(self: *Terminal, path: []const u8, options: ImageFileOptions, protocol: ImageProtocol) !bool {
        if (path.len == 0) return false;
        if (!fileExists(path)) return false;

        switch (protocol) {
            .kitty => {
                if (self.image_caps.kitty_graphics) {
                    return self.drawKittyImageFromFile(path, .{
                        .width_cells = options.width_cells,
                        .height_cells = options.height_cells,
                        .image_id = options.image_id,
                        .placement_id = options.placement_id,
                        .move_cursor = options.move_cursor,
                        .quiet = options.quiet,
                        .z_index = options.z_index,
                        .unicode_placeholder = options.unicode_placeholder,
                    });
                }
                return false;
            },
            .iterm2 => {
                if (self.image_caps.iterm2_inline_image) {
                    return self.drawIterm2ImageFromFile(path, .{
                        .width_cells = options.width_cells,
                        .height_cells = options.height_cells,
                        .preserve_aspect_ratio = options.preserve_aspect_ratio,
                        .move_cursor = options.move_cursor,
                    });
                }
                return false;
            },
            .sixel => {
                if (self.image_caps.sixel) {
                    return self.drawSixelFromFile(path, .{});
                }
                return false;
            },
            .auto => {
                if (self.image_caps.kitty_graphics) {
                    return self.drawKittyImageFromFile(path, .{
                        .width_cells = options.width_cells,
                        .height_cells = options.height_cells,
                        .image_id = options.image_id,
                        .placement_id = options.placement_id,
                        .move_cursor = options.move_cursor,
                        .quiet = options.quiet,
                        .z_index = options.z_index,
                        .unicode_placeholder = options.unicode_placeholder,
                    });
                }
                if (self.image_caps.iterm2_inline_image) {
                    return self.drawIterm2ImageFromFile(path, .{
                        .width_cells = options.width_cells,
                        .height_cells = options.height_cells,
                        .preserve_aspect_ratio = options.preserve_aspect_ratio,
                        .move_cursor = options.move_cursor,
                    });
                }
                if (self.image_caps.sixel) {
                    return self.drawSixelFromFile(path, .{});
                }
                return false;
            },
        }
    }

    /// Draw in-memory image data using the best available protocol.
    pub fn drawImageData(self: *Terminal, data: []const u8, options: ImageDataOptions) !bool {
        return self.drawImageDataWithProtocol(data, options, .auto);
    }

    /// Draw in-memory image data using a specific or auto-selected protocol.
    pub fn drawImageDataWithProtocol(self: *Terminal, data: []const u8, options: ImageDataOptions, protocol: ImageProtocol) !bool {
        if (data.len == 0) return false;

        switch (protocol) {
            .kitty => {
                if (self.image_caps.kitty_graphics) {
                    return self.drawKittyImage(data, .{
                        .format = options.format,
                        .width_cells = options.width_cells,
                        .height_cells = options.height_cells,
                        .image_id = options.image_id,
                        .placement_id = options.placement_id,
                        .move_cursor = options.move_cursor,
                        .quiet = options.quiet,
                        .z_index = options.z_index,
                        .unicode_placeholder = options.unicode_placeholder,
                        .pixel_width = options.pixel_width,
                        .pixel_height = options.pixel_height,
                    });
                }
                return false;
            },
            .iterm2 => {
                if (self.image_caps.iterm2_inline_image) {
                    return self.drawIterm2ImageData(data, .{
                        .width_cells = options.width_cells,
                        .height_cells = options.height_cells,
                        .preserve_aspect_ratio = options.preserve_aspect_ratio,
                        .move_cursor = options.move_cursor,
                    });
                }
                return false;
            },
            .sixel => {
                // Sixel only supports pre-encoded data or file paths.
                if (self.image_caps.sixel) {
                    self.sendSixelPayload(data) catch return false;
                    return true;
                }
                return false;
            },
            .auto => {
                if (self.image_caps.kitty_graphics) {
                    return self.drawKittyImage(data, .{
                        .format = options.format,
                        .width_cells = options.width_cells,
                        .height_cells = options.height_cells,
                        .image_id = options.image_id,
                        .placement_id = options.placement_id,
                        .move_cursor = options.move_cursor,
                        .quiet = options.quiet,
                        .z_index = options.z_index,
                        .unicode_placeholder = options.unicode_placeholder,
                        .pixel_width = options.pixel_width,
                        .pixel_height = options.pixel_height,
                    });
                }
                if (self.image_caps.iterm2_inline_image) {
                    return self.drawIterm2ImageData(data, .{
                        .width_cells = options.width_cells,
                        .height_cells = options.height_cells,
                        .preserve_aspect_ratio = options.preserve_aspect_ratio,
                        .move_cursor = options.move_cursor,
                    });
                }
                if (self.image_caps.sixel) {
                    self.sendSixelPayload(data) catch return false;
                    return true;
                }
                return false;
            },
        }
    }

    /// Draw a Sixel image from file.
    /// Supports either:
    /// - pre-encoded `.sixel`/`.six` data files, or
    /// - regular image files converted through `img2sixel` when available.
    pub fn drawSixelFromFile(self: *Terminal, path: []const u8, options: SixelImageFileOptions) !bool {
        if (!self.image_caps.sixel or path.len == 0) return false;
        if (!fileExists(path)) return false;

        if (isSixelDataPath(path)) {
            var file = try std.fs.cwd().openFile(path, .{});
            defer file.close();
            try self.sendSixelPayloadFromFile(&file);
            return true;
        }

        if (!commandExists("img2sixel")) return false;

        var argv_buf: [6][]const u8 = undefined;
        var argc: usize = 0;
        argv_buf[argc] = "img2sixel";
        argc += 1;
        var w_buf: [16]u8 = undefined;
        var h_buf: [16]u8 = undefined;
        if (options.width_pixels) |wp| {
            argv_buf[argc] = "-w";
            argc += 1;
            argv_buf[argc] = std.fmt.bufPrint(&w_buf, "{d}", .{wp}) catch "0";
            argc += 1;
        }
        if (options.height_pixels) |hp| {
            argv_buf[argc] = "-h";
            argc += 1;
            argv_buf[argc] = std.fmt.bufPrint(&h_buf, "{d}", .{hp}) catch "0";
            argc += 1;
        }
        argv_buf[argc] = path;
        argc += 1;

        const result = try std.process.Child.run(.{
            .allocator = std.heap.page_allocator,
            .argv = argv_buf[0..argc],
            .max_output_bytes = options.max_output_bytes,
        });
        defer std.heap.page_allocator.free(result.stdout);
        defer std.heap.page_allocator.free(result.stderr);

        switch (result.term) {
            .Exited => |code| if (code != 0) return error.BrokenPipe,
            else => return error.BrokenPipe,
        }

        try self.sendSixelPayload(result.stdout);
        return true;
    }

    fn detectUnicodeWidthCapabilities(self: *Terminal) void {
        self.unicode_width_caps = .{
            .kitty_text_sizing = self.queryKittyTextSizingSupport() catch false,
        };

        if (!self.isTty()) {
            return;
        }

        if (builtin.os.tag != .windows) {
            self.unicode_width_caps.mode_2027 = self.queryMode2027Support() catch false;
            if (self.unicode_width_caps.mode_2027) {
                self.writeBytes(ansi.unicode_width_mode_enable) catch {};
            }
        }

        self.unicode_width_caps.strategy = self.selectWidthStrategy();
    }

    fn detectImageCapabilities(self: *Terminal) void {
        if (!self.isTty()) {
            self.image_caps = .{};
            return;
        }

        const term_features_owned = std.process.getEnvVarOwned(std.heap.page_allocator, "TERM_FEATURES") catch null;
        defer if (term_features_owned) |value| std.heap.page_allocator.free(value);
        const term_features = if (term_features_owned) |value| value else "";

        const kitty_candidate = looksLikeKittyTerminal() or
            envVarEquals("TERM_PROGRAM", "WezTerm") or
            envVarContains("TERM", "wezterm") or
            envVarContains("TERM", "ghostty");
        const iterm_candidate = looksLikeIterm2Terminal() or
            envVarEquals("TERM_PROGRAM", "WezTerm");
        const in_multiplexer = isInsideMultiplexer();

        var kitty = false;
        var iterm = iterm_candidate or termFeaturesContain(term_features, "F");
        var sixel = looksLikeSixelTerminal() or termFeaturesContain(term_features, "Sx");

        if (kitty_candidate) {
            kitty = self.queryKittyGraphicsSupport() catch false;
            // Keep an env fallback only outside multiplexers where probe failures are uncommon.
            if (!kitty and !in_multiplexer) {
                kitty = envVarExists("KITTY_WINDOW_ID");
            }
        }

        if (iterm_candidate or term_features.len > 0) {
            if (self.queryIterm2Capabilities() catch null) |caps| {
                iterm = iterm or caps.inline_image;
                sixel = sixel or caps.sixel;
            }
        }

        if (!sixel) sixel = self.queryPrimaryDeviceAttributesHasParam(4) catch false;

        self.image_caps = .{
            .kitty_graphics = kitty,
            .iterm2_inline_image = iterm,
            .sixel = sixel,
        };
    }

    const Osc52ParsedResponse = struct {
        payload_b64: []const u8,
        consume_start: usize,
        consume_end: usize,
    };

    fn parseOsc52Response(bytes: []const u8, expected_target: []const u8, strict_target: bool) ?Osc52ParsedResponse {
        const prefix = "\x1b]52;";
        var search_from: usize = 0;

        while (search_from < bytes.len) {
            const start = std.mem.indexOfPos(u8, bytes, search_from, prefix) orelse return null;
            const selector_start = start + prefix.len;
            const selector_end = std.mem.indexOfScalarPos(u8, bytes, selector_start, ';') orelse return null;
            const payload_start = selector_end + 1;
            const osc_end = indexOfOscTerminator(bytes, payload_start) orelse return null;
            const osc_term_len: usize = if (bytes[osc_end] == 0x07) 1 else 2;

            const selector = bytes[selector_start..selector_end];
            if (strict_target and !std.mem.eql(u8, selector, expected_target)) {
                search_from = selector_end + 1;
                continue;
            }

            var payload_end = osc_end;
            if (start > 0 and bytes[start - 1] == 0x1b and bytes[osc_end] == 0x1b and osc_end + 1 < bytes.len and bytes[osc_end + 1] == '\\') {
                // DCS passthrough can encode inner ST as ESC ESC \.
                if (payload_end > payload_start) payload_end -= 1;
            }

            var consume_start = start;
            var consume_end = osc_end + osc_term_len;

            if (findOpenDcsStart(bytes, start)) |dcs_start| {
                if (indexOfSt(bytes, consume_end)) |outer_st| {
                    consume_start = dcs_start;
                    consume_end = outer_st + 2;
                }
            }

            return .{
                .payload_b64 = bytes[payload_start..payload_end],
                .consume_start = consume_start,
                .consume_end = consume_end,
            };
        }

        return null;
    }

    fn findOpenDcsStart(bytes: []const u8, pos: usize) ?usize {
        if (pos == 0) return null;

        var i: usize = 0;
        var open: ?usize = null;
        while (i + 1 < pos) : (i += 1) {
            if (bytes[i] != 0x1b) continue;
            if (bytes[i + 1] == 'P') {
                open = i;
                i += 1;
                continue;
            }
            if (bytes[i + 1] == '\\') {
                open = null;
                i += 1;
                continue;
            }
        }
        return open;
    }

    fn decodeOsc52Payload(allocator: std.mem.Allocator, payload_b64: []const u8, max_bytes: ?usize) !?[]u8 {
        if (payload_b64.len == 0 or (payload_b64.len == 1 and payload_b64[0] == '?')) return null;

        const decoder = std.base64.standard.Decoder;
        const out_len = decoder.calcSizeForSlice(payload_b64) catch return null;

        if (max_bytes) |limit| {
            if (out_len > limit) return null;
        }

        const out = try allocator.alloc(u8, out_len);
        errdefer allocator.free(out);
        _ = decoder.decode(out, payload_b64) catch return null;
        return out;
    }

    fn readPlatformInput(self: *Terminal, buffer: []u8, timeout_ms: i32) !usize {
        return platform.readInput(&self.state, buffer, timeout_ms);
    }

    fn queueInput(self: *Terminal, bytes: []const u8) void {
        if (bytes.len == 0) return;

        const free_space = self.pending_input.len - self.pending_input_len;
        const take = @min(bytes.len, free_space);
        if (take == 0) return;

        @memcpy(self.pending_input[self.pending_input_len .. self.pending_input_len + take], bytes[0..take]);
        self.pending_input_len += take;
    }

    fn queueInputExceptRange(self: *Terminal, bytes: []const u8, start: usize, end: usize) void {
        if (start > 0) {
            self.queueInput(bytes[0..start]);
        }
        if (end < bytes.len) {
            self.queueInput(bytes[end..]);
        }
    }

    fn resolveOsc52Passthrough(self: *const Terminal, mode: Osc52Passthrough) ansi.Osc52Passthrough {
        _ = self;
        return switch (mode) {
            .none => .none,
            .tmux => .tmux,
            .dcs => .dcs,
            .auto => blk: {
                if (envVarExists("TMUX")) break :blk .tmux;
                if (envVarContains("TERM", "screen")) break :blk .dcs;
                break :blk .none;
            },
        };
    }

    fn writeBase64(self: *Terminal, bytes: []const u8) !void {
        const encoder = std.base64.standard.Encoder;
        var b64_buf: [4096]u8 = undefined;
        const raw_chunk_max: usize = (b64_buf.len / 4) * 3;

        var src_index: usize = 0;
        while (src_index < bytes.len) {
            const take = @min(bytes.len - src_index, raw_chunk_max);
            const chunk = bytes[src_index .. src_index + take];
            const encoded_len = encoder.calcSize(chunk.len);
            const encoded = encoder.encode(b64_buf[0..encoded_len], chunk);
            try self.writeBytes(encoded);
            src_index += take;
        }
    }

    fn sendKittyGraphicsPayload(self: *Terminal, first_params: []const u8, payload: []const u8) !void {
        const encoder = std.base64.standard.Encoder;
        var b64_buf: [4096]u8 = undefined;
        const raw_chunk_max: usize = (b64_buf.len / 4) * 3;

        var src_index: usize = 0;
        var first = true;

        while (true) {
            const remaining = payload.len - src_index;
            const take = @min(remaining, raw_chunk_max);
            const chunk = payload[src_index .. src_index + take];

            const encoded_len = encoder.calcSize(chunk.len);
            const encoded = encoder.encode(b64_buf[0..encoded_len], chunk);
            const has_more = src_index + take < payload.len;

            if (first) {
                var first_chunk_params: [192]u8 = undefined;
                const params = try std.fmt.bufPrint(
                    &first_chunk_params,
                    "{s},m={d}",
                    .{ first_params, if (has_more) @as(u8, 1) else @as(u8, 0) },
                );
                try ansi.kittyGraphics(self.writer(), params, encoded);
                first = false;
            } else {
                const params = if (has_more) "m=1" else "m=0";
                try ansi.kittyGraphics(self.writer(), params, encoded);
            }

            if (!has_more) break;
            src_index += take;
        }
    }

    fn sendIterm2InlineImagePayload(self: *Terminal, params: []const u8, file: *std.fs.File, file_size: u64) !void {
        const encoder = std.base64.standard.Encoder;
        var raw_buf: [3072]u8 = undefined;
        var b64_buf: [4096]u8 = undefined;
        const encoded_total = std.math.cast(usize, encoder.calcSize(@intCast(file_size))) orelse std.math.maxInt(usize);
        const single_sequence_soft_limit: usize = 750 * 1024;

        if (encoded_total <= single_sequence_soft_limit) {
            try self.writeBytes(ansi.OSC ++ "1337;File=");
            try self.writeBytes(params);
            try self.writeBytes(":");

            while (true) {
                const n = try file.read(&raw_buf);
                if (n == 0) break;
                const encoded_len = encoder.calcSize(n);
                const encoded = encoder.encode(b64_buf[0..encoded_len], raw_buf[0..n]);
                try self.writeBytes(encoded);
            }
            try self.writeBytes("\x07");
            return;
        }

        // iTerm2 supports multipart transfer to avoid oversized OSC sequences.
        try self.writeBytes(ansi.OSC ++ "1337;MultipartFile=");
        try self.writeBytes(params);
        try self.writeBytes("\x07");

        while (true) {
            const n = try file.read(&raw_buf);
            if (n == 0) break;
            const encoded_len = encoder.calcSize(n);
            const encoded = encoder.encode(b64_buf[0..encoded_len], raw_buf[0..n]);
            try self.writeBytes(ansi.OSC ++ "1337;FilePart=");
            try self.writeBytes(encoded);
            try self.writeBytes("\x07");
        }

        try self.writeBytes(ansi.OSC ++ "1337;FileEnd\x07");
    }

    fn sendIterm2InlineImageDataPayload(self: *Terminal, params: []const u8, data: []const u8) !void {
        const encoder = std.base64.standard.Encoder;
        const encoded_total = encoder.calcSize(data.len);
        const single_sequence_soft_limit: usize = 750 * 1024;

        if (encoded_total <= single_sequence_soft_limit) {
            try self.writeBytes(ansi.OSC ++ "1337;File=");
            try self.writeBytes(params);
            try self.writeBytes(":");

            var src_index: usize = 0;
            var b64_buf: [4096]u8 = undefined;
            const raw_chunk_max: usize = (b64_buf.len / 4) * 3;
            while (src_index < data.len) {
                const take = @min(data.len - src_index, raw_chunk_max);
                const chunk = data[src_index .. src_index + take];
                const encoded_len = encoder.calcSize(chunk.len);
                const encoded = encoder.encode(b64_buf[0..encoded_len], chunk);
                try self.writeBytes(encoded);
                src_index += take;
            }
            try self.writeBytes("\x07");
            return;
        }

        // Multipart transfer for large payloads.
        try self.writeBytes(ansi.OSC ++ "1337;MultipartFile=");
        try self.writeBytes(params);
        try self.writeBytes("\x07");

        var src_index: usize = 0;
        var b64_buf: [4096]u8 = undefined;
        const raw_chunk_max: usize = (b64_buf.len / 4) * 3;
        while (src_index < data.len) {
            const take = @min(data.len - src_index, raw_chunk_max);
            const chunk = data[src_index .. src_index + take];
            const encoded_len = encoder.calcSize(chunk.len);
            const encoded = encoder.encode(b64_buf[0..encoded_len], chunk);
            try self.writeBytes(ansi.OSC ++ "1337;FilePart=");
            try self.writeBytes(encoded);
            try self.writeBytes("\x07");
            src_index += take;
        }

        try self.writeBytes(ansi.OSC ++ "1337;FileEnd\x07");
    }

    fn sendSixelPayloadFromFile(self: *Terminal, file: *std.fs.File) !void {
        var payload_buf: [4096]u8 = undefined;
        var first_read = true;
        var wrapped = false;

        while (true) {
            const n = try file.read(&payload_buf);
            if (n == 0) break;
            const chunk = payload_buf[0..n];

            if (first_read) {
                first_read = false;
                if (isLikelyFullSixelSequence(chunk)) {
                    wrapped = true;
                } else {
                    try self.writeBytes(ansi.DCS ++ "q");
                }
            }
            try self.writeBytes(chunk);
        }

        if (!first_read and !wrapped) {
            try self.writeBytes(ansi.ST);
        }
    }

    fn sendSixelPayload(self: *Terminal, bytes: []const u8) !void {
        if (bytes.len == 0) return;
        if (isLikelyFullSixelSequence(bytes)) {
            try self.writeBytes(bytes);
            return;
        }
        try self.writeBytes(ansi.DCS ++ "q");
        try self.writeBytes(bytes);
        try self.writeBytes(ansi.ST);
    }

    fn queryKittyGraphicsSupport(self: *Terminal) !bool {
        const probe_id: u32 = 9931;
        self.drainInput();
        try ansi.kittyGraphics(self.writer(), "a=q,i=9931,s=1,v=1,t=d,f=24", "AAAA");
        try self.flush();

        var collected: [1024]u8 = undefined;
        var collected_len: usize = 0;
        const deadline_ms = std.time.milliTimestamp() + 180;

        while (std.time.milliTimestamp() < deadline_ms) {
            var chunk: [128]u8 = undefined;
            const n = self.readInput(&chunk, 30) catch 0;
            if (n == 0) continue;

            const copy_len = @min(n, collected.len - collected_len);
            if (copy_len > 0) {
                @memcpy(collected[collected_len .. collected_len + copy_len], chunk[0..copy_len]);
                collected_len += copy_len;
            }

            if (parseKittyGraphicsProbeResponse(collected[0..collected_len], probe_id)) |supported| {
                return supported;
            }
        }

        return false;
    }

    fn parseKittyGraphicsProbeResponse(bytes: []const u8, probe_id: u32) ?bool {
        const prefix = "\x1b_G";
        var search_from: usize = 0;

        var id_buf: [24]u8 = undefined;
        const expected_id = std.fmt.bufPrint(&id_buf, "i={d}", .{probe_id}) catch return null;

        while (search_from < bytes.len) {
            const start = std.mem.indexOfPos(u8, bytes, search_from, prefix) orelse return null;
            const content_start = start + prefix.len;
            const semicolon = std.mem.indexOfScalarPos(u8, bytes, content_start, ';') orelse return null;
            const st_index = indexOfSt(bytes, semicolon + 1) orelse return null;

            const params = bytes[content_start..semicolon];
            const payload = bytes[semicolon + 1 .. st_index];

            if (std.mem.indexOf(u8, params, expected_id) != null) {
                return std.mem.startsWith(u8, payload, "OK");
            }

            search_from = st_index + 2;
        }

        return null;
    }

    fn queryIterm2Capabilities(self: *Terminal) !?Iterm2Capabilities {
        self.drainInput();
        try self.writeBytes(ansi.OSC ++ "1337;Capabilities\x07");
        try self.flush();

        var collected: [2048]u8 = undefined;
        var collected_len: usize = 0;
        const deadline_ms = std.time.milliTimestamp() + 180;

        while (std.time.milliTimestamp() < deadline_ms) {
            var chunk: [128]u8 = undefined;
            const n = self.readInput(&chunk, 30) catch 0;
            if (n == 0) continue;

            const copy_len = @min(n, collected.len - collected_len);
            if (copy_len > 0) {
                @memcpy(collected[collected_len .. collected_len + copy_len], chunk[0..copy_len]);
                collected_len += copy_len;
            }

            if (parseIterm2CapabilitiesResponse(collected[0..collected_len])) |caps| {
                return caps;
            }
        }

        return null;
    }

    fn parseIterm2CapabilitiesResponse(bytes: []const u8) ?Iterm2Capabilities {
        const prefix = "\x1b]1337;Capabilities=";
        const start = std.mem.indexOf(u8, bytes, prefix) orelse return null;
        const payload_start = start + prefix.len;
        const end = indexOfOscTerminator(bytes, payload_start) orelse return null;
        const payload = bytes[payload_start..end];
        return .{
            .inline_image = termFeaturesContain(payload, "F"),
            .sixel = termFeaturesContain(payload, "Sx"),
        };
    }

    fn queryPrimaryDeviceAttributesHasParam(self: *Terminal, needle: u16) !bool {
        self.drainInput();
        try self.writeBytes(ansi.CSI ++ "c");
        try self.flush();

        var collected: [1024]u8 = undefined;
        var collected_len: usize = 0;
        const deadline_ms = std.time.milliTimestamp() + 120;

        while (std.time.milliTimestamp() < deadline_ms) {
            var chunk: [128]u8 = undefined;
            const n = self.readInput(&chunk, 25) catch 0;
            if (n == 0) continue;

            const copy_len = @min(n, collected.len - collected_len);
            if (copy_len > 0) {
                @memcpy(collected[collected_len .. collected_len + copy_len], chunk[0..copy_len]);
                collected_len += copy_len;
            }

            if (parsePrimaryDeviceAttributes(collected[0..collected_len])) |params| {
                return primaryDeviceAttributesHasParam(params, needle);
            }
        }

        return false;
    }

    fn parsePrimaryDeviceAttributes(bytes: []const u8) ?[]const u8 {
        const prefix = "\x1b[";
        var search_from: usize = 0;

        while (search_from < bytes.len) {
            const start = std.mem.indexOfPos(u8, bytes, search_from, prefix) orelse return null;
            var i = start + prefix.len;

            if (i < bytes.len and bytes[i] == '?') i += 1;
            const params_start = i;

            while (i < bytes.len and ((bytes[i] >= '0' and bytes[i] <= '9') or bytes[i] == ';')) : (i += 1) {}
            if (i >= bytes.len) return null;

            if (bytes[i] == 'c' and i > params_start) {
                return bytes[params_start..i];
            }

            search_from = start + 1;
        }

        return null;
    }

    fn primaryDeviceAttributesHasParam(params: []const u8, needle: u16) bool {
        var it = std.mem.splitScalar(u8, params, ';');
        while (it.next()) |part| {
            if (part.len == 0) continue;
            const value = std.fmt.parseInt(u16, part, 10) catch continue;
            if (value == needle) return true;
        }
        return false;
    }

    fn queryMode2027Support(self: *Terminal) !bool {
        try self.writeBytes(ansi.unicode_width_mode_query);
        try self.flush();

        var collected: [512]u8 = undefined;
        var collected_len: usize = 0;
        const deadline_ms = std.time.milliTimestamp() + 250;

        while (std.time.milliTimestamp() < deadline_ms) {
            var chunk: [128]u8 = undefined;
            const n = self.readInput(&chunk, 40) catch 0;
            if (n == 0) continue;

            const copy_len = @min(n, collected.len - collected_len);
            if (copy_len > 0) {
                @memcpy(collected[collected_len .. collected_len + copy_len], chunk[0..copy_len]);
                collected_len += copy_len;
            }

            if (parseMode2027Response(collected[0..collected_len])) |supported| {
                return supported;
            }
        }

        return false;
    }

    fn parseMode2027Response(bytes: []const u8) ?bool {
        const prefix = "\x1b[?2027;";
        var search_from: usize = 0;

        while (search_from < bytes.len) {
            const start = std.mem.indexOfPos(u8, bytes, search_from, prefix) orelse return null;
            var i = start + prefix.len;
            var param: usize = 0;
            var saw_digit = false;

            while (i < bytes.len and bytes[i] >= '0' and bytes[i] <= '9') : (i += 1) {
                saw_digit = true;
                param = param * 10 + (bytes[i] - '0');
            }

            if (!saw_digit) {
                search_from = start + 1;
                continue;
            }

            if (i + 1 < bytes.len and bytes[i] == '$' and bytes[i + 1] == 'y') {
                return param != 0;
            }

            search_from = start + 1;
        }

        return null;
    }

    fn selectWidthStrategy(self: *const Terminal) unicode.WidthStrategy {
        if (isInsideMultiplexer()) {
            return .legacy_wcwidth;
        }

        if (self.unicode_width_caps.mode_2027) {
            return .unicode;
        }

        if (self.unicode_width_caps.kitty_text_sizing) {
            return .unicode;
        }

        if (isKnownUnicodeWidthTerminal()) {
            return .unicode;
        }

        return .legacy_wcwidth;
    }

    fn queryKittyTextSizingSupport(self: *Terminal) !bool {
        if (!looksLikeKittyTerminal()) return false;

        const cpr = "\x1b[6n";
        // CR, CPR, draw 2-cell space via kitty OSC 66 width-only, CPR.
        const probe = "\r" ++ cpr ++ "\x1b]66;w=2; \x07" ++ cpr;
        try self.writeBytes(probe);
        try self.flush();

        var buf: [512]u8 = undefined;
        var len: usize = 0;
        const deadline_ms = std.time.milliTimestamp() + 250;

        while (std.time.milliTimestamp() < deadline_ms) {
            var chunk: [128]u8 = undefined;
            const n = self.readInput(&chunk, 40) catch 0;
            if (n == 0) continue;

            const copy_len = @min(n, buf.len - len);
            if (copy_len > 0) {
                @memcpy(buf[len .. len + copy_len], chunk[0..copy_len]);
                len += copy_len;
            }

            if (parseTwoCprColumns(buf[0..len])) |cols| {
                return cols.second == cols.first + 2;
            }
        }

        return false;
    }

    fn parseTwoCprColumns(bytes: []const u8) ?struct { first: usize, second: usize } {
        var idx: usize = 0;
        var found: [2]usize = .{ 0, 0 };
        var count: usize = 0;

        while (idx < bytes.len and count < 2) {
            const esc = std.mem.indexOfPos(u8, bytes, idx, "\x1b[") orelse break;
            var i = esc + 2;

            while (i < bytes.len and bytes[i] >= '0' and bytes[i] <= '9') : (i += 1) {}
            if (i >= bytes.len or bytes[i] != ';') {
                idx = esc + 1;
                continue;
            }
            i += 1;

            const col_start = i;
            while (i < bytes.len and bytes[i] >= '0' and bytes[i] <= '9') : (i += 1) {}
            if (i >= bytes.len or bytes[i] != 'R' or col_start == i) {
                idx = esc + 1;
                continue;
            }

            const col = std.fmt.parseInt(usize, bytes[col_start..i], 10) catch {
                idx = esc + 1;
                continue;
            };
            found[count] = col;
            count += 1;
            idx = i + 1;
        }

        if (count == 2) {
            return .{ .first = found[0], .second = found[1] };
        }
        return null;
    }

    fn isInsideMultiplexer() bool {
        return envVarExists("TMUX") or envVarExists("ZELLIJ") or envVarContains("TERM", "screen");
    }

    fn drainInput(self: *Terminal) void {
        var buf: [128]u8 = undefined;
        while (true) {
            const n = self.readInput(&buf, 0) catch return;
            if (n == 0) return;
        }
    }

    fn termFeaturesContain(features: []const u8, needle: []const u8) bool {
        if (features.len == 0 or needle.len == 0) return false;

        var i: usize = 0;
        while (i < features.len) {
            if (!std.ascii.isUpper(features[i])) {
                i += 1;
                continue;
            }

            var j = i + 1;
            while (j < features.len and std.ascii.isLower(features[j])) : (j += 1) {}
            const code = features[i..j];

            while (j < features.len and std.ascii.isDigit(features[j])) : (j += 1) {}
            if (std.mem.eql(u8, code, needle)) return true;

            i = j;
        }

        return false;
    }

    fn indexOfOscTerminator(bytes: []const u8, start: usize) ?usize {
        var i = start;
        while (i < bytes.len) : (i += 1) {
            if (bytes[i] == 0x07) return i;
            if (bytes[i] == 0x1b and i + 1 < bytes.len and bytes[i + 1] == '\\') {
                return i;
            }
        }
        return null;
    }

    fn indexOfSt(bytes: []const u8, start: usize) ?usize {
        var i = start;
        while (i + 1 < bytes.len) : (i += 1) {
            if (bytes[i] == 0x1b and bytes[i + 1] == '\\') return i;
        }
        return null;
    }

    fn isKnownUnicodeWidthTerminal() bool {
        // Terminals known to use grapheme-aware width by default.
        return envVarEquals("TERM_PROGRAM", "WezTerm") or
            envVarEquals("TERM_PROGRAM", "iTerm.app") or
            envVarContains("TERM", "wezterm") or
            envVarContains("TERM", "ghostty");
    }

    fn looksLikeKittyTerminal() bool {
        return envVarExists("KITTY_WINDOW_ID") or envVarContains("TERM", "kitty");
    }

    fn looksLikeIterm2Terminal() bool {
        return envVarEquals("TERM_PROGRAM", "iTerm.app") or
            envVarEquals("LC_TERMINAL", "iTerm2");
    }

    fn looksLikeSixelTerminal() bool {
        return envVarContains("TERM", "sixel") or
            envVarContains("TERM", "mlterm") or
            envVarContains("TERM", "yaft") or
            envVarContains("TERM", "contour");
    }

    fn isLikelyFullSixelSequence(bytes: []const u8) bool {
        if (bytes.len == 0) return false;
        return std.mem.startsWith(u8, bytes, ansi.DCS) or bytes[0] == 0x90;
    }

    fn isSixelDataPath(path: []const u8) bool {
        return std.mem.endsWith(u8, path, ".sixel") or
            std.mem.endsWith(u8, path, ".SIXEL") or
            std.mem.endsWith(u8, path, ".six") or
            std.mem.endsWith(u8, path, ".SIX");
    }

    fn fileExists(path: []const u8) bool {
        std.fs.cwd().access(path, .{}) catch return false;
        return true;
    }

    fn commandExists(name: []const u8) bool {
        const argv = [_][]const u8{ name, "--version" };
        const result = std.process.Child.run(.{
            .allocator = std.heap.page_allocator,
            .argv = &argv,
            .max_output_bytes = 1024,
        }) catch return false;
        defer std.heap.page_allocator.free(result.stdout);
        defer std.heap.page_allocator.free(result.stderr);
        return true;
    }

    fn envVarExists(name: []const u8) bool {
        const value = std.process.getEnvVarOwned(std.heap.page_allocator, name) catch return false;
        defer std.heap.page_allocator.free(value);
        return value.len > 0;
    }

    fn envVarEquals(name: []const u8, expected: []const u8) bool {
        const value = std.process.getEnvVarOwned(std.heap.page_allocator, name) catch return false;
        defer std.heap.page_allocator.free(value);
        return std.ascii.eqlIgnoreCase(value, expected);
    }

    fn envVarContains(name: []const u8, needle: []const u8) bool {
        const value = std.process.getEnvVarOwned(std.heap.page_allocator, name) catch return false;
        defer std.heap.page_allocator.free(value);
        return std.mem.indexOf(u8, value, needle) != null;
    }

    /// Simple writer struct for compatibility
    pub const Writer = struct {
        terminal: *Terminal,

        pub fn writeAll(self: Writer, bytes: []const u8) !void {
            try self.terminal.writeBytes(bytes);
        }

        pub fn print(self: Writer, comptime fmt: []const u8, args: anytype) !void {
            var buf: [256]u8 = undefined;
            const result = std.fmt.bufPrint(&buf, fmt, args) catch return;
            try self.terminal.writeBytes(result);
        }
    };
};

test "parseOsc52Response direct BEL" {
    const bytes = "\x1b]52;c;YQ==\x07";
    const parsed = Terminal.parseOsc52Response(bytes, "c", true).?;
    try std.testing.expectEqual(@as(usize, 0), parsed.consume_start);
    try std.testing.expectEqual(bytes.len, parsed.consume_end);
    try std.testing.expectEqualStrings("YQ==", parsed.payload_b64);
}

test "parseOsc52Response direct ST" {
    const bytes = "\x1b]52;c;YQ==\x1b\\";
    const parsed = Terminal.parseOsc52Response(bytes, "c", true).?;
    try std.testing.expectEqual(@as(usize, 0), parsed.consume_start);
    try std.testing.expectEqual(bytes.len, parsed.consume_end);
    try std.testing.expectEqualStrings("YQ==", parsed.payload_b64);
}

test "parseOsc52Response tmux passthrough BEL" {
    const bytes = "\x1bPtmux;\x1b\x1b]52;c;YQ==\x07\x1b\\";
    const parsed = Terminal.parseOsc52Response(bytes, "c", true).?;
    try std.testing.expectEqual(@as(usize, 0), parsed.consume_start);
    try std.testing.expectEqual(bytes.len, parsed.consume_end);
    try std.testing.expectEqualStrings("YQ==", parsed.payload_b64);
}

test "parseOsc52Response tmux passthrough ST" {
    const bytes = "\x1bPtmux;\x1b\x1b]52;c;YQ==\x1b\x1b\\\x1b\\";
    const parsed = Terminal.parseOsc52Response(bytes, "c", true).?;
    try std.testing.expectEqual(@as(usize, 0), parsed.consume_start);
    try std.testing.expectEqual(bytes.len, parsed.consume_end);
    try std.testing.expectEqualStrings("YQ==", parsed.payload_b64);
}

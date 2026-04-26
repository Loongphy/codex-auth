//! Command system for the ZigZag TUI framework.
//! Commands represent side effects and actions to be performed.

const std = @import("std");

/// Parameters for image rendering by file path.
pub const ImagePlacement = enum {
    /// Use the current cursor position.
    cursor,
    /// Draw from top-left corner.
    top_left,
    /// Draw from top-center using width hint.
    top_center,
    /// Center using provided width/height cell hints.
    center,
};

/// Preferred image protocol for rendering.
pub const ImageProtocol = enum {
    /// Auto-select best available (Kitty > iTerm2 > Sixel).
    auto,
    /// Force Kitty graphics protocol.
    kitty,
    /// Force iTerm2 inline image protocol.
    iterm2,
    /// Force Sixel graphics protocol.
    sixel,
};

/// Pixel format for in-memory image data.
pub const ImageFormat = enum(u16) {
    rgb = 24,
    rgba = 32,
    png = 100,
};

/// Parameters for image rendering by file path.
pub const ImageFile = struct {
    path: []const u8,
    width_cells: ?u16 = null,
    height_cells: ?u16 = null,
    placement: ImagePlacement = .top_left,
    /// Optional absolute row (0-indexed). Overrides anchor row when provided.
    row: ?u16 = null,
    /// Optional absolute column (0-indexed). Overrides anchor column when provided.
    col: ?u16 = null,
    /// Signed row offset (in terminal cells) applied after anchor/absolute position.
    row_offset: i16 = 0,
    /// Signed column offset (in terminal cells) applied after anchor/absolute position.
    col_offset: i16 = 0,
    preserve_aspect_ratio: bool = true,
    image_id: ?u32 = null,
    placement_id: ?u32 = null,
    move_cursor: bool = true,
    quiet: bool = true,
    /// Preferred protocol (default: auto-select).
    protocol: ImageProtocol = .auto,
    /// Z-index for layering (Kitty only). Negative = behind text.
    z_index: ?i32 = null,
    /// Enable unicode placeholders (Kitty only). Images participate in text reflow.
    unicode_placeholder: bool = false,
};

/// Parameters for rendering in-memory image data.
pub const ImageData = struct {
    /// Raw pixel data (RGB, RGBA, or PNG bytes).
    data: []const u8,
    /// Pixel format of the data.
    format: ImageFormat = .png,
    /// Pixel width of the image (required for RGB/RGBA).
    pixel_width: ?u32 = null,
    /// Pixel height of the image (required for RGB/RGBA).
    pixel_height: ?u32 = null,
    width_cells: ?u16 = null,
    height_cells: ?u16 = null,
    placement: ImagePlacement = .top_left,
    row: ?u16 = null,
    col: ?u16 = null,
    row_offset: i16 = 0,
    col_offset: i16 = 0,
    image_id: ?u32 = null,
    placement_id: ?u32 = null,
    move_cursor: bool = true,
    quiet: bool = true,
    protocol: ImageProtocol = .auto,
    z_index: ?i32 = null,
    unicode_placeholder: bool = false,
};

/// Transmit an image to the terminal without displaying it (Kitty cache).
pub const CacheImage = struct {
    /// File path or in-memory data source.
    source: ImageSource,
    /// Unique image ID for later reference. Required.
    image_id: u32,
    /// Pixel format (only for in-memory data).
    format: ImageFormat = .png,
    /// Pixel width (required for RGB/RGBA in-memory data).
    pixel_width: ?u32 = null,
    /// Pixel height (required for RGB/RGBA in-memory data).
    pixel_height: ?u32 = null,
    quiet: bool = true,
};

/// Source for an image: file path or in-memory bytes.
pub const ImageSource = union(enum) {
    file: []const u8,
    data: []const u8,
};

/// Display a previously cached image by ID (Kitty virtual placement).
pub const PlaceCachedImage = struct {
    /// Image ID from a previous cache_image command.
    image_id: u32,
    placement_id: ?u32 = null,
    width_cells: ?u16 = null,
    height_cells: ?u16 = null,
    placement: ImagePlacement = .top_left,
    row: ?u16 = null,
    col: ?u16 = null,
    row_offset: i16 = 0,
    col_offset: i16 = 0,
    move_cursor: bool = true,
    quiet: bool = true,
    z_index: ?i32 = null,
    unicode_placeholder: bool = false,
};

/// Delete a cached image or placement (Kitty).
pub const DeleteImage = union(enum) {
    /// Delete all placements of a specific image ID.
    by_id: u32,
    /// Delete a specific placement of an image.
    by_placement: struct { image_id: u32, placement_id: u32 },
    /// Delete all images and placements.
    all,
};

/// Backward-compatible alias for existing Kitty-only APIs.
pub const KittyImageFile = ImageFile;

/// Command type parameterized by the user's message type
pub fn Cmd(comptime Msg: type) type {
    return union(enum) {
        /// No operation
        none,

        /// Quit the application
        quit,

        /// Request a tick after the specified duration (nanoseconds)
        tick: u64,

        /// Request repeating tick at interval (nanoseconds)
        every: u64,

        /// Execute a batch of commands
        batch: []const Cmd(Msg),

        /// Execute commands in sequence (wait for each to complete)
        sequence: []const Cmd(Msg),

        /// Send a message to the update function
        msg: Msg,

        /// Execute a custom function that produces a message
        perform: *const fn () ?Msg,

        /// Suspend the program (Ctrl+Z behavior)
        suspend_process,

        /// Runtime terminal commands
        enable_mouse,
        disable_mouse,
        show_cursor,
        hide_cursor,
        enter_alt_screen,
        exit_alt_screen,
        set_title: []const u8,

        /// Print a line above the program output
        println: []const u8,

        /// Draw an image file using the best available protocol (Kitty, iTerm2, Sixel)
        image_file: ImageFile,

        /// Draw an image file via Kitty graphics protocol (no-op if unsupported)
        kitty_image_file: KittyImageFile,

        /// Draw in-memory image data (RGB, RGBA, or PNG bytes)
        image_data: ImageData,

        /// Transmit an image to the terminal cache without displaying (Kitty)
        cache_image: CacheImage,

        /// Display a previously cached image (Kitty virtual placement)
        place_cached_image: PlaceCachedImage,

        /// Delete a cached image or placement (Kitty)
        delete_image: DeleteImage,

        const Self = @This();

        /// Create a none command
        pub fn none_cmd() Self {
            return .none;
        }

        /// Create a quit command
        pub fn quit_cmd() Self {
            return .quit;
        }

        /// Request a tick after milliseconds
        pub fn tickMs(ms: u64) Self {
            return .{ .tick = ms * std.time.ns_per_ms };
        }

        /// Request a tick after seconds
        pub fn tickSec(sec: u64) Self {
            return .{ .tick = sec * std.time.ns_per_s };
        }

        /// Request a repeating tick every `ms` milliseconds
        pub fn everyMs(ms: u64) Self {
            return .{ .every = ms * std.time.ns_per_ms };
        }

        /// Request a repeating tick every `sec` seconds
        pub fn everySec(sec: u64) Self {
            return .{ .every = sec * std.time.ns_per_s };
        }

        /// Create a batch of commands
        pub fn batchOf(cmds: []const Self) Self {
            return .{ .batch = cmds };
        }

        /// Create a sequence of commands
        pub fn sequenceOf(cmds: []const Self) Self {
            return .{ .sequence = cmds };
        }

        /// Send a message
        pub fn send(message: Msg) Self {
            return .{ .msg = message };
        }

        /// Execute a function to get a message
        pub fn performFn(func: *const fn () ?Msg) Self {
            return .{ .perform = func };
        }

        /// Check if command is none
        pub fn isNone(self: Self) bool {
            return self == .none;
        }

        /// Check if command is quit
        pub fn isQuit(self: Self) bool {
            return self == .quit;
        }
    };
}

/// Standard commands without message type
pub const StandardCmd = union(enum) {
    none,
    quit,
    tick: u64,
    set_title: []const u8,
    enable_mouse,
    disable_mouse,
    show_cursor,
    hide_cursor,
    enter_alt_screen,
    exit_alt_screen,
    image_file: ImageFile,
    kitty_image_file: KittyImageFile,
    image_data: ImageData,
    cache_image: CacheImage,
    place_cached_image: PlaceCachedImage,
    delete_image: DeleteImage,
};

/// Combine multiple commands into a batch
pub fn batch(comptime Msg: type, cmds: []const Cmd(Msg)) Cmd(Msg) {
    return .{ .batch = cmds };
}

/// Combine multiple commands into a sequence
pub fn sequence(comptime Msg: type, cmds: []const Cmd(Msg)) Cmd(Msg) {
    return .{ .sequence = cmds };
}

/// Create a tick command with millisecond duration
pub fn tick(comptime Msg: type, ms: u64) Cmd(Msg) {
    return Cmd(Msg).tickMs(ms);
}

/// Create a tick command that fires every frame
pub fn everyFrame(comptime Msg: type) Cmd(Msg) {
    return Cmd(Msg).tickMs(16); // ~60fps
}

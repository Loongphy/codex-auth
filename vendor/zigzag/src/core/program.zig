//! Program runtime for the ZigZag TUI framework.
//! Implements the Model-Update-View pattern with an event loop.

const std = @import("std");
const builtin = @import("builtin");
const Terminal = @import("../terminal/terminal.zig").Terminal;
const ansi = @import("../terminal/ansi.zig");
const keyboard = @import("../input/keyboard.zig");
const Context = @import("context.zig").Context;
const Options = @import("context.zig").Options;
const message = @import("message.zig");
const command = @import("command.zig");
const Logger = @import("log.zig").Logger;
const unicode = @import("../unicode.zig");

pub const Cmd = command.Cmd;
pub const Msg = message;

const PendingImage = union(enum) {
    auto: command.ImageFile,
    kitty: command.KittyImageFile,
    data: command.ImageData,
    place_cached: command.PlaceCachedImage,
};

/// Program runtime that manages the application lifecycle
pub fn Program(comptime Model: type) type {
    // Ensure Model has required declarations
    comptime {
        if (!@hasDecl(Model, "Msg")) {
            @compileError("Model must have a 'Msg' type declaration");
        }
        if (!@hasDecl(Model, "init")) {
            @compileError("Model must have an 'init' function");
        }
        if (!@hasDecl(Model, "update")) {
            @compileError("Model must have an 'update' function");
        }
        if (!@hasDecl(Model, "view")) {
            @compileError("Model must have a 'view' function");
        }
    }

    const UserMsg = Model.Msg;
    const UserCmd = Cmd(UserMsg);

    return struct {
        allocator: std.mem.Allocator,
        arena: std.heap.ArenaAllocator,
        model: Model,
        terminal: ?Terminal,
        context: Context,
        options: Options,
        running: bool,
        clock: std.time.Timer,
        start_time: u64,
        last_frame_time: u64,
        pending_tick: ?u64,
        every_interval: ?u64,
        last_every_tick: u64,
        last_view_hash: u64,
        last_line_count: usize,
        pending_image: ?PendingImage,
        logger: ?Logger,

        /// Message filter function
        filter: ?*const fn (UserMsg) ?UserMsg,

        const Self = @This();

        /// Initialize the program
        pub fn init(allocator: std.mem.Allocator) !Self {
            return initWithOptions(allocator, .{});
        }

        /// Initialize with custom options
        pub fn initWithOptions(allocator: std.mem.Allocator, options: Options) !Self {
            const arena = std.heap.ArenaAllocator.init(allocator);
            var clock = try std.time.Timer.start();
            const now = clock.read();
            const self = Self{
                .allocator = allocator,
                .arena = arena,
                .model = undefined,
                .terminal = null,
                // `self` is returned by value, so don't capture an arena allocator here.
                // It would point at this function's stack copy and dangle after return.
                .context = Context.init(allocator, allocator),
                .options = options,
                .running = false,
                .clock = clock,
                .start_time = now,
                .last_frame_time = now,
                .pending_tick = null,
                .every_interval = null,
                .last_every_tick = 0,
                .last_view_hash = 0,
                .last_line_count = 0,
                .pending_image = null,
                .logger = null,
                .filter = null,
            };

            return self;
        }

        /// Clean up resources
        pub fn deinit(self: *Self) void {
            if (self.terminal) |*term| {
                term.deinit();
            }
            if (self.logger) |*l| {
                l.deinit();
            }
            self.arena.deinit();

            // Call model's deinit if it exists
            if (@hasDecl(Model, "deinit")) {
                self.model.deinit();
            }
        }

        /// Set a message filter function
        pub fn setFilter(self: *Self, f: ?*const fn (UserMsg) ?UserMsg) void {
            self.filter = f;
        }

        /// Run the program with the built-in event loop.
        /// For custom event loops, use `start()` + `tick()` instead.
        pub fn run(self: *Self) !void {
            try self.start();

            // Main event loop
            while (self.running) {
                try self.tick();
            }
        }

        /// Initialize the terminal and model without entering the event loop.
        /// After calling this, drive the program manually by calling `tick()`
        /// in your own loop. Check `isRunning()` to know when to stop.
        ///
        /// Example:
        /// ```
        /// try program.start();
        /// while (program.isRunning()) {
        ///     try program.tick();
        ///     // ... do other work between frames ...
        /// }
        /// ```
        pub fn start(self: *Self) !void {
            // Initialize logger if configured
            if (self.options.log_file) |log_path| {
                self.logger = Logger.init(log_path) catch null;
                if (self.logger != null) {
                    self.context._logger = &self.logger.?;
                }
            }

            // Initialize terminal
            self.terminal = try Terminal.init(.{
                .alt_screen = self.options.alt_screen,
                .hide_cursor = !self.options.cursor,
                .mouse = self.options.mouse,
                .bracketed_paste = self.options.bracketed_paste,
                .input = self.options.input,
                .output = self.options.output,
                .kitty_keyboard = self.options.kitty_keyboard,
                .osc52 = self.options.osc52,
            });

            // Set title if provided
            if (self.options.title) |title| {
                try self.terminal.?.setTitle(title);
            }

            // Get initial size
            const size = try self.terminal.?.getSize();
            self.context.width = size.cols;
            self.context.height = size.rows;
            self.context._terminal = &self.terminal.?;

            const width_caps = self.terminal.?.getUnicodeWidthCapabilities();
            const effective_width_strategy = self.resolveUnicodeWidthStrategy(width_caps.strategy);
            self.context.unicode_width_strategy = effective_width_strategy;
            self.context.terminal_mode_2027 = width_caps.mode_2027;
            self.context.kitty_text_sizing = width_caps.kitty_text_sizing;
            unicode.setWidthStrategy(effective_width_strategy);

            self.clock.reset();
            self.start_time = self.clock.read();
            self.last_frame_time = self.start_time;
            self.context.elapsed = 0;
            self.context.delta = 0;
            self.context.frame = 0;

            self.resetFrameAllocator();

            // Initialize the model
            const init_cmd = self.model.init(&self.context);
            try self.processCommand(init_cmd);

            self.running = true;
        }

        /// Returns true if the program is still running.
        pub fn isRunning(self: *const Self) bool {
            return self.running;
        }

        /// Execute a single frame: poll input, process events, render.
        pub fn tick(self: *Self) !void {
            const now = self.clock.read();
            const delta = now - self.last_frame_time;

            // Enforce framerate limit
            const min_frame_time_ns: u64 = if (self.options.fps > 0)
                @divFloor(std.time.ns_per_s, self.options.fps)
            else
                16_666_666; // ~60fps default

            if (delta < min_frame_time_ns) {
                sleepNs(min_frame_time_ns - delta);
            }

            const frame_time = self.clock.read();
            const actual_delta = frame_time - self.last_frame_time;
            self.last_frame_time = frame_time;

            self.context.delta = actual_delta;
            self.context.elapsed = frame_time - self.start_time;
            self.context.frame += 1;

            self.resetFrameAllocator();

            // Check for resize
            if (self.terminal.?.checkResize()) {
                const size = try self.terminal.?.getSize();
                self.context.width = size.cols;
                self.context.height = size.rows;

                // Only send window_size message if the user model supports it
                if (@hasField(UserMsg, "window_size")) {
                    const cmd = self.dispatchToModel(.{ .window_size = .{
                        .width = size.cols,
                        .height = size.rows,
                    } });
                    try self.processCommand(cmd);
                }
            }

            // Read input
            var input_buf: [256]u8 = undefined;
            const bytes_read = try self.terminal.?.readInput(&input_buf, 16);

            if (bytes_read > 0) {
                const events = try keyboard.parseAll(self.context.allocator, input_buf[0..bytes_read]);
                for (events) |event| {
                    const user_cmd = switch (event) {
                        .key => |k| self.processKeyEvent(k),
                        .mouse => |m| self.processMouseEvent(m),
                        .none => null,
                    };
                    if (user_cmd) |cmd| {
                        try self.processCommand(cmd);
                    }
                }
            }

            // Handle pending tick
            if (self.pending_tick) |tick_ns| {
                if (self.context.elapsed >= tick_ns) {
                    self.pending_tick = null;
                    // Deliver tick to user's update if Model.Msg has a tick variant
                    if (@hasField(UserMsg, "tick")) {
                        const user_msg = UserMsg{ .tick = .{
                            .timestamp = @intCast(frame_time),
                            .delta = actual_delta,
                        } };
                        const cmd = self.dispatchToModel(user_msg);
                        try self.processCommand(cmd);
                    }
                }
            }

            // Handle repeating tick
            if (self.every_interval) |interval| {
                if (self.context.elapsed - self.last_every_tick >= interval) {
                    self.last_every_tick = self.context.elapsed;
                    if (@hasField(UserMsg, "tick")) {
                        const user_msg = UserMsg{ .tick = .{
                            .timestamp = @intCast(frame_time),
                            .delta = actual_delta,
                        } };
                        const cmd = self.dispatchToModel(user_msg);
                        try self.processCommand(cmd);
                    }
                }
            }

            // Render
            try self.render();
            try self.flushPendingImage();
        }

        /// Dispatch a message to the model, applying the filter if set
        fn dispatchToModel(self: *Self, user_msg: UserMsg) UserCmd {
            if (self.filter) |f| {
                if (f(user_msg)) |filtered_msg| {
                    return self.model.update(filtered_msg, &self.context);
                }
                return .none;
            }
            return self.model.update(user_msg, &self.context);
        }

        fn processKeyEvent(self: *Self, key: keyboard.KeyEvent) ?UserCmd {
            // Check for Ctrl+C to quit
            if (key.modifiers.ctrl) {
                switch (key.key) {
                    .char => |c| {
                        if (c == 'c') {
                            self.running = false;
                            return null;
                        }
                        // Handle Ctrl+Z for suspend
                        if (c == 'z' and self.options.suspend_enabled) {
                            self.performSuspend();
                            return null;
                        }
                    },
                    else => {},
                }
            }

            // Handle paste events
            if (key.key == .paste) {
                if (@hasField(UserMsg, "paste")) {
                    const user_msg = UserMsg{ .paste = key.key.paste };
                    return self.dispatchToModel(user_msg);
                }
                // If model doesn't handle paste, send as individual key events
                if (@hasField(UserMsg, "key")) {
                    const user_msg = UserMsg{ .key = key };
                    return self.dispatchToModel(user_msg);
                }
                return null;
            }

            // Convert to user message if Model.Msg has a key variant
            if (@hasField(UserMsg, "key")) {
                const user_msg = UserMsg{ .key = key };
                return self.dispatchToModel(user_msg);
            }

            return null;
        }

        fn resolveUnicodeWidthStrategy(self: *const Self, detected: unicode.WidthStrategy) unicode.WidthStrategy {
            if (self.options.unicode_width_strategy) |forced| {
                return forced;
            }
            if (envUnicodeWidthOverride()) |from_env| {
                return from_env;
            }
            return detected;
        }

        fn envUnicodeWidthOverride() ?unicode.WidthStrategy {
            const raw = std.process.getEnvVarOwned(std.heap.page_allocator, "ZZ_UNICODE_WIDTH") catch return null;
            defer std.heap.page_allocator.free(raw);
            if (std.ascii.eqlIgnoreCase(raw, "unicode")) return .unicode;
            if (std.ascii.eqlIgnoreCase(raw, "legacy")) return .legacy_wcwidth;
            if (std.ascii.eqlIgnoreCase(raw, "auto")) return null;
            return null;
        }

        fn processMouseEvent(self: *Self, mouse_event: keyboard.MouseEvent) ?UserCmd {
            if (@hasField(UserMsg, "mouse")) {
                const user_msg = UserMsg{ .mouse = mouse_event };
                return self.dispatchToModel(user_msg);
            }

            return null;
        }

        /// Perform suspend (Ctrl+Z) — POSIX only
        fn performSuspend(self: *Self) void {
            if (builtin.os.tag == .windows) return;

            // Cleanup terminal
            if (self.terminal) |*term| {
                term.cleanup();
            }

            // Raise SIGTSTP to suspend process
            if (builtin.os.tag != .windows) {
                const posix = std.posix;
                _ = posix.raise(posix.SIG.TSTP) catch {};
            }

            // When we resume (after `fg`), re-setup terminal
            if (self.terminal) |*term| {
                term.setup() catch {};
            }

            // Avoid a large post-resume frame delta.
            self.last_frame_time = self.clock.read();

            // Force re-render
            self.last_view_hash = 0;

            // Dispatch resumed message if model supports it
            if (@hasField(UserMsg, "resumed")) {
                const cmd = self.dispatchToModel(.{ .resumed = {} });
                self.processCommand(cmd) catch {};
            }
        }

        fn processCommand(self: *Self, cmd: UserCmd) !void {
            switch (cmd) {
                .none => {},
                .quit => {
                    self.running = false;
                },
                .tick => |ns| {
                    self.pending_tick = self.context.elapsed + ns;
                },
                .every => |ns| {
                    self.every_interval = ns;
                    self.last_every_tick = self.context.elapsed;
                },
                .batch => |cmds| {
                    for (cmds) |c| {
                        try self.processCommand(c);
                    }
                },
                .sequence => |cmds| {
                    for (cmds) |c| {
                        try self.processCommand(c);
                    }
                },
                .msg => |m| {
                    const new_cmd = self.dispatchToModel(m);
                    try self.processCommand(new_cmd);
                },
                .perform => |func| {
                    if (func()) |m| {
                        const new_cmd = self.dispatchToModel(m);
                        try self.processCommand(new_cmd);
                    }
                },
                .suspend_process => {
                    self.performSuspend();
                },
                .enable_mouse => {
                    if (self.terminal) |*term| {
                        try term.enableMouse();
                    }
                },
                .disable_mouse => {
                    if (self.terminal) |*term| {
                        try term.disableMouse();
                    }
                },
                .show_cursor => {
                    if (self.terminal) |*term| {
                        const writer = term.writer();
                        try writer.writeAll(ansi.cursor_show);
                        try term.flush();
                    }
                },
                .hide_cursor => {
                    if (self.terminal) |*term| {
                        const writer = term.writer();
                        try writer.writeAll(ansi.cursor_hide);
                        try term.flush();
                    }
                },
                .enter_alt_screen => {
                    if (self.terminal) |*term| {
                        const writer = term.writer();
                        try writer.writeAll(ansi.alt_screen_enter);
                        try term.flush();
                    }
                },
                .exit_alt_screen => {
                    if (self.terminal) |*term| {
                        const writer = term.writer();
                        try writer.writeAll(ansi.alt_screen_exit);
                        try term.flush();
                    }
                },
                .set_title => |title| {
                    if (self.terminal) |*term| {
                        try term.setTitle(title);
                    }
                },
                .println => |line| {
                    if (self.terminal) |*term| {
                        const writer = term.writer();
                        try writer.writeAll(ansi.cursor_save);
                        try writer.writeAll(ansi.cursor_home);
                        try writer.writeAll(line);
                        try writer.writeAll("\n");
                        try writer.writeAll(ansi.cursor_restore);
                        try term.flush();
                    }
                },
                .image_file => |image| {
                    self.pending_image = .{ .auto = image };
                },
                .kitty_image_file => |image| {
                    self.pending_image = .{ .kitty = image };
                },
                .image_data => |image| {
                    self.pending_image = .{ .data = image };
                },
                .cache_image => |cache| {
                    if (self.terminal) |*term| {
                        switch (cache.source) {
                            .file => |path| {
                                _ = term.transmitKittyImageFromFile(path, .{
                                    .image_id = cache.image_id,
                                    .format = @enumFromInt(@intFromEnum(cache.format)),
                                    .quiet = cache.quiet,
                                    .pixel_width = cache.pixel_width,
                                    .pixel_height = cache.pixel_height,
                                }) catch {};
                            },
                            .data => |data| {
                                _ = term.transmitKittyImage(data, .{
                                    .image_id = cache.image_id,
                                    .format = @enumFromInt(@intFromEnum(cache.format)),
                                    .quiet = cache.quiet,
                                    .pixel_width = cache.pixel_width,
                                    .pixel_height = cache.pixel_height,
                                }) catch {};
                            },
                        }
                        term.flush() catch {};
                    }
                },
                .place_cached_image => |place| {
                    self.pending_image = .{ .place_cached = place };
                },
                .delete_image => |del| {
                    if (self.terminal) |*term| {
                        const target: @import("../terminal/terminal.zig").KittyDeleteTarget = switch (del) {
                            .by_id => |id| .{ .by_id = id },
                            .by_placement => |bp| .{ .by_placement = .{ .image_id = bp.image_id, .placement_id = bp.placement_id } },
                            .all => .all,
                        };
                        _ = term.deleteKittyImage(target) catch {};
                        term.flush() catch {};
                    }
                },
            }
        }

        fn flushPendingImage(self: *Self) !void {
            const TerminalMod = @import("../terminal/terminal.zig");
            const pending = self.pending_image orelse return;
            self.pending_image = null;
            if (self.terminal) |*term| {
                switch (pending) {
                    .auto => |image| {
                        if (!image.move_cursor) {
                            try term.writer().writeAll(ansi.cursor_save);
                        }
                        try self.positionPendingImage(term, image);
                        const protocol: TerminalMod.ImageProtocol = switch (image.protocol) {
                            .auto => .auto,
                            .kitty => .kitty,
                            .iterm2 => .iterm2,
                            .sixel => .sixel,
                        };
                        _ = try term.drawImageFromFileWithProtocol(image.path, .{
                            .width_cells = image.width_cells,
                            .height_cells = image.height_cells,
                            .preserve_aspect_ratio = image.preserve_aspect_ratio,
                            .image_id = image.image_id,
                            .placement_id = image.placement_id,
                            .move_cursor = image.move_cursor,
                            .quiet = image.quiet,
                            .z_index = image.z_index,
                            .unicode_placeholder = image.unicode_placeholder,
                        }, protocol);
                        if (!image.move_cursor) {
                            try term.writer().writeAll(ansi.cursor_restore);
                        }
                    },
                    .kitty => |image| {
                        if (!image.move_cursor) {
                            try term.writer().writeAll(ansi.cursor_save);
                        }
                        try self.positionPendingImage(term, image);
                        _ = try term.drawKittyImageFromFile(image.path, .{
                            .width_cells = image.width_cells,
                            .height_cells = image.height_cells,
                            .image_id = image.image_id,
                            .placement_id = image.placement_id,
                            .move_cursor = image.move_cursor,
                            .quiet = image.quiet,
                            .z_index = image.z_index,
                            .unicode_placeholder = image.unicode_placeholder,
                        });
                        if (!image.move_cursor) {
                            try term.writer().writeAll(ansi.cursor_restore);
                        }
                    },
                    .data => |image| {
                        if (!image.move_cursor) {
                            try term.writer().writeAll(ansi.cursor_save);
                        }
                        try self.positionPendingImageData(term, image);
                        const protocol: TerminalMod.ImageProtocol = switch (image.protocol) {
                            .auto => .auto,
                            .kitty => .kitty,
                            .iterm2 => .iterm2,
                            .sixel => .sixel,
                        };
                        _ = try term.drawImageDataWithProtocol(image.data, .{
                            .format = @enumFromInt(@intFromEnum(image.format)),
                            .pixel_width = image.pixel_width,
                            .pixel_height = image.pixel_height,
                            .width_cells = image.width_cells,
                            .height_cells = image.height_cells,
                            .image_id = image.image_id,
                            .placement_id = image.placement_id,
                            .move_cursor = image.move_cursor,
                            .quiet = image.quiet,
                            .z_index = image.z_index,
                            .unicode_placeholder = image.unicode_placeholder,
                        }, protocol);
                        if (!image.move_cursor) {
                            try term.writer().writeAll(ansi.cursor_restore);
                        }
                    },
                    .place_cached => |place| {
                        if (!place.move_cursor) {
                            try term.writer().writeAll(ansi.cursor_save);
                        }
                        try self.positionPendingCachedImage(term, place);
                        _ = try term.placeKittyImage(.{
                            .image_id = place.image_id,
                            .placement_id = place.placement_id,
                            .width_cells = place.width_cells,
                            .height_cells = place.height_cells,
                            .move_cursor = place.move_cursor,
                            .quiet = place.quiet,
                            .z_index = place.z_index,
                            .unicode_placeholder = place.unicode_placeholder,
                        });
                        if (!place.move_cursor) {
                            try term.writer().writeAll(ansi.cursor_restore);
                        }
                    },
                }
                try term.flush();
            }
        }

        fn positionPendingImage(self: *Self, term: *Terminal, image: command.ImageFile) !void {
            try self.positionByPlacement(term, image.placement, image.width_cells, image.height_cells, image.row, image.col, image.row_offset, image.col_offset);
        }

        fn positionPendingImageData(self: *Self, term: *Terminal, image: command.ImageData) !void {
            try self.positionByPlacement(term, image.placement, image.width_cells, image.height_cells, image.row, image.col, image.row_offset, image.col_offset);
        }

        fn positionPendingCachedImage(self: *Self, term: *Terminal, place: command.PlaceCachedImage) !void {
            try self.positionByPlacement(term, place.placement, place.width_cells, place.height_cells, place.row, place.col, place.row_offset, place.col_offset);
        }

        fn positionByPlacement(
            self: *Self,
            term: *Terminal,
            placement: command.ImagePlacement,
            width_cells: ?u16,
            height_cells: ?u16,
            opt_row: ?u16,
            opt_col: ?u16,
            row_offset: i16,
            col_offset: i16,
        ) !void {
            var row: u16 = 0;
            var col: u16 = 0;

            switch (placement) {
                .cursor => return,
                .top_left => {
                    row = 0;
                    col = 0;
                },
                .top_center => {
                    if (width_cells) |w_cells| {
                        const term_width = @as(usize, self.context.width);
                        const image_width = @as(usize, w_cells);
                        if (term_width > image_width) {
                            col = @intCast((term_width - image_width) / 2);
                        }
                    }
                    row = 0;
                },
                .center => {
                    if (width_cells) |w_cells| {
                        const term_width = @as(usize, self.context.width);
                        const image_width = @as(usize, w_cells);
                        if (term_width > image_width) {
                            col = @intCast((term_width - image_width) / 2);
                        }
                    }
                    if (height_cells) |h_cells| {
                        const term_height = @as(usize, self.context.height);
                        const image_height = @as(usize, h_cells);
                        if (term_height > image_height) {
                            row = @intCast((term_height - image_height) / 2);
                        }
                    }
                },
            }

            if (opt_row) |r| row = r;
            if (opt_col) |c| col = c;

            const max_row = if (height_cells) |h| self.context.height -| h else self.context.height -| 1;
            const max_col = if (width_cells) |w| self.context.width -| w else self.context.width -| 1;
            row = applySignedOffsetClamped(row, row_offset, max_row);
            col = applySignedOffsetClamped(col, col_offset, max_col);

            try term.moveTo(row, col);
        }

        fn applySignedOffsetClamped(base: u16, offset: i16, max: u16) u16 {
            const base_i32 = @as(i32, @intCast(base));
            const offset_i32 = @as(i32, offset);
            const max_i32 = @as(i32, @intCast(max));
            var value = base_i32 + offset_i32;
            if (value < 0) value = 0;
            if (value > max_i32) value = max_i32;
            return @intCast(value);
        }

        fn sleepNs(nanoseconds: u64) void {
            if (nanoseconds == 0) return;
            const ns_per_s: u64 = if (@hasDecl(std.time, "ns_per_s")) std.time.ns_per_s else 1_000_000_000;
            const ns_per_ms: u64 = if (@hasDecl(std.time, "ns_per_ms")) std.time.ns_per_ms else 1_000_000;

            // Zig 0.15 API path.
            if (@hasDecl(std.Thread, "sleep")) {
                std.Thread.sleep(nanoseconds);
                return;
            }

            // Zig 0.16+ API path.
            if (@hasDecl(std, "Io")) {
                const Io = std.Io;
                if (@hasDecl(Io, "Threaded") and
                    @hasDecl(Io, "Clock") and
                    @hasDecl(Io.Clock, "Duration") and
                    @hasDecl(Io.Clock.Duration, "fromNanoseconds") and
                    @hasDecl(Io.Clock.Duration, "sleep"))
                {
                    var threaded_io: Io.Threaded = .init_single_threaded;
                    const io = threaded_io.io();
                    const duration = Io.Clock.Duration.fromNanoseconds(@intCast(nanoseconds));
                    duration.sleep(io) catch {};
                    return;
                }
            }

            // Fallback for targets/environments where the above are unavailable.
            if (@hasDecl(std, "os") and @hasDecl(std.os, "windows") and builtin.os.tag == .windows) {
                const windows = std.os.windows;
                const big_ms_from_ns = nanoseconds / ns_per_ms;
                const ms = std.math.cast(windows.DWORD, big_ms_from_ns) orelse std.math.maxInt(windows.DWORD);
                windows.kernel32.Sleep(ms);
                return;
            }

            if (@hasDecl(std, "posix") and @hasDecl(std.posix, "nanosleep")) {
                const seconds = nanoseconds / ns_per_s;
                const rem_ns = nanoseconds % ns_per_s;
                std.posix.nanosleep(seconds, rem_ns);
                return;
            }

            // Last resort: spin for the requested duration.
            var timer = std.time.Timer.start() catch return;
            const start_ns = timer.read();
            while (timer.read() - start_ns < nanoseconds) {
                std.atomic.spinLoopHint();
            }
        }

        fn resetFrameAllocator(self: *Self) void {
            _ = self.arena.reset(.retain_capacity);
            self.context.allocator = self.arena.allocator();
        }

        fn render(self: *Self) !void {
            const view_output = self.model.view(&self.context);

            // Compute hash of view output
            const view_hash = std.hash.Wyhash.hash(0, view_output);

            // Only redraw if view changed
            if (view_hash != self.last_view_hash) {
                const writer = self.terminal.?.writer();

                // Start synchronized output (prevents tearing on supporting terminals)
                try writer.writeAll(ansi.sync_start);

                // Move cursor home (don't clear entire screen to reduce flicker)
                try writer.writeAll(ansi.cursor_home);

                // Write each line, clearing to end of line
                var lines = std.mem.splitScalar(u8, view_output, '\n');
                var first = true;
                var line_count: usize = 0;
                while (lines.next()) |line| {
                    if (!first) try writer.writeAll("\r\n");
                    first = false;
                    try writer.writeAll(line);
                    try writer.writeAll(ansi.line_clear_right);
                    line_count += 1;
                }

                // Clear remaining lines if previous content was taller
                if (self.last_line_count > line_count) {
                    var remaining = self.last_line_count - line_count;
                    while (remaining > 0) : (remaining -= 1) {
                        try writer.writeAll("\r\n");
                        try writer.writeAll(ansi.line_clear);
                    }
                }
                self.last_line_count = line_count;

                // End synchronized output
                try writer.writeAll(ansi.sync_end);

                try self.terminal.?.flush();

                // Save hash for comparison
                self.last_view_hash = view_hash;
            }
        }

        /// Send a message to the model
        pub fn send(self: *Self, m: UserMsg) !void {
            const cmd = self.dispatchToModel(m);
            try self.processCommand(cmd);
        }

        /// Stop the program
        pub fn quit(self: *Self) void {
            self.running = false;
        }
    };
}

const std = @import("std");
const app_runtime = @import("../core/runtime.zig");
const builtin = @import("builtin");
const style = @import("style.zig");
const io = @import("io.zig");
const windows = std.os.windows;

const readFileOnce = io.readFileOnce;

const win = struct {
    pub const BOOL = windows.BOOL;
    pub const CHAR = windows.CHAR;
    pub const DWORD = windows.DWORD;
    pub const HANDLE = windows.HANDLE;
    pub const SHORT = windows.SHORT;
    pub const WCHAR = windows.WCHAR;
    pub const WORD = windows.WORD;

    pub const ENABLE_PROCESSED_INPUT: DWORD = 0x0001;
    pub const ENABLE_LINE_INPUT: DWORD = 0x0002;
    pub const ENABLE_ECHO_INPUT: DWORD = 0x0004;
    pub const ENABLE_WINDOW_INPUT: DWORD = 0x0008;
    pub const ENABLE_MOUSE_INPUT: DWORD = 0x0010;
    pub const ENABLE_QUICK_EDIT_MODE: DWORD = 0x0040;
    pub const ENABLE_EXTENDED_FLAGS: DWORD = 0x0080;
    pub const ENABLE_VIRTUAL_TERMINAL_INPUT: DWORD = 0x0200;

    pub const ENABLE_PROCESSED_OUTPUT: DWORD = 0x0001;
    pub const ENABLE_VIRTUAL_TERMINAL_PROCESSING: DWORD = windows.ENABLE_VIRTUAL_TERMINAL_PROCESSING;

    pub const KEY_EVENT: WORD = 0x0001;
    pub const WINDOW_BUFFER_SIZE_EVENT: WORD = 0x0004;

    pub const VK_BACK: WORD = 0x08;
    pub const VK_RETURN: WORD = 0x0D;
    pub const VK_ESCAPE: WORD = 0x1B;
    pub const VK_PRIOR: WORD = 0x21;
    pub const VK_NEXT: WORD = 0x22;
    pub const VK_END: WORD = 0x23;
    pub const VK_HOME: WORD = 0x24;
    pub const VK_UP: WORD = 0x26;
    pub const VK_DOWN: WORD = 0x28;

    pub const WAIT_OBJECT_0: DWORD = 0x00000000;
    pub const WAIT_TIMEOUT: DWORD = 258;
    pub const INFINITE: DWORD = 0xFFFF_FFFF;

    pub const KEY_EVENT_RECORD = extern struct {
        bKeyDown: BOOL,
        wRepeatCount: WORD,
        wVirtualKeyCode: WORD,
        wVirtualScanCode: WORD,
        uChar: extern union {
            UnicodeChar: WCHAR,
            AsciiChar: CHAR,
        },
        dwControlKeyState: DWORD,
    };

    pub const COORD = extern struct {
        X: SHORT,
        Y: SHORT,
    };

    pub const WINDOW_BUFFER_SIZE_RECORD = extern struct {
        dwSize: COORD,
    };

    pub const INPUT_RECORD = extern struct {
        EventType: WORD,
        Event: extern union {
            KeyEvent: KEY_EVENT_RECORD,
            WindowBufferSizeEvent: WINDOW_BUFFER_SIZE_RECORD,
        },
    };

    extern "kernel32" fn GetConsoleMode(
        console_handle: HANDLE,
        mode: *DWORD,
    ) callconv(.winapi) BOOL;
    extern "kernel32" fn SetConsoleMode(
        console_handle: HANDLE,
        mode: DWORD,
    ) callconv(.winapi) BOOL;
    extern "kernel32" fn ReadConsoleInputW(
        console_input: HANDLE,
        buffer: *INPUT_RECORD,
        length: DWORD,
        number_of_events_read: *DWORD,
    ) callconv(.winapi) BOOL;
    extern "kernel32" fn WaitForSingleObject(
        handle: HANDLE,
        milliseconds: DWORD,
    ) callconv(.winapi) DWORD;
};

pub const win32 = win;

pub const tui_poll_input_mask: i16 = if (builtin.os.tag == .windows) 0 else std.posix.POLL.IN;
pub const tui_poll_error_mask: i16 = if (builtin.os.tag == .windows) 0 else std.posix.POLL.ERR | std.posix.POLL.HUP | std.posix.POLL.NVAL;
pub const tui_escape_sequence_timeout_ms: i32 = 100;
pub const live_ui_tick_ms: i32 = 100;

pub const TuiNavigation = enum {
    up,
    down,
    keyboard_up,
    keyboard_down,
    page_up,
    page_down,
    home,
    end,
    scroll_up,
    scroll_down,
};

pub const TuiEscapeClassification = union(enum) {
    incomplete,
    ignore,
    keyboard_enhancement_supported,
    navigation: TuiNavigation,
};

pub const TuiEscapeAction = enum {
    quit,
    ignore,
    move_up,
    move_down,
    keyboard_up,
    keyboard_down,
    page_up,
    page_down,
    home,
    end,
    scroll_up,
    scroll_down,
    keyboard_enhancement_supported,
};

pub const TuiEscapeReadResult = struct {
    action: TuiEscapeAction,
    buffered_bytes_consumed: usize,
};

pub const TuiPollResult = enum {
    ready,
    timeout,
    closed,
};

pub const TuiInputRead = union(enum) {
    ready: usize,
    timeout,
    closed,
};

pub const TuiInputKey = union(enum) {
    move_up,
    move_down,
    keyboard_up,
    keyboard_down,
    page_up,
    page_down,
    home,
    end,
    scroll_up,
    scroll_down,
    enter,
    quit,
    backspace,
    redraw,
    byte: u8,
};

pub const TuiSize = struct {
    rows: usize,
    cols: usize,
};

pub fn windowsTuiInputMode(saved_input_mode: win.DWORD) win.DWORD {
    var raw_input_mode = saved_input_mode |
        win.ENABLE_EXTENDED_FLAGS |
        win.ENABLE_WINDOW_INPUT;
    // Keep resize events enabled for redraws, but leave mouse explicitly disabled
    // until the TUI has a real click/scroll interaction model.
    raw_input_mode &= ~@as(
        win.DWORD,
        win.ENABLE_PROCESSED_INPUT |
            win.ENABLE_QUICK_EDIT_MODE |
            win.ENABLE_LINE_INPUT |
            win.ENABLE_ECHO_INPUT |
            win.ENABLE_MOUSE_INPUT |
            win.ENABLE_VIRTUAL_TERMINAL_INPUT,
    );
    return raw_input_mode;
}

pub fn windowsTuiOutputMode(saved_output_mode: win.DWORD) win.DWORD {
    return saved_output_mode |
        win.ENABLE_PROCESSED_OUTPUT |
        win.ENABLE_VIRTUAL_TERMINAL_PROCESSING;
}

pub const pollTuiInput = if (builtin.os.tag == .windows)
    struct {
        fn call(file: std.Io.File, timeout_ms: i32, _: i16) !TuiPollResult {
            const wait_ms: win.DWORD = if (timeout_ms < 0) win.INFINITE else @intCast(timeout_ms);
            return switch (win.WaitForSingleObject(file.handle, wait_ms)) {
                win.WAIT_OBJECT_0 => .ready,
                win.WAIT_TIMEOUT => .timeout,
                else => .closed,
            };
        }
    }.call
else
    struct {
        fn call(file: std.Io.File, timeout_ms: i32, poll_error_mask: i16) !TuiPollResult {
            var fds = [_]std.posix.pollfd{.{
                .fd = file.handle,
                .events = tui_poll_input_mask,
                .revents = 0,
            }};
            const ready = try std.posix.poll(&fds, timeout_ms);
            if (ready == 0) return .timeout;
            if ((fds[0].revents & poll_error_mask) != 0) return .closed;
            return .ready;
        }
    }.call;

pub fn writeTuiEnterTo(out: *std.Io.Writer) !void {
    try out.writeAll("\x1b[?1049h\x1b[?25l\x1b[?1007h");
    try out.writeAll("\x1b[?u\x1b[>7u");
    try out.writeAll("\x1b[H\x1b[J");
}

pub fn writeTuiExitTo(out: *std.Io.Writer) !void {
    try out.writeAll("\x1b[<1u\x1b[?1007l\x1b[?25h\x1b[?1049l");
}

pub fn writeTuiResetFrameTo(out: *std.Io.Writer) !void {
    try out.writeAll("\x1b[H\x1b[J");
}

pub fn writeTuiFrameTo(out: *std.Io.Writer, frame: []const u8, previous_line_count: usize) !usize {
    try out.writeAll("\x1b[?2026h\x1b[H");

    var line_count: usize = 0;
    var start: usize = 0;
    var first = true;
    while (start < frame.len) {
        const newline = std.mem.indexOfScalarPos(u8, frame, start, '\n') orelse frame.len;
        const line = frame[start..newline];
        if (!first) try out.writeAll("\r\n");
        first = false;
        try out.writeAll(line);
        try out.writeAll("\x1b[K");
        line_count += 1;
        if (newline == frame.len) break;
        start = newline + 1;
    }

    if (previous_line_count > line_count) {
        var remaining = previous_line_count - line_count;
        while (remaining > 0) : (remaining -= 1) {
            try out.writeAll("\r\n");
            try out.writeAll("\x1b[2K");
        }
    }

    try out.writeAll("\x1b[?2026l");
    return line_count;
}

pub fn switchTuiFooterText(is_windows: bool) []const u8 {
    return if (is_windows)
        "Keys: Up/Down or j/k, 1-9 type, Enter select, Esc or q quit\n"
    else
        "Keys: ↑/↓ or j/k, 1-9 type, Enter select, Esc or q quit\n";
}

pub fn writeSwitchTuiFooter(out: *std.Io.Writer, use_color: bool) !void {
    try writeSwitchTuiFooterBounded(out, use_color, null);
}

pub fn writeSwitchTuiFooterBounded(out: *std.Io.Writer, use_color: bool, max_cols: ?usize) !void {
    try writeStyledTuiLineBounded(out, if (use_color) style.ansi.cyan else "", switchTuiFooterText(builtin.os.tag == .windows), max_cols);
}

pub fn removeTuiFooterText(is_windows: bool) []const u8 {
    return if (is_windows)
        "Keys: Up/Down or j/k move, Space toggle, 1-9 type, Enter delete, Esc or q quit\n"
    else
        "Keys: ↑/↓ or j/k move, Space toggle, 1-9 type, Enter delete, Esc or q quit\n";
}

pub fn writeRemoveTuiFooter(out: *std.Io.Writer, use_color: bool) !void {
    try writeRemoveTuiFooterBounded(out, use_color, null);
}

pub fn writeRemoveTuiFooterBounded(out: *std.Io.Writer, use_color: bool, max_cols: ?usize) !void {
    try writeStyledTuiLineBounded(out, if (use_color) style.ansi.cyan else "", removeTuiFooterText(builtin.os.tag == .windows), max_cols);
}

pub fn listTuiFooterText(is_windows: bool) []const u8 {
    return if (is_windows)
        "Keys: Up/Down scroll, PgUp/PgDn page, Home/End jump, Esc or q quit\n"
    else
        "Keys: ↑/↓ scroll, PgUp/PgDn page, Home/End jump, Esc or q quit\n";
}

pub fn writeListTuiFooter(out: *std.Io.Writer, use_color: bool) !void {
    try writeListTuiFooterBounded(out, use_color, null);
}

pub fn writeListTuiFooterBounded(out: *std.Io.Writer, use_color: bool, max_cols: ?usize) !void {
    try writeStyledTuiLineBounded(out, if (use_color) style.ansi.cyan else "", listTuiFooterText(builtin.os.tag == .windows), max_cols);
}

pub fn writeTuiLineBounded(out: *std.Io.Writer, text: []const u8, max_cols: ?usize) !void {
    try writeTuiLineContentBounded(out, text, max_cols);
    try out.writeAll("\n");
}

pub fn writeStyledTuiLineBounded(out: *std.Io.Writer, ansi_style: []const u8, text: []const u8, max_cols: ?usize) !void {
    if (ansi_style.len != 0) try out.writeAll(ansi_style);
    try writeTuiLineContentBounded(out, text, max_cols);
    if (ansi_style.len != 0) try out.writeAll(style.ansi.reset);
    try out.writeAll("\n");
}

fn writeTuiLineContentBounded(out: *std.Io.Writer, text: []const u8, max_cols: ?usize) !void {
    const line = if (std.mem.endsWith(u8, text, "\n")) text[0 .. text.len - 1] else text;
    const limit = max_cols orelse {
        try out.writeAll(line);
        return;
    };
    if (line.len <= limit) {
        try out.writeAll(line);
    } else if (limit == 1) {
        try out.writeAll(".");
    } else if (limit > 1) {
        try out.writeAll(line[0 .. limit - 1]);
        try out.writeAll(".");
    }
}

pub fn writeTuiPromptLine(out: *std.Io.Writer, prompt: []const u8, digits: []const u8) !void {
    try out.writeAll(prompt);
    if (digits.len != 0) {
        try out.writeAll(" ");
        try out.writeAll(digits);
    }
    try out.writeAll("\n");
}

const TuiSavedInputState = if (builtin.os.tag == .windows) win.DWORD else std.posix.termios;
const TuiSavedOutputState = if (builtin.os.tag == .windows) win.DWORD else void;

pub fn mapTuiOutputError(err: anyerror) anyerror {
    return switch (err) {
        error.WriteFailed => error.TuiOutputUnavailable,
        else => err,
    };
}

pub const TuiSession = struct {
    input: std.Io.File,
    output: std.Io.File,
    saved_input_state: TuiSavedInputState = if (builtin.os.tag == .windows) 0 else undefined,
    saved_output_state: TuiSavedOutputState = if (builtin.os.tag == .windows) 0 else {},
    pending_windows_key: ?TuiInputKey = null,
    pending_windows_repeat_count: u16 = 0,
    keyboard_enhancement_supported: bool = false,
    last_frame_hash: u64 = 0,
    last_frame_line_count: usize = 0,
    has_last_frame: bool = false,
    writer_buffer: [4096]u8 = undefined,
    writer: std.Io.File.Writer = undefined,

    pub fn init(self: *@This()) !void {
        const input = std.Io.File.stdin();
        const output = std.Io.File.stdout();
        if (!(try input.isTty(app_runtime.io())) or !(try output.isTty(app_runtime.io()))) {
            return error.TuiRequiresTty;
        }

        if (comptime builtin.os.tag == .windows) {
            var saved_input_mode: win.DWORD = 0;
            var saved_output_mode: win.DWORD = 0;
            if (win.GetConsoleMode(input.handle, &saved_input_mode) == .FALSE) {
                return error.TuiRequiresTty;
            }
            if (win.GetConsoleMode(output.handle, &saved_output_mode) == .FALSE) {
                return error.TuiRequiresTty;
            }

            const raw_input_mode = windowsTuiInputMode(saved_input_mode);
            if (win.SetConsoleMode(input.handle, raw_input_mode) == .FALSE) {
                return error.TuiRequiresTty;
            }
            errdefer _ = win.SetConsoleMode(input.handle, saved_input_mode);

            const raw_output_mode = windowsTuiOutputMode(saved_output_mode);
            if (win.SetConsoleMode(output.handle, raw_output_mode) == .FALSE) {
                return error.TuiRequiresTty;
            }
            errdefer _ = win.SetConsoleMode(output.handle, saved_output_mode);

            self.* = .{
                .input = input,
                .output = output,
                .saved_input_state = saved_input_mode,
                .saved_output_state = saved_output_mode,
            };
            self.writer = self.output.writer(app_runtime.io(), &self.writer_buffer);
            self.enter() catch |err| return mapTuiOutputError(err);
        } else {
            const saved_termios = try std.posix.tcgetattr(input.handle);
            var raw = saved_termios;
            raw.lflag.ICANON = false;
            raw.lflag.ECHO = false;
            raw.cc[@intFromEnum(std.c.V.MIN)] = 1;
            raw.cc[@intFromEnum(std.c.V.TIME)] = 0;
            try std.posix.tcsetattr(input.handle, .FLUSH, raw);
            errdefer std.posix.tcsetattr(input.handle, .FLUSH, saved_termios) catch {};

            self.* = .{
                .input = input,
                .output = output,
                .saved_input_state = saved_termios,
            };
            self.writer = self.output.writer(app_runtime.io(), &self.writer_buffer);
            self.enter() catch |err| return mapTuiOutputError(err);
        }
    }

    pub fn deinit(self: *@This()) void {
        const writer = self.out();
        writeTuiExitTo(writer) catch {};
        writer.flush() catch {};
        if (comptime builtin.os.tag == .windows) {
            _ = win.SetConsoleMode(self.output.handle, self.saved_output_state);
            _ = win.SetConsoleMode(self.input.handle, self.saved_input_state);
        } else {
            std.posix.tcsetattr(self.input.handle, .FLUSH, self.saved_input_state) catch {};
        }
        self.* = undefined;
    }

    pub fn out(self: *@This()) *std.Io.Writer {
        return &self.writer.interface;
    }

    pub fn read(self: *@This(), buffer: []u8) !usize {
        return try readFileOnce(self.input, buffer);
    }

    pub fn readInputKeys(self: *@This(), timeout_ms: i32, keys: []TuiInputKey) !TuiInputRead {
        std.debug.assert(keys.len != 0);

        switch (try pollTuiInput(self.input, timeout_ms, tui_poll_error_mask)) {
            .timeout => return .timeout,
            .closed => return .closed,
            .ready => {},
        }

        if (comptime builtin.os.tag == .windows) {
            keys[0] = try self.readWindowsKey();
            return .{ .ready = 1 };
        }

        var buffer: [64]u8 = undefined;
        const n = try self.read(&buffer);
        if (n == 0) return .closed;

        var key_count: usize = 0;
        var i: usize = 0;
        while (i < n) : (i += 1) {
            if (buffer[i] == 0x1b) {
                const escape = try readTuiEscapeAction(
                    self.input,
                    buffer[i + 1 .. n],
                    tui_poll_error_mask,
                    tui_escape_sequence_timeout_ms,
                );
                switch (escape.action) {
                    .move_up => appendTuiInputKey(keys, &key_count, if (self.keyboard_enhancement_supported) .scroll_up else .move_up),
                    .move_down => appendTuiInputKey(keys, &key_count, if (self.keyboard_enhancement_supported) .scroll_down else .move_down),
                    .keyboard_up => appendTuiInputKey(keys, &key_count, .keyboard_up),
                    .keyboard_down => appendTuiInputKey(keys, &key_count, .keyboard_down),
                    .page_up => appendTuiInputKey(keys, &key_count, .page_up),
                    .page_down => appendTuiInputKey(keys, &key_count, .page_down),
                    .home => appendTuiInputKey(keys, &key_count, .home),
                    .end => appendTuiInputKey(keys, &key_count, .end),
                    .scroll_up => appendTuiInputKey(keys, &key_count, .scroll_up),
                    .scroll_down => appendTuiInputKey(keys, &key_count, .scroll_down),
                    .quit => appendTuiInputKey(keys, &key_count, .quit),
                    .keyboard_enhancement_supported => self.keyboard_enhancement_supported = true,
                    .ignore => {},
                }
                i += escape.buffered_bytes_consumed;
                continue;
            }

            switch (buffer[i]) {
                '\r', '\n' => appendTuiInputKey(keys, &key_count, .enter),
                0x7f, 0x08 => appendTuiInputKey(keys, &key_count, .backspace),
                else => appendTuiInputKey(keys, &key_count, .{ .byte = buffer[i] }),
            }
        }

        return .{ .ready = key_count };
    }

    pub fn terminalRows(self: *@This()) usize {
        return if (terminalSize(self.output)) |size| size.rows else 24;
    }

    pub fn terminalCols(self: *@This()) usize {
        return if (terminalSize(self.output)) |size| size.cols else 80;
    }

    pub fn readWindowsKey(self: *@This()) !TuiInputKey {
        if (comptime builtin.os.tag != .windows) unreachable;

        if (self.pending_windows_key) |pending| {
            if (self.pending_windows_repeat_count > 1) {
                self.pending_windows_repeat_count -= 1;
            } else {
                self.pending_windows_repeat_count = 0;
                self.pending_windows_key = null;
            }
            return pending;
        }

        while (true) {
            var record: win.INPUT_RECORD = undefined;
            var events_read: win.DWORD = 0;
            if (win.ReadConsoleInputW(self.input.handle, &record, 1, &events_read) == .FALSE) {
                return error.EndOfStream;
            }
            if (events_read == 0) continue;
            if (record.EventType == win.WINDOW_BUFFER_SIZE_EVENT) {
                self.pending_windows_key = null;
                self.pending_windows_repeat_count = 0;
                return .redraw;
            }
            if (record.EventType != win.KEY_EVENT) continue;

            const key_event = record.Event.KeyEvent;
            if (key_event.bKeyDown == .FALSE) continue;

            const key = switch (key_event.wVirtualKeyCode) {
                win.VK_UP => TuiInputKey.move_up,
                win.VK_DOWN => TuiInputKey.move_down,
                win.VK_PRIOR => TuiInputKey.page_up,
                win.VK_NEXT => TuiInputKey.page_down,
                win.VK_HOME => TuiInputKey.home,
                win.VK_END => TuiInputKey.end,
                win.VK_RETURN => TuiInputKey.enter,
                win.VK_ESCAPE => TuiInputKey.quit,
                win.VK_BACK => TuiInputKey.backspace,
                else => blk: {
                    const codepoint = key_event.uChar.UnicodeChar;
                    if (codepoint == 0 or codepoint > 0x7f) continue;
                    break :blk TuiInputKey{ .byte = @intCast(codepoint) };
                },
            };

            const repeat_count = if (key_event.wRepeatCount == 0) 1 else key_event.wRepeatCount;
            if (repeat_count > 1) {
                self.pending_windows_key = key;
                self.pending_windows_repeat_count = repeat_count - 1;
            }
            return key;
        }
    }

    pub fn enter(self: *@This()) !void {
        const writer = self.out();
        try writeTuiEnterTo(writer);
        try writer.flush();
    }

    pub fn resetFrame(self: *@This()) !void {
        writeTuiResetFrameTo(self.out()) catch |err| return mapTuiOutputError(err);
    }

    pub fn drawFrame(self: *@This(), frame: []const u8) !void {
        const hash = std.hash.Wyhash.hash(0, frame);
        if (self.has_last_frame and hash == self.last_frame_hash) return;
        self.last_frame_line_count = writeTuiFrameTo(
            self.out(),
            frame,
            self.last_frame_line_count,
        ) catch |err| return mapTuiOutputError(err);
        self.last_frame_hash = hash;
        self.has_last_frame = true;
        try self.flushOutput();
    }

    pub fn flushOutput(self: *@This()) !void {
        self.out().flush() catch |err| return mapTuiOutputError(err);
    }
};

fn appendTuiInputKey(keys: []TuiInputKey, key_count: *usize, key: TuiInputKey) void {
    if (key_count.* >= keys.len) return;
    keys[key_count.*] = key;
    key_count.* += 1;
}

pub fn terminalSize(file: std.Io.File) ?TuiSize {
    if (!(file.isTty(app_runtime.io()) catch false)) return null;

    if (comptime builtin.os.tag == .windows) {
        var get_console_info = std.os.windows.CONSOLE.USER_IO.GET_SCREEN_BUFFER_INFO;
        switch (get_console_info.operate(app_runtime.io(), file) catch return null) {
            .SUCCESS => {},
            else => return null,
        }
        const rows = @as(i32, get_console_info.Data.dwWindowSize.Y);
        const cols = @as(i32, get_console_info.Data.dwWindowSize.X);
        if (rows <= 0 or cols <= 0) return null;
        return .{
            .rows = @intCast(rows),
            .cols = @intCast(cols),
        };
    } else {
        var wsz: std.posix.winsize = .{
            .row = 0,
            .col = 0,
            .xpixel = 0,
            .ypixel = 0,
        };
        const rc = std.posix.system.ioctl(file.handle, std.posix.T.IOCGWINSZ, @intFromPtr(&wsz));
        if (std.posix.errno(rc) != .SUCCESS or wsz.row == 0 or wsz.col == 0) return null;
        return .{
            .rows = @intCast(wsz.row),
            .cols = @intCast(wsz.col),
        };
    }
}

fn isKeyboardEnhancementFlagsResponse(seq: []const u8) bool {
    if (seq.len < 4 or seq[0] != '[' or seq[1] != '?' or seq[seq.len - 1] != 'u') return false;
    for (seq[2 .. seq.len - 1]) |ch| {
        if (!std.ascii.isDigit(ch)) return false;
    }
    return true;
}

fn isEnhancedArrowSuffix(seq: []const u8) bool {
    if (seq.len < 4) return false;
    const final = seq[seq.len - 1];
    if (final != 'A' and final != 'B') return false;
    if (seq[0] != '[') return false;

    var has_separator = false;
    for (seq[1 .. seq.len - 1]) |ch| {
        switch (ch) {
            ';', ':' => has_separator = true,
            '0'...'9' => {},
            else => return false,
        }
    }
    return has_separator;
}

fn isCsiUKeyboardArrow(seq: []const u8) ?TuiNavigation {
    if (seq.len < 4 or seq[0] != '[' or seq[seq.len - 1] != 'u') return null;
    const params = seq[1 .. seq.len - 1];
    var code_end: usize = 0;
    while (code_end < params.len and params[code_end] != ':' and params[code_end] != ';') : (code_end += 1) {}
    if (code_end == 0) return null;
    const code = std.fmt.parseInt(usize, params[0..code_end], 10) catch return null;
    return switch (code) {
        57419 => .keyboard_up,
        57420 => .keyboard_down,
        else => null,
    };
}

pub fn classifyTuiEscapeSuffix(seq: []const u8) TuiEscapeClassification {
    if (seq.len == 0) return .incomplete;

    return switch (seq[0]) {
        '[' => blk: {
            if (seq.len == 1) break :blk .incomplete;
            const final = seq[seq.len - 1];
            if (isKeyboardEnhancementFlagsResponse(seq)) break :blk .keyboard_enhancement_supported;
            if (isCsiUKeyboardArrow(seq)) |direction| break :blk .{ .navigation = direction };
            if (seq[1] == '<') {
                if (final != 'M' and final != 'm') {
                    if (final >= '@' and final <= '~') break :blk .ignore;
                    break :blk .incomplete;
                }
                const first_semicolon = std.mem.indexOfScalar(u8, seq[2 .. seq.len - 1], ';') orelse break :blk .ignore;
                const button_code = std.fmt.parseInt(usize, seq[2 .. 2 + first_semicolon], 10) catch break :blk .ignore;
                break :blk switch (button_code) {
                    64 => .{ .navigation = .scroll_up },
                    65 => .{ .navigation = .scroll_down },
                    else => .ignore,
                };
            }
            if (final == 'A' or final == 'B') {
                if (isEnhancedArrowSuffix(seq)) {
                    break :blk .{ .navigation = if (final == 'A') .keyboard_up else .keyboard_down };
                }
                for (seq[1 .. seq.len - 1]) |ch| {
                    if (!std.ascii.isDigit(ch) and ch != ';') break :blk .ignore;
                }
                break :blk .{ .navigation = if (final == 'A') .up else .down };
            }
            if (final == 'H' or final == 'F') {
                for (seq[1 .. seq.len - 1]) |ch| {
                    if (!std.ascii.isDigit(ch) and ch != ';') break :blk .ignore;
                }
                break :blk .{ .navigation = if (final == 'H') .home else .end };
            }
            if (final == '~') {
                for (seq[1 .. seq.len - 1]) |ch| {
                    if (!std.ascii.isDigit(ch) and ch != ';') break :blk .ignore;
                }
                const code = std.fmt.parseInt(usize, seq[1 .. seq.len - 1], 10) catch break :blk .ignore;
                break :blk switch (code) {
                    1, 7 => .{ .navigation = .home },
                    4, 8 => .{ .navigation = .end },
                    5 => .{ .navigation = .page_up },
                    6 => .{ .navigation = .page_down },
                    else => .ignore,
                };
            }
            if (final >= '@' and final <= '~') break :blk .ignore;
            break :blk .incomplete;
        },
        'O' => blk: {
            if (seq.len == 1) break :blk .incomplete;
            const code = seq[1];
            if (code == 'A' or code == 'B') {
                break :blk .{ .navigation = if (code == 'A') .up else .down };
            }
            if (code == 'H' or code == 'F') {
                break :blk .{ .navigation = if (code == 'H') .home else .end };
            }
            break :blk .ignore;
        },
        else => .ignore,
    };
}

pub fn readTuiEscapeAction(
    tty: std.Io.File,
    buffered_tail: []const u8,
    poll_error_mask: i16,
    timeout_ms: i32,
) !TuiEscapeReadResult {
    var seq: [32]u8 = undefined;
    var seq_len: usize = 0;
    var buffered_bytes_consumed: usize = 0;

    while (true) {
        switch (classifyTuiEscapeSuffix(seq[0..seq_len])) {
            .navigation => |direction| {
                return .{
                    .action = switch (direction) {
                        .up => .move_up,
                        .down => .move_down,
                        .keyboard_up => .keyboard_up,
                        .keyboard_down => .keyboard_down,
                        .page_up => .page_up,
                        .page_down => .page_down,
                        .home => .home,
                        .end => .end,
                        .scroll_up => .scroll_up,
                        .scroll_down => .scroll_down,
                    },
                    .buffered_bytes_consumed = buffered_bytes_consumed,
                };
            },
            .keyboard_enhancement_supported => return .{
                .action = .keyboard_enhancement_supported,
                .buffered_bytes_consumed = buffered_bytes_consumed,
            },
            .ignore => return .{
                .action = .ignore,
                .buffered_bytes_consumed = buffered_bytes_consumed,
            },
            .incomplete => {},
        }

        if (buffered_bytes_consumed < buffered_tail.len) {
            if (seq_len == seq.len) {
                return .{
                    .action = .ignore,
                    .buffered_bytes_consumed = buffered_bytes_consumed,
                };
            }
            seq[seq_len] = buffered_tail[buffered_bytes_consumed];
            seq_len += 1;
            buffered_bytes_consumed += 1;
            continue;
        }

        if (seq_len == seq.len) {
            return .{
                .action = .ignore,
                .buffered_bytes_consumed = buffered_bytes_consumed,
            };
        }

        switch (try pollTuiInput(tty, timeout_ms, poll_error_mask)) {
            .timeout => return .{
                .action = if (seq_len == 0) .quit else .ignore,
                .buffered_bytes_consumed = buffered_bytes_consumed,
            },
            .closed => return .{
                .action = .quit,
                .buffered_bytes_consumed = buffered_bytes_consumed,
            },
            .ready => {},
        }

        const read_n = try readFileOnce(tty, seq[seq_len .. seq_len + 1]);
        if (read_n == 0) {
            return .{
                .action = if (seq_len == 0) .quit else .ignore,
                .buffered_bytes_consumed = buffered_bytes_consumed,
            };
        }
        seq_len += read_n;
    }
}

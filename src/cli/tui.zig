const std = @import("std");
const app_runtime = @import("../core/runtime.zig");
const builtin = @import("builtin");
const style = @import("style.zig");
const io = @import("io.zig");
const text_width = @import("../tui/text_width.zig");
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

pub const tui_poll_input_mask: i16 = if (builtin.target.os.tag == .windows) 0 else std.posix.POLL.IN;
pub const tui_poll_error_mask: i16 = if (builtin.target.os.tag == .windows) 0 else std.posix.POLL.ERR | std.posix.POLL.HUP | std.posix.POLL.NVAL;
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
    key: TuiInputKey,
};

pub const TuiEscapeAction = enum {
    quit,
    ignore,
    enter,
    backspace,
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
    /// Set when a byte following a standalone Esc was already consumed from
    /// the TTY and must be replayed as a normal key by the caller.
    pending_byte: ?u8 = null,
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

pub const pollTuiInput = if (builtin.target.os.tag == .windows)
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
        const newline = std.mem.findScalarPos(u8, frame, start, '\n') orelse frame.len;
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

/// Footer legends shrink in three semantic tiers instead of hard-truncating:
/// the full legend, a mid variant keeping the mode's verbs, and a compact
/// variant keeping only the commit and exit keys. `·`/`↑` stay out of the
/// Windows set per docs/windows.md.
const FooterLadder = struct {
    full: []const u8,
    mid: []const u8,
    compact: []const u8,
};

fn footerFor(ladder: FooterLadder, max_cols: ?usize) []const u8 {
    const limit = max_cols orelse return ladder.full;
    if (text_width.displayWidth(ladder.full) <= limit) return ladder.full;
    if (text_width.displayWidth(ladder.mid) <= limit) return ladder.mid;
    return ladder.compact;
}

fn switchFooterLadder(is_windows: bool) FooterLadder {
    return if (is_windows) .{
        .full = "Keys: Up/Down or j/k, 1-9 type, Enter select, Esc or q quit\n",
        .mid = "Up/Down - Enter select - Esc quit\n",
        .compact = "Enter select - Esc quit\n",
    } else .{
        .full = "Keys: ↑/↓ or j/k, 1-9 type, Enter select, Esc or q quit\n",
        .mid = "↑/↓ · Enter select · Esc quit\n",
        .compact = "Enter select · Esc quit\n",
    };
}

pub fn switchTuiFooterText(is_windows: bool) []const u8 {
    return switchFooterLadder(is_windows).full;
}

/// Widest switch legend that fits `max_cols`, so narrow terminals still show
/// the select/quit keys instead of a sliced sentence.
pub fn switchTuiFooterTextFor(is_windows: bool, max_cols: ?usize) []const u8 {
    return footerFor(switchFooterLadder(is_windows), max_cols);
}

pub fn writeSwitchTuiFooterBounded(out: *std.Io.Writer, use_color: bool, max_cols: ?usize) !void {
    try writeStyledTuiLineBounded(out, if (use_color) style.ansi.cyan else "", switchTuiFooterTextFor(builtin.target.os.tag == .windows, max_cols), max_cols);
}

fn removeFooterLadder(is_windows: bool) FooterLadder {
    return if (is_windows) .{
        .full = "Keys: Up/Down or j/k move, Space toggle, 1-9 type, Enter delete, Esc or q quit\n",
        .mid = "Up/Down - Space - Enter delete - Esc quit\n",
        .compact = "Enter delete - Esc quit\n",
    } else .{
        .full = "Keys: ↑/↓ or j/k move, Space toggle, 1-9 type, Enter delete, Esc or q quit\n",
        .mid = "↑/↓ · Space · Enter delete · Esc quit\n",
        .compact = "Enter delete · Esc quit\n",
    };
}

pub fn removeTuiFooterText(is_windows: bool) []const u8 {
    return removeFooterLadder(is_windows).full;
}

pub fn removeTuiFooterTextFor(is_windows: bool, max_cols: ?usize) []const u8 {
    return footerFor(removeFooterLadder(is_windows), max_cols);
}

pub fn writeRemoveTuiFooterBounded(out: *std.Io.Writer, use_color: bool, max_cols: ?usize) !void {
    try writeStyledTuiLineBounded(out, if (use_color) style.ansi.cyan else "", removeTuiFooterTextFor(builtin.target.os.tag == .windows, max_cols), max_cols);
}

fn listFooterLadder(is_windows: bool) FooterLadder {
    return if (is_windows) .{
        .full = "Keys: Up/Down scroll, j/k row, Enter credits, PgUp/PgDn/Home/End page, Esc/q quit\n",
        .mid = "j/k row - Enter credits - Esc quit\n",
        .compact = "Enter - Esc\n",
    } else .{
        .full = "Keys: ↑/↓ scroll, j/k row, Enter credits, PgUp/PgDn/Home/End page, Esc/q quit\n",
        .mid = "j/k row · Enter credits · Esc quit\n",
        .compact = "Enter · Esc\n",
    };
}

pub fn listTuiFooterText(is_windows: bool) []const u8 {
    return listFooterLadder(is_windows).full;
}

pub fn listTuiFooterTextFor(is_windows: bool, max_cols: ?usize) []const u8 {
    return footerFor(listFooterLadder(is_windows), max_cols);
}

fn listCreditsFooterLadder(is_windows: bool) FooterLadder {
    return if (is_windows) .{
        .full = "Keys: Up/Down or j/k credit, Enter redeem, Esc/q back\n",
        .mid = "Up/Down - Enter redeem - Esc back\n",
        .compact = "Enter redeem - Esc\n",
    } else .{
        .full = "Keys: ↑/↓ or j/k credit, Enter redeem, Esc/q back\n",
        .mid = "↑/↓ · Enter redeem · Esc back\n",
        .compact = "Enter redeem · Esc\n",
    };
}

/// Footer while the reset credits rail owns the navigation keys. It replaces
/// the account-list legend entirely, so the rail mode shows only its own
/// actions and cannot imply that `j`/`k` still move account rows.
pub fn listCreditsTuiFooterText(is_windows: bool) []const u8 {
    return listCreditsFooterLadder(is_windows).full;
}

pub fn listCreditsTuiFooterTextFor(is_windows: bool, max_cols: ?usize) []const u8 {
    return footerFor(listCreditsFooterLadder(is_windows), max_cols);
}

pub fn writeListTuiFooterBounded(out: *std.Io.Writer, use_color: bool, max_cols: ?usize) !void {
    try writeStyledTuiLineBounded(out, if (use_color) style.ansi.cyan else "", listTuiFooterTextFor(builtin.target.os.tag == .windows, max_cols), max_cols);
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
    if (text_width.displayWidth(line) <= limit) {
        try out.writeAll(line);
        return;
    }
    // Line-level truncation keeps a `...` tail — unlike the single `.` used
    // inside table cells, a cut sentence still reads as one.
    if (limit <= 3) {
        try out.writeAll(line[0..text_width.prefixByteLength(line, limit)]);
        return;
    }
    try out.writeAll(line[0..text_width.prefixByteLength(line, limit - 3)]);
    try out.writeAll("...");
}

pub fn writeTuiPromptLine(out: *std.Io.Writer, prompt: []const u8, digits: []const u8) !void {
    try writeTuiPromptLineBounded(out, prompt, digits, null);
}

/// Prompt plus the in-progress digit echo, bounded to `max_cols`. Typed digits
/// are the live feedback the user is watching, so on a tight line the prompt
/// is what gives way — same priority split as the rail's confirm hint.
pub fn writeTuiPromptLineBounded(out: *std.Io.Writer, prompt: []const u8, digits: []const u8, max_cols: ?usize) !void {
    const limit = max_cols orelse {
        try out.writeAll(prompt);
        if (digits.len != 0) {
            try out.writeAll(" ");
            try out.writeAll(digits);
        }
        try out.writeAll("\n");
        return;
    };
    if (digits.len == 0) {
        try writeTuiLineContentBounded(out, prompt, limit);
        try out.writeAll("\n");
        return;
    }
    const digits_width = text_width.displayWidth(digits);
    if (digits_width + 1 >= limit) {
        try writeTuiLineContentBounded(out, digits, limit);
        try out.writeAll("\n");
        return;
    }
    try writeTuiLineContentBounded(out, prompt, limit - digits_width - 1);
    try out.writeAll(" ");
    try out.writeAll(digits);
    try out.writeAll("\n");
}

const TuiSavedInputState = if (builtin.target.os.tag == .windows) win.DWORD else std.posix.termios;
const TuiSavedOutputState = if (builtin.target.os.tag == .windows) win.DWORD else void;

pub fn mapTuiOutputError(err: anyerror) anyerror {
    return switch (err) {
        error.WriteFailed => error.TuiOutputUnavailable,
        else => err,
    };
}

pub const TuiSession = struct {
    input: std.Io.File,
    output: std.Io.File,
    saved_input_state: TuiSavedInputState = if (builtin.target.os.tag == .windows) 0 else undefined,
    saved_output_state: TuiSavedOutputState = if (builtin.target.os.tag == .windows) 0 else {},
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

        if (comptime builtin.target.os.tag == .windows) {
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
            // Signals would kill the process before `deinit` can restore the
            // terminal; with ISIG off, Ctrl-C arrives as a byte the input loop
            // maps to `.quit`, so quitting always runs the restore path.
            raw.lflag.ISIG = false;
            raw.cc[@backingInt(std.c.V.MIN)] = 1;
            raw.cc[@backingInt(std.c.V.TIME)] = 0;
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
        if (comptime builtin.target.os.tag == .windows) {
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

        if (comptime builtin.target.os.tag == .windows) {
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
                i += try appendTuiInputKeysFromEscape(
                    self.input,
                    buffer[i + 1 .. n],
                    keys,
                    &key_count,
                    &self.keyboard_enhancement_supported,
                );
                continue;
            }

            appendTuiInputKey(keys, &key_count, tuiInputKeyFromByte(buffer[i]));
        }

        return .{ .ready = key_count };
    }

    pub fn terminalRows(self: *@This()) usize {
        // A terminal may report only one dimension (rows or cols as 0), so
        // each accessor falls back independently instead of losing both.
        const rows = if (terminalSize(self.output)) |size| size.rows else 0;
        return if (rows != 0) rows else 24;
    }

    pub fn terminalCols(self: *@This()) usize {
        const cols = if (terminalSize(self.output)) |size| size.cols else 0;
        return if (cols != 0) cols else 80;
    }

    pub fn readWindowsKey(self: *@This()) !TuiInputKey {
        if (comptime builtin.target.os.tag != .windows) unreachable;

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
                    break :blk tuiInputKeyFromByte(@intCast(codepoint));
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

/// Byte-to-key mapping shared by the normal input path, the `pending_byte`
/// replay, and the Windows console reader: Enter variants, backspace
/// variants, and Ctrl-C, which arrives as a byte because ISIG and
/// ENABLE_PROCESSED_INPUT stay off for the whole session.
pub fn tuiInputKeyFromByte(byte: u8) TuiInputKey {
    return switch (byte) {
        '\r', '\n' => .enter,
        0x7f, 0x08 => .backspace,
        0x03 => .quit,
        else => .{ .byte = byte },
    };
}

/// Translates the bytes that follow a consumed Esc into input keys and returns
/// how many `buffered_tail` bytes that took. A `pending_byte` that cannot
/// start a known sequence replays through `tuiInputKeyFromByte`, so Enter and
/// Backspace mean the same thing there as anywhere else. A pending Esc is
/// trickier: it may head a real sequence (Esc then Arrow inside one read or
/// paste), so it re-enters the parser instead of assuming a second quit —
/// otherwise Esc+Arrow would read as Esc+Esc and quit twice.
pub fn appendTuiInputKeysFromEscape(
    tty: std.Io.File,
    buffered_tail: []const u8,
    keys: []TuiInputKey,
    key_count: *usize,
    keyboard_enhancement_supported: *bool,
) !usize {
    var consumed: usize = 0;
    while (true) {
        const escape = try readTuiEscapeAction(
            tty,
            buffered_tail[consumed..],
            tui_poll_error_mask,
            tui_escape_sequence_timeout_ms,
        );
        consumed += escape.buffered_bytes_consumed;
        switch (escape.action) {
            .enter => appendTuiInputKey(keys, key_count, .enter),
            .backspace => appendTuiInputKey(keys, key_count, .backspace),
            .move_up => appendTuiInputKey(keys, key_count, if (keyboard_enhancement_supported.*) .scroll_up else .move_up),
            .move_down => appendTuiInputKey(keys, key_count, if (keyboard_enhancement_supported.*) .scroll_down else .move_down),
            .keyboard_up => appendTuiInputKey(keys, key_count, .keyboard_up),
            .keyboard_down => appendTuiInputKey(keys, key_count, .keyboard_down),
            .page_up => appendTuiInputKey(keys, key_count, .page_up),
            .page_down => appendTuiInputKey(keys, key_count, .page_down),
            .home => appendTuiInputKey(keys, key_count, .home),
            .end => appendTuiInputKey(keys, key_count, .end),
            .scroll_up => appendTuiInputKey(keys, key_count, .scroll_up),
            .scroll_down => appendTuiInputKey(keys, key_count, .scroll_down),
            .quit => {
                appendTuiInputKey(keys, key_count, .quit);
                if (escape.pending_byte) |byte| {
                    if (byte == 0x1b) continue;
                    appendTuiInputKey(keys, key_count, tuiInputKeyFromByte(byte));
                }
            },
            .keyboard_enhancement_supported => keyboard_enhancement_supported.* = true,
            .ignore => {},
        }
        break;
    }
    return consumed;
}

pub fn terminalSize(file: std.Io.File) ?TuiSize {
    if (!(file.isTty(app_runtime.io()) catch false)) return null;

    if (comptime builtin.target.os.tag == .windows) {
        var get_console_info = std.os.windows.CONSOLE.USER_IO.GET_SCREEN_BUFFER_INFO;
        switch (get_console_info.operate(app_runtime.io(), file) catch return null) {
            .SUCCESS => {},
            else => return null,
        }
        const rows = @as(i32, get_console_info.Data.dwWindowSize.Y);
        const cols = @as(i32, get_console_info.Data.dwWindowSize.X);
        // 0 means "unknown" for that dimension; only fail when both are.
        if (rows <= 0 and cols <= 0) return null;
        return .{
            .rows = @intCast(@max(0, rows)),
            .cols = @intCast(@max(0, cols)),
        };
    } else {
        var wsz: std.posix.winsize = .{
            .row = 0,
            .col = 0,
            .xpixel = 0,
            .ypixel = 0,
        };
        const rc = std.posix.system.ioctl(file.handle, std.posix.T.IOCGWINSZ, @intFromPtr(&wsz));
        if (std.posix.errno(rc) != .SUCCESS or (wsz.row == 0 and wsz.col == 0)) return null;
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

/// Event type carried in a kitty `key;mods:event` parameter tail: 1 press,
/// 2 repeat, 3 release. Legacy sequences carry none and count as a press.
/// The same check the CSI-u decoder applies, for the CSI-letter forms.
fn csiKeyEventType(params: []const u8) usize {
    const last_field = if (std.mem.findScalarLast(u8, params, ';')) |semi|
        params[semi + 1 ..]
    else
        params;
    const colon = std.mem.findScalar(u8, last_field, ':') orelse return 1;
    return std.fmt.parseInt(usize, last_field[colon + 1 ..], 10) catch 1;
}

/// Decodes a `CSI <key>;<modifiers>:<event-type> u` key event (the kitty
/// keyboard protocol the `\x1b[>7u` push enables). Disambiguate moves Escape,
/// Enter and Backspace off their legacy bytes — Esc arrives as `27u`, and
/// Ctrl-C arrives as `99;5` rather than byte 0x03. Returns null for sequences
/// that stay `.ignore`: key releases (event type 3 — press and repeat both
/// fire), unbound keys, and malformed parameters.
fn csiUKey(seq: []const u8) ?TuiInputKey {
    if (seq.len < 3 or seq[0] != '[' or seq[seq.len - 1] != 'u') return null;
    const params = seq[1 .. seq.len - 1];

    // Field 1 is `key-code[:shifted[:base-layout]]`; field 2 is
    // `modifiers[:event-type]`. The alternate key codes and any third field
    // (text codepoints) are irrelevant to the keys this TUI binds.
    var fields = std.mem.splitScalar(u8, params, ';');
    const key_field = fields.first();
    const code_end = std.mem.findScalar(u8, key_field, ':') orelse key_field.len;
    const code = std.fmt.parseInt(usize, key_field[0..code_end], 10) catch return null;

    var modifiers: usize = 1;
    var event_type: usize = 1;
    if (fields.next()) |mod_field| {
        if (std.mem.findScalar(u8, mod_field, ':')) |colon| {
            modifiers = std.fmt.parseInt(usize, mod_field[0..colon], 10) catch 1;
            event_type = std.fmt.parseInt(usize, mod_field[colon + 1 ..], 10) catch 1;
        } else if (mod_field.len != 0) {
            modifiers = std.fmt.parseInt(usize, mod_field, 10) catch 1;
        }
    }
    if (event_type == 3) return null;

    return switch (code) {
        27 => .quit,
        13 => .enter,
        127 => .backspace,
        57419 => .keyboard_up,
        57420 => .keyboard_down,
        99 => if (modifiers > 1 and (modifiers - 1) & 4 != 0) .quit else null,
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
            if (csiUKey(seq)) |key| break :blk .{ .key = key };
            if (seq[1] == '<') {
                if (final != 'M' and final != 'm') {
                    if (final >= '@' and final <= '~') break :blk .ignore;
                    break :blk .incomplete;
                }
                const first_semicolon = std.mem.findScalar(u8, seq[2 .. seq.len - 1], ';') orelse break :blk .ignore;
                const button_code = std.fmt.parseInt(usize, seq[2 .. 2 + first_semicolon], 10) catch break :blk .ignore;
                break :blk switch (button_code) {
                    64 => .{ .navigation = .scroll_up },
                    65 => .{ .navigation = .scroll_down },
                    else => .ignore,
                };
            }
            if (final == 'A' or final == 'B') {
                const params = seq[1 .. seq.len - 1];
                if (isEnhancedArrowSuffix(seq)) {
                    // Kitty reports a key release as `1;mods:3 A/B`; without
                    // this filter a single press moves twice.
                    if (csiKeyEventType(params) == 3) break :blk .ignore;
                    break :blk .{ .navigation = if (final == 'A') .keyboard_up else .keyboard_down };
                }
                for (params) |ch| {
                    if (!std.ascii.isDigit(ch) and ch != ';') break :blk .ignore;
                }
                break :blk .{ .navigation = if (final == 'A') .up else .down };
            }
            if (final == 'H' or final == 'F') {
                const params = seq[1 .. seq.len - 1];
                for (params) |ch| {
                    if (!std.ascii.isDigit(ch) and ch != ';' and ch != ':') break :blk .ignore;
                }
                if (csiKeyEventType(params) == 3) break :blk .ignore;
                break :blk .{ .navigation = if (final == 'H') .home else .end };
            }
            if (final == '~') {
                const params = seq[1 .. seq.len - 1];
                for (params) |ch| {
                    if (!std.ascii.isDigit(ch) and ch != ';' and ch != ':') break :blk .ignore;
                }
                if (csiKeyEventType(params) == 3) break :blk .ignore;
                // The key number is the first field; modifiers and the event
                // type live in later fields the TUI does not bind.
                const key_end = std.mem.findScalar(u8, params, ';') orelse params.len;
                const code = std.fmt.parseInt(usize, params[0..key_end], 10) catch break :blk .ignore;
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

fn isTuiEscapeSequenceStarter(byte: u8) bool {
    // CSI (`\x1b[...`) and SS3 (`\x1bO...`) cover everything this TUI reads:
    // arrows, PgUp/PgDn, Home/End, mouse, and the keyboard-enhancement reply.
    return byte == '[' or byte == 'O';
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
        // A bare Esc followed by a byte that cannot start a known sequence is a
        // standalone Esc, not the head of an unknown sequence. Without this,
        // fast typists and key auto-repeat lose the Esc (and the byte) to the
        // `.ignore` path: the escape-sequence window would swallow both. The
        // byte travels out as `pending_byte` for the caller to replay.
        if (seq_len == 1 and !isTuiEscapeSequenceStarter(seq[0])) {
            return .{
                .action = .quit,
                .buffered_bytes_consumed = buffered_bytes_consumed,
                .pending_byte = seq[0],
            };
        }
        switch (classifyTuiEscapeSuffix(seq[0..seq_len])) {
            .key => |key| {
                return .{
                    .action = switch (key) {
                        .quit => .quit,
                        .enter => .enter,
                        .backspace => .backspace,
                        .keyboard_up => .keyboard_up,
                        .keyboard_down => .keyboard_down,
                        else => .ignore,
                    },
                    .buffered_bytes_consumed = buffered_bytes_consumed,
                };
            },
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

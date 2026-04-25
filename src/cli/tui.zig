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

pub const TuiNavigation = enum {
    up,
    down,
};

pub const TuiEscapeClassification = union(enum) {
    incomplete,
    ignore,
    navigation: TuiNavigation,
};

pub const TuiEscapeAction = enum {
    quit,
    ignore,
    move_up,
    move_down,
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

pub const TuiInputKey = union(enum) {
    move_up,
    move_down,
    enter,
    quit,
    backspace,
    redraw,
    byte: u8,
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
    try out.writeAll("\x1b[?1049h\x1b[?25l");
    try out.writeAll("\x1b[H\x1b[J");
}

pub fn writeTuiExitTo(out: *std.Io.Writer) !void {
    try out.writeAll("\x1b[?25h\x1b[?1049l");
}

pub fn writeTuiResetFrameTo(out: *std.Io.Writer) !void {
    try out.writeAll("\x1b[H\x1b[J");
}

pub fn switchTuiFooterText(is_windows: bool) []const u8 {
    return if (is_windows)
        "Keys: Up/Down or j/k, 1-9 type, Enter select, Esc or q quit\n"
    else
        "Keys: ↑/↓ or j/k, 1-9 type, Enter select, Esc or q quit\n";
}

pub fn writeSwitchTuiFooter(out: *std.Io.Writer, use_color: bool) !void {
    if (use_color) try out.writeAll(style.ansi.dim);
    try out.writeAll(switchTuiFooterText(builtin.os.tag == .windows));
    if (use_color) try out.writeAll(style.ansi.reset);
}

pub fn removeTuiFooterText(is_windows: bool) []const u8 {
    return if (is_windows)
        "Keys: Up/Down or j/k move, Space toggle, 1-9 type, Enter delete, Esc or q quit\n"
    else
        "Keys: ↑/↓ or j/k move, Space toggle, 1-9 type, Enter delete, Esc or q quit\n";
}

pub fn writeRemoveTuiFooter(out: *std.Io.Writer, use_color: bool) !void {
    if (use_color) try out.writeAll(style.ansi.dim);
    try out.writeAll(removeTuiFooterText(builtin.os.tag == .windows));
    if (use_color) try out.writeAll(style.ansi.reset);
}

pub fn writeListTuiFooter(out: *std.Io.Writer, use_color: bool) !void {
    if (use_color) try out.writeAll(style.ansi.dim);
    try out.writeAll("Keys: Esc or q quit\n");
    if (use_color) try out.writeAll(style.ansi.reset);
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

    pub fn flushOutput(self: *@This()) !void {
        self.out().flush() catch |err| return mapTuiOutputError(err);
    }
};

pub fn classifyTuiEscapeSuffix(seq: []const u8) TuiEscapeClassification {
    if (seq.len == 0) return .incomplete;

    return switch (seq[0]) {
        '[' => blk: {
            if (seq.len == 1) break :blk .incomplete;
            const final = seq[seq.len - 1];
            if (final == 'A' or final == 'B') {
                for (seq[1 .. seq.len - 1]) |ch| {
                    if (!std.ascii.isDigit(ch) and ch != ';') break :blk .ignore;
                }
                break :blk .{ .navigation = if (final == 'A') .up else .down };
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
    var seq: [8]u8 = undefined;
    var seq_len: usize = 0;
    var buffered_bytes_consumed: usize = 0;

    while (true) {
        switch (classifyTuiEscapeSuffix(seq[0..seq_len])) {
            .navigation => |direction| {
                return .{
                    .action = switch (direction) {
                        .up => .move_up,
                        .down => .move_down,
                    },
                    .buffered_bytes_consumed = buffered_bytes_consumed,
                };
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

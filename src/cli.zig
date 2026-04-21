const std = @import("std");
const app_runtime = @import("runtime.zig");
const builtin = @import("builtin");
const display_rows = @import("display_rows.zig");
const registry = @import("registry.zig");
const io_util = @import("io_util.zig");
const terminal_color = @import("terminal_color.zig");
const timefmt = @import("timefmt.zig");
const version = @import("version.zig");
const windows = std.os.windows;
const c = @cImport({
    @cInclude("time.h");
});
const win = struct {
    const BOOL = windows.BOOL;
    const CHAR = windows.CHAR;
    const DWORD = windows.DWORD;
    const HANDLE = windows.HANDLE;
    const SHORT = windows.SHORT;
    const WCHAR = windows.WCHAR;
    const WORD = windows.WORD;

    const ENABLE_PROCESSED_INPUT: DWORD = 0x0001;
    const ENABLE_LINE_INPUT: DWORD = 0x0002;
    const ENABLE_ECHO_INPUT: DWORD = 0x0004;
    const ENABLE_WINDOW_INPUT: DWORD = 0x0008;
    const ENABLE_MOUSE_INPUT: DWORD = 0x0010;
    const ENABLE_QUICK_EDIT_MODE: DWORD = 0x0040;
    const ENABLE_EXTENDED_FLAGS: DWORD = 0x0080;
    const ENABLE_VIRTUAL_TERMINAL_INPUT: DWORD = 0x0200;

    const ENABLE_PROCESSED_OUTPUT: DWORD = 0x0001;
    const ENABLE_VIRTUAL_TERMINAL_PROCESSING: DWORD = windows.ENABLE_VIRTUAL_TERMINAL_PROCESSING;

    const KEY_EVENT: WORD = 0x0001;
    const WINDOW_BUFFER_SIZE_EVENT: WORD = 0x0004;

    const VK_BACK: WORD = 0x08;
    const VK_RETURN: WORD = 0x0D;
    const VK_ESCAPE: WORD = 0x1B;
    const VK_UP: WORD = 0x26;
    const VK_DOWN: WORD = 0x28;

    const WAIT_OBJECT_0: DWORD = 0x00000000;
    const WAIT_TIMEOUT: DWORD = 258;
    const INFINITE: DWORD = 0xFFFF_FFFF;

    const KEY_EVENT_RECORD = extern struct {
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

    const COORD = extern struct {
        X: SHORT,
        Y: SHORT,
    };

    const WINDOW_BUFFER_SIZE_RECORD = extern struct {
        dwSize: COORD,
    };

    const INPUT_RECORD = extern struct {
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

const ansi = struct {
    const reset = "\x1b[0m";
    const dim = "\x1b[2m";
    const red = "\x1b[31m";
    const bold_red = "\x1b[1;31m";
    const yellow = "\x1b[33m";
    const bold_yellow = "\x1b[1;33m";
    const green = "\x1b[32m";
    const bold_green = "\x1b[1;32m";
    const cyan = "\x1b[36m";
    const bold_cyan = "\x1b[1;36m";
    const bold = "\x1b[1m";
};

const tui_poll_input_mask: i16 = if (builtin.os.tag == .windows) 0 else std.posix.POLL.IN;
const tui_poll_error_mask: i16 = if (builtin.os.tag == .windows) 0 else std.posix.POLL.ERR | std.posix.POLL.HUP | std.posix.POLL.NVAL;
const tui_escape_sequence_timeout_ms: i32 = 100;

const TuiNavigation = enum {
    up,
    down,
};

const TuiEscapeClassification = union(enum) {
    incomplete,
    ignore,
    navigation: TuiNavigation,
};

const TuiEscapeAction = enum {
    quit,
    ignore,
    move_up,
    move_down,
};

const TuiEscapeReadResult = struct {
    action: TuiEscapeAction,
    buffered_bytes_consumed: usize,
};

const TuiPollResult = enum {
    ready,
    timeout,
    closed,
};

const TuiInputKey = union(enum) {
    move_up,
    move_down,
    enter,
    quit,
    backspace,
    redraw,
    byte: u8,
};

fn windowsTuiInputMode(saved_input_mode: win.DWORD) win.DWORD {
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

fn windowsTuiOutputMode(saved_output_mode: win.DWORD) win.DWORD {
    return saved_output_mode |
        win.ENABLE_PROCESSED_OUTPUT |
        win.ENABLE_VIRTUAL_TERMINAL_PROCESSING;
}

const pollTuiInput = if (builtin.os.tag == .windows)
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

fn writeTuiEnterTo(out: *std.Io.Writer) !void {
    try out.writeAll("\x1b[?1049h\x1b[?25l");
    try out.writeAll("\x1b[H\x1b[J");
}

fn writeTuiExitTo(out: *std.Io.Writer) !void {
    try out.writeAll("\x1b[?25h\x1b[?1049l");
}

fn writeTuiResetFrameTo(out: *std.Io.Writer) !void {
    try out.writeAll("\x1b[H\x1b[J");
}

fn switchTuiFooterText(is_windows: bool) []const u8 {
    return if (is_windows)
        "Keys: Up/Down or j/k, 1-9 type, Enter select, Esc or q quit\n"
    else
        "Keys: ↑/↓ or j/k, 1-9 type, Enter select, Esc or q quit\n";
}

fn writeSwitchTuiFooter(out: *std.Io.Writer, use_color: bool) !void {
    if (use_color) try out.writeAll(ansi.dim);
    try out.writeAll(switchTuiFooterText(builtin.os.tag == .windows));
    if (use_color) try out.writeAll(ansi.reset);
}

fn removeTuiFooterText(is_windows: bool) []const u8 {
    return if (is_windows)
        "Keys: Up/Down or j/k move, Space toggle, 1-9 type, Enter delete, Esc or q quit\n"
    else
        "Keys: ↑/↓ or j/k move, Space toggle, 1-9 type, Enter delete, Esc or q quit\n";
}

fn writeRemoveTuiFooter(out: *std.Io.Writer, use_color: bool) !void {
    if (use_color) try out.writeAll(ansi.dim);
    try out.writeAll(removeTuiFooterText(builtin.os.tag == .windows));
    if (use_color) try out.writeAll(ansi.reset);
}

fn writeListTuiFooter(out: *std.Io.Writer, use_color: bool) !void {
    if (use_color) try out.writeAll(ansi.dim);
    try out.writeAll("Keys: Esc or q quit\n");
    if (use_color) try out.writeAll(ansi.reset);
}

fn writeTuiPromptLine(out: *std.Io.Writer, prompt: []const u8, digits: []const u8) !void {
    try out.writeAll(prompt);
    if (digits.len != 0) {
        try out.writeAll(" ");
        try out.writeAll(digits);
    }
    try out.writeAll("\n");
}

fn importReportMarker(outcome: registry.ImportOutcome, is_windows: bool) []const u8 {
    return switch (outcome) {
        .imported => if (is_windows) "[+]" else "✓",
        .updated => if (is_windows) "[~]" else "✓",
        .skipped => if (is_windows) "[x]" else "✗",
    };
}

fn activeRowMarker(is_cursor_or_selected: bool, is_active: bool) []const u8 {
    return if (is_cursor_or_selected) "> " else if (is_active) "* " else "  ";
}

const TuiSavedInputState = if (builtin.os.tag == .windows) win.DWORD else std.posix.termios;
const TuiSavedOutputState = if (builtin.os.tag == .windows) win.DWORD else void;

const TuiSession = struct {
    input: std.Io.File,
    output: std.Io.File,
    saved_input_state: TuiSavedInputState = if (builtin.os.tag == .windows) 0 else undefined,
    saved_output_state: TuiSavedOutputState = if (builtin.os.tag == .windows) 0 else {},
    pending_windows_key: ?TuiInputKey = null,
    pending_windows_repeat_count: u16 = 0,
    writer_buffer: [4096]u8 = undefined,
    writer: std.Io.File.Writer = undefined,

    fn init() !@This() {
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

            var session = @This(){
                .input = input,
                .output = output,
                .saved_input_state = saved_input_mode,
                .saved_output_state = saved_output_mode,
            };
            session.writer = session.output.writer(app_runtime.io(), &session.writer_buffer);
            try session.enter();
            return session;
        } else {
            const saved_termios = try std.posix.tcgetattr(input.handle);
            var raw = saved_termios;
            raw.lflag.ICANON = false;
            raw.lflag.ECHO = false;
            raw.cc[@intFromEnum(std.c.V.MIN)] = 1;
            raw.cc[@intFromEnum(std.c.V.TIME)] = 0;
            try std.posix.tcsetattr(input.handle, .FLUSH, raw);
            errdefer std.posix.tcsetattr(input.handle, .FLUSH, saved_termios) catch {};

            var session = @This(){
                .input = input,
                .output = output,
                .saved_input_state = saved_termios,
            };
            session.writer = session.output.writer(app_runtime.io(), &session.writer_buffer);
            try session.enter();
            return session;
        }
    }

    fn deinit(self: *@This()) void {
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

    fn out(self: *@This()) *std.Io.Writer {
        return &self.writer.interface;
    }

    fn read(self: *@This(), buffer: []u8) !usize {
        return try readFileOnce(self.input, buffer);
    }

    fn readWindowsKey(self: *@This()) !TuiInputKey {
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

    fn enter(self: *@This()) !void {
        const writer = self.out();
        try writeTuiEnterTo(writer);
        try writer.flush();
    }

    fn resetFrame(self: *@This()) !void {
        try writeTuiResetFrameTo(self.out());
    }
};

fn classifyTuiEscapeSuffix(seq: []const u8) TuiEscapeClassification {
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

fn readTuiEscapeAction(
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

test "Scenario: Given tty arrow escape suffixes when classifying them then both CSI and SS3 arrows are recognized" {
    switch (classifyTuiEscapeSuffix("[A")) {
        .navigation => |direction| try std.testing.expectEqual(TuiNavigation.up, direction),
        else => return error.TestUnexpectedResult,
    }
    switch (classifyTuiEscapeSuffix("[1;2B")) {
        .navigation => |direction| try std.testing.expectEqual(TuiNavigation.down, direction),
        else => return error.TestUnexpectedResult,
    }
    switch (classifyTuiEscapeSuffix("OA")) {
        .navigation => |direction| try std.testing.expectEqual(TuiNavigation.up, direction),
        else => return error.TestUnexpectedResult,
    }
}

test "Scenario: Given unrelated tty escape suffixes when classifying them then they are ignored instead of acting like quit" {
    try std.testing.expectEqual(TuiEscapeClassification.ignore, classifyTuiEscapeSuffix("x"));
    try std.testing.expectEqual(TuiEscapeClassification.ignore, classifyTuiEscapeSuffix("[200~"));
    try std.testing.expectEqual(TuiEscapeClassification.incomplete, classifyTuiEscapeSuffix("["));
}

test "Scenario: Given shared TUI screen lifecycle when writing it then switch and remove can stay inside the alternate screen" {
    const gpa = std.testing.allocator;
    var aw: std.Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();

    try writeTuiEnterTo(&aw.writer);
    try writeTuiExitTo(&aw.writer);

    try std.testing.expectEqualStrings(
        "\x1b[?1049h\x1b[?25l" ++
            "\x1b[H\x1b[J" ++
            "\x1b[?25h\x1b[?1049l",
        aw.written(),
    );
}

test "Scenario: Given shared TUI frame redraw when writing it then it clears only the alternate screen frame instead of appending full screens" {
    const gpa = std.testing.allocator;
    var aw: std.Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();

    try writeTuiResetFrameTo(&aw.writer);

    try std.testing.expectEqualStrings("\x1b[H\x1b[J", aw.written());
    try std.testing.expect(std.mem.indexOf(u8, aw.written(), "\x1b[2J\x1b[H") == null);
}

test "Scenario: Given TUI prompt with numeric input when rendering then the current digits stay inline with the title" {
    const gpa = std.testing.allocator;
    var with_digits: std.Io.Writer.Allocating = .init(gpa);
    defer with_digits.deinit();
    var without_digits: std.Io.Writer.Allocating = .init(gpa);
    defer without_digits.deinit();

    try writeTuiPromptLine(&with_digits.writer, "Select account to activate:", "123");
    try std.testing.expectEqualStrings("Select account to activate: 123\n", with_digits.written());

    try writeTuiPromptLine(&without_digits.writer, "Select account to activate:", "");
    try std.testing.expectEqualStrings("Select account to activate:\n", without_digits.written());
}

test "Scenario: Given Windows TUI console modes when configuring them then resize stays enabled while mouse and cooked input stay disabled" {
    const saved_input_mode: win.DWORD =
        win.ENABLE_MOUSE_INPUT |
        win.ENABLE_WINDOW_INPUT |
        win.ENABLE_LINE_INPUT |
        win.ENABLE_ECHO_INPUT;
    const configured_input_mode = windowsTuiInputMode(saved_input_mode);

    try std.testing.expect((configured_input_mode & win.ENABLE_WINDOW_INPUT) != 0);
    try std.testing.expect((configured_input_mode & win.ENABLE_EXTENDED_FLAGS) != 0);
    try std.testing.expect((configured_input_mode & win.ENABLE_MOUSE_INPUT) == 0);
    try std.testing.expect((configured_input_mode & win.ENABLE_LINE_INPUT) == 0);
    try std.testing.expect((configured_input_mode & win.ENABLE_ECHO_INPUT) == 0);
    try std.testing.expect((configured_input_mode & win.ENABLE_VIRTUAL_TERMINAL_INPUT) == 0);

    const configured_output_mode = windowsTuiOutputMode(0);
    try std.testing.expect((configured_output_mode & win.ENABLE_PROCESSED_OUTPUT) != 0);
    try std.testing.expect((configured_output_mode & win.ENABLE_VIRTUAL_TERMINAL_PROCESSING) != 0);
}

fn colorEnabled() bool {
    return terminal_color.stdoutColorEnabled();
}

fn stderrColorEnabled() bool {
    return terminal_color.stderrColorEnabled();
}

fn readFileOnce(file: std.Io.File, buffer: []u8) !usize {
    var buffers = [_][]u8{buffer};
    return file.readStreaming(app_runtime.io(), &buffers) catch |err| switch (err) {
        error.EndOfStream => 0,
        else => |e| return e,
    };
}

pub const ApiMode = enum {
    default,
    force_api,
    skip_api,
};

pub const ListOptions = struct {
    live: bool = false,
    api_mode: ApiMode = .default,
};
pub const LoginOptions = struct {
    device_auth: bool = false,
};
pub const ImportSource = enum { standard, cpa };
pub const ImportOptions = struct {
    auth_path: ?[]u8,
    alias: ?[]u8,
    purge: bool,
    source: ImportSource,
};
pub const SwitchOptions = struct {
    query: ?[]u8,
    live: bool = false,
    auto: bool = false,
    api_mode: ApiMode = .default,
};
pub const RemoveOptions = struct {
    selectors: [][]const u8,
    all: bool,
    live: bool = false,
    api_mode: ApiMode = .default,
};
pub const CleanOptions = struct {};
pub const AutoAction = enum { enable, disable };
pub const AutoThresholdOptions = struct {
    threshold_5h_percent: ?u8,
    threshold_weekly_percent: ?u8,
};
pub const AutoOptions = union(enum) {
    action: AutoAction,
    configure: AutoThresholdOptions,
};
pub const ApiAction = enum { enable, disable };
pub const ConfigOptions = union(enum) {
    auto_switch: AutoOptions,
    api: ApiAction,
};
pub const DaemonMode = enum { watch, once };
pub const DaemonOptions = struct { mode: DaemonMode };
pub const HelpTopic = enum {
    top_level,
    list,
    status,
    login,
    import_auth,
    switch_account,
    remove_account,
    clean,
    config,
    daemon,
};

pub const Command = union(enum) {
    list: ListOptions,
    login: LoginOptions,
    import_auth: ImportOptions,
    switch_account: SwitchOptions,
    remove_account: RemoveOptions,
    clean: CleanOptions,
    config: ConfigOptions,
    status: void,
    daemon: DaemonOptions,
    version: void,
    help: HelpTopic,
};

pub const UsageError = struct {
    topic: HelpTopic,
    message: []u8,
};

pub const ParseResult = union(enum) {
    command: Command,
    usage_error: UsageError,
};

pub fn parseArgs(allocator: std.mem.Allocator, args: []const [:0]const u8) !ParseResult {
    if (args.len < 2) return .{ .command = .{ .help = .top_level } };
    const cmd = std.mem.sliceTo(args[1], 0);

    if (isHelpFlag(cmd)) {
        if (args.len > 2) {
            return usageErrorResult(allocator, .top_level, "unexpected argument after `{s}`: `{s}`.", .{
                cmd,
                std.mem.sliceTo(args[2], 0),
            });
        }
        return .{ .command = .{ .help = .top_level } };
    }

    if (std.mem.eql(u8, cmd, "help")) {
        return try parseHelpArgs(allocator, args[2..]);
    }

    if (std.mem.eql(u8, cmd, "--version") or std.mem.eql(u8, cmd, "-V")) {
        if (args.len > 2) {
            return usageErrorResult(allocator, .top_level, "unexpected argument after `{s}`: `{s}`.", .{
                cmd,
                std.mem.sliceTo(args[2], 0),
            });
        }
        return .{ .command = .{ .version = {} } };
    }

    if (std.mem.eql(u8, cmd, "list")) {
        if (args.len == 3 and isHelpFlag(std.mem.sliceTo(args[2], 0))) {
            return .{ .command = .{ .help = .list } };
        }

        var opts: ListOptions = .{};
        var i: usize = 2;
        while (i < args.len) : (i += 1) {
            const arg = std.mem.sliceTo(args[i], 0);
            if (std.mem.eql(u8, arg, "--live")) {
                if (opts.live) {
                    return usageErrorResult(allocator, .list, "duplicate `--live` for `list`.", .{});
                }
                opts.live = true;
                continue;
            }
            if (std.mem.eql(u8, arg, "--api")) {
                switch (opts.api_mode) {
                    .default => opts.api_mode = .force_api,
                    .force_api => return usageErrorResult(allocator, .list, "duplicate `--api` for `list`.", .{}),
                    .skip_api => return usageErrorResult(allocator, .list, "`--api` cannot be combined with `--skip-api` for `list`.", .{}),
                }
                continue;
            }
            if (std.mem.eql(u8, arg, "--skip-api")) {
                switch (opts.api_mode) {
                    .default => opts.api_mode = .skip_api,
                    .skip_api => return usageErrorResult(allocator, .list, "duplicate `--skip-api` for `list`.", .{}),
                    .force_api => return usageErrorResult(allocator, .list, "`--skip-api` cannot be combined with `--api` for `list`.", .{}),
                }
                continue;
            }
            if (isHelpFlag(arg)) {
                return usageErrorResult(allocator, .list, "`--help` must be used by itself for `list`.", .{});
            }
            if (std.mem.startsWith(u8, arg, "-")) {
                return usageErrorResult(allocator, .list, "unknown flag `{s}` for `list`.", .{arg});
            }
            return usageErrorResult(allocator, .list, "unexpected argument `{s}` for `list`.", .{arg});
        }
        return .{ .command = .{ .list = opts } };
    }

    if (std.mem.eql(u8, cmd, "login")) {
        if (args.len == 3 and isHelpFlag(std.mem.sliceTo(args[2], 0))) {
            return .{ .command = .{ .help = .login } };
        }

        var opts: LoginOptions = .{};
        var i: usize = 2;
        while (i < args.len) : (i += 1) {
            const arg = std.mem.sliceTo(args[i], 0);
            if (std.mem.eql(u8, arg, "--device-auth")) {
                if (opts.device_auth) {
                    return usageErrorResult(allocator, .login, "duplicate `--device-auth` for `login`.", .{});
                }
                opts.device_auth = true;
                continue;
            }
            if (isHelpFlag(arg)) {
                return usageErrorResult(allocator, .login, "`--help` must be used by itself for `login`.", .{});
            }
            if (std.mem.startsWith(u8, arg, "-")) {
                return usageErrorResult(allocator, .login, "unknown flag `{s}` for `login`.", .{arg});
            }
            return usageErrorResult(allocator, .login, "unexpected argument `{s}` for `login`.", .{arg});
        }
        return .{ .command = .{ .login = opts } };
    }

    if (std.mem.eql(u8, cmd, "import")) {
        if (args.len == 3 and isHelpFlag(std.mem.sliceTo(args[2], 0))) {
            return .{ .command = .{ .help = .import_auth } };
        }

        var auth_path: ?[]u8 = null;
        var alias: ?[]u8 = null;
        var purge = false;
        var source: ImportSource = .standard;
        var i: usize = 2;
        while (i < args.len) : (i += 1) {
            const arg = std.mem.sliceTo(args[i], 0);
            if (std.mem.eql(u8, arg, "--alias")) {
                if (i + 1 >= args.len) {
                    freeImportOptions(allocator, auth_path, alias);
                    return usageErrorResult(allocator, .import_auth, "missing value for `--alias`.", .{});
                }
                if (alias != null) {
                    freeImportOptions(allocator, auth_path, alias);
                    return usageErrorResult(allocator, .import_auth, "duplicate `--alias` for `import`.", .{});
                }
                alias = try allocator.dupe(u8, std.mem.sliceTo(args[i + 1], 0));
                i += 1;
            } else if (std.mem.eql(u8, arg, "--purge")) {
                if (purge) {
                    freeImportOptions(allocator, auth_path, alias);
                    return usageErrorResult(allocator, .import_auth, "duplicate `--purge` for `import`.", .{});
                }
                purge = true;
            } else if (std.mem.eql(u8, arg, "--cpa")) {
                if (source == .cpa) {
                    freeImportOptions(allocator, auth_path, alias);
                    return usageErrorResult(allocator, .import_auth, "duplicate `--cpa` for `import`.", .{});
                }
                source = .cpa;
            } else if (isHelpFlag(arg)) {
                freeImportOptions(allocator, auth_path, alias);
                return usageErrorResult(allocator, .import_auth, "`--help` must be used by itself for `import`.", .{});
            } else if (std.mem.startsWith(u8, arg, "-")) {
                freeImportOptions(allocator, auth_path, alias);
                return usageErrorResult(allocator, .import_auth, "unknown flag `{s}` for `import`.", .{arg});
            } else {
                if (auth_path != null) {
                    freeImportOptions(allocator, auth_path, alias);
                    return usageErrorResult(allocator, .import_auth, "unexpected extra path `{s}` for `import`.", .{arg});
                }
                auth_path = try allocator.dupe(u8, arg);
            }
        }
        if (purge and source == .cpa) {
            freeImportOptions(allocator, auth_path, alias);
            return usageErrorResult(allocator, .import_auth, "`--purge` cannot be combined with `--cpa`.", .{});
        }
        if (auth_path == null and !purge and source == .standard) {
            freeImportOptions(allocator, auth_path, alias);
            return usageErrorResult(allocator, .import_auth, "`import` requires a path unless `--purge` or `--cpa` is used.", .{});
        }
        return .{ .command = .{ .import_auth = .{
            .auth_path = auth_path,
            .alias = alias,
            .purge = purge,
            .source = source,
        } } };
    }

    if (std.mem.eql(u8, cmd, "switch")) {
        if (args.len == 3 and isHelpFlag(std.mem.sliceTo(args[2], 0))) {
            return .{ .command = .{ .help = .switch_account } };
        }

        var opts: SwitchOptions = .{ .query = null };
        var i: usize = 2;
        while (i < args.len) : (i += 1) {
            const arg = std.mem.sliceTo(args[i], 0);
            if (std.mem.eql(u8, arg, "--live")) {
                if (opts.live) {
                    if (opts.query) |query| allocator.free(query);
                    return usageErrorResult(allocator, .switch_account, "duplicate `--live` for `switch`.", .{});
                }
                opts.live = true;
                continue;
            }
            if (std.mem.eql(u8, arg, "--auto")) {
                if (opts.auto) {
                    if (opts.query) |query| allocator.free(query);
                    return usageErrorResult(allocator, .switch_account, "duplicate `--auto` for `switch`.", .{});
                }
                opts.auto = true;
                continue;
            }
            if (std.mem.eql(u8, arg, "--api")) {
                switch (opts.api_mode) {
                    .default => opts.api_mode = .force_api,
                    .force_api => {
                        if (opts.query) |query| allocator.free(query);
                        return usageErrorResult(allocator, .switch_account, "duplicate `--api` for `switch`.", .{});
                    },
                    .skip_api => {
                        if (opts.query) |query| allocator.free(query);
                        return usageErrorResult(allocator, .switch_account, "`--api` cannot be combined with `--skip-api` for `switch`.", .{});
                    },
                }
                continue;
            }
            if (std.mem.eql(u8, arg, "--skip-api")) {
                switch (opts.api_mode) {
                    .default => opts.api_mode = .skip_api,
                    .skip_api => {
                        if (opts.query) |query| allocator.free(query);
                        return usageErrorResult(allocator, .switch_account, "duplicate `--skip-api` for `switch`.", .{});
                    },
                    .force_api => {
                        if (opts.query) |query| allocator.free(query);
                        return usageErrorResult(allocator, .switch_account, "`--skip-api` cannot be combined with `--api` for `switch`.", .{});
                    },
                }
                continue;
            }
            if (std.mem.startsWith(u8, arg, "-")) {
                if (opts.query) |query| allocator.free(query);
                return usageErrorResult(allocator, .switch_account, "unknown flag `{s}` for `switch`.", .{arg});
            }
            if (opts.query != null) {
                if (opts.query) |query| allocator.free(query);
                return usageErrorResult(allocator, .switch_account, "unexpected extra query `{s}` for `switch`.", .{arg});
            }
            opts.query = try allocator.dupe(u8, arg);
        }
        if (opts.auto and !opts.live) {
            if (opts.query) |query| allocator.free(query);
            return usageErrorResult(allocator, .switch_account, "`--auto` requires `--live` for `switch`.", .{});
        }
        if (opts.query != null and (opts.api_mode != .default or opts.live or opts.auto)) {
            if (opts.query) |query| allocator.free(query);
            return usageErrorResult(
                allocator,
                .switch_account,
                "`switch <query>` does not support `--live`, `--auto`, `--api`, or `--skip-api`.",
                .{},
            );
        }
        return .{ .command = .{ .switch_account = opts } };
    }

    if (std.mem.eql(u8, cmd, "remove")) {
        if (args.len == 3 and isHelpFlag(std.mem.sliceTo(args[2], 0))) {
            return .{ .command = .{ .help = .remove_account } };
        }

        var selectors = std.ArrayList([]const u8).empty;
        errdefer freeOwnedStringList(allocator, selectors.items);
        defer selectors.deinit(allocator);
        var opts: RemoveOptions = .{
            .selectors = &.{},
            .all = false,
        };
        var i: usize = 2;
        while (i < args.len) : (i += 1) {
            const arg = std.mem.sliceTo(args[i], 0);
            if (std.mem.eql(u8, arg, "--live")) {
                if (opts.live) {
                    return usageErrorResult(allocator, .remove_account, "duplicate `--live` for `remove`.", .{});
                }
                opts.live = true;
                continue;
            }
            if (std.mem.eql(u8, arg, "--api")) {
                switch (opts.api_mode) {
                    .default => opts.api_mode = .force_api,
                    .force_api => return usageErrorResult(allocator, .remove_account, "duplicate `--api` for `remove`.", .{}),
                    .skip_api => return usageErrorResult(allocator, .remove_account, "`--api` cannot be combined with `--skip-api` for `remove`.", .{}),
                }
                continue;
            }
            if (std.mem.eql(u8, arg, "--skip-api")) {
                switch (opts.api_mode) {
                    .default => opts.api_mode = .skip_api,
                    .skip_api => return usageErrorResult(allocator, .remove_account, "duplicate `--skip-api` for `remove`.", .{}),
                    .force_api => return usageErrorResult(allocator, .remove_account, "`--skip-api` cannot be combined with `--api` for `remove`.", .{}),
                }
                continue;
            }
            if (std.mem.eql(u8, arg, "--all")) {
                if (opts.all or selectors.items.len != 0) {
                    return usageErrorResult(allocator, .remove_account, "`remove` cannot combine `--all` with another selector.", .{});
                }
                opts.all = true;
                continue;
            }
            if (std.mem.startsWith(u8, arg, "-")) {
                return usageErrorResult(allocator, .remove_account, "unknown flag `{s}` for `remove`.", .{arg});
            }
            if (opts.all) {
                return usageErrorResult(allocator, .remove_account, "`remove` cannot combine `--all` with another selector.", .{});
            }
            try selectors.append(allocator, try allocator.dupe(u8, arg));
        }
        if ((opts.live or opts.api_mode != .default) and (opts.all or selectors.items.len != 0)) {
            freeOwnedStringList(allocator, selectors.items);
            return usageErrorResult(
                allocator,
                .remove_account,
                "`remove <query>` and `remove --all` do not support `--live`, `--api`, or `--skip-api`.",
                .{},
            );
        }
        opts.selectors = try selectors.toOwnedSlice(allocator);
        return .{ .command = .{ .remove_account = opts } };
    }

    if (std.mem.eql(u8, cmd, "clean")) {
        return try parseSimpleCommandArgs(allocator, "clean", .clean, .{ .clean = .{} }, args[2..]);
    }

    if (std.mem.eql(u8, cmd, "status")) {
        return try parseSimpleCommandArgs(allocator, "status", .status, .{ .status = {} }, args[2..]);
    }

    if (std.mem.eql(u8, cmd, "config")) {
        if (args.len == 3 and isHelpFlag(std.mem.sliceTo(args[2], 0))) {
            return .{ .command = .{ .help = .config } };
        }
        if (args.len < 3) return usageErrorResult(allocator, .config, "`config` requires a section.", .{});
        const scope = std.mem.sliceTo(args[2], 0);

        if (std.mem.eql(u8, scope, "auto")) {
            if (args.len == 4 and isHelpFlag(std.mem.sliceTo(args[3], 0))) {
                return .{ .command = .{ .help = .config } };
            }
            if (args.len == 4) {
                const action = std.mem.sliceTo(args[3], 0);
                if (std.mem.eql(u8, action, "enable")) return .{ .command = .{ .config = .{ .auto_switch = .{ .action = .enable } } } };
                if (std.mem.eql(u8, action, "disable")) return .{ .command = .{ .config = .{ .auto_switch = .{ .action = .disable } } } };
            }

            var threshold_5h_percent: ?u8 = null;
            var threshold_weekly_percent: ?u8 = null;
            var i: usize = 3;
            while (i < args.len) : (i += 1) {
                const arg = std.mem.sliceTo(args[i], 0);
                if (std.mem.eql(u8, arg, "--5h")) {
                    if (i + 1 >= args.len) return usageErrorResult(allocator, .config, "missing value for `--5h`.", .{});
                    if (threshold_5h_percent != null) return usageErrorResult(allocator, .config, "duplicate `--5h` for `config auto`.", .{});
                    threshold_5h_percent = parsePercentArg(std.mem.sliceTo(args[i + 1], 0)) orelse
                        return usageErrorResult(allocator, .config, "`--5h` must be an integer from 1 to 100.", .{});
                    i += 1;
                    continue;
                }
                if (std.mem.eql(u8, arg, "--weekly")) {
                    if (i + 1 >= args.len) return usageErrorResult(allocator, .config, "missing value for `--weekly`.", .{});
                    if (threshold_weekly_percent != null) return usageErrorResult(allocator, .config, "duplicate `--weekly` for `config auto`.", .{});
                    threshold_weekly_percent = parsePercentArg(std.mem.sliceTo(args[i + 1], 0)) orelse
                        return usageErrorResult(allocator, .config, "`--weekly` must be an integer from 1 to 100.", .{});
                    i += 1;
                    continue;
                }
                if (std.mem.eql(u8, arg, "enable") or std.mem.eql(u8, arg, "disable")) {
                    return usageErrorResult(allocator, .config, "`config auto` cannot mix actions with threshold flags.", .{});
                }
                return usageErrorResult(allocator, .config, "unknown argument `{s}` for `config auto`.", .{arg});
            }
            if (threshold_5h_percent == null and threshold_weekly_percent == null) {
                return usageErrorResult(allocator, .config, "`config auto` requires an action or threshold flags.", .{});
            }
            return .{ .command = .{ .config = .{ .auto_switch = .{ .configure = .{
                .threshold_5h_percent = threshold_5h_percent,
                .threshold_weekly_percent = threshold_weekly_percent,
            } } } } };
        }

        if (std.mem.eql(u8, scope, "api")) {
            if (args.len == 4 and isHelpFlag(std.mem.sliceTo(args[3], 0))) {
                return .{ .command = .{ .help = .config } };
            }
            if (args.len != 4) return usageErrorResult(allocator, .config, "`config api` requires `enable` or `disable`.", .{});
            const action = std.mem.sliceTo(args[3], 0);
            if (std.mem.eql(u8, action, "enable")) return .{ .command = .{ .config = .{ .api = .enable } } };
            if (std.mem.eql(u8, action, "disable")) return .{ .command = .{ .config = .{ .api = .disable } } };
            return usageErrorResult(allocator, .config, "unknown action `{s}` for `config api`.", .{action});
        }

        return usageErrorResult(allocator, .config, "unknown config section `{s}`.", .{scope});
    }

    if (std.mem.eql(u8, cmd, "daemon")) {
        if (args.len == 3 and isHelpFlag(std.mem.sliceTo(args[2], 0))) {
            return .{ .command = .{ .help = .daemon } };
        }
        if (args.len == 3 and std.mem.eql(u8, std.mem.sliceTo(args[2], 0), "--watch")) {
            return .{ .command = .{ .daemon = .{ .mode = .watch } } };
        }
        if (args.len == 3 and std.mem.eql(u8, std.mem.sliceTo(args[2], 0), "--once")) {
            return .{ .command = .{ .daemon = .{ .mode = .once } } };
        }
        return usageErrorResult(allocator, .daemon, "`daemon` requires `--watch` or `--once`.", .{});
    }

    return usageErrorResult(allocator, .top_level, "unknown command `{s}`.", .{cmd});
}

pub fn freeParseResult(allocator: std.mem.Allocator, result: *ParseResult) void {
    switch (result.*) {
        .command => |*cmd| freeCommand(allocator, cmd),
        .usage_error => |*usage_err| allocator.free(usage_err.message),
    }
}

fn freeCommand(allocator: std.mem.Allocator, cmd: *Command) void {
    switch (cmd.*) {
        .import_auth => |*opts| {
            if (opts.auth_path) |path| allocator.free(path);
            if (opts.alias) |a| allocator.free(a);
        },
        .switch_account => |*opts| {
            if (opts.query) |query| allocator.free(query);
        },
        .remove_account => |*opts| {
            freeOwnedStringList(allocator, opts.selectors);
            allocator.free(opts.selectors);
        },
        else => {},
    }
}

fn isHelpFlag(arg: []const u8) bool {
    return std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h");
}

fn usageErrorResult(
    allocator: std.mem.Allocator,
    topic: HelpTopic,
    comptime fmt: []const u8,
    args: anytype,
) !ParseResult {
    return .{ .usage_error = .{
        .topic = topic,
        .message = try std.fmt.allocPrint(allocator, fmt, args),
    } };
}

fn parseSimpleCommandArgs(
    allocator: std.mem.Allocator,
    command_name: []const u8,
    topic: HelpTopic,
    command: Command,
    rest: []const [:0]const u8,
) !ParseResult {
    if (rest.len == 0) return .{ .command = command };
    if (rest.len == 1 and isHelpFlag(std.mem.sliceTo(rest[0], 0))) {
        return .{ .command = .{ .help = topic } };
    }
    const arg = std.mem.sliceTo(rest[0], 0);
    if (std.mem.startsWith(u8, arg, "-")) {
        return usageErrorResult(allocator, topic, "unknown flag `{s}` for `{s}`.", .{ arg, command_name });
    }
    return usageErrorResult(allocator, topic, "unexpected argument `{s}` for `{s}`.", .{ arg, command_name });
}

fn parseHelpArgs(allocator: std.mem.Allocator, rest: []const [:0]const u8) !ParseResult {
    if (rest.len == 0) return .{ .command = .{ .help = .top_level } };
    if (rest.len > 1) {
        return usageErrorResult(allocator, .top_level, "unexpected argument after `help`: `{s}`.", .{
            std.mem.sliceTo(rest[1], 0),
        });
    }

    const topic = helpTopicForName(std.mem.sliceTo(rest[0], 0)) orelse
        return usageErrorResult(allocator, .top_level, "unknown help topic `{s}`.", .{
            std.mem.sliceTo(rest[0], 0),
        });
    return .{ .command = .{ .help = topic } };
}

fn helpTopicForName(name: []const u8) ?HelpTopic {
    if (std.mem.eql(u8, name, "list")) return .list;
    if (std.mem.eql(u8, name, "status")) return .status;
    if (std.mem.eql(u8, name, "login")) return .login;
    if (std.mem.eql(u8, name, "import")) return .import_auth;
    if (std.mem.eql(u8, name, "switch")) return .switch_account;
    if (std.mem.eql(u8, name, "remove")) return .remove_account;
    if (std.mem.eql(u8, name, "clean")) return .clean;
    if (std.mem.eql(u8, name, "config")) return .config;
    if (std.mem.eql(u8, name, "daemon")) return .daemon;
    return null;
}

fn freeImportOptions(allocator: std.mem.Allocator, auth_path: ?[]u8, alias: ?[]u8) void {
    if (auth_path) |path| allocator.free(path);
    if (alias) |value| allocator.free(value);
}

fn freeOwnedStringList(allocator: std.mem.Allocator, items: []const []const u8) void {
    for (items) |item| allocator.free(@constCast(item));
}

pub fn printHelp(auto_cfg: *const registry.AutoSwitchConfig, api_cfg: *const registry.ApiConfig) !void {
    var stdout: io_util.Stdout = undefined;
    stdout.init();
    const out = stdout.out();
    const use_color = colorEnabled();
    try writeHelp(out, use_color, auto_cfg, api_cfg);
    try out.flush();
}

pub fn writeHelp(
    out: *std.Io.Writer,
    use_color: bool,
    auto_cfg: *const registry.AutoSwitchConfig,
    api_cfg: *const registry.ApiConfig,
) !void {
    if (use_color) try out.writeAll(ansi.bold);
    try out.writeAll("codex-auth");
    if (use_color) try out.writeAll(ansi.reset);
    try out.writeAll(" ");
    if (use_color) try out.writeAll(ansi.dim);
    try out.writeAll(version.app_version);
    if (use_color) try out.writeAll(ansi.reset);
    try out.writeAll("\n\n");

    if (use_color) try out.writeAll(ansi.bold);
    try out.writeAll("Auto Switch:");
    if (use_color) try out.writeAll(ansi.reset);
    try out.print(
        " {s} (5h<{d}%, weekly<{d}%)\n\n",
        .{ if (auto_cfg.enabled) "ON" else "OFF", auto_cfg.threshold_5h_percent, auto_cfg.threshold_weekly_percent },
    );

    if (use_color) try out.writeAll(ansi.bold);
    try out.writeAll("Usage API:");
    if (use_color) try out.writeAll(ansi.reset);
    try out.print(
        " {s} ({s})\n\n",
        .{ if (api_cfg.usage) "ON" else "OFF", if (api_cfg.usage) "api" else "local" },
    );

    if (use_color) try out.writeAll(ansi.bold);
    try out.writeAll("Account API:");
    if (use_color) try out.writeAll(ansi.reset);
    try out.print(
        " {s}\n\n",
        .{if (api_cfg.account) "ON" else "OFF"},
    );

    if (use_color) try out.writeAll(ansi.bold);
    try out.writeAll("Commands:");
    if (use_color) try out.writeAll(ansi.reset);
    try out.writeAll("\n\n");

    const commands = [_]HelpEntry{
        .{ .name = "--version, -V", .description = "Show version" },
        .{ .name = "list", .description = "List available accounts" },
        .{ .name = "status", .description = "Show auto-switch and usage API status" },
        .{ .name = "login", .description = "Login and add the current account" },
        .{ .name = "import", .description = "Import auth files or rebuild registry" },
        .{ .name = "switch [--live] [--auto] [--api|--skip-api] | switch <query>", .description = "Switch the active account" },
        .{ .name = "remove [--live] [--api|--skip-api] | remove <query> [<query>...] | remove --all", .description = "Remove one or more accounts" },
        .{ .name = "clean", .description = "Delete backup and stale files under accounts/" },
        .{ .name = "config", .description = "Manage configuration" },
    };
    const import_details = [_]HelpEntry{
        .{ .name = "<path>", .description = "Import one file or batch import a directory" },
        .{ .name = "--cpa [<path>]", .description = "Import CPA flat token JSON from one file or directory" },
        .{ .name = "--alias <alias>", .description = "Set alias for single-file import" },
        .{ .name = "--purge [<path>]", .description = "Rebuild `registry.json` from auth files" },
    };
    const config_details = [_]HelpEntry{
        .{ .name = "auto enable", .description = "Enable background auto-switching" },
        .{ .name = "auto disable", .description = "Disable background auto-switching" },
        .{ .name = "auto --5h <percent> [--weekly <percent>]", .description = "Configure auto-switch thresholds" },
        .{ .name = "api enable", .description = "Enable usage and account APIs" },
        .{ .name = "api disable", .description = "Disable usage and account APIs" },
    };
    const parent_indent: usize = 2;
    const child_indent: usize = parent_indent + 4;
    const child_description_extra: usize = 4;
    const command_col = helpTargetColumn(&commands, parent_indent);
    const import_detail_col = @max(command_col + child_description_extra, helpTargetColumn(&import_details, child_indent));
    const config_detail_col = @max(command_col + child_description_extra, helpTargetColumn(&config_details, child_indent));

    try writeHelpEntry(out, use_color, parent_indent, command_col, commands[0].name, commands[0].description);
    try writeHelpEntry(out, use_color, parent_indent, command_col, commands[1].name, commands[1].description);
    try writeHelpEntry(out, use_color, parent_indent, command_col, commands[2].name, commands[2].description);
    try writeHelpEntry(out, use_color, parent_indent, command_col, commands[3].name, commands[3].description);
    try writeHelpEntry(out, use_color, parent_indent, command_col, commands[4].name, commands[4].description);
    try writeHelpEntry(out, use_color, child_indent, import_detail_col, import_details[0].name, import_details[0].description);
    try writeHelpEntry(out, use_color, child_indent, import_detail_col, import_details[1].name, import_details[1].description);
    try writeHelpEntry(out, use_color, child_indent, import_detail_col, import_details[2].name, import_details[2].description);
    try writeHelpEntry(out, use_color, child_indent, import_detail_col, import_details[3].name, import_details[3].description);
    try writeHelpEntry(out, use_color, parent_indent, command_col, commands[5].name, commands[5].description);
    try writeHelpEntry(out, use_color, parent_indent, command_col, commands[6].name, commands[6].description);
    try writeHelpEntry(out, use_color, parent_indent, command_col, commands[7].name, commands[7].description);
    try writeHelpEntry(out, use_color, parent_indent, command_col, commands[8].name, commands[8].description);
    try writeHelpEntry(out, use_color, child_indent, config_detail_col, config_details[0].name, config_details[0].description);
    try writeHelpEntry(out, use_color, child_indent, config_detail_col, config_details[1].name, config_details[1].description);
    try writeHelpEntry(out, use_color, child_indent, config_detail_col, config_details[2].name, config_details[2].description);
    try writeHelpEntry(out, use_color, child_indent, config_detail_col, config_details[3].name, config_details[3].description);
    try writeHelpEntry(out, use_color, child_indent, config_detail_col, config_details[4].name, config_details[4].description);

    try out.writeAll("\n");
    if (use_color) try out.writeAll(ansi.bold);
    try out.writeAll("Notes:");
    if (use_color) try out.writeAll(ansi.reset);
    try out.writeAll("\n\n");
    try out.writeAll("  Run `codex-auth <command> --help` for command-specific usage details.\n");
    try out.writeAll("  `config api enable` may trigger OpenAI account restrictions or suspension in some environments.\n");
}

fn parsePercentArg(raw: []const u8) ?u8 {
    const value = std.fmt.parseInt(u8, raw, 10) catch return null;
    if (value < 1 or value > 100) return null;
    return value;
}

const HelpEntry = struct {
    name: []const u8,
    description: []const u8,
};

fn helpTargetColumn(entries: []const HelpEntry, indent: usize) usize {
    var max_visible_len: usize = 0;
    for (entries) |entry| {
        max_visible_len = @max(max_visible_len, indent + entry.name.len);
    }
    return max_visible_len + 2;
}

fn writeHelpEntry(
    out: *std.Io.Writer,
    use_color: bool,
    indent: usize,
    target_col: usize,
    name: []const u8,
    description: []const u8,
) !void {
    if (use_color) try out.writeAll(ansi.bold_green);
    var i: usize = 0;
    while (i < indent) : (i += 1) {
        try out.writeAll(" ");
    }
    try out.print("{s}", .{name});
    if (use_color) try out.writeAll(ansi.reset);

    const visible_len = indent + name.len;
    const spaces = if (visible_len >= target_col) 2 else target_col - visible_len;
    i = 0;
    while (i < spaces) : (i += 1) {
        try out.writeAll(" ");
    }

    try out.writeAll(description);
    try out.writeAll("\n");
}

pub fn printCommandHelp(topic: HelpTopic) !void {
    var stdout: io_util.Stdout = undefined;
    stdout.init();
    const out = stdout.out();
    try writeCommandHelp(out, colorEnabled(), topic);
    try out.flush();
}

pub fn writeCommandHelp(out: *std.Io.Writer, use_color: bool, topic: HelpTopic) !void {
    try writeCommandHelpHeader(out, use_color, topic);
    try out.writeAll("\n");
    try writeUsageSection(out, topic);
    if (commandHelpHasExamples(topic)) {
        try out.writeAll("\n\n");
        try writeExamplesSection(out, topic);
    }
}

fn writeCommandHelpHeader(out: *std.Io.Writer, use_color: bool, topic: HelpTopic) !void {
    if (use_color) try out.writeAll(ansi.bold);
    try out.print("codex-auth {s}", .{commandNameForTopic(topic)});
    if (use_color) try out.writeAll(ansi.reset);
    try out.writeAll("\n");
    try out.print("{s}\n", .{commandDescriptionForTopic(topic)});
}

fn commandNameForTopic(topic: HelpTopic) []const u8 {
    return switch (topic) {
        .top_level => "",
        .list => "list",
        .status => "status",
        .login => "login",
        .import_auth => "import",
        .switch_account => "switch",
        .remove_account => "remove",
        .clean => "clean",
        .config => "config",
        .daemon => "daemon",
    };
}

fn commandDescriptionForTopic(topic: HelpTopic) []const u8 {
    return switch (topic) {
        .top_level => "Command-line account management for Codex.",
        .list => "List available accounts.",
        .status => "Show auto-switch, service, and usage API status.",
        .login => "Run `codex login` or `codex login --device-auth`, then add the current account.",
        .import_auth => "Import auth files or rebuild the registry.",
        .switch_account => "Switch the active account interactively, or by query using stored local data.",
        .remove_account => "Remove one or more accounts interactively or by query.",
        .clean => "Delete backup and stale files under accounts/.",
        .config => "Manage auto-switch and usage API configuration.",
        .daemon => "Run the background auto-switch daemon.",
    };
}

fn commandHelpHasExamples(topic: HelpTopic) bool {
    return switch (topic) {
        .import_auth, .switch_account, .remove_account, .config, .daemon => true,
        else => false,
    };
}

fn writeUsageSection(out: *std.Io.Writer, topic: HelpTopic) !void {
    try out.writeAll("Usage:\n");
    switch (topic) {
        .top_level => {
            try out.writeAll("  codex-auth <command>\n");
            try out.writeAll("  codex-auth --help\n");
            try out.writeAll("  codex-auth help <command>\n");
        },
        .list => try out.writeAll("  codex-auth list [--live] [--api|--skip-api]\n"),
        .status => try out.writeAll("  codex-auth status\n"),
        .login => {
            try out.writeAll("  codex-auth login\n");
            try out.writeAll("  codex-auth login --device-auth\n");
        },
        .import_auth => {
            try out.writeAll("  codex-auth import <path> [--alias <alias>]\n");
            try out.writeAll("  codex-auth import --cpa [<path>] [--alias <alias>]\n");
            try out.writeAll("  codex-auth import --purge [<path>]\n");
        },
        .switch_account => {
            try out.writeAll("  codex-auth switch [--live] [--auto] [--api|--skip-api]\n");
            try out.writeAll("  codex-auth switch <query>\n");
        },
        .remove_account => {
            try out.writeAll("  codex-auth remove [--live] [--api|--skip-api]\n");
            try out.writeAll("  codex-auth remove <query> [<query>...]\n");
            try out.writeAll("  codex-auth remove --all\n");
        },
        .clean => try out.writeAll("  codex-auth clean\n"),
        .config => {
            try out.writeAll("  codex-auth config auto enable\n");
            try out.writeAll("  codex-auth config auto disable\n");
            try out.writeAll("  codex-auth config auto --5h <percent> [--weekly <percent>]\n");
            try out.writeAll("  codex-auth config auto --weekly <percent>\n");
            try out.writeAll("  codex-auth config api enable\n");
            try out.writeAll("  codex-auth config api disable\n");
        },
        .daemon => {
            try out.writeAll("  codex-auth daemon --watch\n");
            try out.writeAll("  codex-auth daemon --once\n");
        },
    }
}

fn writeExamplesSection(out: *std.Io.Writer, topic: HelpTopic) !void {
    try out.writeAll("Examples:\n");
    switch (topic) {
        .top_level => {
            try out.writeAll("  codex-auth list\n");
            try out.writeAll("  codex-auth import /path/to/auth.json --alias personal\n");
            try out.writeAll("  codex-auth config auto enable\n");
        },
        .list => {
            try out.writeAll("  codex-auth list\n");
            try out.writeAll("  codex-auth list --live\n");
            try out.writeAll("  codex-auth list --api\n");
            try out.writeAll("  codex-auth list --skip-api\n");
        },
        .status => try out.writeAll("  codex-auth status\n"),
        .login => {
            try out.writeAll("  codex-auth login\n");
            try out.writeAll("  codex-auth login --device-auth\n");
        },
        .import_auth => {
            try out.writeAll("  codex-auth import /path/to/auth.json --alias personal\n");
            try out.writeAll("  codex-auth import --cpa /path/to/token.json --alias work\n");
            try out.writeAll("  codex-auth import --purge\n");
        },
        .switch_account => {
            try out.writeAll("  codex-auth switch\n");
            try out.writeAll("  codex-auth switch --live\n");
            try out.writeAll("  codex-auth switch --live --auto\n");
            try out.writeAll("  codex-auth switch --api\n");
            try out.writeAll("  codex-auth switch --skip-api\n");
            try out.writeAll("  codex-auth switch work\n");
            try out.writeAll("  codex-auth switch 02\n");
        },
        .remove_account => {
            try out.writeAll("  codex-auth remove\n");
            try out.writeAll("  codex-auth remove --live\n");
            try out.writeAll("  codex-auth remove --api\n");
            try out.writeAll("  codex-auth remove --skip-api\n");
            try out.writeAll("  codex-auth remove 01 03\n");
            try out.writeAll("  codex-auth remove work personal\n");
            try out.writeAll("  codex-auth remove john@example.com jane@example.com\n");
            try out.writeAll("  codex-auth remove --all\n");
        },
        .clean => try out.writeAll("  codex-auth clean\n"),
        .config => {
            try out.writeAll("  codex-auth config auto --5h 12 --weekly 8\n");
            try out.writeAll("  codex-auth config api enable\n");
        },
        .daemon => {
            try out.writeAll("  codex-auth daemon --watch\n");
            try out.writeAll("  codex-auth daemon --once\n");
        },
    }
}

pub fn printUsageError(usage_err: *const UsageError) !void {
    var buffer: [2048]u8 = undefined;
    var writer = std.Io.File.stderr().writer(app_runtime.io(), &buffer);
    const out = &writer.interface;
    const use_color = stderrColorEnabled();
    try writeErrorPrefixTo(out, use_color);
    try out.print(" {s}\n\n", .{usage_err.message});
    try writeUsageSection(out, usage_err.topic);
    try out.writeAll("\n");
    try writeHintPrefixTo(out, use_color);
    try out.print(" Run `{s}` for examples.\n", .{helpCommandForTopic(usage_err.topic)});
    try out.flush();
}

fn helpCommandForTopic(topic: HelpTopic) []const u8 {
    return switch (topic) {
        .top_level => "codex-auth --help",
        .list => "codex-auth list --help",
        .status => "codex-auth status --help",
        .login => "codex-auth login --help",
        .import_auth => "codex-auth import --help",
        .switch_account => "codex-auth switch --help",
        .remove_account => "codex-auth remove --help",
        .clean => "codex-auth clean --help",
        .config => "codex-auth config --help",
        .daemon => "codex-auth daemon --help",
    };
}

pub fn printVersion() !void {
    var stdout: io_util.Stdout = undefined;
    stdout.init();
    const out = stdout.out();
    try out.print("codex-auth {s}\n", .{version.app_version});
    try out.flush();
}

pub fn printImportReport(report: *const registry.ImportReport) !void {
    var stdout: io_util.Stdout = undefined;
    stdout.init();
    var stderr_buffer: [4096]u8 = undefined;
    var stderr_writer = std.Io.File.stderr().writer(app_runtime.io(), &stderr_buffer);
    try writeImportReport(stdout.out(), &stderr_writer.interface, report);
}

pub fn writeImportReport(
    out: *std.Io.Writer,
    err_out: *std.Io.Writer,
    report: *const registry.ImportReport,
) !void {
    const is_windows = builtin.os.tag == .windows;
    if (report.render_kind == .scanned) {
        try out.print("Scanning {s}...\n", .{report.source_label.?});
        try out.flush();
    }

    for (report.events.items) |event| {
        switch (event.outcome) {
            .imported => {
                try out.print("  {s} imported  {s}\n", .{ importReportMarker(.imported, is_windows), event.label });
                try out.flush();
            },
            .updated => {
                try out.print("  {s} updated   {s}\n", .{ importReportMarker(.updated, is_windows), event.label });
                try out.flush();
            },
            .skipped => {
                try err_out.print("  {s} skipped   {s}: {s}\n", .{ importReportMarker(.skipped, is_windows), event.label, event.reason.? });
                try err_out.flush();
            },
        }
    }

    if (report.render_kind == .scanned) {
        try out.print(
            "Import Summary: {d} imported, {d} updated, {d} skipped (total {d} {s})\n",
            .{
                report.imported,
                report.updated,
                report.skipped,
                report.total_files,
                if (report.total_files == 1) "file" else "files",
            },
        );
        try out.flush();
        return;
    }

    if (report.skipped > 0 and report.imported == 0 and report.updated == 0) {
        try out.print(
            "Import Summary: {d} imported, {d} skipped\n",
            .{ report.imported, report.skipped },
        );
        try out.flush();
    }
}

pub fn writeErrorPrefixTo(out: *std.Io.Writer, use_color: bool) !void {
    if (use_color) try out.writeAll(ansi.bold_red);
    try out.writeAll("error:");
    if (use_color) try out.writeAll(ansi.reset);
}

pub fn writeHintPrefixTo(out: *std.Io.Writer, use_color: bool) !void {
    if (use_color) try out.writeAll(ansi.bold_cyan);
    try out.writeAll("hint:");
    if (use_color) try out.writeAll(ansi.reset);
}

pub fn printAccountNotFoundError(query: []const u8) !void {
    var buffer: [512]u8 = undefined;
    var writer = std.Io.File.stderr().writer(app_runtime.io(), &buffer);
    const out = &writer.interface;
    const use_color = stderrColorEnabled();
    try writeErrorPrefixTo(out, use_color);
    try out.print(" no account matches '{s}'.\n", .{query});
    try out.flush();
}

pub fn printAccountNotFoundErrors(queries: []const []const u8) !void {
    if (queries.len == 0) return;
    if (queries.len == 1) {
        return printAccountNotFoundError(queries[0]);
    }

    var buffer: [1024]u8 = undefined;
    var writer = std.Io.File.stderr().writer(app_runtime.io(), &buffer);
    const out = &writer.interface;
    const use_color = stderrColorEnabled();
    try writeErrorPrefixTo(out, use_color);
    try out.writeAll(" no account matches: ");
    for (queries, 0..) |query, idx| {
        if (idx != 0) try out.writeAll(", ");
        try out.writeAll(query);
    }
    try out.writeAll(".\n");
    try out.flush();
}

pub fn printSwitchRequiresTtyError() !void {
    var buffer: [512]u8 = undefined;
    var writer = std.Io.File.stderr().writer(app_runtime.io(), &buffer);
    const out = &writer.interface;
    const use_color = stderrColorEnabled();
    try writeErrorPrefixTo(out, use_color);
    try out.writeAll(" interactive switch requires a TTY.\n");
    try writeHintPrefixTo(out, use_color);
    try out.writeAll(" Run `codex-auth switch` in a terminal, or narrow `codex-auth switch <query>` to one account.\n");
    try out.flush();
}

pub fn printListRequiresTtyError() !void {
    var buffer: [512]u8 = undefined;
    var writer = std.Io.File.stderr().writer(app_runtime.io(), &buffer);
    const out = &writer.interface;
    const use_color = stderrColorEnabled();
    try writeErrorPrefixTo(out, use_color);
    try out.writeAll(" live list requires a TTY.\n");
    try writeHintPrefixTo(out, use_color);
    try out.writeAll(" Run `codex-auth list --live` in a terminal.\n");
    try out.flush();
}

pub fn printRemoveRequiresTtyError() !void {
    var buffer: [512]u8 = undefined;
    var writer = std.Io.File.stderr().writer(app_runtime.io(), &buffer);
    const out = &writer.interface;
    const use_color = stderrColorEnabled();
    try writeErrorPrefixTo(out, use_color);
    try out.writeAll(" interactive remove requires a TTY.\n");
    try writeHintPrefixTo(out, use_color);
    try out.writeAll(" Use `codex-auth remove <query>...` or `codex-auth remove --all` instead.\n");
    try out.flush();
}

pub fn printInvalidRemoveSelectionError() !void {
    var buffer: [512]u8 = undefined;
    var writer = std.Io.File.stderr().writer(app_runtime.io(), &buffer);
    const out = &writer.interface;
    const use_color = stderrColorEnabled();
    try writeErrorPrefixTo(out, use_color);
    try out.writeAll(" invalid remove selection input.\n");
    try writeHintPrefixTo(out, use_color);
    try out.writeAll(" Use numbers separated by commas or spaces, for example `1 2` or `1,2`.\n");
    try out.flush();
}

pub fn buildRemoveLabels(
    allocator: std.mem.Allocator,
    reg: *registry.Registry,
    indices: []const usize,
) !std.ArrayList([]const u8) {
    var labels = std.ArrayList([]const u8).empty;
    errdefer {
        for (labels.items) |label| allocator.free(@constCast(label));
        labels.deinit(allocator);
    }

    var display = try display_rows.buildDisplayRows(allocator, reg, indices);
    defer display.deinit(allocator);

    var current_header: ?[]const u8 = null;
    for (display.rows) |row| {
        if (row.account_index == null) {
            current_header = row.account_cell;
            continue;
        }

        const label = if (row.depth == 0 or current_header == null) blk: {
            const rec = &reg.accounts.items[row.account_index.?];
            if (std.mem.eql(u8, row.account_cell, rec.email)) {
                const preferred = try display_rows.buildPreferredAccountLabelAlloc(allocator, rec, rec.email);
                defer allocator.free(preferred);
                if (std.mem.eql(u8, preferred, rec.email)) {
                    break :blk try allocator.dupe(u8, row.account_cell);
                }
                break :blk try std.fmt.allocPrint(allocator, "{s} / {s}", .{ rec.email, preferred });
            }
            break :blk try std.fmt.allocPrint(allocator, "{s} / {s}", .{ rec.email, row.account_cell });
        } else try std.fmt.allocPrint(allocator, "{s} / {s}", .{ current_header.?, row.account_cell });
        try labels.append(allocator, label);
    }
    return labels;
}

fn writeMatchedAccountsListTo(out: *std.Io.Writer, labels: []const []const u8) !void {
    try out.writeAll("Matched multiple accounts:\n");
    for (labels) |label| {
        try out.print("- {s}\n", .{label});
    }
}

pub fn writeRemoveConfirmationTo(out: *std.Io.Writer, labels: []const []const u8) !void {
    try writeMatchedAccountsListTo(out, labels);
    try out.writeAll("Confirm delete? [y/N]: ");
}

pub fn printRemoveConfirmationUnavailableError(labels: []const []const u8) !void {
    var buffer: [1024]u8 = undefined;
    var writer = std.Io.File.stderr().writer(app_runtime.io(), &buffer);
    const out = &writer.interface;
    const use_color = stderrColorEnabled();
    try writeMatchedAccountsListTo(out, labels);
    try writeErrorPrefixTo(out, use_color);
    try out.writeAll(" multiple accounts match the query in non-interactive mode.\n");
    try writeHintPrefixTo(out, use_color);
    try out.writeAll(" Refine the query to match one account, or run the command in a TTY.\n");
    try out.flush();
}

pub fn confirmRemoveMatches(labels: []const []const u8) !bool {
    var stdout: io_util.Stdout = undefined;
    stdout.init();
    const out = stdout.out();
    try writeRemoveConfirmationTo(out, labels);
    try out.flush();

    var buf: [64]u8 = undefined;
    const n = try readFileOnce(std.Io.File.stdin(), &buf);
    const line = std.mem.trim(u8, buf[0..n], " \n\r\t");
    return line.len == 1 and (line[0] == 'y' or line[0] == 'Y');
}

pub fn writeRemoveSummaryTo(out: *std.Io.Writer, labels: []const []const u8) !void {
    try out.print("Removed {d} account(s): ", .{labels.len});
    for (labels, 0..) |label, idx| {
        if (idx != 0) try out.writeAll(", ");
        try out.writeAll(label);
    }
    try out.writeAll("\n");
}

pub fn printRemoveSummary(labels: []const []const u8) !void {
    var stdout: io_util.Stdout = undefined;
    stdout.init();
    const out = stdout.out();
    try writeRemoveSummaryTo(out, labels);
    try out.flush();
}

pub fn printSwitchedAccount(
    allocator: std.mem.Allocator,
    reg: *registry.Registry,
    account_key: []const u8,
) !void {
    const label = if (registry.findAccountIndexByAccountKey(reg, account_key)) |idx|
        try display_rows.buildPreferredAccountLabelAlloc(allocator, &reg.accounts.items[idx], reg.accounts.items[idx].email)
    else
        try allocator.dupe(u8, account_key);
    defer allocator.free(label);

    var stdout: io_util.Stdout = undefined;
    stdout.init();
    const out = stdout.out();
    const use_color = colorEnabled();
    if (use_color) try out.writeAll(ansi.bold_green);
    try out.print("Switched to {s}\n", .{label});
    if (use_color) try out.writeAll(ansi.reset);
    try out.flush();
}

fn writeCodexLoginLaunchFailureHint(err_name: []const u8, use_color: bool) !void {
    var buffer: [512]u8 = undefined;
    var writer = std.Io.File.stderr().writer(app_runtime.io(), &buffer);
    const out = &writer.interface;
    try writeCodexLoginLaunchFailureHintTo(out, err_name, use_color);
    try out.flush();
}

pub fn writeCodexLoginLaunchFailureHintTo(out: *std.Io.Writer, err_name: []const u8, use_color: bool) !void {
    try writeErrorPrefixTo(out, use_color);
    if (std.mem.eql(u8, err_name, "FileNotFound")) {
        try out.writeAll(" the `codex` executable was not found in your PATH.\n\n");
        try writeHintPrefixTo(out, use_color);
        try out.writeAll(" Ensure the Codex CLI is installed and available in your environment.\n");
        try out.writeAll("      Then run `codex login` manually and retry your command.\n");
    } else {
        try out.writeAll(" failed to launch the `codex login` process.\n\n");
        try writeHintPrefixTo(out, use_color);
        try out.writeAll(" Try running `codex login` manually, then retry your command.\n");
    }
}

pub fn codexLoginArgs(opts: LoginOptions) []const []const u8 {
    return if (opts.device_auth)
        &[_][]const u8{ "codex", "login", "--device-auth" }
    else
        &[_][]const u8{ "codex", "login" };
}

fn ensureCodexLoginSucceeded(term: std.process.Child.Term) !void {
    switch (term) {
        .exited => |code| {
            if (code == 0) return;
            return error.CodexLoginFailed;
        },
        else => return error.CodexLoginFailed,
    }
}

pub fn runCodexLogin(opts: LoginOptions) !void {
    var child = std.process.spawn(app_runtime.io(), .{
        .argv = codexLoginArgs(opts),
        .stdin = .inherit,
        .stdout = .inherit,
        .stderr = .inherit,
    }) catch |err| {
        writeCodexLoginLaunchFailureHint(@errorName(err), stderrColorEnabled()) catch {};
        return err;
    };
    const term = child.wait(app_runtime.io()) catch |err| {
        writeCodexLoginLaunchFailureHint(@errorName(err), stderrColorEnabled()) catch {};
        return err;
    };
    try ensureCodexLoginSucceeded(term);
}

pub fn selectAccount(allocator: std.mem.Allocator, reg: *registry.Registry) !?[]const u8 {
    return selectAccountWithUsageOverrides(allocator, reg, null);
}

pub fn selectAccountWithUsageOverrides(
    allocator: std.mem.Allocator,
    reg: *registry.Registry,
    usage_overrides: ?[]const ?[]const u8,
) !?[]const u8 {
    if (shouldUseNumberedSwitchSelector(
        comptime builtin.os.tag == .windows,
        std.Io.File.stdin().isTty(app_runtime.io()) catch false,
        std.Io.File.stdout().isTty(app_runtime.io()) catch false,
    )) {
        return selectWithNumbers(allocator, reg, usage_overrides);
    }
    return selectInteractive(allocator, reg, usage_overrides) catch |err| switch (err) {
        error.TuiRequiresTty => selectWithNumbers(allocator, reg, usage_overrides),
        else => return err,
    };
}

pub const SwitchSelectionDisplay = struct {
    reg: *registry.Registry,
    usage_overrides: ?[]const ?[]const u8,
};

pub const OwnedSwitchSelectionDisplay = struct {
    reg: registry.Registry,
    usage_overrides: []?[]const u8,

    pub fn borrowed(self: *@This()) SwitchSelectionDisplay {
        return .{
            .reg = &self.reg,
            .usage_overrides = self.usage_overrides,
        };
    }

    pub fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
        for (self.usage_overrides) |usage_override| {
            if (usage_override) |value| allocator.free(value);
        }
        allocator.free(self.usage_overrides);
        self.reg.deinit(allocator);
        self.* = undefined;
    }
};

pub const SwitchLiveController = struct {
    context: *anyopaque,
    maybe_start_refresh: *const fn (context: *anyopaque) anyerror!void,
    maybe_take_updated_display: *const fn (context: *anyopaque) anyerror!?OwnedSwitchSelectionDisplay,
    build_status_line: *const fn (
        context: *anyopaque,
        allocator: std.mem.Allocator,
        display: SwitchSelectionDisplay,
    ) anyerror![]u8,
};

pub const LiveActionOutcome = struct {
    updated_display: OwnedSwitchSelectionDisplay,
    action_message: ?[]u8 = null,
};

pub const SwitchLiveActionController = struct {
    refresh: SwitchLiveController,
    apply_selection: *const fn (
        context: *anyopaque,
        allocator: std.mem.Allocator,
        display: SwitchSelectionDisplay,
        account_key: []const u8,
    ) anyerror!LiveActionOutcome,
    auto_switch: bool = false,
};

pub const RemoveLiveActionController = struct {
    refresh: SwitchLiveController,
    apply_selection: *const fn (
        context: *anyopaque,
        allocator: std.mem.Allocator,
        display: SwitchSelectionDisplay,
        account_keys: []const []const u8,
    ) anyerror!LiveActionOutcome,
};

pub fn selectAccountWithLiveUpdates(
    allocator: std.mem.Allocator,
    initial_display: OwnedSwitchSelectionDisplay,
    controller: SwitchLiveController,
) !?[]const u8 {
    var current_display = initial_display;
    defer current_display.deinit(allocator);
    if (current_display.reg.accounts.items.len == 0) return null;

    if (shouldUseNumberedSwitchSelector(
        comptime builtin.os.tag == .windows,
        std.Io.File.stdin().isTty(app_runtime.io()) catch false,
        std.Io.File.stdout().isTty(app_runtime.io()) catch false,
    )) {
        const selected_account_key = try selectWithNumbers(allocator, &current_display.reg, current_display.usage_overrides);
        return try dupeOptionalAccountKey(allocator, selected_account_key);
    }

    var tui = try TuiSession.init();
    defer tui.deinit();

    const out = tui.out();
    const use_color = terminal_color.fileColorEnabled(tui.output);
    const ui_tick_ms: i32 = 1000;

    var selected_account_key = if (current_display.reg.active_account_key) |key|
        try allocator.dupe(u8, key)
    else
        null;
    defer if (selected_account_key) |key| allocator.free(key);

    var number_buf: [8]u8 = undefined;
    var number_len: usize = 0;

    while (true) {
        if (try controller.maybe_take_updated_display(controller.context)) |updated| {
            current_display.deinit(allocator);
            current_display = updated;
        }

        const borrowed = current_display.borrowed();
        var rows = try buildSwitchRowsWithUsageOverrides(allocator, borrowed.reg, borrowed.usage_overrides);
        defer rows.deinit(allocator);
        try filterErroredRowsFromSelectableIndices(allocator, &rows);
        const total_accounts = accountRowCount(rows.items);
        if (total_accounts == 0) return null;

        var selected_idx: ?usize = null;
        if (rows.selectable_row_indices.len != 0) {
            selected_idx = if (selected_account_key) |key|
                selectableIndexForAccountKey(&rows, borrowed.reg, key) orelse activeSelectableIndex(&rows) orelse 0
            else
                activeSelectableIndex(&rows) orelse 0;
            try replaceSelectedAccountKeyForSelectable(allocator, &selected_account_key, &rows, borrowed.reg, selected_idx.?);
        }

        const status_line = try controller.build_status_line(controller.context, allocator, borrowed);
        defer allocator.free(status_line);
        const selected_display_idx = selectedDisplayIndexForRender(&rows, selected_idx, number_buf[0..number_len]);

        try tui.resetFrame();
        try renderSwitchScreen(
            out,
            borrowed.reg,
            rows.items,
            @max(@as(usize, 2), indexWidth(total_accounts)),
            rows.widths,
            selected_display_idx,
            use_color,
            status_line,
            "",
            number_buf[0..number_len],
        );
        try out.flush();

        switch (try pollTuiInput(tui.input, ui_tick_ms, tui_poll_error_mask)) {
            .timeout => {
                try controller.maybe_start_refresh(controller.context);
                continue;
            },
            .closed => return null,
            .ready => {},
        }

        if (comptime builtin.os.tag == .windows) {
            switch (try tui.readWindowsKey()) {
                .move_up => {
                    if (selected_idx) |idx| {
                        if (idx > 0) {
                            try replaceSelectedAccountKeyForSelectable(allocator, &selected_account_key, &rows, borrowed.reg, idx - 1);
                            number_len = 0;
                        }
                    }
                },
                .move_down => {
                    if (selected_idx) |idx| {
                        if (idx + 1 < rows.selectable_row_indices.len) {
                            try replaceSelectedAccountKeyForSelectable(allocator, &selected_account_key, &rows, borrowed.reg, idx + 1);
                            number_len = 0;
                        }
                    }
                },
                .enter => {
                    if (parsedDisplayedIndex(number_buf[0..number_len], total_accounts)) |displayed_idx| {
                        return try dupSelectedAccountKeyForDisplayedAccount(allocator, &rows, borrowed.reg, displayed_idx);
                    }
                    if (selected_idx) |idx| {
                        return try dupSelectedAccountKey(allocator, &rows, borrowed.reg, idx);
                    }
                    return null;
                },
                .quit => return null,
                .backspace => {
                    if (number_len > 0) {
                        number_len -= 1;
                        if (parsedDisplayedIndex(number_buf[0..number_len], total_accounts)) |displayed_idx| {
                            if (selectableIndexForDisplayedAccount(&rows, displayed_idx)) |selectable_idx| {
                                try replaceSelectedAccountKeyForSelectable(allocator, &selected_account_key, &rows, borrowed.reg, selectable_idx);
                            }
                        }
                    }
                },
                .redraw => continue,
                .byte => |ch| {
                    if (isQuitKey(ch)) return null;

                    if (ch == 'k') {
                        if (selected_idx) |idx| {
                            if (idx > 0) {
                                try replaceSelectedAccountKeyForSelectable(allocator, &selected_account_key, &rows, borrowed.reg, idx - 1);
                                number_len = 0;
                            }
                        }
                        continue;
                    }
                    if (ch == 'j') {
                        if (selected_idx) |idx| {
                            if (idx + 1 < rows.selectable_row_indices.len) {
                                try replaceSelectedAccountKeyForSelectable(allocator, &selected_account_key, &rows, borrowed.reg, idx + 1);
                                number_len = 0;
                            }
                        }
                        continue;
                    }
                    if (ch >= '0' and ch <= '9' and number_len < number_buf.len) {
                        number_buf[number_len] = ch;
                        number_len += 1;
                        if (parsedDisplayedIndex(number_buf[0..number_len], total_accounts)) |displayed_idx| {
                            if (selectableIndexForDisplayedAccount(&rows, displayed_idx)) |selectable_idx| {
                                try replaceSelectedAccountKeyForSelectable(allocator, &selected_account_key, &rows, borrowed.reg, selectable_idx);
                            }
                        }
                    }
                },
            }
            continue;
        }

        var b: [8]u8 = undefined;
        const n = try tui.read(&b);
        if (n == 0) return null;

        var i: usize = 0;
        while (i < n) : (i += 1) {
            if (b[i] == 0x1b) {
                const escape = try readTuiEscapeAction(
                    tui.input,
                    b[i + 1 .. n],
                    tui_poll_error_mask,
                    tui_escape_sequence_timeout_ms,
                );
                switch (escape.action) {
                    .move_up => {
                        if (selected_idx) |idx| {
                            if (idx > 0) {
                                try replaceSelectedAccountKeyForSelectable(allocator, &selected_account_key, &rows, borrowed.reg, idx - 1);
                                number_len = 0;
                            }
                        }
                    },
                    .move_down => {
                        if (selected_idx) |idx| {
                            if (idx + 1 < rows.selectable_row_indices.len) {
                                try replaceSelectedAccountKeyForSelectable(allocator, &selected_account_key, &rows, borrowed.reg, idx + 1);
                                number_len = 0;
                            }
                        }
                    },
                    .quit => return null,
                    .ignore => {},
                }
                i += escape.buffered_bytes_consumed;
                continue;
            }

            if (b[i] == '\r' or b[i] == '\n') {
                if (parsedDisplayedIndex(number_buf[0..number_len], total_accounts)) |displayed_idx| {
                    return try dupSelectedAccountKeyForDisplayedAccount(allocator, &rows, borrowed.reg, displayed_idx);
                }
                if (selected_idx) |idx| {
                    return try dupSelectedAccountKey(allocator, &rows, borrowed.reg, idx);
                }
                return null;
            }
            if (isQuitKey(b[i])) return null;

            if (b[i] == 'k') {
                if (selected_idx) |idx| {
                    if (idx > 0) {
                        try replaceSelectedAccountKeyForSelectable(allocator, &selected_account_key, &rows, borrowed.reg, idx - 1);
                        number_len = 0;
                    }
                }
                continue;
            }
            if (b[i] == 'j') {
                if (selected_idx) |idx| {
                    if (idx + 1 < rows.selectable_row_indices.len) {
                        try replaceSelectedAccountKeyForSelectable(allocator, &selected_account_key, &rows, borrowed.reg, idx + 1);
                        number_len = 0;
                    }
                }
                continue;
            }
            if (b[i] == 0x7f or b[i] == 0x08) {
                if (number_len > 0) {
                    number_len -= 1;
                    if (parsedDisplayedIndex(number_buf[0..number_len], total_accounts)) |displayed_idx| {
                        if (selectableIndexForDisplayedAccount(&rows, displayed_idx)) |selectable_idx| {
                            try replaceSelectedAccountKeyForSelectable(allocator, &selected_account_key, &rows, borrowed.reg, selectable_idx);
                        }
                    }
                }
                continue;
            }
            if (b[i] >= '0' and b[i] <= '9') {
                if (number_len < number_buf.len) {
                    number_buf[number_len] = b[i];
                    number_len += 1;
                    if (parsedDisplayedIndex(number_buf[0..number_len], total_accounts)) |displayed_idx| {
                        if (selectableIndexForDisplayedAccount(&rows, displayed_idx)) |selectable_idx| {
                            try replaceSelectedAccountKeyForSelectable(allocator, &selected_account_key, &rows, borrowed.reg, selectable_idx);
                        }
                    }
                }
                continue;
            }
        }
    }
}

pub fn viewAccountsWithLiveUpdates(
    allocator: std.mem.Allocator,
    initial_display: OwnedSwitchSelectionDisplay,
    controller: SwitchLiveController,
) !void {
    var current_display = initial_display;
    defer current_display.deinit(allocator);

    var tui = try TuiSession.init();
    defer tui.deinit();

    const out = tui.out();
    const use_color = terminal_color.fileColorEnabled(tui.output);
    const ui_tick_ms: i32 = 1000;

    while (true) {
        if (try controller.maybe_take_updated_display(controller.context)) |updated| {
            current_display.deinit(allocator);
            current_display = updated;
        }

        var rows = try buildSwitchRowsWithUsageOverrides(allocator, &current_display.reg, current_display.usage_overrides);
        defer rows.deinit(allocator);
        const status_line = try controller.build_status_line(controller.context, allocator, current_display.borrowed());
        defer allocator.free(status_line);

        try tui.resetFrame();
        try renderListScreen(
            out,
            &current_display.reg,
            rows.items,
            @max(@as(usize, 2), indexWidth(rows.selectable_row_indices.len)),
            rows.widths,
            use_color,
            status_line,
        );
        try out.flush();

        switch (try pollTuiInput(tui.input, ui_tick_ms, tui_poll_error_mask)) {
            .timeout => {
                try controller.maybe_start_refresh(controller.context);
                continue;
            },
            .closed => return,
            .ready => {},
        }

        if (comptime builtin.os.tag == .windows) {
            switch (try tui.readWindowsKey()) {
                .quit => return,
                .redraw => continue,
                else => continue,
            }
        }

        var b: [8]u8 = undefined;
        const n = try tui.read(&b);
        if (n == 0) return;

        var i: usize = 0;
        while (i < n) : (i += 1) {
            if (b[i] == 0x1b) {
                const escape = try readTuiEscapeAction(
                    tui.input,
                    b[i + 1 .. n],
                    tui_poll_error_mask,
                    tui_escape_sequence_timeout_ms,
                );
                switch (escape.action) {
                    .quit => return,
                    else => {},
                }
                i += escape.buffered_bytes_consumed;
                continue;
            }
            if (isQuitKey(b[i])) return;
        }
    }
}

pub fn runSwitchLiveActions(
    allocator: std.mem.Allocator,
    initial_display: OwnedSwitchSelectionDisplay,
    controller: SwitchLiveActionController,
) !void {
    var current_display = initial_display;
    defer current_display.deinit(allocator);

    var tui = try TuiSession.init();
    defer tui.deinit();

    const out = tui.out();
    const use_color = terminal_color.fileColorEnabled(tui.output);
    const ui_tick_ms: i32 = 1000;

    var selected_account_key = if (current_display.reg.active_account_key) |key|
        try allocator.dupe(u8, key)
    else
        null;
    defer if (selected_account_key) |key| allocator.free(key);

    var action_message: ?[]u8 = null;
    defer if (action_message) |message| allocator.free(message);

    var number_buf: [8]u8 = undefined;
    var number_len: usize = 0;
    var auto_check_pending = controller.auto_switch;

    while (true) {
        if (try controller.refresh.maybe_take_updated_display(controller.refresh.context)) |updated| {
            current_display.deinit(allocator);
            current_display = updated;
            auto_check_pending = controller.auto_switch;
        }

        const borrowed = current_display.borrowed();
        var rows = try buildSwitchRowsWithUsageOverrides(allocator, borrowed.reg, borrowed.usage_overrides);
        defer rows.deinit(allocator);
        try filterErroredRowsFromSelectableIndices(allocator, &rows);
        const total_accounts = accountRowCount(rows.items);

        var selected_idx: ?usize = null;
        if (rows.selectable_row_indices.len != 0) {
            selected_idx = if (selected_account_key) |key|
                selectableIndexForAccountKey(&rows, borrowed.reg, key) orelse activeSelectableIndex(&rows) orelse 0
            else
                activeSelectableIndex(&rows) orelse 0;
            try replaceSelectedAccountKeyForSelectable(allocator, &selected_account_key, &rows, borrowed.reg, selected_idx.?);
        }

        if (auto_check_pending) {
            if (try maybeAutoSwitchTargetKeyAlloc(allocator, borrowed, &rows)) |target_key| {
                defer allocator.free(target_key);
                const outcome = controller.apply_selection(controller.refresh.context, allocator, borrowed, target_key) catch |err| {
                    replaceOptionalOwnedString(
                        allocator,
                        &action_message,
                        try std.fmt.allocPrint(allocator, "Auto-switch failed: {s}", .{@errorName(err)}),
                    );
                    replaceOptionalOwnedString(allocator, &selected_account_key, try allocator.dupe(u8, target_key));
                    number_len = 0;
                    auto_check_pending = false;
                    continue;
                };
                current_display.deinit(allocator);
                current_display = outcome.updated_display;
                replaceOptionalOwnedString(allocator, &action_message, outcome.action_message);
                replaceOptionalOwnedString(allocator, &selected_account_key, try allocator.dupe(u8, target_key));
                number_len = 0;
                auto_check_pending = controller.auto_switch;
                continue;
            }
            auto_check_pending = false;
        }

        const status_line = try controller.refresh.build_status_line(controller.refresh.context, allocator, borrowed);
        defer allocator.free(status_line);
        const selected_display_idx = selectedDisplayIndexForRender(&rows, selected_idx, number_buf[0..number_len]);

        try tui.resetFrame();
        try renderSwitchScreen(
            out,
            borrowed.reg,
            rows.items,
            @max(@as(usize, 2), indexWidth(total_accounts)),
            rows.widths,
            selected_display_idx,
            use_color,
            status_line,
            action_message orelse "",
            number_buf[0..number_len],
        );
        try out.flush();

        switch (try pollTuiInput(tui.input, ui_tick_ms, tui_poll_error_mask)) {
            .timeout => {
                try controller.refresh.maybe_start_refresh(controller.refresh.context);
                continue;
            },
            .closed => return,
            .ready => {},
        }

        if (comptime builtin.os.tag == .windows) {
            switch (try tui.readWindowsKey()) {
                .move_up => {
                    if (selected_idx) |idx| {
                        if (idx > 0) {
                            try replaceSelectedAccountKeyForSelectable(allocator, &selected_account_key, &rows, borrowed.reg, idx - 1);
                            number_len = 0;
                        }
                    }
                },
                .move_down => {
                    if (selected_idx) |idx| {
                        if (idx + 1 < rows.selectable_row_indices.len) {
                            try replaceSelectedAccountKeyForSelectable(allocator, &selected_account_key, &rows, borrowed.reg, idx + 1);
                            number_len = 0;
                        }
                    }
                },
                .enter => {
                    const target_key = if (parsedDisplayedIndex(number_buf[0..number_len], total_accounts)) |displayed_idx|
                        try allocator.dupe(u8, accountIdForDisplayedAccount(&rows, borrowed.reg, displayed_idx) orelse continue)
                    else if (selected_idx) |idx|
                        try accountKeyForSelectableAlloc(allocator, &rows, borrowed.reg, idx)
                    else
                        continue;
                    defer allocator.free(target_key);
                    const outcome = controller.apply_selection(controller.refresh.context, allocator, borrowed, target_key) catch |err| {
                        replaceOptionalOwnedString(
                            allocator,
                            &action_message,
                            try std.fmt.allocPrint(allocator, "Switch failed: {s}", .{@errorName(err)}),
                        );
                        replaceOptionalOwnedString(allocator, &selected_account_key, try allocator.dupe(u8, target_key));
                        number_len = 0;
                        continue;
                    };
                    current_display.deinit(allocator);
                    current_display = outcome.updated_display;
                    replaceOptionalOwnedString(allocator, &action_message, outcome.action_message);
                    replaceOptionalOwnedString(allocator, &selected_account_key, try allocator.dupe(u8, target_key));
                    number_len = 0;
                    auto_check_pending = controller.auto_switch;
                },
                .quit => return,
                .backspace => {
                    if (number_len > 0) {
                        number_len -= 1;
                        if (parsedDisplayedIndex(number_buf[0..number_len], total_accounts)) |displayed_idx| {
                            if (selectableIndexForDisplayedAccount(&rows, displayed_idx)) |selectable_idx| {
                                try replaceSelectedAccountKeyForSelectable(allocator, &selected_account_key, &rows, borrowed.reg, selectable_idx);
                            }
                        }
                    }
                },
                .redraw => continue,
                .byte => |ch| {
                    if (isQuitKey(ch)) return;
                    if (ch == 'k') {
                        if (selected_idx) |idx| {
                            if (idx > 0) {
                                try replaceSelectedAccountKeyForSelectable(allocator, &selected_account_key, &rows, borrowed.reg, idx - 1);
                                number_len = 0;
                            }
                        }
                        continue;
                    }
                    if (ch == 'j') {
                        if (selected_idx) |idx| {
                            if (idx + 1 < rows.selectable_row_indices.len) {
                                try replaceSelectedAccountKeyForSelectable(allocator, &selected_account_key, &rows, borrowed.reg, idx + 1);
                                number_len = 0;
                            }
                        }
                        continue;
                    }
                    if (ch >= '0' and ch <= '9' and number_len < number_buf.len) {
                        number_buf[number_len] = ch;
                        number_len += 1;
                        if (parsedDisplayedIndex(number_buf[0..number_len], total_accounts)) |displayed_idx| {
                            if (selectableIndexForDisplayedAccount(&rows, displayed_idx)) |selectable_idx| {
                                try replaceSelectedAccountKeyForSelectable(allocator, &selected_account_key, &rows, borrowed.reg, selectable_idx);
                            }
                        }
                    }
                },
            }
            continue;
        }

        var b: [8]u8 = undefined;
        const n = try tui.read(&b);
        if (n == 0) return;

        var i: usize = 0;
        while (i < n) : (i += 1) {
            if (b[i] == 0x1b) {
                const escape = try readTuiEscapeAction(
                    tui.input,
                    b[i + 1 .. n],
                    tui_poll_error_mask,
                    tui_escape_sequence_timeout_ms,
                );
                switch (escape.action) {
                    .move_up => {
                        if (selected_idx) |idx| {
                            if (idx > 0) {
                                try replaceSelectedAccountKeyForSelectable(allocator, &selected_account_key, &rows, borrowed.reg, idx - 1);
                                number_len = 0;
                            }
                        }
                    },
                    .move_down => {
                        if (selected_idx) |idx| {
                            if (idx + 1 < rows.selectable_row_indices.len) {
                                try replaceSelectedAccountKeyForSelectable(allocator, &selected_account_key, &rows, borrowed.reg, idx + 1);
                                number_len = 0;
                            }
                        }
                    },
                    .quit => return,
                    .ignore => {},
                }
                i += escape.buffered_bytes_consumed;
                continue;
            }

            if (b[i] == '\r' or b[i] == '\n') {
                const target_key = if (parsedDisplayedIndex(number_buf[0..number_len], total_accounts)) |displayed_idx|
                    try allocator.dupe(u8, accountIdForDisplayedAccount(&rows, borrowed.reg, displayed_idx) orelse continue)
                else if (selected_idx) |idx|
                    try accountKeyForSelectableAlloc(allocator, &rows, borrowed.reg, idx)
                else
                    continue;
                defer allocator.free(target_key);
                const outcome = controller.apply_selection(controller.refresh.context, allocator, borrowed, target_key) catch |err| {
                    replaceOptionalOwnedString(
                        allocator,
                        &action_message,
                        try std.fmt.allocPrint(allocator, "Switch failed: {s}", .{@errorName(err)}),
                    );
                    replaceOptionalOwnedString(allocator, &selected_account_key, try allocator.dupe(u8, target_key));
                    number_len = 0;
                    continue;
                };
                current_display.deinit(allocator);
                current_display = outcome.updated_display;
                replaceOptionalOwnedString(allocator, &action_message, outcome.action_message);
                replaceOptionalOwnedString(allocator, &selected_account_key, try allocator.dupe(u8, target_key));
                number_len = 0;
                auto_check_pending = controller.auto_switch;
                continue;
            }
            if (isQuitKey(b[i])) return;

            if (b[i] == 'k') {
                if (selected_idx) |idx| {
                    if (idx > 0) {
                        try replaceSelectedAccountKeyForSelectable(allocator, &selected_account_key, &rows, borrowed.reg, idx - 1);
                        number_len = 0;
                    }
                }
                continue;
            }
            if (b[i] == 'j') {
                if (selected_idx) |idx| {
                    if (idx + 1 < rows.selectable_row_indices.len) {
                        try replaceSelectedAccountKeyForSelectable(allocator, &selected_account_key, &rows, borrowed.reg, idx + 1);
                        number_len = 0;
                    }
                }
                continue;
            }
            if (b[i] == 0x7f or b[i] == 0x08) {
                if (number_len > 0) {
                    number_len -= 1;
                    if (parsedDisplayedIndex(number_buf[0..number_len], total_accounts)) |displayed_idx| {
                        if (selectableIndexForDisplayedAccount(&rows, displayed_idx)) |selectable_idx| {
                            try replaceSelectedAccountKeyForSelectable(allocator, &selected_account_key, &rows, borrowed.reg, selectable_idx);
                        }
                    }
                }
                continue;
            }
            if (b[i] >= '0' and b[i] <= '9') {
                if (number_len < number_buf.len) {
                    number_buf[number_len] = b[i];
                    number_len += 1;
                    if (parsedDisplayedIndex(number_buf[0..number_len], total_accounts)) |displayed_idx| {
                        if (selectableIndexForDisplayedAccount(&rows, displayed_idx)) |selectable_idx| {
                            try replaceSelectedAccountKeyForSelectable(allocator, &selected_account_key, &rows, borrowed.reg, selectable_idx);
                        }
                    }
                }
                continue;
            }
        }
    }
}

pub fn runRemoveLiveActions(
    allocator: std.mem.Allocator,
    initial_display: OwnedSwitchSelectionDisplay,
    controller: RemoveLiveActionController,
) !void {
    var current_display = initial_display;
    defer current_display.deinit(allocator);

    var tui = try TuiSession.init();
    defer tui.deinit();

    const out = tui.out();
    const use_color = terminal_color.fileColorEnabled(tui.output);
    const ui_tick_ms: i32 = 1000;

    var cursor_account_key: ?[]u8 = null;
    defer if (cursor_account_key) |key| allocator.free(key);

    var checked_account_keys = std.ArrayList([]u8).empty;
    defer {
        clearOwnedAccountKeys(allocator, &checked_account_keys);
        checked_account_keys.deinit(allocator);
    }

    var action_message: ?[]u8 = null;
    defer if (action_message) |message| allocator.free(message);

    var number_buf: [8]u8 = undefined;
    var number_len: usize = 0;

    while (true) {
        if (try controller.refresh.maybe_take_updated_display(controller.refresh.context)) |updated| {
            current_display.deinit(allocator);
            current_display = updated;
        }

        const borrowed = current_display.borrowed();
        var rows = try buildSwitchRowsWithUsageOverrides(allocator, borrowed.reg, borrowed.usage_overrides);
        defer rows.deinit(allocator);

        var cursor_idx: ?usize = null;
        if (rows.selectable_row_indices.len != 0) {
            cursor_idx = if (cursor_account_key) |key|
                selectableIndexForAccountKey(&rows, borrowed.reg, key) orelse activeSelectableIndex(&rows) orelse 0
            else
                activeSelectableIndex(&rows) orelse 0;
            try replaceSelectedAccountKeyForSelectable(allocator, &cursor_account_key, &rows, borrowed.reg, cursor_idx.?);
        }

        const checked_flags = try allocator.alloc(bool, rows.selectable_row_indices.len);
        defer allocator.free(checked_flags);
        for (checked_flags, 0..) |*flag, selectable_idx| {
            flag.* = containsOwnedAccountKey(&checked_account_keys, accountIdForSelectable(&rows, borrowed.reg, selectable_idx));
        }

        const status_line = try controller.refresh.build_status_line(controller.refresh.context, allocator, borrowed);
        defer allocator.free(status_line);

        try tui.resetFrame();
        try renderRemoveScreen(
            out,
            borrowed.reg,
            rows.items,
            @max(@as(usize, 2), indexWidth(rows.selectable_row_indices.len)),
            rows.widths,
            cursor_idx,
            checked_flags,
            use_color,
            status_line,
            action_message orelse "",
            number_buf[0..number_len],
        );
        try out.flush();

        switch (try pollTuiInput(tui.input, ui_tick_ms, tui_poll_error_mask)) {
            .timeout => {
                try controller.refresh.maybe_start_refresh(controller.refresh.context);
                continue;
            },
            .closed => return,
            .ready => {},
        }

        if (comptime builtin.os.tag == .windows) {
            switch (try tui.readWindowsKey()) {
                .move_up => {
                    if (cursor_idx) |idx| {
                        if (idx > 0) {
                            try replaceSelectedAccountKeyForSelectable(allocator, &cursor_account_key, &rows, borrowed.reg, idx - 1);
                            number_len = 0;
                        }
                    }
                },
                .move_down => {
                    if (cursor_idx) |idx| {
                        if (idx + 1 < rows.selectable_row_indices.len) {
                            try replaceSelectedAccountKeyForSelectable(allocator, &cursor_account_key, &rows, borrowed.reg, idx + 1);
                            number_len = 0;
                        }
                    }
                },
                .enter => {
                    if (checked_account_keys.items.len == 0) {
                        replaceOptionalOwnedString(allocator, &action_message, try allocator.dupe(u8, "No accounts selected"));
                        continue;
                    }
                    const selected_keys = try allocator.alloc([]const u8, checked_account_keys.items.len);
                    defer allocator.free(selected_keys);
                    for (checked_account_keys.items, 0..) |key, idx| selected_keys[idx] = key;
                    const outcome = controller.apply_selection(controller.refresh.context, allocator, borrowed, selected_keys) catch |err| {
                        replaceOptionalOwnedString(
                            allocator,
                            &action_message,
                            try std.fmt.allocPrint(allocator, "Delete failed: {s}", .{@errorName(err)}),
                        );
                        continue;
                    };
                    clearOwnedAccountKeys(allocator, &checked_account_keys);
                    current_display.deinit(allocator);
                    current_display = outcome.updated_display;
                    replaceOptionalOwnedString(allocator, &action_message, outcome.action_message);
                    number_len = 0;
                },
                .quit => return,
                .backspace => {
                    if (number_len > 0) {
                        number_len -= 1;
                        if (number_len > 0 and rows.selectable_row_indices.len != 0) {
                            const parsed = std.fmt.parseInt(usize, number_buf[0..number_len], 10) catch 0;
                            if (parsed >= 1 and parsed <= rows.selectable_row_indices.len) {
                                try replaceSelectedAccountKeyForSelectable(allocator, &cursor_account_key, &rows, borrowed.reg, parsed - 1);
                            }
                        }
                    }
                },
                .redraw => continue,
                .byte => |ch| {
                    if (isQuitKey(ch)) return;
                    if (ch == 'k') {
                        if (cursor_idx) |idx| {
                            if (idx > 0) {
                                try replaceSelectedAccountKeyForSelectable(allocator, &cursor_account_key, &rows, borrowed.reg, idx - 1);
                                number_len = 0;
                            }
                        }
                        continue;
                    }
                    if (ch == 'j') {
                        if (cursor_idx) |idx| {
                            if (idx + 1 < rows.selectable_row_indices.len) {
                                try replaceSelectedAccountKeyForSelectable(allocator, &cursor_account_key, &rows, borrowed.reg, idx + 1);
                                number_len = 0;
                            }
                        }
                        continue;
                    }
                    if (ch == ' ') {
                        if (cursor_idx) |idx| {
                            try toggleOwnedAccountKey(allocator, &checked_account_keys, accountIdForSelectable(&rows, borrowed.reg, idx));
                            number_len = 0;
                        }
                        continue;
                    }
                    if (ch >= '0' and ch <= '9' and number_len < number_buf.len) {
                        number_buf[number_len] = ch;
                        number_len += 1;
                        if (rows.selectable_row_indices.len != 0) {
                            const parsed = std.fmt.parseInt(usize, number_buf[0..number_len], 10) catch 0;
                            if (parsed >= 1 and parsed <= rows.selectable_row_indices.len) {
                                try replaceSelectedAccountKeyForSelectable(allocator, &cursor_account_key, &rows, borrowed.reg, parsed - 1);
                            }
                        }
                    }
                },
            }
            continue;
        }

        var b: [8]u8 = undefined;
        const n = try tui.read(&b);
        if (n == 0) return;

        var i: usize = 0;
        while (i < n) : (i += 1) {
            if (b[i] == 0x1b) {
                const escape = try readTuiEscapeAction(
                    tui.input,
                    b[i + 1 .. n],
                    tui_poll_error_mask,
                    tui_escape_sequence_timeout_ms,
                );
                switch (escape.action) {
                    .move_up => {
                        if (cursor_idx) |idx| {
                            if (idx > 0) {
                                try replaceSelectedAccountKeyForSelectable(allocator, &cursor_account_key, &rows, borrowed.reg, idx - 1);
                                number_len = 0;
                            }
                        }
                    },
                    .move_down => {
                        if (cursor_idx) |idx| {
                            if (idx + 1 < rows.selectable_row_indices.len) {
                                try replaceSelectedAccountKeyForSelectable(allocator, &cursor_account_key, &rows, borrowed.reg, idx + 1);
                                number_len = 0;
                            }
                        }
                    },
                    .quit => return,
                    .ignore => {},
                }
                i += escape.buffered_bytes_consumed;
                continue;
            }

            if (b[i] == '\r' or b[i] == '\n') {
                if (checked_account_keys.items.len == 0) {
                    replaceOptionalOwnedString(allocator, &action_message, try allocator.dupe(u8, "No accounts selected"));
                    continue;
                }
                const selected_keys = try allocator.alloc([]const u8, checked_account_keys.items.len);
                defer allocator.free(selected_keys);
                for (checked_account_keys.items, 0..) |key, idx| selected_keys[idx] = key;
                const outcome = controller.apply_selection(controller.refresh.context, allocator, borrowed, selected_keys) catch |err| {
                    replaceOptionalOwnedString(
                        allocator,
                        &action_message,
                        try std.fmt.allocPrint(allocator, "Delete failed: {s}", .{@errorName(err)}),
                    );
                    continue;
                };
                clearOwnedAccountKeys(allocator, &checked_account_keys);
                current_display.deinit(allocator);
                current_display = outcome.updated_display;
                replaceOptionalOwnedString(allocator, &action_message, outcome.action_message);
                number_len = 0;
                continue;
            }
            if (isQuitKey(b[i])) return;
            if (b[i] == 'k') {
                if (cursor_idx) |idx| {
                    if (idx > 0) {
                        try replaceSelectedAccountKeyForSelectable(allocator, &cursor_account_key, &rows, borrowed.reg, idx - 1);
                        number_len = 0;
                    }
                }
                continue;
            }
            if (b[i] == 'j') {
                if (cursor_idx) |idx| {
                    if (idx + 1 < rows.selectable_row_indices.len) {
                        try replaceSelectedAccountKeyForSelectable(allocator, &cursor_account_key, &rows, borrowed.reg, idx + 1);
                        number_len = 0;
                    }
                }
                continue;
            }
            if (b[i] == ' ') {
                if (cursor_idx) |idx| {
                    try toggleOwnedAccountKey(allocator, &checked_account_keys, accountIdForSelectable(&rows, borrowed.reg, idx));
                    number_len = 0;
                }
                continue;
            }
            if (b[i] == 0x7f or b[i] == 0x08) {
                if (number_len > 0) {
                    number_len -= 1;
                    if (number_len > 0 and rows.selectable_row_indices.len != 0) {
                        const parsed = std.fmt.parseInt(usize, number_buf[0..number_len], 10) catch 0;
                        if (parsed >= 1 and parsed <= rows.selectable_row_indices.len) {
                            try replaceSelectedAccountKeyForSelectable(allocator, &cursor_account_key, &rows, borrowed.reg, parsed - 1);
                        }
                    }
                }
                continue;
            }
            if (b[i] >= '0' and b[i] <= '9') {
                if (number_len < number_buf.len) {
                    number_buf[number_len] = b[i];
                    number_len += 1;
                    if (rows.selectable_row_indices.len != 0) {
                        const parsed = std.fmt.parseInt(usize, number_buf[0..number_len], 10) catch 0;
                        if (parsed >= 1 and parsed <= rows.selectable_row_indices.len) {
                            try replaceSelectedAccountKeyForSelectable(allocator, &cursor_account_key, &rows, borrowed.reg, parsed - 1);
                        }
                    }
                }
                continue;
            }
        }
    }
}

pub fn selectAccountFromIndices(allocator: std.mem.Allocator, reg: *registry.Registry, indices: []const usize) !?[]const u8 {
    return selectAccountFromIndicesWithUsageOverrides(allocator, reg, indices, null);
}

pub fn selectAccountFromIndicesWithUsageOverrides(
    allocator: std.mem.Allocator,
    reg: *registry.Registry,
    indices: []const usize,
    usage_overrides: ?[]const ?[]const u8,
) !?[]const u8 {
    if (indices.len == 0) return null;
    if (indices.len == 1) return reg.accounts.items[indices[0]].account_key;
    if (shouldUseNumberedSwitchSelector(
        comptime builtin.os.tag == .windows,
        std.Io.File.stdin().isTty(app_runtime.io()) catch false,
        std.Io.File.stdout().isTty(app_runtime.io()) catch false,
    )) {
        return selectWithNumbersFromIndices(allocator, reg, indices, usage_overrides);
    }
    return selectInteractiveFromIndices(allocator, reg, indices, usage_overrides) catch |err| switch (err) {
        error.TuiRequiresTty => selectWithNumbersFromIndices(allocator, reg, indices, usage_overrides),
        else => return err,
    };
}

pub fn shouldUseNumberedSwitchSelector(is_windows: bool, stdin_is_tty: bool, stdout_is_tty: bool) bool {
    _ = is_windows;
    return !stdin_is_tty or !stdout_is_tty;
}

pub fn selectAccountsToRemove(allocator: std.mem.Allocator, reg: *registry.Registry) !?[]usize {
    return selectAccountsToRemoveWithUsageOverrides(allocator, reg, null);
}

pub fn selectAccountsToRemoveWithUsageOverrides(
    allocator: std.mem.Allocator,
    reg: *registry.Registry,
    usage_overrides: ?[]const ?[]const u8,
) !?[]usize {
    if (shouldUseNumberedRemoveSelector(
        comptime builtin.os.tag == .windows,
        std.Io.File.stdin().isTty(app_runtime.io()) catch false,
        std.Io.File.stdout().isTty(app_runtime.io()) catch false,
    )) {
        return selectRemoveWithNumbers(allocator, reg, usage_overrides);
    }
    return selectRemoveInteractive(allocator, reg, usage_overrides) catch |err| switch (err) {
        error.TuiRequiresTty => selectRemoveWithNumbers(allocator, reg, usage_overrides),
        else => return err,
    };
}

pub fn shouldUseNumberedRemoveSelector(is_windows: bool, stdin_is_tty: bool, stdout_is_tty: bool) bool {
    _ = is_windows;
    return !stdin_is_tty or !stdout_is_tty;
}

fn isQuitInput(input: []const u8) bool {
    return input.len == 1 and (input[0] == 'q' or input[0] == 'Q');
}

fn isQuitKey(key: u8) bool {
    return key == 'q' or key == 'Q';
}

fn activeSelectableIndex(rows: *const SwitchRows) ?usize {
    for (rows.selectable_row_indices, 0..) |row_idx, pos| {
        if (rows.items[row_idx].is_active) return pos;
    }
    return null;
}

fn accountIdForSelectable(rows: *const SwitchRows, reg: *registry.Registry, selectable_idx: usize) []const u8 {
    const row_idx = rows.selectable_row_indices[selectable_idx];
    const account_idx = rows.items[row_idx].account_index.?;
    return reg.accounts.items[account_idx].account_key;
}

fn accountRowCount(rows: []const SwitchRow) usize {
    var count: usize = 0;
    for (rows) |row| {
        if (!row.is_header) count += 1;
    }
    return count;
}

fn rowIndexForDisplayedAccount(rows: []const SwitchRow, displayed_idx: usize) ?usize {
    var current: usize = 0;
    for (rows, 0..) |row, row_idx| {
        if (row.is_header) continue;
        if (current == displayed_idx) return row_idx;
        current += 1;
    }
    return null;
}

fn displayedIndexForRowIndex(rows: []const SwitchRow, row_idx: usize) ?usize {
    if (row_idx >= rows.len or rows[row_idx].is_header) return null;
    var current: usize = 0;
    for (rows, 0..) |row, idx| {
        if (row.is_header) continue;
        if (idx == row_idx) return current;
        current += 1;
    }
    return null;
}

fn displayedIndexForSelectable(rows: *const SwitchRows, selectable_idx: usize) ?usize {
    if (selectable_idx >= rows.selectable_row_indices.len) return null;
    return displayedIndexForRowIndex(rows.items, rows.selectable_row_indices[selectable_idx]);
}

fn selectableIndexForDisplayedAccount(rows: *const SwitchRows, displayed_idx: usize) ?usize {
    const row_idx = rowIndexForDisplayedAccount(rows.items, displayed_idx) orelse return null;
    for (rows.selectable_row_indices, 0..) |selectable_row_idx, selectable_idx| {
        if (selectable_row_idx == row_idx) return selectable_idx;
    }
    return null;
}

fn accountIdForDisplayedAccount(
    rows: *const SwitchRows,
    reg: *registry.Registry,
    displayed_idx: usize,
) ?[]const u8 {
    const row_idx = rowIndexForDisplayedAccount(rows.items, displayed_idx) orelse return null;
    const account_idx = rows.items[row_idx].account_index orelse return null;
    return reg.accounts.items[account_idx].account_key;
}

fn dupSelectedAccountKeyForDisplayedAccount(
    allocator: std.mem.Allocator,
    rows: *const SwitchRows,
    reg: *registry.Registry,
    displayed_idx: usize,
) !?[]const u8 {
    const account_key = accountIdForDisplayedAccount(rows, reg, displayed_idx) orelse return null;
    return try allocator.dupe(u8, account_key);
}

fn parsedDisplayedIndex(number_input: []const u8, total_accounts: usize) ?usize {
    if (number_input.len == 0) return null;
    const parsed = std.fmt.parseInt(usize, number_input, 10) catch return null;
    if (parsed == 0 or parsed > total_accounts) return null;
    return parsed - 1;
}

fn selectedDisplayIndexForRender(
    rows: *const SwitchRows,
    selected_selectable_idx: ?usize,
    number_input: []const u8,
) ?usize {
    if (parsedDisplayedIndex(number_input, accountRowCount(rows.items))) |displayed_idx| {
        return displayed_idx;
    }
    if (selected_selectable_idx) |selectable_idx| {
        return displayedIndexForSelectable(rows, selectable_idx);
    }
    return null;
}

fn numericUsageOverrideStatus(usage_override: ?[]const u8) ?u16 {
    const value = usage_override orelse return null;
    return std.fmt.parseInt(u16, value, 10) catch null;
}

fn accountHasExhaustedUsage(rec: *const registry.AccountRecord, now: i64) bool {
    const rate_5h = resolveRateWindow(rec.last_usage, 300, true);
    const rate_week = resolveRateWindow(rec.last_usage, 10080, false);
    const rem_5h = registry.remainingPercentAt(rate_5h, now);
    const rem_week = registry.remainingPercentAt(rate_week, now);
    return (rem_5h != null and rem_5h.? == 0) or (rem_week != null and rem_week.? == 0);
}

fn shouldAutoSwitchActiveAccount(display: SwitchSelectionDisplay, now: i64) bool {
    const active_account_key = display.reg.active_account_key orelse return false;
    const active_idx = registry.findAccountIndexByAccountKey(display.reg, active_account_key) orelse return false;

    if (numericUsageOverrideStatus(usageOverrideForAccount(display.usage_overrides, active_idx))) |status_code| {
        return status_code != 200;
    }

    return accountHasExhaustedUsage(&display.reg.accounts.items[active_idx], now);
}

fn autoSwitchCandidateIsBetter(
    candidate_score: ?i64,
    candidate_last_usage_at: ?i64,
    best_score: ?i64,
    best_last_usage_at: i64,
) bool {
    if (candidate_score != null and best_score == null) return true;
    if (candidate_score == null and best_score != null) return false;
    if (candidate_score != null and best_score != null and candidate_score.? != best_score.?) {
        return candidate_score.? > best_score.?;
    }

    return (candidate_last_usage_at orelse -1) > best_last_usage_at;
}

fn bestAutoSwitchCandidateSelectableIndex(
    rows: *const SwitchRows,
    reg: *registry.Registry,
    now: i64,
) ?usize {
    const active_account_key = reg.active_account_key orelse return null;

    var best_selectable_idx: ?usize = null;
    var best_score: ?i64 = null;
    var best_last_usage_at: i64 = -1;

    for (rows.selectable_row_indices, 0..) |row_idx, selectable_idx| {
        const account_idx = rows.items[row_idx].account_index orelse continue;
        const rec = &reg.accounts.items[account_idx];
        if (std.mem.eql(u8, rec.account_key, active_account_key)) continue;
        if (accountHasExhaustedUsage(rec, now)) continue;

        const candidate_score = registry.usageScoreAt(rec.last_usage, now);
        if (best_selectable_idx == null or autoSwitchCandidateIsBetter(
            candidate_score,
            rec.last_usage_at,
            best_score,
            best_last_usage_at,
        )) {
            best_selectable_idx = selectable_idx;
            best_score = candidate_score;
            best_last_usage_at = rec.last_usage_at orelse -1;
        }
    }

    return best_selectable_idx;
}

fn maybeAutoSwitchTargetKeyAlloc(
    allocator: std.mem.Allocator,
    display: SwitchSelectionDisplay,
    rows: *const SwitchRows,
) !?[]u8 {
    const now = std.Io.Timestamp.now(app_runtime.io(), .real).toSeconds();
    if (!shouldAutoSwitchActiveAccount(display, now)) return null;

    const selectable_idx = bestAutoSwitchCandidateSelectableIndex(rows, display.reg, now) orelse return null;
    return try accountKeyForSelectableAlloc(allocator, rows, display.reg, selectable_idx);
}

fn dupSelectedAccountKey(
    allocator: std.mem.Allocator,
    rows: *const SwitchRows,
    reg: *registry.Registry,
    selectable_idx: usize,
) ![]const u8 {
    return try allocator.dupe(u8, accountIdForSelectable(rows, reg, selectable_idx));
}

fn dupeOptionalAccountKey(allocator: std.mem.Allocator, account_key: ?[]const u8) !?[]const u8 {
    return if (account_key) |value| try allocator.dupe(u8, value) else null;
}

fn accountIndexForSelectable(rows: *const SwitchRows, selectable_idx: usize) usize {
    const row_idx = rows.selectable_row_indices[selectable_idx];
    return rows.items[row_idx].account_index.?;
}

fn selectableIndexForAccountKey(
    rows: *const SwitchRows,
    reg: *registry.Registry,
    account_key: []const u8,
) ?usize {
    for (rows.selectable_row_indices, 0..) |row_idx, selectable_idx| {
        const account_idx = rows.items[row_idx].account_index orelse continue;
        if (std.mem.eql(u8, reg.accounts.items[account_idx].account_key, account_key)) return selectable_idx;
    }
    return null;
}

fn replaceSelectedAccountKeyForSelectable(
    allocator: std.mem.Allocator,
    selected_account_key: *?[]u8,
    rows: *const SwitchRows,
    reg: *registry.Registry,
    selectable_idx: usize,
) !void {
    const next_key = try allocator.dupe(u8, accountIdForSelectable(rows, reg, selectable_idx));
    if (selected_account_key.*) |current_key| allocator.free(current_key);
    selected_account_key.* = next_key;
}

fn replaceOptionalOwnedString(
    allocator: std.mem.Allocator,
    target: *?[]u8,
    next: ?[]u8,
) void {
    if (target.*) |current| allocator.free(current);
    target.* = next;
}

fn accountKeyForSelectableAlloc(
    allocator: std.mem.Allocator,
    rows: *const SwitchRows,
    reg: *registry.Registry,
    selectable_idx: usize,
) ![]u8 {
    return try allocator.dupe(u8, accountIdForSelectable(rows, reg, selectable_idx));
}

fn firstSelectableAccountKeyAlloc(
    allocator: std.mem.Allocator,
    rows: *const SwitchRows,
    reg: *registry.Registry,
) !?[]u8 {
    if (rows.selectable_row_indices.len == 0) return null;
    return try accountKeyForSelectableAlloc(allocator, rows, reg, 0);
}

fn removeOwnedAccountKey(
    allocator: std.mem.Allocator,
    keys: *std.ArrayList([]u8),
    account_key: []const u8,
) bool {
    for (keys.items, 0..) |key, idx| {
        if (!std.mem.eql(u8, key, account_key)) continue;
        allocator.free(key);
        _ = keys.orderedRemove(idx);
        return true;
    }
    return false;
}

fn containsOwnedAccountKey(keys: *const std.ArrayList([]u8), account_key: []const u8) bool {
    for (keys.items) |key| {
        if (std.mem.eql(u8, key, account_key)) return true;
    }
    return false;
}

fn toggleOwnedAccountKey(
    allocator: std.mem.Allocator,
    keys: *std.ArrayList([]u8),
    account_key: []const u8,
) !void {
    if (removeOwnedAccountKey(allocator, keys, account_key)) return;
    try keys.append(allocator, try allocator.dupe(u8, account_key));
}

fn clearOwnedAccountKeys(allocator: std.mem.Allocator, keys: *std.ArrayList([]u8)) void {
    for (keys.items) |key| allocator.free(key);
    keys.clearRetainingCapacity();
}

fn selectWithNumbers(
    allocator: std.mem.Allocator,
    reg: *registry.Registry,
    usage_overrides: ?[]const ?[]const u8,
) !?[]const u8 {
    var stdout: io_util.Stdout = undefined;
    stdout.init();
    const out = stdout.out();
    if (reg.accounts.items.len == 0) return null;
    var rows = try buildSwitchRowsWithUsageOverrides(allocator, reg, usage_overrides);
    defer rows.deinit(allocator);
    try filterErroredRowsFromSelectableIndices(allocator, &rows);
    const total_accounts = accountRowCount(rows.items);
    if (total_accounts == 0) return null;
    const use_color = colorEnabled();
    const active_idx = activeSelectableIndex(&rows);
    const idx_width = @max(@as(usize, 2), indexWidth(total_accounts));
    const widths = rows.widths;
    const active_display_idx = if (active_idx) |idx| displayedIndexForSelectable(&rows, idx) else null;

    try out.writeAll("Select account to activate:\n\n");
    try renderSwitchList(out, reg, rows.items, idx_width, widths, active_display_idx, use_color);
    try out.writeAll("Select account number (or q to quit): ");
    try out.flush();

    var buf: [64]u8 = undefined;
    const n = try readFileOnce(std.Io.File.stdin(), &buf);
    const line = std.mem.trim(u8, buf[0..n], " \n\r\t");
    if (line.len == 0) {
        if (active_idx) |i| return accountIdForSelectable(&rows, reg, i);
        return null;
    }
    if (isQuitInput(line)) return null;
    const displayed_idx = parsedDisplayedIndex(line, total_accounts) orelse return null;
    return accountIdForDisplayedAccount(&rows, reg, displayed_idx);
}

fn selectWithNumbersFromIndices(
    allocator: std.mem.Allocator,
    reg: *registry.Registry,
    indices: []const usize,
    usage_overrides: ?[]const ?[]const u8,
) !?[]const u8 {
    var stdout: io_util.Stdout = undefined;
    stdout.init();
    const out = stdout.out();
    if (indices.len == 0) return null;

    var rows = try buildSwitchRowsFromIndicesWithUsageOverrides(allocator, reg, indices, usage_overrides);
    defer rows.deinit(allocator);
    try filterErroredRowsFromSelectableIndices(allocator, &rows);
    const total_accounts = accountRowCount(rows.items);
    if (total_accounts == 0) return null;
    const use_color = colorEnabled();
    const active_idx = activeSelectableIndex(&rows);
    const idx_width = @max(@as(usize, 2), indexWidth(total_accounts));
    const widths = rows.widths;
    const active_display_idx = if (active_idx) |idx| displayedIndexForSelectable(&rows, idx) else null;

    try out.writeAll("Select account to activate:\n\n");
    try renderSwitchList(out, reg, rows.items, idx_width, widths, active_display_idx, use_color);
    try out.writeAll("Select account number (or q to quit): ");
    try out.flush();

    var buf: [64]u8 = undefined;
    const n = try readFileOnce(std.Io.File.stdin(), &buf);
    const line = std.mem.trim(u8, buf[0..n], " \n\r\t");
    if (line.len == 0) {
        if (active_idx) |i| return accountIdForSelectable(&rows, reg, i);
        return null;
    }
    if (isQuitInput(line)) return null;
    const displayed_idx = parsedDisplayedIndex(line, total_accounts) orelse return null;
    return accountIdForDisplayedAccount(&rows, reg, displayed_idx);
}

fn selectInteractiveFromIndices(
    allocator: std.mem.Allocator,
    reg: *registry.Registry,
    indices: []const usize,
    usage_overrides: ?[]const ?[]const u8,
) !?[]const u8 {
    if (indices.len == 0) return null;
    var rows = try buildSwitchRowsFromIndicesWithUsageOverrides(allocator, reg, indices, usage_overrides);
    defer rows.deinit(allocator);
    try filterErroredRowsFromSelectableIndices(allocator, &rows);
    const total_accounts = accountRowCount(rows.items);
    if (total_accounts == 0) return null;

    var tui = try TuiSession.init();
    defer tui.deinit();
    const out = tui.out();
    const active_idx = activeSelectableIndex(&rows);
    var idx: usize = active_idx orelse 0;
    var number_buf: [8]u8 = undefined;
    var number_len: usize = 0;
    const use_color = terminal_color.fileColorEnabled(tui.output);
    const idx_width = @max(@as(usize, 2), indexWidth(total_accounts));
    const widths = rows.widths;

    while (true) {
        const selected_display_idx = selectedDisplayIndexForRender(
            &rows,
            if (rows.selectable_row_indices.len != 0) idx else null,
            number_buf[0..number_len],
        );
        try tui.resetFrame();
        try renderSwitchScreen(
            out,
            reg,
            rows.items,
            idx_width,
            widths,
            selected_display_idx,
            use_color,
            "",
            "",
            number_buf[0..number_len],
        );
        try out.flush();

        if (comptime builtin.os.tag == .windows) {
            switch (try tui.readWindowsKey()) {
                .move_up => {
                    if (rows.selectable_row_indices.len != 0 and idx > 0) {
                        idx -= 1;
                        number_len = 0;
                    }
                },
                .move_down => {
                    if (rows.selectable_row_indices.len != 0 and idx + 1 < rows.selectable_row_indices.len) {
                        idx += 1;
                        number_len = 0;
                    }
                },
                .enter => {
                    if (parsedDisplayedIndex(number_buf[0..number_len], total_accounts)) |displayed_idx| {
                        return accountIdForDisplayedAccount(&rows, reg, displayed_idx);
                    }
                    if (rows.selectable_row_indices.len == 0) return null;
                    return accountIdForSelectable(&rows, reg, idx);
                },
                .quit => return null,
                .backspace => {
                    if (number_len > 0) {
                        number_len -= 1;
                        if (parsedDisplayedIndex(number_buf[0..number_len], total_accounts)) |displayed_idx| {
                            if (selectableIndexForDisplayedAccount(&rows, displayed_idx)) |selectable_idx| {
                                idx = selectable_idx;
                            }
                        }
                    }
                },
                .redraw => continue,
                .byte => |ch| {
                    if (isQuitKey(ch)) return null;
                    if (ch == 'k' and rows.selectable_row_indices.len != 0 and idx > 0) {
                        idx -= 1;
                        number_len = 0;
                        continue;
                    }
                    if (ch == 'j' and rows.selectable_row_indices.len != 0 and idx + 1 < rows.selectable_row_indices.len) {
                        idx += 1;
                        number_len = 0;
                        continue;
                    }
                    if (ch >= '0' and ch <= '9' and number_len < number_buf.len) {
                        number_buf[number_len] = ch;
                        number_len += 1;
                        if (parsedDisplayedIndex(number_buf[0..number_len], total_accounts)) |displayed_idx| {
                            if (selectableIndexForDisplayedAccount(&rows, displayed_idx)) |selectable_idx| {
                                idx = selectable_idx;
                            }
                        }
                    }
                },
            }
            continue;
        }

        var b: [8]u8 = undefined;
        const n = try tui.read(&b);
        var i: usize = 0;
        while (i < n) : (i += 1) {
            if (b[i] == 0x1b) {
                const escape = try readTuiEscapeAction(
                    tui.input,
                    b[i + 1 .. n],
                    tui_poll_error_mask,
                    tui_escape_sequence_timeout_ms,
                );
                switch (escape.action) {
                    .move_up => {
                        if (rows.selectable_row_indices.len != 0 and idx > 0) {
                            idx -= 1;
                            number_len = 0;
                        }
                    },
                    .move_down => {
                        if (rows.selectable_row_indices.len != 0 and idx + 1 < rows.selectable_row_indices.len) {
                            idx += 1;
                            number_len = 0;
                        }
                    },
                    .quit => return null,
                    .ignore => {},
                }
                i += escape.buffered_bytes_consumed;
                continue;
            }

            if (b[i] == '\r' or b[i] == '\n') {
                if (parsedDisplayedIndex(number_buf[0..number_len], total_accounts)) |displayed_idx| {
                    return accountIdForDisplayedAccount(&rows, reg, displayed_idx);
                }
                if (rows.selectable_row_indices.len == 0) return null;
                return accountIdForSelectable(&rows, reg, idx);
            }
            if (isQuitKey(b[i])) return null;

            if (b[i] == 'k' and rows.selectable_row_indices.len != 0 and idx > 0) {
                idx -= 1;
                number_len = 0;
                continue;
            }
            if (b[i] == 'j' and rows.selectable_row_indices.len != 0 and idx + 1 < rows.selectable_row_indices.len) {
                idx += 1;
                number_len = 0;
                continue;
            }
            if (b[i] == 0x7f or b[i] == 0x08) {
                if (number_len > 0) {
                    number_len -= 1;
                    if (parsedDisplayedIndex(number_buf[0..number_len], total_accounts)) |displayed_idx| {
                        if (selectableIndexForDisplayedAccount(&rows, displayed_idx)) |selectable_idx| {
                            idx = selectable_idx;
                        }
                    }
                }
                continue;
            }
            if (b[i] >= '0' and b[i] <= '9') {
                if (number_len < number_buf.len) {
                    number_buf[number_len] = b[i];
                    number_len += 1;
                    if (parsedDisplayedIndex(number_buf[0..number_len], total_accounts)) |displayed_idx| {
                        if (selectableIndexForDisplayedAccount(&rows, displayed_idx)) |selectable_idx| {
                            idx = selectable_idx;
                        }
                    }
                }
                continue;
            }
        }
    }
}

fn selectRemoveWithNumbers(
    allocator: std.mem.Allocator,
    reg: *registry.Registry,
    usage_overrides: ?[]const ?[]const u8,
) !?[]usize {
    var stdout: io_util.Stdout = undefined;
    stdout.init();
    const out = stdout.out();
    if (reg.accounts.items.len == 0) return null;
    var rows = try buildSwitchRowsWithUsageOverrides(allocator, reg, usage_overrides);
    defer rows.deinit(allocator);
    const use_color = colorEnabled();
    const idx_width = @max(@as(usize, 2), indexWidth(rows.selectable_row_indices.len));
    const widths = rows.widths;

    var checked = try allocator.alloc(bool, rows.selectable_row_indices.len);
    defer allocator.free(checked);
    @memset(checked, false);

    try out.writeAll("Select accounts to delete:\n\n");
    try renderRemoveList(out, reg, rows.items, idx_width, widths, null, checked, use_color);
    try out.writeAll("Enter account numbers (comma/space separated, empty to cancel): ");
    try out.flush();

    var buf: [256]u8 = undefined;
    const n = try readFileOnce(std.Io.File.stdin(), &buf);
    const line = std.mem.trim(u8, buf[0..n], " \n\r\t");
    if (line.len == 0) return null;
    if (!isStrictRemoveSelectionLine(line)) return error.InvalidRemoveSelectionInput;

    var current: usize = 0;
    var in_number = false;
    for (line) |ch| {
        if (ch >= '0' and ch <= '9') {
            current = current * 10 + @as(usize, ch - '0');
            in_number = true;
            continue;
        }
        if (in_number) {
            if (current >= 1 and current <= rows.selectable_row_indices.len) {
                checked[current - 1] = true;
            }
            current = 0;
            in_number = false;
        }
    }
    if (in_number and current >= 1 and current <= rows.selectable_row_indices.len) {
        checked[current - 1] = true;
    }

    var count: usize = 0;
    for (checked) |flag| {
        if (flag) count += 1;
    }
    if (count == 0) return null;
    var selected = try allocator.alloc(usize, count);
    var idx: usize = 0;
    for (checked, 0..) |flag, i| {
        if (!flag) continue;
        selected[idx] = accountIndexForSelectable(&rows, i);
        idx += 1;
    }
    return selected;
}

fn isStrictRemoveSelectionLine(line: []const u8) bool {
    for (line) |ch| {
        if ((ch >= '0' and ch <= '9') or ch == ',' or ch == ' ' or ch == '\t') continue;
        return false;
    }
    return true;
}

fn selectInteractive(
    allocator: std.mem.Allocator,
    reg: *registry.Registry,
    usage_overrides: ?[]const ?[]const u8,
) !?[]const u8 {
    if (reg.accounts.items.len == 0) return null;
    var rows = try buildSwitchRowsWithUsageOverrides(allocator, reg, usage_overrides);
    defer rows.deinit(allocator);
    try filterErroredRowsFromSelectableIndices(allocator, &rows);
    const total_accounts = accountRowCount(rows.items);
    if (total_accounts == 0) return null;

    var tui = try TuiSession.init();
    defer tui.deinit();
    const out = tui.out();
    const active_idx = activeSelectableIndex(&rows);
    var idx: usize = active_idx orelse 0;
    var number_buf: [8]u8 = undefined;
    var number_len: usize = 0;
    const use_color = terminal_color.fileColorEnabled(tui.output);
    const idx_width = @max(@as(usize, 2), indexWidth(total_accounts));
    const widths = rows.widths;

    while (true) {
        const selected_display_idx = selectedDisplayIndexForRender(
            &rows,
            if (rows.selectable_row_indices.len != 0) idx else null,
            number_buf[0..number_len],
        );
        try tui.resetFrame();
        try renderSwitchScreen(
            out,
            reg,
            rows.items,
            idx_width,
            widths,
            selected_display_idx,
            use_color,
            "",
            "",
            number_buf[0..number_len],
        );
        try out.flush();

        if (comptime builtin.os.tag == .windows) {
            switch (try tui.readWindowsKey()) {
                .move_up => {
                    if (rows.selectable_row_indices.len != 0 and idx > 0) {
                        idx -= 1;
                        number_len = 0;
                    }
                },
                .move_down => {
                    if (rows.selectable_row_indices.len != 0 and idx + 1 < rows.selectable_row_indices.len) {
                        idx += 1;
                        number_len = 0;
                    }
                },
                .enter => {
                    if (parsedDisplayedIndex(number_buf[0..number_len], total_accounts)) |displayed_idx| {
                        return accountIdForDisplayedAccount(&rows, reg, displayed_idx);
                    }
                    if (rows.selectable_row_indices.len == 0) return null;
                    return accountIdForSelectable(&rows, reg, idx);
                },
                .quit => return null,
                .backspace => {
                    if (number_len > 0) {
                        number_len -= 1;
                        if (parsedDisplayedIndex(number_buf[0..number_len], total_accounts)) |displayed_idx| {
                            if (selectableIndexForDisplayedAccount(&rows, displayed_idx)) |selectable_idx| {
                                idx = selectable_idx;
                            }
                        }
                    }
                },
                .redraw => continue,
                .byte => |ch| {
                    if (isQuitKey(ch)) return null;
                    if (ch == 'k' and rows.selectable_row_indices.len != 0 and idx > 0) {
                        idx -= 1;
                        number_len = 0;
                        continue;
                    }
                    if (ch == 'j' and rows.selectable_row_indices.len != 0 and idx + 1 < rows.selectable_row_indices.len) {
                        idx += 1;
                        number_len = 0;
                        continue;
                    }
                    if (ch >= '0' and ch <= '9' and number_len < number_buf.len) {
                        number_buf[number_len] = ch;
                        number_len += 1;
                        if (parsedDisplayedIndex(number_buf[0..number_len], total_accounts)) |displayed_idx| {
                            if (selectableIndexForDisplayedAccount(&rows, displayed_idx)) |selectable_idx| {
                                idx = selectable_idx;
                            }
                        }
                    }
                },
            }
            continue;
        }

        var b: [8]u8 = undefined;
        const n = try tui.read(&b);
        var i: usize = 0;
        while (i < n) : (i += 1) {
            if (b[i] == 0x1b) {
                const escape = try readTuiEscapeAction(
                    tui.input,
                    b[i + 1 .. n],
                    tui_poll_error_mask,
                    tui_escape_sequence_timeout_ms,
                );
                switch (escape.action) {
                    .move_up => {
                        if (rows.selectable_row_indices.len != 0 and idx > 0) {
                            idx -= 1;
                            number_len = 0;
                        }
                    },
                    .move_down => {
                        if (rows.selectable_row_indices.len != 0 and idx + 1 < rows.selectable_row_indices.len) {
                            idx += 1;
                            number_len = 0;
                        }
                    },
                    .quit => return null,
                    .ignore => {},
                }
                i += escape.buffered_bytes_consumed;
                continue;
            }

            if (b[i] == '\r' or b[i] == '\n') {
                if (parsedDisplayedIndex(number_buf[0..number_len], total_accounts)) |displayed_idx| {
                    return accountIdForDisplayedAccount(&rows, reg, displayed_idx);
                }
                if (rows.selectable_row_indices.len == 0) return null;
                return accountIdForSelectable(&rows, reg, idx);
            }
            if (isQuitKey(b[i])) return null;
            if (b[i] == 'k' and rows.selectable_row_indices.len != 0 and idx > 0) {
                idx -= 1;
                number_len = 0;
                continue;
            }
            if (b[i] == 'j' and rows.selectable_row_indices.len != 0 and idx + 1 < rows.selectable_row_indices.len) {
                idx += 1;
                number_len = 0;
                continue;
            }
            if (b[i] == 0x7f or b[i] == 0x08) {
                if (number_len > 0) {
                    number_len -= 1;
                    if (parsedDisplayedIndex(number_buf[0..number_len], total_accounts)) |displayed_idx| {
                        if (selectableIndexForDisplayedAccount(&rows, displayed_idx)) |selectable_idx| {
                            idx = selectable_idx;
                        }
                    }
                }
                continue;
            }
            if (b[i] >= '0' and b[i] <= '9') {
                if (number_len < number_buf.len) {
                    number_buf[number_len] = b[i];
                    number_len += 1;
                    if (parsedDisplayedIndex(number_buf[0..number_len], total_accounts)) |displayed_idx| {
                        if (selectableIndexForDisplayedAccount(&rows, displayed_idx)) |selectable_idx| {
                            idx = selectable_idx;
                        }
                    }
                }
                continue;
            }
        }
    }
}

fn selectRemoveInteractive(
    allocator: std.mem.Allocator,
    reg: *registry.Registry,
    usage_overrides: ?[]const ?[]const u8,
) !?[]usize {
    if (reg.accounts.items.len == 0) return null;
    var rows = try buildSwitchRowsWithUsageOverrides(allocator, reg, usage_overrides);
    defer rows.deinit(allocator);

    var checked = try allocator.alloc(bool, rows.selectable_row_indices.len);
    defer allocator.free(checked);
    @memset(checked, false);

    var tui = try TuiSession.init();
    defer tui.deinit();
    const out = tui.out();
    var idx: usize = 0;
    var number_buf: [8]u8 = undefined;
    var number_len: usize = 0;
    const use_color = terminal_color.fileColorEnabled(tui.output);
    const idx_width = @max(@as(usize, 2), indexWidth(rows.selectable_row_indices.len));
    const widths = rows.widths;

    while (true) {
        try tui.resetFrame();
        try writeTuiPromptLine(out, "Select accounts to delete:", number_buf[0..number_len]);
        try out.writeAll("\n");
        try renderRemoveList(out, reg, rows.items, idx_width, widths, idx, checked, use_color);
        try out.writeAll("\n");
        try writeRemoveTuiFooter(out, use_color);
        try out.flush();

        if (comptime builtin.os.tag == .windows) {
            switch (try tui.readWindowsKey()) {
                .move_up => {
                    if (idx > 0) {
                        idx -= 1;
                        number_len = 0;
                    }
                },
                .move_down => {
                    if (idx + 1 < rows.selectable_row_indices.len) {
                        idx += 1;
                        number_len = 0;
                    }
                },
                .enter => {
                    var count: usize = 0;
                    for (checked) |flag| {
                        if (flag) count += 1;
                    }
                    if (count == 0) return null;
                    var selected = try allocator.alloc(usize, count);
                    var out_idx: usize = 0;
                    for (checked, 0..) |flag, sel_idx| {
                        if (!flag) continue;
                        selected[out_idx] = accountIndexForSelectable(&rows, sel_idx);
                        out_idx += 1;
                    }
                    return selected;
                },
                .quit => return null,
                .backspace => {
                    if (number_len > 0) {
                        number_len -= 1;
                        if (number_len > 0) {
                            const parsed = std.fmt.parseInt(usize, number_buf[0..number_len], 10) catch 0;
                            if (parsed >= 1 and parsed <= rows.selectable_row_indices.len) {
                                idx = parsed - 1;
                            }
                        }
                    }
                },
                .redraw => continue,
                .byte => |ch| {
                    if (isQuitKey(ch)) return null;
                    if (ch == 'k' and idx > 0) {
                        idx -= 1;
                        number_len = 0;
                        continue;
                    }
                    if (ch == 'j' and idx + 1 < rows.selectable_row_indices.len) {
                        idx += 1;
                        number_len = 0;
                        continue;
                    }
                    if (ch == ' ') {
                        checked[idx] = !checked[idx];
                        number_len = 0;
                        continue;
                    }
                    if (ch >= '0' and ch <= '9' and number_len < number_buf.len) {
                        number_buf[number_len] = ch;
                        number_len += 1;
                        const parsed = std.fmt.parseInt(usize, number_buf[0..number_len], 10) catch 0;
                        if (parsed >= 1 and parsed <= rows.selectable_row_indices.len) {
                            idx = parsed - 1;
                        }
                    }
                },
            }
            continue;
        }

        var b: [8]u8 = undefined;
        const n = try tui.read(&b);
        var i: usize = 0;
        while (i < n) : (i += 1) {
            if (b[i] == 0x1b) {
                const escape = try readTuiEscapeAction(
                    tui.input,
                    b[i + 1 .. n],
                    tui_poll_error_mask,
                    tui_escape_sequence_timeout_ms,
                );
                switch (escape.action) {
                    .move_up => {
                        if (idx > 0) {
                            idx -= 1;
                            number_len = 0;
                        }
                    },
                    .move_down => {
                        if (idx + 1 < rows.selectable_row_indices.len) {
                            idx += 1;
                            number_len = 0;
                        }
                    },
                    .quit => return null,
                    .ignore => {},
                }
                i += escape.buffered_bytes_consumed;
                continue;
            }

            if (b[i] == '\r' or b[i] == '\n') {
                var count: usize = 0;
                for (checked) |flag| {
                    if (flag) count += 1;
                }
                if (count == 0) return null;
                var selected = try allocator.alloc(usize, count);
                var out_idx: usize = 0;
                for (checked, 0..) |flag, sel_idx| {
                    if (!flag) continue;
                    selected[out_idx] = accountIndexForSelectable(&rows, sel_idx);
                    out_idx += 1;
                }
                return selected;
            }
            if (isQuitKey(b[i])) return null;
            if (b[i] == 'k' and idx > 0) {
                idx -= 1;
                number_len = 0;
                continue;
            }
            if (b[i] == 'j' and idx + 1 < rows.selectable_row_indices.len) {
                idx += 1;
                number_len = 0;
                continue;
            }
            if (b[i] == ' ') {
                checked[idx] = !checked[idx];
                number_len = 0;
                continue;
            }
            if (b[i] == 0x7f or b[i] == 0x08) {
                if (number_len > 0) {
                    number_len -= 1;
                    if (number_len > 0) {
                        const parsed = std.fmt.parseInt(usize, number_buf[0..number_len], 10) catch 0;
                        if (parsed >= 1 and parsed <= rows.selectable_row_indices.len) {
                            idx = parsed - 1;
                        }
                    }
                }
                continue;
            }
            if (b[i] >= '0' and b[i] <= '9') {
                if (number_len < number_buf.len) {
                    number_buf[number_len] = b[i];
                    number_len += 1;
                    const parsed = std.fmt.parseInt(usize, number_buf[0..number_len], 10) catch 0;
                    if (parsed >= 1 and parsed <= rows.selectable_row_indices.len) {
                        idx = parsed - 1;
                    }
                }
                continue;
            }
        }
    }
}

fn renderSwitchScreen(
    out: *std.Io.Writer,
    reg: *registry.Registry,
    rows: []const SwitchRow,
    idx_width: usize,
    widths: SwitchWidths,
    selected: ?usize,
    use_color: bool,
    status_line: []const u8,
    action_line: []const u8,
    number_input: []const u8,
) !void {
    try writeTuiPromptLine(out, "Select account to activate:", number_input);
    try out.writeAll("\n");
    try renderSwitchList(out, reg, rows, idx_width, widths, selected, use_color);
    try out.writeAll("\n");
    if (status_line.len != 0) {
        if (use_color) try out.writeAll(ansi.dim);
        try out.writeAll(status_line);
        try out.writeAll("\n");
        if (use_color) try out.writeAll(ansi.reset);
    }
    try writeSwitchTuiFooter(out, use_color);
    if (action_line.len != 0) {
        if (use_color) try out.writeAll(ansi.bold_green);
        try out.writeAll(action_line);
        try out.writeAll("\n");
        if (use_color) try out.writeAll(ansi.reset);
    }
}

fn renderListScreen(
    out: *std.Io.Writer,
    reg: *registry.Registry,
    rows: []const SwitchRow,
    idx_width: usize,
    widths: SwitchWidths,
    use_color: bool,
    status_line: []const u8,
) !void {
    try out.writeAll("Live account list:\n\n");
    try renderSwitchList(out, reg, rows, idx_width, widths, null, use_color);
    try out.writeAll("\n");
    if (status_line.len != 0) {
        if (use_color) try out.writeAll(ansi.dim);
        try out.writeAll(status_line);
        try out.writeAll("\n");
        if (use_color) try out.writeAll(ansi.reset);
    }
    try writeListTuiFooter(out, use_color);
}

fn renderRemoveScreen(
    out: *std.Io.Writer,
    reg: *registry.Registry,
    rows: []const SwitchRow,
    idx_width: usize,
    widths: SwitchWidths,
    cursor: ?usize,
    checked: []const bool,
    use_color: bool,
    status_line: []const u8,
    action_line: []const u8,
    number_input: []const u8,
) !void {
    try writeTuiPromptLine(out, "Select accounts to delete:", number_input);
    try out.writeAll("\n");
    try renderRemoveList(out, reg, rows, idx_width, widths, cursor, checked, use_color);
    try out.writeAll("\n");
    if (status_line.len != 0) {
        if (use_color) try out.writeAll(ansi.dim);
        try out.writeAll(status_line);
        try out.writeAll("\n");
        if (use_color) try out.writeAll(ansi.reset);
    }
    try writeRemoveTuiFooter(out, use_color);
    if (action_line.len != 0) {
        if (use_color) try out.writeAll(ansi.bold_green);
        try out.writeAll(action_line);
        try out.writeAll("\n");
        if (use_color) try out.writeAll(ansi.reset);
    }
}

fn renderSwitchList(
    out: *std.Io.Writer,
    reg: *registry.Registry,
    rows: []const SwitchRow,
    idx_width: usize,
    widths: SwitchWidths,
    selected: ?usize,
    use_color: bool,
) !void {
    _ = reg;
    const prefix = 2 + idx_width + 1;
    var pad: usize = 0;
    while (pad < prefix) : (pad += 1) {
        try out.writeAll(" ");
    }
    try writePadded(out, "ACCOUNT", widths.email);
    try out.writeAll("  ");
    try writePadded(out, "PLAN", widths.plan);
    try out.writeAll("  ");
    try writePadded(out, "5H", widths.rate_5h);
    try out.writeAll("  ");
    try writePadded(out, "WEEKLY", widths.rate_week);
    try out.writeAll("  ");
    try writePadded(out, "LAST", widths.last);
    try out.writeAll("\n");

    var displayed_counter: usize = 0;
    for (rows) |row| {
        if (row.is_header) {
            if (use_color) try out.writeAll(ansi.dim);
            try out.writeAll("  ");
            var pad_header: usize = 0;
            while (pad_header < idx_width + 1) : (pad_header += 1) {
                try out.writeAll(" ");
            }
            try writeTruncatedPadded(out, row.account, widths.email);
            try out.writeAll("\n");
            if (use_color) try out.writeAll(ansi.reset);
            continue;
        }

        const is_selected = selected != null and selected.? == displayed_counter;
        const is_active = row.is_active;
        if (use_color) {
            if (row.has_error) {
                if (is_selected or is_active) {
                    try out.writeAll(ansi.bold_red);
                } else {
                    try out.writeAll(ansi.red);
                }
            } else if (is_selected) {
                try out.writeAll(ansi.bold_green);
            } else if (is_active) {
                try out.writeAll(ansi.green);
            } else {
                try out.writeAll(ansi.dim);
            }
        }
        try out.writeAll(activeRowMarker(is_selected, is_active));
        try writeIndexPadded(out, displayed_counter + 1, idx_width);
        try out.writeAll(" ");
        const indent: usize = @as(usize, row.depth) * 2;
        const indent_to_print: usize = @min(indent, widths.email);
        try writeRepeat(out, ' ', indent_to_print);
        try writeTruncatedPadded(out, row.account, widths.email - indent_to_print);
        try out.writeAll("  ");
        try writeTruncatedPadded(out, row.plan, widths.plan);
        try out.writeAll("  ");
        try writeTruncatedPadded(out, row.rate_5h, widths.rate_5h);
        try out.writeAll("  ");
        try writeTruncatedPadded(out, row.rate_week, widths.rate_week);
        try out.writeAll("  ");
        try writeTruncatedPadded(out, row.last, widths.last);
        try out.writeAll("\n");
        if (use_color) try out.writeAll(ansi.reset);
        displayed_counter += 1;
    }
}

fn renderRemoveList(
    out: *std.Io.Writer,
    reg: *registry.Registry,
    rows: []const SwitchRow,
    idx_width: usize,
    widths: SwitchWidths,
    cursor: ?usize,
    checked: []const bool,
    use_color: bool,
) !void {
    _ = reg;
    const checkbox_width: usize = 3;
    const prefix = 2 + checkbox_width + 1 + idx_width + 1;
    var pad: usize = 0;
    while (pad < prefix) : (pad += 1) {
        try out.writeAll(" ");
    }
    try writePadded(out, "ACCOUNT", widths.email);
    try out.writeAll("  ");
    try writePadded(out, "PLAN", widths.plan);
    try out.writeAll("  ");
    try writePadded(out, "5H", widths.rate_5h);
    try out.writeAll("  ");
    try writePadded(out, "WEEKLY", widths.rate_week);
    try out.writeAll("  ");
    try writePadded(out, "LAST", widths.last);
    try out.writeAll("\n");

    var selectable_counter: usize = 0;
    for (rows) |row| {
        if (row.is_header) {
            if (use_color) try out.writeAll(ansi.dim);
            try out.writeAll("  ");
            var pad_header: usize = 0;
            while (pad_header < checkbox_width + 1 + idx_width + 1) : (pad_header += 1) {
                try out.writeAll(" ");
            }
            try writeTruncatedPadded(out, row.account, widths.email);
            try out.writeAll("\n");
            if (use_color) try out.writeAll(ansi.reset);
            continue;
        }

        const is_cursor = cursor != null and cursor.? == selectable_counter;
        const is_checked = checked[selectable_counter];
        const is_active = row.is_active;
        if (use_color) {
            if (row.has_error) {
                if (is_cursor or is_checked or is_active) {
                    try out.writeAll(ansi.bold_red);
                } else {
                    try out.writeAll(ansi.red);
                }
            } else if (is_cursor) {
                try out.writeAll(ansi.bold_green);
            } else if (is_checked or is_active) {
                try out.writeAll(ansi.green);
            } else {
                try out.writeAll(ansi.dim);
            }
        }
        try out.writeAll(activeRowMarker(is_cursor, is_active));
        try out.writeAll(if (is_checked) "[x]" else "[ ]");
        try out.writeAll(" ");
        try writeIndexPadded(out, selectable_counter + 1, idx_width);
        try out.writeAll(" ");
        const indent: usize = @as(usize, row.depth) * 2;
        const indent_to_print: usize = @min(indent, widths.email);
        try writeRepeat(out, ' ', indent_to_print);
        try writeTruncatedPadded(out, row.account, widths.email - indent_to_print);
        try out.writeAll("  ");
        try writeTruncatedPadded(out, row.plan, widths.plan);
        try out.writeAll("  ");
        try writeTruncatedPadded(out, row.rate_5h, widths.rate_5h);
        try out.writeAll("  ");
        try writeTruncatedPadded(out, row.rate_week, widths.rate_week);
        try out.writeAll("  ");
        try writeTruncatedPadded(out, row.last, widths.last);
        try out.writeAll("\n");
        if (use_color) try out.writeAll(ansi.reset);
        selectable_counter += 1;
    }
}

fn writeIndexPadded(out: *std.Io.Writer, idx: usize, width: usize) !void {
    var buf: [16]u8 = undefined;
    const idx_str = std.fmt.bufPrint(&buf, "{d}", .{idx}) catch "0";
    if (idx_str.len < width) {
        var pad: usize = width - idx_str.len;
        while (pad > 0) : (pad -= 1) {
            try out.writeAll("0");
        }
    }
    try out.writeAll(idx_str);
}

fn writePadded(out: *std.Io.Writer, value: []const u8, width: usize) !void {
    try out.writeAll(value);
    if (value.len >= width) return;
    var i: usize = 0;
    const pad = width - value.len;
    while (i < pad) : (i += 1) {
        try out.writeAll(" ");
    }
}

fn writeTruncatedPadded(out: *std.Io.Writer, value: []const u8, width: usize) !void {
    if (width == 0) return;
    if (value.len <= width) {
        try writePadded(out, value, width);
        return;
    }
    if (width == 1) {
        try out.writeAll(".");
        return;
    }
    try out.writeAll(value[0 .. width - 1]);
    try out.writeAll(".");
}

fn writeRepeat(out: *std.Io.Writer, ch: u8, count: usize) !void {
    var i: usize = 0;
    while (i < count) : (i += 1) {
        try out.writeByte(ch);
    }
}

const SwitchWidths = struct {
    email: usize,
    plan: usize,
    rate_5h: usize,
    rate_week: usize,
    last: usize,
};

const SwitchRow = struct {
    account_index: ?usize,
    account: []u8,
    plan: []const u8,
    rate_5h: []u8,
    rate_week: []u8,
    last: []u8,
    depth: u8,
    is_active: bool,
    has_error: bool,
    is_header: bool,

    fn deinit(self: *SwitchRow, allocator: std.mem.Allocator) void {
        allocator.free(self.account);
        allocator.free(self.rate_5h);
        allocator.free(self.rate_week);
        allocator.free(self.last);
    }
};

const SwitchRows = struct {
    items: []SwitchRow,
    selectable_row_indices: []usize,
    widths: SwitchWidths,

    fn deinit(self: *SwitchRows, allocator: std.mem.Allocator) void {
        for (self.items) |*row| row.deinit(allocator);
        allocator.free(self.items);
        allocator.free(self.selectable_row_indices);
    }
};

fn filterErroredRowsFromSelectableIndices(allocator: std.mem.Allocator, rows: *SwitchRows) !void {
    var selectable_count: usize = 0;
    for (rows.selectable_row_indices) |row_idx| {
        if (!rows.items[row_idx].has_error) selectable_count += 1;
    }

    const filtered = try allocator.alloc(usize, selectable_count);
    var next_idx: usize = 0;
    for (rows.selectable_row_indices) |row_idx| {
        if (rows.items[row_idx].has_error) continue;
        filtered[next_idx] = row_idx;
        next_idx += 1;
    }

    allocator.free(rows.selectable_row_indices);
    rows.selectable_row_indices = filtered;
}

fn usageOverrideForAccount(
    usage_overrides: ?[]const ?[]const u8,
    account_idx: usize,
) ?[]const u8 {
    const overrides = usage_overrides orelse return null;
    if (account_idx >= overrides.len) return null;
    return overrides[account_idx];
}

fn usageCellTextAlloc(
    allocator: std.mem.Allocator,
    window: ?registry.RateLimitWindow,
    usage_override: ?[]const u8,
) ![]u8 {
    if (usage_override) |value| return allocator.dupe(u8, value);
    return formatRateLimitSwitchAlloc(allocator, window);
}

fn buildSwitchRows(allocator: std.mem.Allocator, reg: *registry.Registry) !SwitchRows {
    return buildSwitchRowsWithUsageOverrides(allocator, reg, null);
}

fn buildSwitchRowsWithUsageOverrides(
    allocator: std.mem.Allocator,
    reg: *registry.Registry,
    usage_overrides: ?[]const ?[]const u8,
) !SwitchRows {
    var display = try display_rows.buildDisplayRows(allocator, reg, null);
    defer display.deinit(allocator);
    var rows = try allocator.alloc(SwitchRow, display.rows.len);
    var widths = SwitchWidths{
        .email = "EMAIL".len,
        .plan = "PLAN".len,
        .rate_5h = "5H".len,
        .rate_week = "WEEKLY".len,
        .last = "LAST".len,
    };
    const now = std.Io.Timestamp.now(app_runtime.io(), .real).toSeconds();
    for (display.rows, 0..) |display_row, i| {
        if (display_row.account_index) |account_idx| {
            const rec = reg.accounts.items[account_idx];
            const plan = if (registry.resolveDisplayPlan(&rec)) |p| registry.planLabel(p) else "-";
            const rate_5h = resolveRateWindow(rec.last_usage, 300, true);
            const rate_week = resolveRateWindow(rec.last_usage, 10080, false);
            const usage_override = usageOverrideForAccount(usage_overrides, account_idx);
            const rate_5h_str = try usageCellTextAlloc(allocator, rate_5h, usage_override);
            const rate_week_str = try usageCellTextAlloc(allocator, rate_week, usage_override);
            const last = try timefmt.formatRelativeTimeOrDashAlloc(allocator, rec.last_usage_at, now);
            rows[i] = .{
                .account_index = account_idx,
                .account = try allocator.dupe(u8, display_row.account_cell),
                .plan = plan,
                .rate_5h = rate_5h_str,
                .rate_week = rate_week_str,
                .last = last,
                .depth = display_row.depth,
                .is_active = display_row.is_active,
                .has_error = usage_override != null,
                .is_header = false,
            };
            widths.email = @max(widths.email, display_row.account_cell.len + (@as(usize, display_row.depth) * 2));
            widths.plan = @max(widths.plan, plan.len);
            widths.rate_5h = @max(widths.rate_5h, rate_5h_str.len);
            widths.rate_week = @max(widths.rate_week, rate_week_str.len);
            widths.last = @max(widths.last, last.len);
        } else {
            rows[i] = .{
                .account_index = null,
                .account = try allocator.dupe(u8, display_row.account_cell),
                .plan = "",
                .rate_5h = try allocator.dupe(u8, ""),
                .rate_week = try allocator.dupe(u8, ""),
                .last = try allocator.dupe(u8, ""),
                .depth = display_row.depth,
                .is_active = false,
                .has_error = false,
                .is_header = true,
            };
            widths.email = @max(widths.email, display_row.account_cell.len + (@as(usize, display_row.depth) * 2));
        }
    }
    if (widths.email > 32) widths.email = 32;
    return SwitchRows{
        .items = rows,
        .selectable_row_indices = try allocator.dupe(usize, display.selectable_row_indices),
        .widths = widths,
    };
}

fn buildSwitchRowsFromIndices(
    allocator: std.mem.Allocator,
    reg: *registry.Registry,
    indices: []const usize,
) !SwitchRows {
    return buildSwitchRowsFromIndicesWithUsageOverrides(allocator, reg, indices, null);
}

fn buildSwitchRowsFromIndicesWithUsageOverrides(
    allocator: std.mem.Allocator,
    reg: *registry.Registry,
    indices: []const usize,
    usage_overrides: ?[]const ?[]const u8,
) !SwitchRows {
    var display = try display_rows.buildDisplayRows(allocator, reg, indices);
    defer display.deinit(allocator);
    var rows = try allocator.alloc(SwitchRow, display.rows.len);
    var widths = SwitchWidths{
        .email = "EMAIL".len,
        .plan = "PLAN".len,
        .rate_5h = "5H".len,
        .rate_week = "WEEKLY".len,
        .last = "LAST".len,
    };
    const now = std.Io.Timestamp.now(app_runtime.io(), .real).toSeconds();
    for (display.rows, 0..) |display_row, i| {
        if (display_row.account_index) |account_idx| {
            const rec = reg.accounts.items[account_idx];
            const plan = if (registry.resolveDisplayPlan(&rec)) |p| registry.planLabel(p) else "-";
            const rate_5h = resolveRateWindow(rec.last_usage, 300, true);
            const rate_week = resolveRateWindow(rec.last_usage, 10080, false);
            const usage_override = usageOverrideForAccount(usage_overrides, account_idx);
            const rate_5h_str = try usageCellTextAlloc(allocator, rate_5h, usage_override);
            const rate_week_str = try usageCellTextAlloc(allocator, rate_week, usage_override);
            const last = try timefmt.formatRelativeTimeOrDashAlloc(allocator, rec.last_usage_at, now);
            rows[i] = .{
                .account_index = account_idx,
                .account = try allocator.dupe(u8, display_row.account_cell),
                .plan = plan,
                .rate_5h = rate_5h_str,
                .rate_week = rate_week_str,
                .last = last,
                .depth = display_row.depth,
                .is_active = display_row.is_active,
                .has_error = usage_override != null,
                .is_header = false,
            };
            widths.email = @max(widths.email, display_row.account_cell.len + (@as(usize, display_row.depth) * 2));
            widths.plan = @max(widths.plan, plan.len);
            widths.rate_5h = @max(widths.rate_5h, rate_5h_str.len);
            widths.rate_week = @max(widths.rate_week, rate_week_str.len);
            widths.last = @max(widths.last, last.len);
        } else {
            rows[i] = .{
                .account_index = null,
                .account = try allocator.dupe(u8, display_row.account_cell),
                .plan = "",
                .rate_5h = try allocator.dupe(u8, ""),
                .rate_week = try allocator.dupe(u8, ""),
                .last = try allocator.dupe(u8, ""),
                .depth = display_row.depth,
                .is_active = false,
                .has_error = false,
                .is_header = true,
            };
            widths.email = @max(widths.email, display_row.account_cell.len + (@as(usize, display_row.depth) * 2));
        }
    }
    if (widths.email > 32) widths.email = 32;
    return SwitchRows{
        .items = rows,
        .selectable_row_indices = try allocator.dupe(usize, display.selectable_row_indices),
        .widths = widths,
    };
}

fn resolveRateWindow(usage: ?registry.RateLimitSnapshot, minutes: i64, fallback_primary: bool) ?registry.RateLimitWindow {
    if (usage == null) return null;
    if (usage.?.primary) |p| {
        if (p.window_minutes != null and p.window_minutes.? == minutes) return p;
    }
    if (usage.?.secondary) |s| {
        if (s.window_minutes != null and s.window_minutes.? == minutes) return s;
    }
    return if (fallback_primary) usage.?.primary else usage.?.secondary;
}

fn formatRateLimitSwitchAlloc(allocator: std.mem.Allocator, window: ?registry.RateLimitWindow) ![]u8 {
    if (window == null) return try std.fmt.allocPrint(allocator, "-", .{});
    if (window.?.resets_at == null) return try std.fmt.allocPrint(allocator, "-", .{});
    const now = std.Io.Timestamp.now(app_runtime.io(), .real).toSeconds();
    const reset_at = window.?.resets_at.?;
    if (now >= reset_at) {
        return try std.fmt.allocPrint(allocator, "100%", .{});
    }
    const remaining = remainingPercent(window.?.used_percent);
    var parts = try resetPartsAlloc(allocator, reset_at, now);
    defer parts.deinit(allocator);
    if (parts.same_day) {
        return std.fmt.allocPrint(allocator, "{d}% ({s})", .{ remaining, parts.time });
    }
    return std.fmt.allocPrint(allocator, "{d}% ({s} on {s})", .{ remaining, parts.time, parts.date });
}

const ResetParts = struct {
    time: []u8,
    date: []u8,
    same_day: bool,

    fn deinit(self: *ResetParts, allocator: std.mem.Allocator) void {
        allocator.free(self.time);
        allocator.free(self.date);
    }
};

fn localtimeCompat(ts: i64, out_tm: *c.struct_tm) bool {
    if (comptime builtin.os.tag == .windows) {
        // Bind directly to the exported CRT symbol on Windows.
        if (comptime @hasDecl(c, "_localtime64_s") and @hasDecl(c, "__time64_t")) {
            var t64 = std.math.cast(c.__time64_t, ts) orelse return false;
            return c._localtime64_s(out_tm, &t64) == 0;
        }
        return false;
    }

    var t = std.math.cast(c.time_t, ts) orelse return false;
    if (comptime @hasDecl(c, "localtime_r")) {
        return c.localtime_r(&t, out_tm) != null;
    }

    if (comptime @hasDecl(c, "localtime")) {
        const tm_ptr = c.localtime(&t);
        if (tm_ptr == null) return false;
        out_tm.* = tm_ptr.*;
        return true;
    }

    return false;
}

fn resetPartsAlloc(allocator: std.mem.Allocator, reset_at: i64, now: i64) !ResetParts {
    var tm: c.struct_tm = undefined;
    if (!localtimeCompat(reset_at, &tm)) {
        return ResetParts{
            .time = try std.fmt.allocPrint(allocator, "-", .{}),
            .date = try std.fmt.allocPrint(allocator, "-", .{}),
            .same_day = true,
        };
    }
    var now_tm: c.struct_tm = undefined;
    if (!localtimeCompat(now, &now_tm)) {
        return ResetParts{
            .time = try std.fmt.allocPrint(allocator, "-", .{}),
            .date = try std.fmt.allocPrint(allocator, "-", .{}),
            .same_day = true,
        };
    }

    const same_day = tm.tm_year == now_tm.tm_year and tm.tm_mon == now_tm.tm_mon and tm.tm_mday == now_tm.tm_mday;
    const hour = @as(u32, @intCast(tm.tm_hour));
    const min = @as(u32, @intCast(tm.tm_min));
    const day = @as(u32, @intCast(tm.tm_mday));
    const months = [_][]const u8{
        "Jan",
        "Feb",
        "Mar",
        "Apr",
        "May",
        "Jun",
        "Jul",
        "Aug",
        "Sep",
        "Oct",
        "Nov",
        "Dec",
    };
    const month_idx: usize = if (tm.tm_mon < 0) 0 else @min(@as(usize, @intCast(tm.tm_mon)), months.len - 1);
    return ResetParts{
        .time = try std.fmt.allocPrint(allocator, "{d:0>2}:{d:0>2}", .{ hour, min }),
        .date = try std.fmt.allocPrint(allocator, "{d} {s}", .{ day, months[month_idx] }),
        .same_day = same_day,
    };
}

fn remainingPercent(used: f64) i64 {
    const remaining = 100.0 - used;
    if (remaining <= 0.0) return 0;
    if (remaining >= 100.0) return 100;
    return @as(i64, @intFromFloat(remaining));
}

fn indexWidth(count: usize) usize {
    var n = count;
    var width: usize = 1;
    while (n >= 10) : (n /= 10) {
        width += 1;
    }
    return width;
}

test "Scenario: Given q quit input when checking switch picker helpers then both line and key shortcuts cancel selection" {
    try std.testing.expect(isQuitInput("q"));
    try std.testing.expect(isQuitInput("Q"));
    try std.testing.expect(!isQuitInput(""));
    try std.testing.expect(!isQuitInput("1"));
    try std.testing.expect(!isQuitInput("qq"));
    try std.testing.expect(isQuitKey('q'));
    try std.testing.expect(isQuitKey('Q'));
    try std.testing.expect(!isQuitKey('j'));
}

fn makeTestRegistry() registry.Registry {
    return .{
        .schema_version = registry.current_schema_version,
        .active_account_key = null,
        .active_account_activated_at_ms = null,
        .auto_switch = registry.defaultAutoSwitchConfig(),
        .api = registry.defaultApiConfig(),
        .accounts = std.ArrayList(registry.AccountRecord).empty,
    };
}

fn appendTestAccount(
    allocator: std.mem.Allocator,
    reg: *registry.Registry,
    record_key: []const u8,
    email: []const u8,
    alias: []const u8,
    plan: registry.PlanType,
) !void {
    const sep = std.mem.lastIndexOf(u8, record_key, "::") orelse return error.InvalidRecordKey;
    const chatgpt_user_id = record_key[0..sep];
    const chatgpt_account_id = record_key[sep + 2 ..];
    try reg.accounts.append(allocator, .{
        .account_key = try allocator.dupe(u8, record_key),
        .chatgpt_account_id = try allocator.dupe(u8, chatgpt_account_id),
        .chatgpt_user_id = try allocator.dupe(u8, chatgpt_user_id),
        .email = try allocator.dupe(u8, email),
        .alias = try allocator.dupe(u8, alias),
        .account_name = null,
        .plan = plan,
        .auth_mode = .chatgpt,
        .created_at = 1,
        .last_used_at = null,
        .last_usage = null,
        .last_usage_at = null,
        .last_local_rollout = null,
    });
}

fn testUsageSnapshot(now: i64, used_5h: f64, used_weekly: f64) registry.RateLimitSnapshot {
    return .{
        .primary = .{
            .used_percent = used_5h,
            .window_minutes = 300,
            .resets_at = now + 3600,
        },
        .secondary = .{
            .used_percent = used_weekly,
            .window_minutes = 10080,
            .resets_at = now + 7 * 24 * 3600,
        },
        .credits = null,
        .plan_type = .pro,
    };
}

test "Scenario: Given grouped accounts when rendering switch list then child rows keep indentation" {
    const gpa = std.testing.allocator;
    var reg = makeTestRegistry();
    defer reg.deinit(gpa);

    try appendTestAccount(gpa, &reg, "user-1::acc-1", "user@example.com", "", .team);
    reg.accounts.items[0].account_name = try gpa.dupe(u8, "Als's Workspace");
    try appendTestAccount(gpa, &reg, "user-1::acc-2", "user@example.com", "", .free);

    var rows = try buildSwitchRows(gpa, &reg);
    defer rows.deinit(gpa);

    var buffer: [2048]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);
    const idx_width = @max(@as(usize, 2), indexWidth(rows.selectable_row_indices.len));
    try renderSwitchList(&writer, &reg, rows.items, idx_width, rows.widths, null, false);

    const output = writer.buffered();
    try std.testing.expect(std.mem.indexOf(u8, output, "01   Als's Workspace") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "02   Free") != null);
}

test "Scenario: Given usage overrides when rendering switch list then failed rows show response status in both usage columns" {
    const gpa = std.testing.allocator;
    var reg = makeTestRegistry();
    defer reg.deinit(gpa);

    try appendTestAccount(gpa, &reg, "user-1::acc-1", "user@example.com", "", .team);
    try appendTestAccount(gpa, &reg, "user-1::acc-2", "user@example.com", "", .free);

    const usage_overrides = [_]?[]const u8{ null, "401" };
    var rows = try buildSwitchRowsWithUsageOverrides(gpa, &reg, &usage_overrides);
    defer rows.deinit(gpa);

    var buffer: [2048]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);
    const idx_width = @max(@as(usize, 2), indexWidth(rows.selectable_row_indices.len));
    try renderSwitchList(&writer, &reg, rows.items, idx_width, rows.widths, null, false);

    const output = writer.buffered();
    try std.testing.expect(std.mem.count(u8, output, "401") >= 2);
}

test "Scenario: Given usage overrides when selecting switch accounts then errored rows are skipped" {
    const gpa = std.testing.allocator;
    var reg = makeTestRegistry();
    defer reg.deinit(gpa);

    try appendTestAccount(gpa, &reg, "user-1::acc-1", "healthy@example.com", "", .team);
    try appendTestAccount(gpa, &reg, "user-1::acc-2", "failed@example.com", "", .free);

    const usage_overrides = [_]?[]const u8{ null, "401" };
    var rows = try buildSwitchRowsWithUsageOverrides(gpa, &reg, &usage_overrides);
    defer rows.deinit(gpa);
    try filterErroredRowsFromSelectableIndices(gpa, &rows);

    try std.testing.expectEqual(@as(usize, 1), rows.selectable_row_indices.len);
    try std.testing.expect(std.mem.eql(u8, accountIdForSelectable(&rows, &reg, 0), "user-1::acc-1"));
}

test "Scenario: Given exhausted active usage when picking an auto-switch target then the best healthy candidate is chosen" {
    const gpa = std.testing.allocator;
    var reg = makeTestRegistry();
    defer reg.deinit(gpa);

    const now = std.Io.Timestamp.now(app_runtime.io(), .real).toSeconds();

    try appendTestAccount(gpa, &reg, "user-1::acc-1", "active@example.com", "", .team);
    try appendTestAccount(gpa, &reg, "user-1::acc-2", "backup-a@example.com", "", .team);
    try appendTestAccount(gpa, &reg, "user-1::acc-3", "backup-b@example.com", "", .team);
    reg.active_account_key = try gpa.dupe(u8, "user-1::acc-1");
    reg.accounts.items[0].last_usage = testUsageSnapshot(now, 100, 10);
    reg.accounts.items[1].last_usage = testUsageSnapshot(now, 35, 15);
    reg.accounts.items[2].last_usage = testUsageSnapshot(now, 5, 8);

    var rows = try buildSwitchRowsWithUsageOverrides(gpa, &reg, null);
    defer rows.deinit(gpa);
    try filterErroredRowsFromSelectableIndices(gpa, &rows);

    const target_key = try maybeAutoSwitchTargetKeyAlloc(gpa, .{
        .reg = &reg,
        .usage_overrides = null,
    }, &rows);
    defer if (target_key) |value| gpa.free(value);

    try std.testing.expect(target_key != null);
    try std.testing.expectEqualStrings("user-1::acc-3", target_key.?);
}

test "Scenario: Given an active api status error when picking an auto-switch target then a healthy candidate is chosen" {
    const gpa = std.testing.allocator;
    var reg = makeTestRegistry();
    defer reg.deinit(gpa);

    const now = std.Io.Timestamp.now(app_runtime.io(), .real).toSeconds();

    try appendTestAccount(gpa, &reg, "user-1::acc-1", "active@example.com", "", .team);
    try appendTestAccount(gpa, &reg, "user-1::acc-2", "backup@example.com", "", .team);
    reg.active_account_key = try gpa.dupe(u8, "user-1::acc-1");
    reg.accounts.items[0].last_usage = testUsageSnapshot(now, 20, 20);
    reg.accounts.items[1].last_usage = testUsageSnapshot(now, 10, 10);

    const usage_overrides = [_]?[]const u8{ "403", null };
    var rows = try buildSwitchRowsWithUsageOverrides(gpa, &reg, &usage_overrides);
    defer rows.deinit(gpa);
    try filterErroredRowsFromSelectableIndices(gpa, &rows);

    const target_key = try maybeAutoSwitchTargetKeyAlloc(gpa, .{
        .reg = &reg,
        .usage_overrides = &usage_overrides,
    }, &rows);
    defer if (target_key) |value| gpa.free(value);

    try std.testing.expect(target_key != null);
    try std.testing.expectEqualStrings("user-1::acc-2", target_key.?);
}

test "Scenario: Given only exhausted candidates when picking an auto-switch target then no target is returned" {
    const gpa = std.testing.allocator;
    var reg = makeTestRegistry();
    defer reg.deinit(gpa);

    const now = std.Io.Timestamp.now(app_runtime.io(), .real).toSeconds();

    try appendTestAccount(gpa, &reg, "user-1::acc-1", "active@example.com", "", .team);
    try appendTestAccount(gpa, &reg, "user-1::acc-2", "backup@example.com", "", .team);
    reg.active_account_key = try gpa.dupe(u8, "user-1::acc-1");
    reg.accounts.items[0].last_usage = testUsageSnapshot(now, 100, 10);
    reg.accounts.items[1].last_usage = testUsageSnapshot(now, 100, 100);

    var rows = try buildSwitchRowsWithUsageOverrides(gpa, &reg, null);
    defer rows.deinit(gpa);
    try filterErroredRowsFromSelectableIndices(gpa, &rows);

    const target_key = try maybeAutoSwitchTargetKeyAlloc(gpa, .{
        .reg = &reg,
        .usage_overrides = null,
    }, &rows);
    defer if (target_key) |value| gpa.free(value);

    try std.testing.expect(target_key == null);
}

test "Scenario: Given usage overrides when rendering switch list then errored rows still show full display numbers" {
    const gpa = std.testing.allocator;
    var reg = makeTestRegistry();
    defer reg.deinit(gpa);

    try appendTestAccount(gpa, &reg, "user-1::acc-1", "healthy@example.com", "", .team);
    try appendTestAccount(gpa, &reg, "user-1::acc-2", "failed@example.com", "", .free);

    const usage_overrides = [_]?[]const u8{ null, "401" };
    var rows = try buildSwitchRowsWithUsageOverrides(gpa, &reg, &usage_overrides);
    defer rows.deinit(gpa);

    var buffer: [2048]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);
    const idx_width = @max(@as(usize, 2), indexWidth(rows.selectable_row_indices.len));
    try renderSwitchList(&writer, &reg, rows.items, idx_width, rows.widths, null, false);

    const output = writer.buffered();
    try std.testing.expect(std.mem.indexOf(u8, output, "01 ") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "02 ") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "healthy@example.com") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "failed@example.com") != null);
}

test "Scenario: Given an active account when rendering switch list then non-selected active rows use the list marker" {
    const gpa = std.testing.allocator;
    var reg = makeTestRegistry();
    defer reg.deinit(gpa);

    try appendTestAccount(gpa, &reg, "user-1::acc-1", "selected@example.com", "", .team);
    try appendTestAccount(gpa, &reg, "user-1::acc-2", "active@example.com", "", .team);
    reg.active_account_key = try gpa.dupe(u8, "user-1::acc-2");

    var rows = try buildSwitchRows(gpa, &reg);
    defer rows.deinit(gpa);

    var buffer: [2048]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);
    const idx_width = @max(@as(usize, 2), indexWidth(rows.selectable_row_indices.len));
    var selected_displayed_idx: ?usize = null;
    for (rows.selectable_row_indices, 0..) |row_idx, selectable_idx| {
        const account_idx = rows.items[row_idx].account_index.?;
        if (std.mem.eql(u8, reg.accounts.items[account_idx].account_key, "user-1::acc-1")) {
            selected_displayed_idx = displayedIndexForSelectable(&rows, selectable_idx);
            break;
        }
    }

    try std.testing.expect(selected_displayed_idx != null);
    try renderSwitchList(&writer, &reg, rows.items, idx_width, rows.widths, selected_displayed_idx.?, false);

    const output = writer.buffered();
    var expected_selected_line_buf: [128]u8 = undefined;
    const expected_selected_line = try std.fmt.bufPrint(
        &expected_selected_line_buf,
        "> {d:0>2} selected@example.com",
        .{selected_displayed_idx.? + 1},
    );
    try std.testing.expect(std.mem.indexOf(u8, output, expected_selected_line) != null);

    const active_displayed_idx = displayedIndexForSelectable(&rows, activeSelectableIndex(&rows).?).?;
    var expected_active_line_buf: [128]u8 = undefined;
    const expected_active_line = try std.fmt.bufPrint(
        &expected_active_line_buf,
        "* {d:0>2} active@example.com",
        .{active_displayed_idx + 1},
    );
    try std.testing.expect(std.mem.indexOf(u8, output, expected_active_line) != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "[ACTIVE]") == null);
}

test "Scenario: Given the active account is selected when rendering switch list then the cursor marker wins" {
    const gpa = std.testing.allocator;
    var reg = makeTestRegistry();
    defer reg.deinit(gpa);

    try appendTestAccount(gpa, &reg, "user-1::acc-1", "active@example.com", "", .team);
    try appendTestAccount(gpa, &reg, "user-1::acc-2", "other@example.com", "", .team);
    reg.active_account_key = try gpa.dupe(u8, "user-1::acc-1");

    var rows = try buildSwitchRows(gpa, &reg);
    defer rows.deinit(gpa);

    var buffer: [2048]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);
    const idx_width = @max(@as(usize, 2), indexWidth(rows.selectable_row_indices.len));
    try renderSwitchList(&writer, &reg, rows.items, idx_width, rows.widths, 0, false);

    const output = writer.buffered();
    try std.testing.expect(std.mem.indexOf(u8, output, "> 01 active@example.com") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "* 01 active@example.com") == null);
    try std.testing.expect(std.mem.indexOf(u8, output, "[ACTIVE]") == null);
}

test "Scenario: Given an active account when rendering remove list then non-cursor active rows use the list marker" {
    const gpa = std.testing.allocator;
    var reg = makeTestRegistry();
    defer reg.deinit(gpa);

    try appendTestAccount(gpa, &reg, "user-1::acc-1", "cursor@example.com", "", .team);
    try appendTestAccount(gpa, &reg, "user-1::acc-2", "active@example.com", "", .team);
    reg.active_account_key = try gpa.dupe(u8, "user-1::acc-2");

    var rows = try buildSwitchRows(gpa, &reg);
    defer rows.deinit(gpa);

    var checked = [_]bool{ false, false };
    var buffer: [2048]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);
    const idx_width = @max(@as(usize, 2), indexWidth(rows.selectable_row_indices.len));
    const cursor_idx = selectableIndexForAccountKey(&rows, &reg, "user-1::acc-1").?;
    try renderRemoveList(&writer, &reg, rows.items, idx_width, rows.widths, cursor_idx, &checked, false);

    const output = writer.buffered();
    var expected_cursor_line_buf: [128]u8 = undefined;
    const expected_cursor_line = try std.fmt.bufPrint(
        &expected_cursor_line_buf,
        "> [ ] {d:0>2} cursor@example.com",
        .{cursor_idx + 1},
    );
    try std.testing.expect(std.mem.indexOf(u8, output, expected_cursor_line) != null);

    const active_idx = selectableIndexForAccountKey(&rows, &reg, "user-1::acc-2").?;
    var expected_active_line_buf: [128]u8 = undefined;
    const expected_active_line = try std.fmt.bufPrint(
        &expected_active_line_buf,
        "* [ ] {d:0>2} active@example.com",
        .{active_idx + 1},
    );
    try std.testing.expect(std.mem.indexOf(u8, output, expected_active_line) != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "[ACTIVE]") == null);
}

test "Scenario: Given the active account is the remove cursor then the cursor marker wins" {
    const gpa = std.testing.allocator;
    var reg = makeTestRegistry();
    defer reg.deinit(gpa);

    try appendTestAccount(gpa, &reg, "user-1::acc-1", "active@example.com", "", .team);
    try appendTestAccount(gpa, &reg, "user-1::acc-2", "other@example.com", "", .team);
    reg.active_account_key = try gpa.dupe(u8, "user-1::acc-1");

    var rows = try buildSwitchRows(gpa, &reg);
    defer rows.deinit(gpa);

    var checked = [_]bool{ false, false };
    var buffer: [2048]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);
    const idx_width = @max(@as(usize, 2), indexWidth(rows.selectable_row_indices.len));
    try renderRemoveList(&writer, &reg, rows.items, idx_width, rows.widths, 0, &checked, false);

    const output = writer.buffered();
    try std.testing.expect(std.mem.indexOf(u8, output, "> [ ] 01 active@example.com") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "* [ ] 01 active@example.com") == null);
    try std.testing.expect(std.mem.indexOf(u8, output, "[ACTIVE]") == null);
}

test "Scenario: Given switch live feedback when rendering switch screen then the action message stays below the footer" {
    const gpa = std.testing.allocator;
    var reg = makeTestRegistry();
    defer reg.deinit(gpa);

    try appendTestAccount(gpa, &reg, "user-1::acc-1", "healthy@example.com", "", .team);
    var rows = try buildSwitchRows(gpa, &reg);
    defer rows.deinit(gpa);

    var buffer: [2048]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);
    try renderSwitchScreen(
        &writer,
        &reg,
        rows.items,
        @max(@as(usize, 2), indexWidth(accountRowCount(rows.items))),
        rows.widths,
        0,
        false,
        "Live refresh: api | Refresh in 9s",
        "Switched to healthy@example.com",
        "",
    );

    const output = writer.buffered();
    const footer_pos = std.mem.indexOf(u8, output, "Keys:") orelse return error.TestExpectedEqual;
    const action_pos = std.mem.indexOf(u8, output, "Switched to healthy@example.com") orelse return error.TestExpectedEqual;
    try std.testing.expect(action_pos > footer_pos);
}

test "Scenario: Given Windows console labels when rendering unicode-prone output then ASCII fallbacks are used" {
    try std.testing.expectEqualStrings(
        "Keys: Up/Down or j/k, 1-9 type, Enter select, Esc or q quit\n",
        switchTuiFooterText(true),
    );
    try std.testing.expectEqualStrings(
        "Keys: Up/Down or j/k move, Space toggle, 1-9 type, Enter delete, Esc or q quit\n",
        removeTuiFooterText(true),
    );
    try std.testing.expectEqualStrings("[+]", importReportMarker(.imported, true));
    try std.testing.expectEqualStrings("[~]", importReportMarker(.updated, true));
    try std.testing.expectEqualStrings("[x]", importReportMarker(.skipped, true));
}

test "Scenario: Given non-Windows console labels when rendering unicode-prone output then the richer glyphs remain" {
    try std.testing.expectEqualStrings(
        "Keys: ↑/↓ or j/k, 1-9 type, Enter select, Esc or q quit\n",
        switchTuiFooterText(false),
    );
    try std.testing.expectEqualStrings(
        "Keys: ↑/↓ or j/k move, Space toggle, 1-9 type, Enter delete, Esc or q quit\n",
        removeTuiFooterText(false),
    );
    try std.testing.expectEqualStrings("✓", importReportMarker(.imported, false));
    try std.testing.expectEqualStrings("✓", importReportMarker(.updated, false));
    try std.testing.expectEqualStrings("✗", importReportMarker(.skipped, false));
}

test "Scenario: Given usage overrides when rendering remove list then failed rows show response status in both usage columns" {
    const gpa = std.testing.allocator;
    var reg = makeTestRegistry();
    defer reg.deinit(gpa);

    try appendTestAccount(gpa, &reg, "user-1::acc-1", "user@example.com", "", .team);
    try appendTestAccount(gpa, &reg, "user-1::acc-2", "user@example.com", "", .free);

    const usage_overrides = [_]?[]const u8{ null, "401" };
    var rows = try buildSwitchRowsWithUsageOverrides(gpa, &reg, &usage_overrides);
    defer rows.deinit(gpa);

    var checked = [_]bool{ false, false };
    var buffer: [2048]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);
    const idx_width = @max(@as(usize, 2), indexWidth(rows.selectable_row_indices.len));
    try renderRemoveList(&writer, &reg, rows.items, idx_width, rows.widths, null, &checked, false);

    const output = writer.buffered();
    try std.testing.expect(std.mem.count(u8, output, "401") >= 2);
}

test "Scenario: Given usage overrides when rendering switch list with color then failed rows are highlighted red" {
    const gpa = std.testing.allocator;
    var reg = makeTestRegistry();
    defer reg.deinit(gpa);

    try appendTestAccount(gpa, &reg, "user-1::acc-1", "user@example.com", "", .team);
    try appendTestAccount(gpa, &reg, "user-1::acc-2", "user@example.com", "", .free);

    const usage_overrides = [_]?[]const u8{ null, "401" };
    var rows = try buildSwitchRowsWithUsageOverrides(gpa, &reg, &usage_overrides);
    defer rows.deinit(gpa);

    var buffer: [2048]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);
    const idx_width = @max(@as(usize, 2), indexWidth(rows.selectable_row_indices.len));
    try renderSwitchList(&writer, &reg, rows.items, idx_width, rows.widths, null, true);

    const output = writer.buffered();
    try std.testing.expect(std.mem.indexOf(u8, output, ansi.red) != null);
}

test "Scenario: Given usage overrides when rendering remove list with color then failed rows are highlighted red" {
    const gpa = std.testing.allocator;
    var reg = makeTestRegistry();
    defer reg.deinit(gpa);

    try appendTestAccount(gpa, &reg, "user-1::acc-1", "user@example.com", "", .team);
    try appendTestAccount(gpa, &reg, "user-1::acc-2", "user@example.com", "", .free);

    const usage_overrides = [_]?[]const u8{ null, "401" };
    var rows = try buildSwitchRowsWithUsageOverrides(gpa, &reg, &usage_overrides);
    defer rows.deinit(gpa);

    var checked = [_]bool{ false, false };
    var buffer: [2048]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);
    const idx_width = @max(@as(usize, 2), indexWidth(rows.selectable_row_indices.len));
    try renderRemoveList(&writer, &reg, rows.items, idx_width, rows.widths, null, &checked, true);

    const output = writer.buffered();
    try std.testing.expect(std.mem.indexOf(u8, output, ansi.red) != null);
}

test "Scenario: Given a usage snapshot plan when building switch rows then the displayed plan prefers it over the stored auth plan" {
    const gpa = std.testing.allocator;
    var reg = makeTestRegistry();
    defer reg.deinit(gpa);

    try appendTestAccount(gpa, &reg, "user-1::acc-1", "user@example.com", "", .plus);
    reg.accounts.items[0].last_usage = .{
        .primary = null,
        .secondary = null,
        .credits = null,
        .plan_type = .team,
    };

    var rows = try buildSwitchRows(gpa, &reg);
    defer rows.deinit(gpa);

    try std.testing.expectEqualStrings("Business", rows.items[0].plan);
}

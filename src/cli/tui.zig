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
    pub const MOUSE_EVENT: WORD = 0x0002;
    pub const WINDOW_BUFFER_SIZE_EVENT: WORD = 0x0004;

    pub const MOUSE_WHEELED: DWORD = 0x0004;
    pub const MOUSE_HWHEELED: DWORD = 0x0008;

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

    pub const MOUSE_EVENT_RECORD = extern struct {
        dwMousePosition: COORD,
        /// Wheel events carry the signed delta in the high word (120 per
        /// notch, positive up); buttons live in the low word for the rest.
        dwButtonState: DWORD,
        dwControlKeyState: DWORD,
        dwEventFlags: DWORD,
    };

    pub const INPUT_RECORD = extern struct {
        EventType: WORD,
        Event: extern union {
            KeyEvent: KEY_EVENT_RECORD,
            MouseEvent: MOUSE_EVENT_RECORD,
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
    extern "kernel32" fn GetNumberOfConsoleInputEvents(
        console_input: HANDLE,
        number_of_events: *DWORD,
    ) callconv(.winapi) BOOL;
};

pub const win32 = win;

pub const tui_poll_input_mask: i16 = if (builtin.target.os.tag == .windows) 0 else std.posix.POLL.IN;
pub const tui_poll_error_mask: i16 = if (builtin.target.os.tag == .windows) 0 else std.posix.POLL.ERR | std.posix.POLL.HUP | std.posix.POLL.NVAL;
pub const tui_escape_sequence_timeout_ms: i32 = 100;
pub const live_ui_tick_ms: i32 = 100;
/// How often a blocking POSIX picker wakes to re-check the window size —
/// SIGWINCH never arrives as input, so this is the redraw heartbeat.
const picker_resize_poll_ms: i32 = 250;
/// Per-call bound on Windows console record draining — see readWindowsKey.
const max_drain_records: usize = 256;

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
        win.ENABLE_WINDOW_INPUT |
        // The console only reports the wheel while mouse input is on; with
        // QuickEdit off those events reach the app instead of driving a
        // selection. Clicks land in the queue too and are discarded.
        win.ENABLE_MOUSE_INPUT;
    raw_input_mode &= ~@as(
        win.DWORD,
        win.ENABLE_PROCESSED_INPUT |
            win.ENABLE_QUICK_EDIT_MODE |
            win.ENABLE_LINE_INPUT |
            win.ENABLE_ECHO_INPUT |
            win.ENABLE_VIRTUAL_TERMINAL_INPUT,
    );
    return raw_input_mode;
}

pub fn windowsTuiOutputMode(saved_output_mode: win.DWORD) win.DWORD {
    return saved_output_mode |
        win.ENABLE_PROCESSED_OUTPUT |
        win.ENABLE_VIRTUAL_TERMINAL_PROCESSING;
}

/// Maps a console `MOUSE_EVENT_RECORD` to a scroll key. Only `MOUSE_WHEELED`
/// produces one, by sign of the delta in the high word of `dwButtonState`
/// (±120 per notch): one console event per notch, and the delta magnitude is
/// folded into the single key the same way an SGR wheel report collapses to
/// one scroll. Clicks, moves, and horizontal wheel return null so the
/// caller's loop keeps draining without mistaking them for keys.
pub fn windowsMouseScrollKey(record: win.INPUT_RECORD) ?TuiInputKey {
    if (record.EventType != win.MOUSE_EVENT) return null;
    const mouse_event = record.Event.MouseEvent;
    if (mouse_event.dwEventFlags != win.MOUSE_WHEELED) return null;
    const delta: i16 = @bitCast(@as(u16, @truncate(mouse_event.dwButtonState >> 16)));
    if (delta > 0) return .scroll_up;
    if (delta < 0) return .scroll_down;
    return null;
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

/// Screen modes the live TUI runs under: alternate screen, hidden cursor,
/// alternate scroll, and mouse reporting. `?1000h` asks for button events —
/// wheel notches included — and `?1006h` makes them arrive as SGR
/// `CSI <button;x;y M`, the same first-class input other full TUIs read. In
/// terminals that honour mouse reporting the wheel stops arriving as arrow
/// keys, so `?1007h` stays only as the fallback for terminals that implement
/// alternate scroll but not mouse reporting. Press/release/motion modes
/// (`?1002h`/`?1003h`/`?1005h`) are deliberately left off.
pub fn writeTuiEnterTo(out: *std.Io.Writer, request_kitty: bool) !void {
    try out.writeAll("\x1b[?1049h\x1b[?25l\x1b[?1007h\x1b[?1000h\x1b[?1006h");
    // Push first, query second: `CSI ?u` reports the flags currently in
    // effect, so it must run after `>7u` — a query emitted first would be
    // answered with the pre-push stack and the enhancement could never
    // confirm itself.
    if (request_kitty) try out.writeAll("\x1b[>7u\x1b[?u");
    try out.writeAll("\x1b[H\x1b[J");
}

/// `pop_kitty` must mirror the request the enter wrote: `CSI <1u` pops
/// whoever is on top of the terminal's flag stack, so it is only emitted when
/// this session actually pushed.
pub fn writeTuiExitTo(out: *std.Io.Writer, pop_kitty: bool) !void {
    if (pop_kitty) try out.writeAll("\x1b[<1u");
    try out.writeAll("\x1b[?1006l\x1b[?1000l\x1b[?1007l\x1b[?25h\x1b[?1049l");
}

/// Terminal brand hints the shell already exports — no probes, so a slow or
/// dead terminal can never stall TUI startup.
pub const TerminalEnvHints = struct {
    term_program: ?[]const u8 = null,
    terminal_emulator: ?[]const u8 = null,
    wt_session: bool = false,
    vte_version: bool = false,
};

pub fn terminalEnvHints() TerminalEnvHints {
    return .{
        .term_program = app_runtime.envValue("TERM_PROGRAM"),
        .terminal_emulator = app_runtime.envValue("TERMINAL_EMULATOR"),
        .wt_session = app_runtime.envHasValue("WT_SESSION"),
        .vte_version = app_runtime.envHasValue("VTE_VERSION"),
    };
}

/// Whether the kitty keyboard enhancement query+push is worth emitting.
/// Terminals that mis-encode the protocol or half-claim it (xterm.js hosts
/// like VSCode and its forks, JediTerm, VTE, Apple Terminal, Windows
/// Terminal) are skipped up front so they cannot answer `CSI ?u` with flags
/// they do not honor; legacy byte input is fully supported either way. The
/// Windows console path reads `INPUT_RECORD`s rather than a byte stream, so
/// the request is meaningless there and is skipped outright.
pub fn kittyRequestAllowed(hints: TerminalEnvHints) bool {
    if (comptime builtin.target.os.tag == .windows) return false;
    if (hints.wt_session or hints.vte_version) return false;
    const term_program = hints.term_program orelse "";
    const terminal_emulator = hints.terminal_emulator orelse "";
    if (std.mem.eql(u8, term_program, "vscode") or
        std.mem.eql(u8, term_program, "Apple_Terminal")) return false;
    if (std.mem.indexOf(u8, term_program, "JediTerm") != null or
        std.mem.indexOf(u8, terminal_emulator, "JediTerm") != null) return false;
    return true;
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

// On Linux, `std.posix.termios` uses the 44-byte kernel layout (NCCS=19), but
// glibc's `struct termios` is 60 bytes (NCCS=32). The libc-backed
// `std.posix.tcgetattr` therefore overwrites 16 bytes past its destination,
// which trips the stack protector in ReleaseSafe builds. Issue the ioctl
// directly instead: the kernel ABI matches `std.posix.termios` exactly.
// Other targets keep `std.posix`, whose layout already matches their libc.
fn tcGetAttr(handle: std.posix.fd_t) std.posix.TermiosGetError!std.posix.termios {
    const linux = std.os.linux;
    if (comptime builtin.target.os.tag != .linux) return std.posix.tcgetattr(handle);
    while (true) {
        // TCGETS fills only the 36-byte kernel termios; zero the trailing
        // speed fields so the saved value stays fully defined.
        var term: std.posix.termios = std.mem.zeroes(std.posix.termios);
        switch (linux.errno(linux.tcgetattr(handle, &term))) {
            .SUCCESS => return term,
            .INTR => continue,
            .BADF => unreachable,
            .NOTTY => return error.NotATerminal,
            else => |err| return std.posix.unexpectedErrno(err),
        }
    }
}

fn tcSetAttr(handle: std.posix.fd_t, optional_action: std.posix.TCSA, termios_p: std.posix.termios) std.posix.TermiosSetError!void {
    const linux = std.os.linux;
    if (comptime builtin.target.os.tag != .linux) return std.posix.tcsetattr(handle, optional_action, termios_p);
    while (true) {
        switch (linux.errno(linux.tcsetattr(handle, optional_action, &termios_p))) {
            .SUCCESS => return,
            .BADF => unreachable,
            .INTR => continue,
            .INVAL => unreachable,
            .NOTTY => return error.NotATerminal,
            .IO => return error.ProcessOrphaned,
            else => |err| return std.posix.unexpectedErrno(err),
        }
    }
}

pub const TuiSession = struct {
    input: std.Io.File,
    output: std.Io.File,
    saved_input_state: TuiSavedInputState = if (builtin.target.os.tag == .windows) 0 else undefined,
    saved_output_state: TuiSavedOutputState = if (builtin.target.os.tag == .windows) 0 else {},
    pending_windows_key: ?TuiInputKey = null,
    pending_windows_repeat_count: u16 = 0,
    keyboard_enhancement_supported: bool = false,
    /// Mirrors the kitty request emitted (or withheld) on enter so deinit
    /// pops the flag stack only when this session pushed onto it.
    keyboard_enhancement_requested: bool = false,
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
        const keyboard_enhancement_requested = kittyRequestAllowed(terminalEnvHints());

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
                .keyboard_enhancement_requested = keyboard_enhancement_requested,
            };
            self.writer = self.output.writer(app_runtime.io(), &self.writer_buffer);
            // A failed enter can leave the DECSET modes half-applied even
            // though the console modes restore via errdefer — run the full
            // exit sequence best-effort on that path too.
            errdefer self.deinit();
            self.enter() catch |err| return mapTuiOutputError(err);
        } else {
            const saved_termios = try tcGetAttr(input.handle);
            var raw = saved_termios;
            raw.lflag.ICANON = false;
            raw.lflag.ECHO = false;
            // Signals would kill the process before `deinit` can restore the
            // terminal; with ISIG off, Ctrl-C arrives as a byte the input loop
            // maps to `.quit`, so quitting always runs the restore path.
            raw.lflag.ISIG = false;
            raw.cc[@backingInt(std.c.V.MIN)] = 1;
            raw.cc[@backingInt(std.c.V.TIME)] = 0;
            try tcSetAttr(input.handle, .FLUSH, raw);
            errdefer tcSetAttr(input.handle, .FLUSH, saved_termios) catch {};

            self.* = .{
                .input = input,
                .output = output,
                .saved_input_state = saved_termios,
                .keyboard_enhancement_requested = keyboard_enhancement_requested,
            };
            self.writer = self.output.writer(app_runtime.io(), &self.writer_buffer);
            errdefer self.deinit();
            self.enter() catch |err| return mapTuiOutputError(err);
        }
    }

    pub fn deinit(self: *@This()) void {
        const writer = self.out();
        writeTuiExitTo(writer, self.keyboard_enhancement_requested) catch {};
        writer.flush() catch {};
        if (comptime builtin.target.os.tag == .windows) {
            _ = win.SetConsoleMode(self.output.handle, self.saved_output_state);
            _ = win.SetConsoleMode(self.input.handle, self.saved_input_state);
        } else {
            tcSetAttr(self.input.handle, .FLUSH, self.saved_input_state) catch {};
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

        if (comptime builtin.target.os.tag == .windows) {
            // A queued key repeat replays without waiting on console input.
            if (self.pending_windows_key != null) {
                keys[0] = (try self.readWindowsKey()).?;
                return .{ .ready = 1 };
            }
        }

        switch (try pollTuiInput(self.input, timeout_ms, tui_poll_error_mask)) {
            .timeout => return .timeout,
            .closed => return .closed,
            .ready => {},
        }

        if (comptime builtin.target.os.tag == .windows) {
            if (try self.readWindowsKey()) |key| {
                keys[0] = key;
                return .{ .ready = 1 };
            }
            // The signal came from a non-key record (mouse move, focus…)
            // that was consumed without producing a key; report a timeout
            // so the caller's refresh cadence keeps running.
            return .timeout;
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

    /// Drains console input until a key event maps to a TuiInputKey and
    /// returns it, or returns null once the input queue is empty. Mouse,
    /// focus, and menu records are consumed without blocking.
    pub fn readWindowsKey(self: *@This()) !?TuiInputKey {
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

        // Drain is bounded per call: a sustained record flood (mouse-move
        // reports while the pointer wiggles) must not stretch one call's
        // latency unboundedly — the rest is picked up next tick.
        var drained: usize = 0;
        while (drained < max_drain_records) : (drained += 1) {
            // Earlier iterations may have drained the queue on non-key
            // records; do not block on an empty queue or the caller's
            // timeout cadence stalls. A racing co-reader could still park
            // ReadConsoleInputW below, but nothing else consumes input here.
            var pending_count: win.DWORD = 0;
            if (win.GetNumberOfConsoleInputEvents(self.input.handle, &pending_count) == .FALSE) {
                return error.EndOfStream;
            }
            if (pending_count == 0) return null;
            var record: win.INPUT_RECORD = undefined;
            var events_read: win.DWORD = 0;
            if (win.ReadConsoleInputW(self.input.handle, &record, 1, &events_read) == .FALSE) {
                return error.EndOfStream;
            }
            if (events_read == 0) continue;
            if (record.EventType == win.WINDOW_BUFFER_SIZE_EVENT) return .redraw;
            if (windowsMouseScrollKey(record)) |key| return key;
            if (record.EventType == win.MOUSE_EVENT) continue;
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
        return null;
    }

    /// Blocks for input bytes the way `read` does, but wakes on a poll
    /// tick to re-check the terminal size: SIGWINCH produces no input
    /// byte, so without this a POSIX picker would keep a stale frame
    /// until the next keypress — the parity of the Windows .redraw path.
    /// `baseline_rows`/`baseline_cols` must be the size the caller just
    /// drew the frame with; sampling here instead would turn a resize
    /// that landed during drawing into the baseline and miss it forever.
    /// Returns null when the window was resized (the caller should
    /// redraw), the byte count otherwise.
    pub fn readPickerBytes(self: *@This(), buffer: []u8, baseline_rows: usize, baseline_cols: usize) !?usize {
        if (comptime builtin.target.os.tag == .windows) unreachable;
        var last_rows = baseline_rows;
        var last_cols = baseline_cols;
        while (true) {
            switch (try pollTuiInput(self.input, picker_resize_poll_ms, tui_poll_error_mask)) {
                .ready => return try self.read(buffer),
                .closed => return error.EndOfStream,
                .timeout => {
                    const rows = self.terminalRows();
                    const cols = self.terminalCols();
                    if (rows != last_rows or cols != last_cols) return null;
                    last_rows = rows;
                    last_cols = cols;
                },
            }
        }
    }

    /// Blocks until a key event maps to a TuiInputKey — the pre-drain
    /// behavior for pickers that have no refresh cadence to service.
    pub fn waitWindowsKey(self: *@This()) !TuiInputKey {
        while (true) {
            if (try self.readWindowsKey()) |key| return key;
            // WAIT_FAILED (0xffffffff) must not spin: a permanently broken
            // input handle would otherwise loop here forever.
            if (win.WaitForSingleObject(self.input.handle, std.math.maxInt(u32)) == 0xffff_ffff)
                return error.EndOfStream;
        }
    }

    pub fn enter(self: *@This()) !void {
        const writer = self.out();
        try writeTuiEnterTo(writer, self.keyboard_enhancement_requested);
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
            // Once the terminal confirms kitty support, real arrow presses
            // arrive as enhanced sequences (keyboard_up/down), so a bare
            // ESC[A/B can only come from the ?1007h alternate-scroll
            // fallback — it is a wheel notch, not a cursor key. Terminals
            // that ACK the flag yet still send legacy arrows are
            // non-conformant; before the ACK arrows keep moving.
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

/// Parses the flags value out of a `CSI ? flags u` keyboard-enhancement
/// reply. The value matters, not just the shape: a terminal that answers the
/// query but applied none of the pushed flags reports `?0u`, and only a reply
/// with bit 0 (disambiguate) set means legacy bytes may now be enhancement
/// sequences instead of keys.
fn keyboardEnhancementFlags(seq: []const u8) ?usize {
    if (seq.len < 4 or seq[0] != '[' or seq[1] != '?' or seq[seq.len - 1] != 'u') return null;
    return std.fmt.parseInt(usize, seq[2 .. seq.len - 1], 10) catch null;
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
            // X10 mouse report `ESC [ M Cb Cx Cy`, the encoding terminals
            // fall back to when they honour `?1000h` but not `?1006h`: the
            // three bytes after `M` are coordinates, not keys. Eat them so a
            // digit-shaped column byte cannot leak into a picker prompt.
            if (seq[1] == 'M') break :blk if (seq.len < 5) .incomplete else .ignore;
            const final = seq[seq.len - 1];
            if (keyboardEnhancementFlags(seq)) |flags| {
                break :blk if (flags & 1 != 0) .keyboard_enhancement_supported else .ignore;
            }
            if (csiUKey(seq)) |key| break :blk .{ .key = key };
            if (seq[1] == '<') {
                if (final != 'M' and final != 'm') {
                    if (final >= '@' and final <= '~') break :blk .ignore;
                    break :blk .incomplete;
                }
                const first_semicolon = std.mem.findScalar(u8, seq[2 .. seq.len - 1], ';') orelse break :blk .ignore;
                const button_code = std.fmt.parseInt(usize, seq[2 .. 2 + first_semicolon], 10) catch break :blk .ignore;
                // SGR button codes: bit 6 marks the wheel group, the low two
                // bits are the direction (0 up, 1 down, 2/3 horizontal), the
                // middle bits are modifiers, and bit 5 is drag motion. Only
                // `M` presses scroll — a wheel notch has no `m` release, and
                // button releases must not re-fire the scroll.
                const direction: ?TuiNavigation = if (final == 'M' and (button_code & 64) != 0 and (button_code & 32) == 0)
                    switch (button_code & 3) {
                        0 => .scroll_up,
                        1 => .scroll_down,
                        else => null,
                    }
                else
                    null;
                break :blk if (direction) |dir| .{ .navigation = dir } else .ignore;
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

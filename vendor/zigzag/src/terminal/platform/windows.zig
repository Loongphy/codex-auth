//! Windows terminal implementation using Console API.
//! Provides terminal control for Windows systems.

const std = @import("std");
const windows = std.os.windows;
const ansi = @import("../ansi.zig");

pub const TerminalError = error{
    NotATty,
    GetAttrFailed,
    SetAttrFailed,
    GetConsoleFailed,
    SetConsoleFailed,
    InvalidHandle,
};

/// Terminal size
pub const Size = struct {
    rows: u16,
    cols: u16,
};

/// Console mode flags
const ENABLE_VIRTUAL_TERMINAL_PROCESSING: windows.DWORD = 0x0004;
const ENABLE_VIRTUAL_TERMINAL_INPUT: windows.DWORD = 0x0200;
const ENABLE_PROCESSED_INPUT: windows.DWORD = 0x0001;
const ENABLE_LINE_INPUT: windows.DWORD = 0x0002;
const ENABLE_ECHO_INPUT: windows.DWORD = 0x0004;
const ENABLE_MOUSE_INPUT: windows.DWORD = 0x0010;
const ENABLE_WINDOW_INPUT: windows.DWORD = 0x0008;
const ENABLE_EXTENDED_FLAGS: windows.DWORD = 0x0080;
const ENABLE_QUICK_EDIT_MODE: windows.DWORD = 0x0040;
const FILE_TYPE_CHAR: windows.DWORD = 0x0002;
const FILE_TYPE_PIPE: windows.DWORD = 0x0003;
const KEY_EVENT: windows.WORD = 0x0001;
const MOUSE_EVENT: windows.WORD = 0x0002;

/// Terminal state for Windows
pub const State = struct {
    original_input_mode: windows.DWORD = 0,
    original_output_mode: windows.DWORD = 0,
    in_raw_mode: bool = false,
    in_alt_screen: bool = false,
    mouse_enabled: bool = false,
    stdin_handle: windows.HANDLE,
    stdout_handle: windows.HANDLE,

    pub fn init() State {
        return .{
            .stdin_handle = windows.GetStdHandle(windows.STD_INPUT_HANDLE) catch windows.INVALID_HANDLE_VALUE,
            .stdout_handle = windows.GetStdHandle(windows.STD_OUTPUT_HANDLE) catch windows.INVALID_HANDLE_VALUE,
        };
    }
};

/// External Windows API declarations
extern "kernel32" fn GetConsoleMode(hConsole: windows.HANDLE, lpMode: *windows.DWORD) callconv(.winapi) windows.BOOL;
extern "kernel32" fn SetConsoleMode(hConsole: windows.HANDLE, dwMode: windows.DWORD) callconv(.winapi) windows.BOOL;
extern "kernel32" fn GetConsoleScreenBufferInfo(hConsole: windows.HANDLE, lpInfo: *CONSOLE_SCREEN_BUFFER_INFO) callconv(.winapi) windows.BOOL;
extern "kernel32" fn GetFileType(hFile: windows.HANDLE) callconv(.winapi) windows.DWORD;
extern "kernel32" fn PeekNamedPipe(
    hNamedPipe: windows.HANDLE,
    lpBuffer: ?*anyopaque,
    nBufferSize: windows.DWORD,
    lpBytesRead: ?*windows.DWORD,
    lpTotalBytesAvail: ?*windows.DWORD,
    lpBytesLeftThisMessage: ?*windows.DWORD,
) callconv(.winapi) windows.BOOL;
extern "kernel32" fn GetNumberOfConsoleInputEvents(
    hConsoleInput: windows.HANDLE,
    lpcNumberOfEvents: *windows.DWORD,
) callconv(.winapi) windows.BOOL;
extern "kernel32" fn PeekConsoleInputW(
    hConsoleInput: windows.HANDLE,
    lpBuffer: [*]INPUT_RECORD,
    nLength: windows.DWORD,
    lpNumberOfEventsRead: *windows.DWORD,
) callconv(.winapi) windows.BOOL;
extern "kernel32" fn ReadConsoleInputW(
    hConsoleInput: windows.HANDLE,
    lpBuffer: [*]INPUT_RECORD,
    nLength: windows.DWORD,
    lpNumberOfEventsRead: *windows.DWORD,
) callconv(.winapi) windows.BOOL;

const CONSOLE_SCREEN_BUFFER_INFO = extern struct {
    dwSize: COORD,
    dwCursorPosition: COORD,
    wAttributes: windows.WORD,
    srWindow: SMALL_RECT,
    dwMaximumWindowSize: COORD,
};

const COORD = extern struct {
    X: windows.SHORT,
    Y: windows.SHORT,
};

const SMALL_RECT = extern struct {
    Left: windows.SHORT,
    Top: windows.SHORT,
    Right: windows.SHORT,
    Bottom: windows.SHORT,
};

const INPUT_RECORD = extern struct {
    EventType: windows.WORD,
    Event: INPUT_EVENT,
};

const INPUT_EVENT = extern union {
    KeyEvent: KEY_EVENT_RECORD,
    MouseEvent: [16]u8,
    WindowBufferSizeEvent: [4]u8,
    MenuEvent: [4]u8,
    FocusEvent: [4]u8,
};

const KEY_EVENT_RECORD = extern struct {
    bKeyDown: windows.BOOL,
    wRepeatCount: windows.WORD,
    wVirtualKeyCode: windows.WORD,
    wVirtualScanCode: windows.WORD,
    uChar: extern union {
        UnicodeChar: windows.WCHAR,
        AsciiChar: windows.CHAR,
    },
    dwControlKeyState: windows.DWORD,
};

/// Check if a handle is valid
pub fn isTty(handle: windows.HANDLE) bool {
    if (handle == windows.INVALID_HANDLE_VALUE) return false;
    var mode: windows.DWORD = 0;
    return GetConsoleMode(handle, &mode) != 0;
}

/// Get terminal size
pub fn getSize(handle: windows.HANDLE) !Size {
    var info: CONSOLE_SCREEN_BUFFER_INFO = undefined;
    if (GetConsoleScreenBufferInfo(handle, &info) == 0) {
        return TerminalError.GetConsoleFailed;
    }
    return .{
        .rows = @intCast(info.srWindow.Bottom - info.srWindow.Top + 1),
        .cols = @intCast(info.srWindow.Right - info.srWindow.Left + 1),
    };
}

/// Enable raw mode
pub fn enableRawMode(state: *State) !void {
    if (state.in_raw_mode) return;

    if (state.stdin_handle == windows.INVALID_HANDLE_VALUE or
        state.stdout_handle == windows.INVALID_HANDLE_VALUE)
    {
        return TerminalError.InvalidHandle;
    }

    // Save original modes
    if (GetConsoleMode(state.stdin_handle, &state.original_input_mode) == 0) {
        return TerminalError.GetConsoleFailed;
    }
    if (GetConsoleMode(state.stdout_handle, &state.original_output_mode) == 0) {
        return TerminalError.GetConsoleFailed;
    }

    // Set input mode for raw input with VT processing.
    // Avoid WINDOW_INPUT because it can signal wait handles without producing bytes for ReadFile.
    const input_mode: windows.DWORD = ENABLE_VIRTUAL_TERMINAL_INPUT;
    if (SetConsoleMode(state.stdin_handle, input_mode) == 0) {
        return TerminalError.SetConsoleFailed;
    }

    // Enable VT processing on output
    const output_mode: windows.DWORD = state.original_output_mode | ENABLE_VIRTUAL_TERMINAL_PROCESSING;
    if (SetConsoleMode(state.stdout_handle, output_mode) == 0) {
        // Restore input mode and fail
        _ = SetConsoleMode(state.stdin_handle, state.original_input_mode);
        return TerminalError.SetConsoleFailed;
    }

    state.in_raw_mode = true;
}

/// Disable raw mode
pub fn disableRawMode(state: *State) void {
    if (!state.in_raw_mode) return;

    _ = SetConsoleMode(state.stdin_handle, state.original_input_mode);
    _ = SetConsoleMode(state.stdout_handle, state.original_output_mode);

    state.in_raw_mode = false;
}

/// Enter alternate screen buffer
pub fn enterAltScreen(state: *State, writer: anytype) !void {
    if (state.in_alt_screen) return;

    try writer.writeAll(ansi.alt_screen_enter);
    state.in_alt_screen = true;
}

/// Exit alternate screen buffer
pub fn exitAltScreen(state: *State, writer: anytype) !void {
    if (!state.in_alt_screen) return;

    try writer.writeAll(ansi.alt_screen_exit);
    state.in_alt_screen = false;
}

/// Enable mouse tracking
pub fn enableMouse(state: *State, writer: anytype) !void {
    if (state.mouse_enabled) return;

    // Enable mouse input in console mode
    if (state.stdin_handle != windows.INVALID_HANDLE_VALUE) {
        var mode: windows.DWORD = 0;
        if (GetConsoleMode(state.stdin_handle, &mode) != 0) {
            _ = SetConsoleMode(state.stdin_handle, mode | ENABLE_MOUSE_INPUT);
        }
    }

    // Also send ANSI sequences for VT mode
    try writer.writeAll("\x1b[?1003h\x1b[?1006h");
    state.mouse_enabled = true;
}

/// Disable mouse tracking
pub fn disableMouse(state: *State, writer: anytype) !void {
    if (!state.mouse_enabled) return;

    try writer.writeAll("\x1b[?1006l\x1b[?1003l");
    state.mouse_enabled = false;
}

/// Read available input (Windows uses std.Io)
pub fn readInput(state: *State, buffer: []u8, timeout_ms: i32) !usize {
    if (state.stdin_handle == windows.INVALID_HANDLE_VALUE) return 0;

    // Match POSIX behavior: wait up to timeout_ms for input, then return 0.
    const wait_ms: windows.DWORD = if (timeout_ms < 0)
        windows.INFINITE
    else
        @intCast(timeout_ms);

    windows.WaitForSingleObject(state.stdin_handle, wait_ms) catch |err| switch (err) {
        error.WaitTimeOut => return 0,
        else => return 0,
    };

    const file_type = GetFileType(state.stdin_handle);

    // ConPTY/Windows Terminal can expose stdin as a pipe. Ensure there are bytes before reading.
    if (file_type == FILE_TYPE_PIPE) {
        var available: windows.DWORD = 0;
        if (PeekNamedPipe(state.stdin_handle, null, 0, null, &available, null) == 0 or available == 0) {
            return 0;
        }
    }

    // Console handles may wake due non-byte events (focus/menu/window-size). Drain those first.
    if (file_type == FILE_TYPE_CHAR and !hasReadableConsoleInput(state.stdin_handle)) {
        return 0;
    }

    // Read from the configured stdin handle after it is signaled as readable.
    const stdin: std.fs.File = .{ .handle = state.stdin_handle };
    return stdin.read(buffer) catch 0;
}

fn hasReadableConsoleInput(handle: windows.HANDLE) bool {
    var record_buf: [1]INPUT_RECORD = undefined;

    while (true) {
        var event_count: windows.DWORD = 0;
        if (GetNumberOfConsoleInputEvents(handle, &event_count) == 0 or event_count == 0) {
            return false;
        }

        var peeked: windows.DWORD = 0;
        if (PeekConsoleInputW(handle, &record_buf, 1, &peeked) == 0 or peeked == 0) {
            return false;
        }

        const record = record_buf[0];
        switch (record.EventType) {
            KEY_EVENT => {
                if (record.Event.KeyEvent.bKeyDown != 0) return true;
            },
            MOUSE_EVENT => return true,
            else => {},
        }

        var consumed: windows.DWORD = 0;
        if (ReadConsoleInputW(handle, &record_buf, 1, &consumed) == 0 or consumed == 0) {
            return false;
        }
    }
}

/// Flush output
pub fn flush(handle: windows.HANDLE) void {
    _ = handle;
    // Windows typically auto-flushes
}

/// Setup signal handlers (Windows uses console events differently)
pub fn setupSignals() !void {
    // Windows handles resize through WINDOW_BUFFER_SIZE_EVENT
    // This is handled in the input loop
}

/// Check if resize was signaled
pub fn checkResize() bool {
    // On Windows, resize is handled through console events
    return false;
}

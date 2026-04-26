//! POSIX terminal implementation for Unix-like systems.
//! Handles raw mode, terminal size, and signal handling.

const std = @import("std");
const posix = std.posix;
const ansi = @import("../ansi.zig");

pub const TerminalError = error{
    NotATty,
    GetAttrFailed,
    SetAttrFailed,
    IoctlFailed,
    PipeFailed,
    SignalSetupFailed,
};

/// Terminal size
pub const Size = struct {
    rows: u16,
    cols: u16,
};

/// Original terminal state for restoration
pub const State = struct {
    original_termios: ?posix.termios = null,
    in_raw_mode: bool = false,
    in_alt_screen: bool = false,
    mouse_enabled: bool = false,
    stdin_fd: posix.fd_t,
    stdout_fd: posix.fd_t,

    pub fn init() State {
        return .{
            .stdin_fd = posix.STDIN_FILENO,
            .stdout_fd = posix.STDOUT_FILENO,
        };
    }
};

/// Check if a file descriptor is a TTY
pub fn isTty(fd: posix.fd_t) bool {
    return posix.isatty(fd);
}

/// Get terminal size using ioctl (falls back to 80x24 for non-TTY)
pub fn getSize(fd: posix.fd_t) !Size {
    var wsz: posix.winsize = undefined;
    const result = posix.system.ioctl(fd, posix.T.IOCGWINSZ, @intFromPtr(&wsz));
    if (result != 0) {
        // Fallback to default size for non-TTY (e.g. pipes)
        if (!isTty(fd)) {
            return .{ .rows = 24, .cols = 80 };
        }
        return TerminalError.IoctlFailed;
    }
    return .{
        .rows = wsz.row,
        .cols = wsz.col,
    };
}

/// Enable raw mode on the terminal
pub fn enableRawMode(state: *State) !void {
    if (state.in_raw_mode) return;

    if (!isTty(state.stdin_fd)) {
        // Non-TTY (e.g. pipe) — skip raw mode setup but mark as active
        state.in_raw_mode = true;
        return;
    }

    // Save original settings
    state.original_termios = posix.tcgetattr(state.stdin_fd) catch {
        return TerminalError.GetAttrFailed;
    };

    var raw = state.original_termios.?;

    // Input flags: disable various input processing
    raw.iflag.BRKINT = false;
    raw.iflag.ICRNL = false;
    raw.iflag.INPCK = false;
    raw.iflag.ISTRIP = false;
    raw.iflag.IXON = false;

    // Output flags: disable output processing
    raw.oflag.OPOST = false;

    // Control flags: set 8-bit characters
    raw.cflag.CSIZE = .CS8;

    // Local flags: disable echo, canonical mode, signals, extended input
    raw.lflag.ECHO = false;
    raw.lflag.ICANON = false;
    raw.lflag.IEXTEN = false;
    raw.lflag.ISIG = false;

    // Control characters: set read timeout
    raw.cc[@intFromEnum(posix.V.MIN)] = 0;
    raw.cc[@intFromEnum(posix.V.TIME)] = 1; // 0.1 seconds

    posix.tcsetattr(state.stdin_fd, .FLUSH, raw) catch {
        return TerminalError.SetAttrFailed;
    };

    state.in_raw_mode = true;
}

/// Disable raw mode and restore original settings
pub fn disableRawMode(state: *State) void {
    if (!state.in_raw_mode) return;

    if (state.original_termios) |termios| {
        posix.tcsetattr(state.stdin_fd, .FLUSH, termios) catch {};
    }

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

    // Enable SGR mouse mode with all motion tracking
    try writer.writeAll("\x1b[?1003h\x1b[?1006h");
    state.mouse_enabled = true;
}

/// Disable mouse tracking
pub fn disableMouse(state: *State, writer: anytype) !void {
    if (!state.mouse_enabled) return;

    try writer.writeAll("\x1b[?1006l\x1b[?1003l");
    state.mouse_enabled = false;
}

/// Read available input with timeout
pub fn readInput(state: *State, buffer: []u8, timeout_ms: i32) !usize {
    var pollfds = [_]posix.pollfd{
        .{
            .fd = state.stdin_fd,
            .events = posix.POLL.IN,
            .revents = 0,
        },
    };

    const result = posix.poll(&pollfds, timeout_ms) catch return 0;

    if (result > 0 and (pollfds[0].revents & posix.POLL.IN) != 0) {
        return posix.read(state.stdin_fd, buffer) catch 0;
    }

    return 0;
}

/// Flush output
pub fn flush(fd: posix.fd_t) void {
    _ = posix.system.fsync(fd);
}

/// Signal handler state (for SIGWINCH)
var resize_signaled: std.atomic.Value(bool) = std.atomic.Value(bool).init(false);

/// Setup signal handlers
pub fn setupSignals() !void {
    const handler = posix.Sigaction{
        .handler = .{
            .handler = struct {
                fn handle(_: c_int) callconv(std.builtin.CallingConvention.c) void {
                    resize_signaled.store(true, .release);
                }
            }.handle,
        },
        .mask = posix.sigemptyset(),
        .flags = 0,
    };

    posix.sigaction(posix.SIG.WINCH, &handler, null);
}

/// Check if resize was signaled
pub fn checkResize() bool {
    return resize_signaled.swap(false, .acquire);
}

//! End-to-end live-TUI tests on a real Windows console.
//!
//! Mirror of tests/tui_pty_test.zig for the classic console path: the app
//! runs inside a headless `conhost.exe`, so its std handles are genuine
//! console handles — the same shape a user gets in cmd.exe or under
//! Windows Terminal. Input is injected as real `INPUT_RECORD`s via
//! `WriteConsoleInputW` (a MOUSE_EVENT_RECORD with MOUSE_WHEELED is exactly
//! what a wheel notch produces); output is read back as rendered cells via
//! `ReadConsoleOutputCharacterW` instead of byte-stream assertions.
//!
//! These tests only run on a real Windows host; nothing here is simulated.
//! A native `zig build test` covers them there, and WSL's interop layer
//! executes the cross-compiled test exes too (see docs/tests.md for the
//! staged-binary contract). On other hosts the cases skip at comptime.

const std = @import("std");
const builtin = @import("builtin");
const test_options = @import("test_options");
const app_runtime = @import("codex_auth").core.runtime;
const fs = @import("codex_auth").core.compat_fs;
const registry = @import("codex_auth").registry;
const fixtures = @import("support/fixtures.zig");
const win32 = @import("codex_auth").cli.tui.win32;

const windows = std.os.windows;

/// Same install-prefix contract as tests/tui_pty_test.zig: the launcher
/// points it at a directory containing bin/codex-auth.exe.
const cli_integration_install_prefix_env = "CODEX_AUTH_CLI_INTEGRATION_INSTALL_PREFIX";
const cli_integration_project_root_env = "CODEX_AUTH_CLI_INTEGRATION_PROJECT_ROOT";

const has_console = builtin.target.os.tag == .windows;

const GENERIC_READ_WRITE: windows.DWORD = 0xC000_0000;
const FILE_SHARE_READ_WRITE: windows.DWORD = 0x0000_0003;
const OPEN_EXISTING: windows.DWORD = 3;
const CREATE_UNICODE_ENVIRONMENT: windows.DWORD = 0x0000_0400;
const TH32CS_SNAPPROCESS: windows.DWORD = 0x0000_0002;
const INVALID_HANDLE_VALUE: windows.HANDLE = @ptrFromInt(std.math.maxInt(usize));

const CONSOLE_SCREEN_BUFFER_INFO = extern struct {
    dwSize: win32.COORD,
    dwCursorPosition: win32.COORD,
    wAttributes: windows.WORD,
    srWindow: extern struct {
        Left: i16,
        Top: i16,
        Right: i16,
        Bottom: i16,
    },
    dwMaximumWindowSize: win32.COORD,
};

const PROCESSENTRY32W = extern struct {
    dwSize: windows.DWORD,
    cntUsage: windows.DWORD,
    th32ProcessID: windows.DWORD,
    th32DefaultHeapID: usize,
    th32ModuleID: windows.DWORD,
    cntThreads: windows.DWORD,
    th32ParentProcessID: windows.DWORD,
    pcPriClassBase: i32,
    dwFlags: windows.DWORD,
    szExeFile: [260]u16,
};

extern "kernel32" fn CreateFileW(
    lpFileName: windows.LPCWSTR,
    dwDesiredAccess: windows.DWORD,
    dwShareMode: windows.DWORD,
    lpSecurityAttributes: ?*windows.SECURITY_ATTRIBUTES,
    dwCreationDisposition: windows.DWORD,
    dwFlagsAndAttributes: windows.DWORD,
    hTemplateFile: ?windows.HANDLE,
) callconv(.winapi) ?windows.HANDLE;
extern "kernel32" fn CreateProcessW(
    lpApplicationName: ?windows.LPCWSTR,
    lpCommandLine: ?windows.LPWSTR,
    lpProcessAttributes: ?*windows.SECURITY_ATTRIBUTES,
    lpThreadAttributes: ?*windows.SECURITY_ATTRIBUTES,
    bInheritHandles: windows.BOOL,
    dwCreationFlags: windows.DWORD,
    lpEnvironment: ?*const anyopaque,
    lpCurrentDirectory: ?windows.LPCWSTR,
    lpStartupInfo: *windows.STARTUPINFOW,
    lpProcessInformation: *windows.PROCESS.INFORMATION,
) callconv(.winapi) windows.BOOL;
extern "kernel32" fn CreateToolhelp32Snapshot(
    dwFlags: windows.DWORD,
    th32ProcessID: windows.DWORD,
) callconv(.winapi) ?windows.HANDLE;
extern "kernel32" fn Process32FirstW(
    hSnapshot: windows.HANDLE,
    lppe: *PROCESSENTRY32W,
) callconv(.winapi) windows.BOOL;
extern "kernel32" fn Process32NextW(
    hSnapshot: windows.HANDLE,
    lppe: *PROCESSENTRY32W,
) callconv(.winapi) windows.BOOL;
extern "kernel32" fn AttachConsole(dwProcessId: windows.DWORD) callconv(.winapi) windows.BOOL;
extern "kernel32" fn FreeConsole() callconv(.winapi) windows.BOOL;
extern "kernel32" fn WriteConsoleInputW(
    hConsoleInput: windows.HANDLE,
    lpBuffer: [*]const win32.INPUT_RECORD,
    nLength: windows.DWORD,
    lpNumberOfEventsWritten: *windows.DWORD,
) callconv(.winapi) windows.BOOL;
extern "kernel32" fn ReadConsoleOutputCharacterW(
    hConsoleOutput: windows.HANDLE,
    lpCharacter: [*]u16,
    nLength: windows.DWORD,
    dwReadCoord: win32.COORD,
    lpNumberOfCharsRead: *windows.DWORD,
) callconv(.winapi) windows.BOOL;
extern "kernel32" fn GetConsoleScreenBufferInfo(
    hConsoleOutput: windows.HANDLE,
    lpConsoleScreenBufferInfo: *CONSOLE_SCREEN_BUFFER_INFO,
) callconv(.winapi) windows.BOOL;
extern "kernel32" fn WaitForSingleObject(
    hHandle: windows.HANDLE,
    dwMilliseconds: windows.DWORD,
) callconv(.winapi) windows.DWORD;
extern "kernel32" fn TerminateProcess(
    hProcess: windows.HANDLE,
    uExitCode: windows.UINT,
) callconv(.winapi) windows.BOOL;
extern "kernel32" fn GetExitCodeProcess(
    hProcess: windows.HANDLE,
    lpExitCode: *windows.DWORD,
) callconv(.winapi) windows.BOOL;
extern "kernel32" fn GetLastError() callconv(.winapi) windows.DWORD;
extern "kernel32" fn Sleep(dwMilliseconds: windows.DWORD) callconv(.winapi) void;
extern "kernel32" fn OpenProcess(
    dwDesiredAccess: windows.DWORD,
    bInheritHandle: windows.BOOL,
    dwProcessId: windows.DWORD,
) callconv(.winapi) ?windows.HANDLE;

const PROCESS_SYNC_QUERY: windows.DWORD = 0x0010_1000;

const console_deadline_ms: i64 = 30_000;

fn nowMs() i64 {
    return std.Io.Timestamp.now(fs.io(), .awake).toMilliseconds();
}

const HostedChild = struct {
    /// The hosting conhost process — it exits when the app inside does.
    process: windows.HANDLE,
    thread: windows.HANDLE,
    pid: windows.DWORD,
    /// The app running inside the console.
    app_pid: windows.DWORD,

    /// Waits on the app inside the console, not the host: conhost outlives
    /// its app whenever this test process is still attached, so its handle
    /// alone can never prove the app exited.
    fn waitAppExit(self: HostedChild, timeout_ms: windows.DWORD) !windows.DWORD {
        const app = OpenProcess(PROCESS_SYNC_QUERY, .FALSE, self.app_pid) orelse
            return error.OpenProcessFailed;
        defer windows.CloseHandle(app);
        if (WaitForSingleObject(app, timeout_ms) != 0) return error.ProcessWaitTimeout;
        var code: windows.DWORD = 0;
        if (GetExitCodeProcess(app, &code) == .FALSE) return error.ExitCodeFailed;
        return code;
    }

    fn kill(self: HostedChild) void {
        if (OpenProcess(PROCESS_SYNC_QUERY | 0x1, .FALSE, self.app_pid)) |app| {
            _ = TerminateProcess(app, 1);
            windows.CloseHandle(app);
        }
        _ = TerminateProcess(self.process, 1);
    }

    fn deinit(self: HostedChild) void {
        windows.CloseHandle(self.process);
        windows.CloseHandle(self.thread);
    }
};

/// Finds the pid of `exe_name` whose parent is `parent_pid`.
fn findChildPid(exe_name: []const u8, parent_pid: windows.DWORD) ?windows.DWORD {
    const snapshot = CreateToolhelp32Snapshot(TH32CS_SNAPPROCESS, 0) orelse return null;
    if (snapshot == INVALID_HANDLE_VALUE) return null;
    defer windows.CloseHandle(snapshot);
    var entry: PROCESSENTRY32W = std.mem.zeroes(PROCESSENTRY32W);
    entry.dwSize = @sizeOf(PROCESSENTRY32W);
    if (Process32FirstW(snapshot, &entry) == .FALSE) return null;
    while (true) {
        if (entry.th32ParentProcessID == parent_pid) {
            const name_len = std.mem.indexOfScalar(u16, &entry.szExeFile, 0) orelse entry.szExeFile.len;
            var name_buf: [260]u8 = undefined;
            const utf8_len = std.unicode.utf16LeToUtf8(&name_buf, entry.szExeFile[0..name_len]) catch 0;
            if (std.ascii.eqlIgnoreCase(name_buf[0..utf8_len], exe_name)) return entry.th32ProcessID;
        }
        if (Process32NextW(snapshot, &entry) == .FALSE) return null;
    }
}

/// Builds the UTF-16 double-null-terminated environment block
/// CreateProcessW expects under CREATE_UNICODE_ENVIRONMENT.
fn buildEnvBlock(allocator: std.mem.Allocator, pairs: []const [2][]const u8) !std.ArrayList(u16) {
    var block: std.ArrayList(u16) = .empty;
    errdefer block.deinit(allocator);
    for (pairs) |pair| {
        const entry = try std.fmt.allocPrint(allocator, "{s}={s}", .{ pair[0], pair[1] });
        defer allocator.free(entry);
        const wide = try std.unicode.utf8ToUtf16LeAlloc(allocator, entry);
        defer allocator.free(wide);
        try block.appendSlice(allocator, wide);
        try block.append(allocator, 0);
    }
    try block.append(allocator, 0);
    return block;
}

/// Spawns `codex-auth list --live --skip-api` inside a headless conhost.
/// The app sees a real console: stdin/out are FILE_TYPE_CHAR handles and
/// console APIs work — WriteConsoleInputW and ReadConsoleOutput are the
/// harness's only way in and out, same as a real console user.
fn spawnHostedList(
    allocator: std.mem.Allocator,
    exe: []const u8,
    home: []const u8,
    codex_home: []const u8,
) !HostedChild {
    var env_block = try buildEnvBlock(allocator, &.{
        .{ "USERPROFILE", home },
        .{ "HOME", home },
        .{ "CODEX_HOME", codex_home },
        .{ "TEMP", home },
        .{ "TMP", home },
        .{ "SystemRoot", "C:\\Windows" },
        .{ "PATH", "C:\\Windows\\System32" },
    });
    defer env_block.deinit(allocator);

    const cmdline = try std.fmt.allocPrint(
        allocator,
        "conhost.exe --headless \"{s}\" list --live --skip-api",
        .{exe},
    );
    defer allocator.free(cmdline);
    const cmd_w = try std.unicode.utf8ToUtf16LeAllocZ(allocator, cmdline);
    defer allocator.free(cmd_w);

    var si: windows.STARTUPINFOW = std.mem.zeroes(windows.STARTUPINFOW);
    si.cb = @sizeOf(windows.STARTUPINFOW);
    var pi: windows.PROCESS.INFORMATION = undefined;
    if (CreateProcessW(
        null,
        cmd_w.ptr,
        null,
        null,
        .FALSE,
        CREATE_UNICODE_ENVIRONMENT,
        env_block.items.ptr,
        null,
        &si,
        &pi,
    ) == .FALSE) return error.SpawnFailed;
    errdefer {
        _ = TerminateProcess(pi.hProcess, 1);
        windows.CloseHandle(pi.hProcess);
        windows.CloseHandle(pi.hThread);
    }

    // The app is conhost's child; poll until the process table shows it.
    const deadline = nowMs() + console_deadline_ms;
    var app_pid: ?windows.DWORD = null;
    while (app_pid == null and nowMs() < deadline) {
        app_pid = findChildPid("codex-auth.exe", pi.dwProcessId);
        if (app_pid == null) Sleep(50);
    }
    return .{
        .process = pi.hProcess,
        .thread = pi.hThread,
        .pid = pi.dwProcessId,
        .app_pid = app_pid orelse return error.HostedAppNotFound,
    };
}

const Console = struct {
    /// Input buffer — inject INPUT_RECORDs here.
    input: windows.HANDLE,
    /// Screen buffer — rendered frames live here.
    output: windows.HANDLE,

    /// Attaches this process to the app's console and opens CONIN$/CONOUT$.
    fn attach(app_pid: windows.DWORD) !Console {
        _ = FreeConsole();
        var attempts: usize = 0;
        while (AttachConsole(app_pid) == .FALSE) {
            attempts += 1;
            if (attempts > 100) return error.AttachConsoleFailed;
            Sleep(20);
        }
        var sa: windows.SECURITY_ATTRIBUTES = .{
            .nLength = @sizeOf(windows.SECURITY_ATTRIBUTES),
            .lpSecurityDescriptor = null,
            .bInheritHandle = .TRUE,
        };
        const input = CreateFileW(
            std.unicode.utf8ToUtf16LeStringLiteral("CONIN$"),
            GENERIC_READ_WRITE,
            FILE_SHARE_READ_WRITE,
            &sa,
            OPEN_EXISTING,
            0,
            null,
        ) orelse {
            std.debug.print("CONIN$ open failed: GetLastError={d}\n", .{GetLastError()});
            return error.ConInFailed;
        };
        if (@intFromPtr(input) == std.math.maxInt(usize)) {
            std.debug.print("CONIN$ open failed: GetLastError={d}\n", .{GetLastError()});
            return error.ConInFailed;
        }
        const output = CreateFileW(
            std.unicode.utf8ToUtf16LeStringLiteral("CONOUT$"),
            GENERIC_READ_WRITE,
            FILE_SHARE_READ_WRITE,
            &sa,
            OPEN_EXISTING,
            0,
            null,
        ) orelse {
            std.debug.print("CONOUT$ open failed: GetLastError={d}\n", .{GetLastError()});
            windows.CloseHandle(input);
            return error.ConOutFailed;
        };
        if (@intFromPtr(output) == std.math.maxInt(usize)) {
            std.debug.print("CONOUT$ open failed: GetLastError={d}\n", .{GetLastError()});
            windows.CloseHandle(input);
            return error.ConOutFailed;
        }
        // Stay attached: FreeConsole detaches the session and the freshly
        // opened CONIN$/CONOUT$ handles die with it (ERROR_INVALID_HANDLE).
        // An extra attached client is invisible to the app.
        return .{ .input = input, .output = output };
    }

    fn deinit(self: Console) void {
        windows.CloseHandle(self.input);
        windows.CloseHandle(self.output);
        _ = FreeConsole();
    }

    fn inject(self: Console, records: []const win32.INPUT_RECORD) !void {
        var written: windows.DWORD = 0;
        if (WriteConsoleInputW(self.input, records.ptr, @intCast(records.len), &written) == .FALSE)
            return error.ConsoleInputFailed;
    }

    /// Reads the screen buffer's character cells as ASCII (markers and the
    /// table are plain text; cells outside ASCII fold to ' ').
    fn bufferText(self: Console, out: *std.ArrayList(u8)) !void {
        var info: CONSOLE_SCREEN_BUFFER_INFO = undefined;
        if (GetConsoleScreenBufferInfo(self.output, &info) == .FALSE) {
            std.debug.print("GetConsoleScreenBufferInfo failed: GetLastError={d}\n", .{GetLastError()});
            return error.ConsoleInfoFailed;
        }
        const cell_count: usize = @as(usize, @intCast(info.dwSize.X)) * @as(usize, @intCast(info.dwSize.Y));
        const cells = try std.testing.allocator.alloc(u16, cell_count);
        defer std.testing.allocator.free(cells);
        var read_n: windows.DWORD = 0;
        if (ReadConsoleOutputCharacterW(
            self.output,
            cells.ptr,
            @intCast(cells.len),
            .{ .X = 0, .Y = 0 },
            &read_n,
        ) == .FALSE) {
            std.debug.print("ReadConsoleOutputCharacterW failed: GetLastError={d}\n", .{GetLastError()});
            return error.ConsoleReadFailed;
        }
        out.clearRetainingCapacity();
        for (cells[0..read_n]) |cell|
            try out.append(std.testing.allocator, if (cell < 0x80) @intCast(cell) else ' ');
    }
};

/// Reads the console buffer until `needle` appears or the deadline passes.
fn waitBufferMarker(console: Console, buf: *std.ArrayList(u8), needle: []const u8, deadline_ms: i64) !void {
    while (true) {
        try console.bufferText(buf);
        if (std.mem.indexOf(u8, buf.items, needle) != null) return;
        if (nowMs() >= deadline_ms) {
            std.debug.print("marker '{s}' not found; buffer:\n{s}\n", .{ needle, buf.items });
            return error.ConsoleTimeout;
        }
        Sleep(50);
    }
}

fn wheelRecord(delta: i16) win32.INPUT_RECORD {
    return .{
        .EventType = win32.MOUSE_EVENT,
        .Event = .{ .MouseEvent = .{
            .dwMousePosition = .{ .X = 10, .Y = 5 },
            .dwButtonState = @as(u32, @bitCast(@as(u32, @bitCast(@as(i32, delta))) << 16)),
            .dwControlKeyState = 0,
            .dwEventFlags = win32.MOUSE_WHEELED,
        } },
    };
}

fn keyRecord(char: u8) win32.INPUT_RECORD {
    return .{
        .EventType = win32.KEY_EVENT,
        .Event = .{ .KeyEvent = .{
            .bKeyDown = .TRUE,
            .wRepeatCount = 1,
            .wVirtualKeyCode = std.ascii.toUpper(char),
            .wVirtualScanCode = 0,
            .uChar = .{ .UnicodeChar = char },
            .dwControlKeyState = 0,
        } },
    };
}

/// Same resolution contract as `builtCliPathAlloc` in tui_pty_test.zig:
/// the staged install prefix wins, otherwise fall back to the project's
/// own zig-out so a native `zig build test` needs no staging.
fn exePathAlloc(allocator: std.mem.Allocator) ![]u8 {
    const prefix = app_runtime.getEnvVarOwned(allocator, cli_integration_install_prefix_env) catch |err| switch (err) {
        error.EnvironmentVariableNotFound => null,
        else => return err,
    };
    defer if (prefix) |dir| allocator.free(dir);
    if (prefix) |dir| return fs.path.join(allocator, &.{ dir, "bin", "codex-auth.exe" });

    const project_root = app_runtime.getEnvVarOwned(allocator, cli_integration_project_root_env) catch |err| switch (err) {
        error.EnvironmentVariableNotFound => null,
        else => return err,
    };
    defer if (project_root) |dir| allocator.free(dir);
    const root = project_root orelse try fs.realpathAlloc(allocator, test_options.project_root);
    defer if (project_root == null) allocator.free(root);
    return fs.path.join(allocator, &.{ root, "zig-out", "bin", "codex-auth.exe" });
}

fn seedAccounts(allocator: std.mem.Allocator, codex_home: []const u8, count: usize) !void {
    var reg = fixtures.makeEmptyRegistry();
    defer reg.deinit(allocator);
    const emails = try allocator.alloc([]u8, count);
    defer {
        for (emails) |email| allocator.free(email);
        allocator.free(emails);
    }
    for (emails, 0..) |*email, i| {
        email.* = try std.fmt.allocPrint(allocator, "user{d:0>2}@example.com", .{i});
        const alias = try std.fmt.allocPrint(allocator, "u{d:0>2}", .{i});
        defer allocator.free(alias);
        try fixtures.appendAccount(allocator, &reg, email.*, alias, null);
    }
    try registry.saveRegistry(allocator, codex_home, &reg);
    // Rows only render from stored auth files, the same way the integration
    // fixtures seed them; the registry alone is not enough.
    for (emails) |email| {
        const key = try fixtures.accountKeyForEmailAlloc(allocator, email);
        defer allocator.free(key);
        const path = try registry.accountAuthPath(allocator, codex_home, key);
        defer allocator.free(path);
        const data = try fixtures.authJsonWithEmailPlan(allocator, email, "plus");
        defer allocator.free(data);
        try fs.cwd().writeFile(.{ .sub_path = path, .data = data });
    }
}

fn setupHostedSession(gpa: std.mem.Allocator, account_count: usize) !struct {
    child: HostedChild,
    console: Console,
    buffer: std.ArrayList(u8),
    deadline_ms: i64,
    tmp: fs.TmpDir,
} {
    const exe = try exePathAlloc(gpa);
    defer gpa.free(exe);
    var tmp = fs.tmpDir(.{});
    errdefer tmp.cleanup();
    const home = try tmp.dir.realpathAlloc(gpa, ".");
    defer gpa.free(home);
    const codex_home = try fs.path.join(gpa, &.{ home, ".codex" });
    defer gpa.free(codex_home);
    try tmp.dir.makePath(".codex");
    try seedAccounts(gpa, codex_home, account_count);

    const child = try spawnHostedList(gpa, exe, home, codex_home);
    errdefer {
        child.kill();
        child.deinit();
    }
    const console = try Console.attach(child.app_pid);
    return .{
        .child = child,
        .console = console,
        .buffer = .empty,
        .deadline_ms = nowMs() + console_deadline_ms,
        .tmp = tmp,
    };
}

test "console: live list renders on a real console and q exits" {
    if (comptime !has_console) return error.SkipZigTest;
    const gpa = std.testing.allocator;
    var session = try setupHostedSession(gpa, 3);
    defer {
        session.console.deinit();
        session.child.deinit();
        session.buffer.deinit(gpa);
        session.tmp.cleanup();
    }

    try waitBufferMarker(session.console, &session.buffer, "ACCOUNT", session.deadline_ms);
    try waitBufferMarker(session.console, &session.buffer, "user00@example.com", session.deadline_ms);
    try session.console.inject(&.{keyRecord('q')});

    const code = session.child.waitAppExit(console_deadline_ms) catch |err| {
        session.child.kill();
        return err;
    };
    try std.testing.expectEqual(@as(windows.DWORD, 0), code);
}

test "console: injected MOUSE_WHEELED records scroll the live list" {
    if (comptime !has_console) return error.SkipZigTest;
    const gpa = std.testing.allocator;
    var session = try setupHostedSession(gpa, 40);
    defer {
        session.console.deinit();
        session.child.deinit();
        session.buffer.deinit(gpa);
        session.tmp.cleanup();
    }

    try waitBufferMarker(session.console, &session.buffer, "user00@example.com", session.deadline_ms);

    // A dense burst of wheel-down records — one MOUSE_EVENT_RECORD per
    // notch, exactly what the console delivers for a flick — should scroll
    // the viewport until the tail rows are visible.
    var records: [30]win32.INPUT_RECORD = undefined;
    for (&records) |*record| record.* = wheelRecord(-120);
    try session.console.inject(&records);

    try waitBufferMarker(session.console, &session.buffer, "user39@example.com", session.deadline_ms);
    try session.console.inject(&.{keyRecord('q')});

    const code = session.child.waitAppExit(console_deadline_ms) catch |err| {
        session.child.kill();
        return err;
    };
    try std.testing.expectEqual(@as(windows.DWORD, 0), code);
}

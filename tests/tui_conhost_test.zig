//! End-to-end live-TUI tests on a real Windows console.
//!
//! Mirror of tests/tui_pty_test.zig for the classic console path: the app
//! runs inside a headless `conhost.exe`, so its std handles are genuine
//! console handles — the same shape a user gets in cmd.exe or under
//! Windows Terminal. Input is injected as real `INPUT_RECORD`s via
//! `WriteConsoleInputW` (a MOUSE_EVENT_RECORD with MOUSE_WHEELED is exactly
//! what a wheel notch produces); output is read back as rendered cells via
//! `ReadConsoleOutputCharacterW` instead of byte-stream assertions.
//! One scenario also hosts the app through real shells (powershell.exe /
//! pwsh.exe) to cover the realistic launch chain — those children need
//! the inherited user environment to start, so shell legs build the env
//! block from the parent's rather than a minimal one.
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

const SMALL_RECT = extern struct {
    Left: i16,
    Top: i16,
    Right: i16,
    Bottom: i16,
};

const CONSOLE_SCREEN_BUFFER_INFO = extern struct {
    dwSize: win32.COORD,
    dwCursorPosition: win32.COORD,
    wAttributes: windows.WORD,
    srWindow: SMALL_RECT,
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
const PROCESS_TERMINATE: windows.DWORD = 0x0000_0001;

const console_deadline_ms: i64 = 30_000;

var headless_probe_done = false;
var headless_probe_mutex: std.Io.Mutex = .init;

fn nowMs() i64 {
    return std.Io.Timestamp.now(fs.io(), .awake).toMilliseconds();
}

/// Older conhost builds exit immediately on `--headless`. Probe once with
/// a trivial inner command — a liveness check on the flag, not a shell
/// leg — so unsupported hosts skip cleanly instead of failing every
/// hosted test on the descendant-poll deadline.
fn ensureHeadlessConhost(allocator: std.mem.Allocator) !void {
    headless_probe_mutex.lockUncancelable(fs.io());
    defer headless_probe_mutex.unlock(fs.io());
    if (headless_probe_done) return;

    const cmd_w = try std.unicode.utf8ToUtf16LeAllocZ(allocator, "conhost.exe --headless cmd.exe /c exit");
    defer allocator.free(cmd_w);
    var si: windows.STARTUPINFOW = std.mem.zeroes(windows.STARTUPINFOW);
    si.cb = @sizeOf(windows.STARTUPINFOW);
    var pi: windows.PROCESS.INFORMATION = undefined;
    if (CreateProcessW(null, cmd_w.ptr, null, null, .FALSE, 0, null, null, &si, &pi) == .FALSE) {
        std.debug.print("conhost could not be spawned; skipping\n", .{});
        return error.SkipZigTest;
    }
    defer windows.CloseHandle(pi.hProcess);
    defer windows.CloseHandle(pi.hThread);
    if (WaitForSingleObject(pi.hProcess, 10_000) != 0) {
        _ = TerminateProcess(pi.hProcess, 1);
        std.debug.print("conhost --headless probe did not exit; skipping\n", .{});
        return error.SkipZigTest;
    }
    var code: windows.DWORD = 0;
    if (GetExitCodeProcess(pi.hProcess, &code) == .FALSE or code != 0) {
        std.debug.print("conhost --headless unsupported on this host (exit={d}); skipping\n", .{code});
        return error.SkipZigTest;
    }
    headless_probe_done = true;
}

const HostedChild = struct {
    /// The hosting conhost process — it exits when the app inside does.
    process: windows.HANDLE,
    thread: windows.HANDLE,
    pid: windows.DWORD,
    /// The app running inside the console.
    app_pid: windows.DWORD,
    /// Kept open for the session so a recycled pid can never be mistaken
    /// for the app — SYNCHRONIZE|QUERY_LIMITED|TERMINATE rights.
    app: windows.HANDLE,

    /// Waits on the app inside the console, not the host: conhost outlives
    /// its app whenever this test process is still attached, so its handle
    /// alone can never prove the app exited.
    fn waitAppExit(self: HostedChild, timeout_ms: windows.DWORD) !windows.DWORD {
        if (WaitForSingleObject(self.app, timeout_ms) != 0) return error.ProcessWaitTimeout;
        var code: windows.DWORD = 0;
        if (GetExitCodeProcess(self.app, &code) == .FALSE) return error.ExitCodeFailed;
        return code;
    }

    fn kill(self: HostedChild) void {
        _ = TerminateProcess(self.app, 1);
        _ = TerminateProcess(self.process, 1);
        // TerminateProcess returns before teardown finishes; a tmp cleanup
        // right after this would race files the dying process still holds.
        _ = WaitForSingleObject(self.app, 2000);
        _ = WaitForSingleObject(self.process, 2000);
    }

    fn deinit(self: HostedChild) void {
        windows.CloseHandle(self.process);
        windows.CloseHandle(self.thread);
        windows.CloseHandle(self.app);
    }
};

const ProcEntry = struct {
    pid: windows.DWORD,
    ppid: windows.DWORD,
    is_target: bool,
};

/// Finds the pid of `exe_name` anywhere under `ancestor_pid`'s process
/// tree — the app may sit behind an intermediate shell when the scenario
/// hosts it through powershell.
fn findDescendantPid(allocator: std.mem.Allocator, exe_name: []const u8, ancestor_pid: windows.DWORD) !?windows.DWORD {
    const snapshot = CreateToolhelp32Snapshot(TH32CS_SNAPPROCESS, 0) orelse return null;
    if (snapshot == INVALID_HANDLE_VALUE) return null;
    defer windows.CloseHandle(snapshot);

    var procs: std.ArrayList(ProcEntry) = .empty;
    defer procs.deinit(allocator);

    var entry: PROCESSENTRY32W = std.mem.zeroes(PROCESSENTRY32W);
    entry.dwSize = @sizeOf(PROCESSENTRY32W);
    if (Process32FirstW(snapshot, &entry) == .FALSE) return null;
    while (true) {
        const name_len = std.mem.indexOfScalar(u16, &entry.szExeFile, 0) orelse entry.szExeFile.len;
        var name_buf: [260]u8 = undefined;
        const utf8_len = std.unicode.utf16LeToUtf8(&name_buf, entry.szExeFile[0..name_len]) catch 0;
        try procs.append(allocator, .{
            .pid = entry.th32ProcessID,
            .ppid = entry.th32ParentProcessID,
            .is_target = std.ascii.eqlIgnoreCase(name_buf[0..utf8_len], exe_name),
        });
        if (Process32NextW(snapshot, &entry) == .FALSE) break;
    }

    for (procs.items) |proc| {
        if (!proc.is_target) continue;
        var cursor = proc.ppid;
        var depth: usize = 0;
        while (depth < 16) : (depth += 1) {
            if (cursor == ancestor_pid) return proc.pid;
            cursor = for (procs.items) |parent| {
                if (parent.pid == cursor) break parent.ppid;
            } else break;
        }
    }
    return null;
}

/// Builds the UTF-16 double-null-terminated environment block
/// CreateProcessW expects under CREATE_UNICODE_ENVIRONMENT. With
/// `inherit`, the block starts from this process's own environment — a
/// real user session needs vars like SystemDrive/PSModulePath/APPDATA
/// that a minimal block lacks (powershell.exe refuses to start without
/// them). `pairs` override matching keys case-insensitively.
fn buildEnvBlock(
    allocator: std.mem.Allocator,
    pairs: []const [2][]const u8,
    inherit: bool,
) !std.ArrayList(u16) {
    var merged: std.ArrayList([2][]const u8) = .empty;
    defer merged.deinit(allocator);
    var seen: std.StringHashMap(void) = .init(allocator);
    defer seen.deinit();
    var seen_keys: std.ArrayList([]const u8) = .empty;
    defer {
        for (seen_keys.items) |key| allocator.free(key);
        seen_keys.deinit(allocator);
    }

    // `merged` borrows the map's key/value slices, so the map must stay
    // alive until the UTF-16 block is built.
    var env_map: ?std.process.Environ.Map = null;
    defer if (env_map) |*map| map.deinit();

    for (pairs) |pair| {
        const lower = try std.ascii.allocLowerString(allocator, pair[0]);
        try seen.put(lower, {});
        try seen_keys.append(allocator, lower);
    }
    if (inherit) {
        env_map = try app_runtime.getEnvMap(allocator);
        var it = env_map.?.iterator();
        while (it.next()) |entry| {
            const lower = try std.ascii.allocLowerString(allocator, entry.key_ptr.*);
            if (seen.contains(lower)) {
                allocator.free(lower);
                continue;
            }
            try seen.put(lower, {});
            try seen_keys.append(allocator, lower);
            try merged.append(allocator, .{ entry.key_ptr.*, entry.value_ptr.* });
        }
    }
    try merged.appendSlice(allocator, pairs);
    // CreateProcessW's environment block must be alphabetically sorted.
    std.mem.sort([2][]const u8, merged.items, {}, envEntryLessThan);
    return buildUtf16Block(allocator, merged.items);
}

fn envEntryLessThan(_: void, a: [2][]const u8, b: [2][]const u8) bool {
    const n = @min(a[0].len, b[0].len);
    for (a[0][0..n], b[0][0..n]) |ca, cb| {
        const la = std.ascii.toLower(ca);
        const lb = std.ascii.toLower(cb);
        if (la != lb) return la < lb;
    }
    return a[0].len < b[0].len;
}

fn buildUtf16Block(allocator: std.mem.Allocator, pairs: []const [2][]const u8) !std.ArrayList(u16) {
    var block: std.ArrayList(u16) = .empty;
    errdefer block.deinit(allocator);
    for (pairs) |pair| {
        const entry = try std.fmt.allocPrint(allocator, "{s}={s}", .{ pair[0], pair[1] });
        defer allocator.free(entry);
        // Inherited env vars can carry non-UTF-8 bytes; a var we can't
        // encode is dropped rather than failing the whole block.
        const wide = std.unicode.utf8ToUtf16LeAlloc(allocator, entry) catch |err| switch (err) {
            error.InvalidUtf8 => continue,
            else => return err,
        };
        defer allocator.free(wide);
        try block.appendSlice(allocator, wide);
        try block.append(allocator, 0);
    }
    try block.append(allocator, 0);
    return block;
}

/// Spawns an inner command line inside a headless conhost — either the app
/// itself or a shell that launches it. The app sees a real console:
/// stdin/out are FILE_TYPE_CHAR handles and console APIs work —
/// WriteConsoleInputW and ReadConsoleOutput are the harness's only way in
/// and out, same as a real console user.
fn spawnHosted(
    allocator: std.mem.Allocator,
    inner_cmdline: []const u8,
    home: []const u8,
    codex_home: []const u8,
    extra_path_dirs: []const []const u8,
    inherit_env: bool,
) !HostedChild {
    var path: std.ArrayList(u8) = .empty;
    defer path.deinit(allocator);
    try path.appendSlice(allocator, "C:\\Windows\\System32;C:\\Windows\\System32\\WindowsPowerShell\\v1.0");
    for (extra_path_dirs) |dir| {
        try path.append(allocator, ';');
        try path.appendSlice(allocator, dir);
    }

    var env_block = try buildEnvBlock(allocator, &.{
        .{ "USERPROFILE", home },
        .{ "HOME", home },
        .{ "CODEX_HOME", codex_home },
        .{ "TEMP", home },
        .{ "TMP", home },
        .{ "SystemRoot", "C:\\Windows" },
        .{ "PATH", path.items },
    }, inherit_env);
    defer env_block.deinit(allocator);

    const cmdline = try std.fmt.allocPrint(
        allocator,
        "conhost.exe --headless {s}",
        .{inner_cmdline},
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

    // The app may sit behind an intermediate shell; poll the process tree
    // until codex-auth.exe shows up under this conhost. A conhost that
    // exits first means the inner command failed outright — no point
    // waiting out the deadline for an app that can never appear.
    const deadline = nowMs() + console_deadline_ms;
    var app_pid: ?windows.DWORD = null;
    while (app_pid == null and nowMs() < deadline) {
        app_pid = try findDescendantPid(allocator, "codex-auth.exe", pi.dwProcessId);
        if (app_pid != null) break;
        if (WaitForSingleObject(pi.hProcess, 0) == 0) {
            std.debug.print("conhost exited before hosting the app\n", .{});
            break;
        }
        Sleep(50);
    }
    if (app_pid == null) {
        // Diagnostic: list whatever actually appeared under the host.
        if (CreateToolhelp32Snapshot(TH32CS_SNAPPROCESS, 0)) |snapshot| {
            if (snapshot != INVALID_HANDLE_VALUE) {
                defer windows.CloseHandle(snapshot);
                var entry: PROCESSENTRY32W = std.mem.zeroes(PROCESSENTRY32W);
                entry.dwSize = @sizeOf(PROCESSENTRY32W);
                var have = Process32FirstW(snapshot, &entry) != .FALSE;
                while (have) : (have = Process32NextW(snapshot, &entry) != .FALSE) {
                    const name_len = std.mem.indexOfScalar(u16, &entry.szExeFile, 0) orelse entry.szExeFile.len;
                    var name_buf: [260]u8 = undefined;
                    const utf8_len = std.unicode.utf16LeToUtf8(&name_buf, entry.szExeFile[0..name_len]) catch 0;
                    if (entry.th32ParentProcessID == pi.dwProcessId)
                        std.debug.print("hosted child: pid={} name={s}\n", .{ entry.th32ProcessID, name_buf[0..utf8_len] });
                }
            }
        }
        if (try findDescendantPid(allocator, "powershell.exe", pi.dwProcessId)) |shell_pid| {
            if (Console.attach(shell_pid)) |console| {
                defer console.deinit();
                var buf: std.ArrayList(u8) = .empty;
                defer buf.deinit(allocator);
                console.bufferText(&buf) catch {};
                std.debug.print("console buffer:\n{s}\n", .{buf.items});
            } else |attach_err| {
                std.debug.print("attach diagnostic failed: {s}\n", .{@errorName(attach_err)});
            }
        }
        return error.HostedAppNotFound;
    }
    const app_handle = OpenProcess(PROCESS_SYNC_QUERY | PROCESS_TERMINATE, .FALSE, app_pid.?) orelse
        return error.HostedAppNotFound;
    return .{
        .process = pi.hProcess,
        .thread = pi.hThread,
        .pid = pi.dwProcessId,
        .app_pid = app_pid.?,
        .app = app_handle,
    };
}

fn spawnHostedList(
    allocator: std.mem.Allocator,
    exe: []const u8,
    home: []const u8,
    codex_home: []const u8,
) !HostedChild {
    const inner = try std.fmt.allocPrint(allocator, "\"{s}\" list --live --skip-api", .{exe});
    defer allocator.free(inner);
    return spawnHosted(allocator, inner, home, codex_home, &.{}, false);
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
        if (written != records.len) return error.ConsoleInputTruncated;
    }

    /// Reads the screen buffer's character cells as ASCII (markers and the
    /// table are plain text; cells outside ASCII fold to ' ').
    fn bufferText(self: Console, out: *std.ArrayList(u8)) !void {
        var info: CONSOLE_SCREEN_BUFFER_INFO = undefined;
        if (GetConsoleScreenBufferInfo(self.output, &info) == .FALSE) {
            std.debug.print("GetConsoleScreenBufferInfo failed: GetLastError={d}\n", .{GetLastError()});
            return error.ConsoleInfoFailed;
        }
        // Only the visible window matters — a marker must be on screen,
        // and the full scroll buffer can hold a million stale cells.
        const width: usize = std.math.cast(usize, info.dwSize.X) orelse return error.ConsoleInfoFailed;
        const rows: usize = std.math.cast(usize, @as(i32, info.srWindow.Bottom) - info.srWindow.Top + 1) orelse return error.ConsoleInfoFailed;
        const cells = try std.testing.allocator.alloc(u16, width * rows);
        defer std.testing.allocator.free(cells);
        var read_n: windows.DWORD = 0;
        if (ReadConsoleOutputCharacterW(
            self.output,
            cells.ptr,
            @intCast(cells.len),
            .{ .X = 0, .Y = info.srWindow.Top },
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

/// A key record whose virtual key and translated character deliberately
/// disagree — Ctrl+C is exactly this shape (VK 'C' + uChar 0x03), and a
/// dead key carries uChar 0.
fn keyRecordShaped(vk: u8, uchar: u16, ctrl_state: u32) win32.INPUT_RECORD {
    return .{
        .EventType = win32.KEY_EVENT,
        .Event = .{ .KeyEvent = .{
            .bKeyDown = .TRUE,
            .wRepeatCount = 1,
            .wVirtualKeyCode = vk,
            .wVirtualScanCode = 0,
            .uChar = .{ .UnicodeChar = uchar },
            .dwControlKeyState = ctrl_state,
        } },
    };
}

fn resizeRecord(cols: i16, rows: i16) win32.INPUT_RECORD {
    return .{
        .EventType = win32.WINDOW_BUFFER_SIZE_EVENT,
        .Event = .{ .WindowBufferSizeEvent = .{ .dwSize = .{ .X = cols, .Y = rows } } },
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
    var filled: usize = 0;
    defer {
        for (emails[0..filled]) |email| allocator.free(email);
        allocator.free(emails);
    }
    for (emails, 0..) |*email, i| {
        email.* = try std.fmt.allocPrint(allocator, "user{d:0>2}@example.com", .{i});
        filled += 1;
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

fn setupHostedSession(
    gpa: std.mem.Allocator,
    account_count: usize,
    inner_cmdline: ?[]const u8,
    extra_path_dirs: []const []const u8,
    inherit_env: bool,
) !struct {
    child: HostedChild,
    console: Console,
    buffer: std.ArrayList(u8),
    deadline_ms: i64,
    tmp: fs.TmpDir,
} {
    try ensureHeadlessConhost(gpa);
    var tmp = fs.tmpDir(.{});
    errdefer tmp.cleanup();
    const home = try tmp.dir.realpathAlloc(gpa, ".");
    defer gpa.free(home);
    const codex_home = try fs.path.join(gpa, &.{ home, ".codex" });
    defer gpa.free(codex_home);
    try tmp.dir.makePath(".codex");
    try seedAccounts(gpa, codex_home, account_count);

    const child = if (inner_cmdline) |inner|
        try spawnHosted(gpa, inner, home, codex_home, extra_path_dirs, inherit_env)
    else blk: {
        const exe = try exePathAlloc(gpa);
        defer gpa.free(exe);
        break :blk try spawnHostedList(gpa, exe, home, codex_home);
    };
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
    var session = try setupHostedSession(gpa, 3, null, &.{}, false);
    defer {
        session.console.deinit();
        session.child.kill();
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
    var session = try setupHostedSession(gpa, 40, null, &.{}, false);
    defer {
        session.console.deinit();
        session.child.kill();
        session.child.deinit();
        session.buffer.deinit(gpa);
        session.tmp.cleanup();
    }

    try waitBufferMarker(session.console, &session.buffer, "user00@example.com", session.deadline_ms);

    // Pin non-vacuity: the tail row must NOT be visible before injection,
    // or the scroll assertion below could pass without any scrolling.
    try session.console.bufferText(&session.buffer);
    try std.testing.expect(std.mem.indexOf(u8, session.buffer.items, "user39@example.com") == null);

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

test "console: ctrl-c, resize, and dead-key records follow real console semantics" {
    if (comptime !has_console) return error.SkipZigTest;
    const gpa = std.testing.allocator;
    var session = try setupHostedSession(gpa, 3, null, &.{}, false);
    defer {
        session.console.deinit();
        session.child.kill();
        session.child.deinit();
        session.buffer.deinit(gpa);
        session.tmp.cleanup();
    }

    try waitBufferMarker(session.console, &session.buffer, "ACCOUNT", session.deadline_ms);

    // Headless conhost pins the window to the buffer: SetConsoleWindowInfo
    // is ignored and buffer resizing cannot shrink below the window, so the
    // app's perceived size cannot change here — geometry-correct .redraw is
    // pinned by the record→key unit tests instead. What e2e can prove is
    // that the resize record and a dead key (uChar=0) are consumed without
    // breaking the loop: a real 'j' afterwards must still re-render.
    try session.console.inject(&.{
        resizeRecord(120, 60),
        keyRecordShaped('Z', 0, 0),
        keyRecordShaped('J', 'j', 0),
    });
    try waitBufferMarker(session.console, &session.buffer, "> 2", session.deadline_ms);

    // With PROCESSED_INPUT off, Ctrl+C arrives as a KEY_EVENT whose uChar is
    // 0x03 — the same byte that quits on every other surface. The virtual
    // key is 'C', so this pins that the uChar path, not the VK, quits.
    try session.console.inject(&.{keyRecordShaped('C', 0x03, 0x0008)});
    const code = session.child.waitAppExit(console_deadline_ms) catch |err| {
        session.child.kill();
        return err;
    };
    try std.testing.expectEqual(@as(windows.DWORD, 0), code);
}

/// Resolves the installed PowerShell 7 binary, if any: the MSI default
/// first, then PATH (Scoop/Chocolatey prefixes), then the per-user Store
/// execution alias. Override the location with CODEX_AUTH_CONSOLE_PWSH_EXE
/// when it lives elsewhere.
fn pwshPathAlloc(gpa: std.mem.Allocator) !?[]u8 {
    const custom = app_runtime.getEnvVarOwned(gpa, "CODEX_AUTH_CONSOLE_PWSH_EXE") catch null;
    if (custom) |path| return path;
    const msi_path = "C:\\Program Files\\PowerShell\\7\\pwsh.exe";
    if (fs.accessAbsolute(msi_path, .{})) |_| return try gpa.dupe(u8, msi_path) else |_| {}
    if (app_runtime.getEnvVarOwned(gpa, "PATH") catch null) |path_env| {
        defer gpa.free(path_env);
        var dirs = std.mem.splitScalar(u8, path_env, ';');
        while (dirs.next()) |dir| {
            if (dir.len == 0) continue;
            const candidate = try fs.path.join(gpa, &.{ dir, "pwsh.exe" });
            if (fs.accessAbsolute(candidate, .{})) |_| return candidate else |_| {
                gpa.free(candidate);
            }
        }
    }
    const local_appdata = app_runtime.getEnvVarOwned(gpa, "LOCALAPPDATA") catch return null;
    defer gpa.free(local_appdata);
    const store_path = try fs.path.join(gpa, &.{ local_appdata, "Microsoft", "WindowsApps", "pwsh.exe" });
    errdefer gpa.free(store_path);
    if (fs.accessAbsolute(store_path, .{})) |_| return store_path else |_| {}
    gpa.free(store_path);
    return null;
}

/// Hosts the app through a real shell inside the console: conhost ->
/// `shell` -> codex-auth. The shell layer exercises env inheritance
/// through a process chain; console semantics themselves are identical
/// (the console belongs to conhost, not the shell).
fn runShellHostedLeg(gpa: std.mem.Allocator, bin_dir: []const u8, shell: []const u8) !void {
    const inner = try std.fmt.allocPrint(
        gpa,
        "\"{s}\" -NoProfile -Command \"codex-auth.exe list --live --skip-api\"",
        .{shell},
    );
    defer gpa.free(inner);
    const shell_dir = fs.path.dirname(shell) orelse return error.BadShellPath;

    var session = try setupHostedSession(gpa, 3, inner, &.{ bin_dir, shell_dir }, true);
    defer {
        session.console.deinit();
        session.child.kill();
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

test "console: live list under powershell renders and q exits" {
    if (comptime !has_console) return error.SkipZigTest;
    const gpa = std.testing.allocator;
    const exe = try exePathAlloc(gpa);
    defer gpa.free(exe);
    const bin_dir = fs.path.dirname(exe) orelse return error.BadExePath;

    // Windows PowerShell 5.1 ships with the OS; PowerShell 7 runs only
    // when installed.
    try runShellHostedLeg(gpa, bin_dir, "C:\\Windows\\System32\\WindowsPowerShell\\v1.0\\powershell.exe");
    if (try pwshPathAlloc(gpa)) |pwsh| {
        defer gpa.free(pwsh);
        try runShellHostedLeg(gpa, bin_dir, pwsh);
    } else {
        std.debug.print("pwsh.exe not installed; skipping the PowerShell 7 leg\n", .{});
    }
}

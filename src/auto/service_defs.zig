const std = @import("std");
const version = @import("../version.zig");

pub const linux_service_name = "codex-auth-autoswitch.service";
pub const linux_timer_name = "codex-auth-autoswitch.timer";
pub const mac_label = "com.loongphy.codex-auth.auto";
pub const windows_task_name = "CodexAuthAutoSwitch";
pub const windows_helper_name = "codex-auth-auto.exe";
pub const windows_task_trigger_kind = "LogonTrigger";
pub const windows_task_restart_count = "999";
pub const windows_task_restart_count_value: i32 = 999;
pub const windows_task_restart_interval_xml = "PT1M";
pub const windows_task_execution_time_limit_xml = "PT0S";
pub const service_version_env_name = "CODEX_AUTH_VERSION";
pub const codex_home_env_name = "CODEX_HOME";

pub const RuntimeState = enum { running, stopped, unknown };

pub fn linuxUnitText(allocator: std.mem.Allocator, self_exe: []const u8, codex_home: []const u8) ![]u8 {
    const exec = try std.fmt.allocPrint(allocator, "\"{s}\" daemon --watch", .{self_exe});
    defer allocator.free(exec);
    const escaped_version = try escapeSystemdValue(allocator, version.app_version);
    defer allocator.free(escaped_version);
    const escaped_codex_home = try escapeSystemdValue(allocator, codex_home);
    defer allocator.free(escaped_codex_home);
    return try std.fmt.allocPrint(
        allocator,
        "[Unit]\nDescription=codex-auth auto-switch watcher\n\n[Service]\nType=simple\nRestart=always\nRestartSec=1\nEnvironment=\"{s}={s}\"\nEnvironment=\"{s}={s}\"\nExecStart={s}\n\n[Install]\nWantedBy=default.target\n",
        .{
            service_version_env_name,
            escaped_version,
            codex_home_env_name,
            escaped_codex_home,
            exec,
        },
    );
}

pub fn macPlistText(allocator: std.mem.Allocator, self_exe: []const u8, codex_home: []const u8) ![]u8 {
    const exe = try escapeXml(allocator, self_exe);
    defer allocator.free(exe);
    const current_version = try escapeXml(allocator, version.app_version);
    defer allocator.free(current_version);
    const escaped_codex_home = try escapeXml(allocator, codex_home);
    defer allocator.free(escaped_codex_home);
    return try std.fmt.allocPrint(
        allocator,
        "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<!DOCTYPE plist PUBLIC \"-//Apple//DTD PLIST 1.0//EN\" \"http://www.apple.com/DTDs/PropertyList-1.0.dtd\">\n<plist version=\"1.0\">\n<dict>\n  <key>Label</key>\n  <string>{s}</string>\n  <key>ProgramArguments</key>\n  <array>\n    <string>{s}</string>\n    <string>daemon</string>\n    <string>--watch</string>\n  </array>\n  <key>EnvironmentVariables</key>\n  <dict>\n    <key>{s}</key>\n    <string>{s}</string>\n    <key>{s}</key>\n    <string>{s}</string>\n  </dict>\n  <key>RunAtLoad</key>\n  <true/>\n  <key>KeepAlive</key>\n  <true/>\n</dict>\n</plist>\n",
        .{ mac_label, exe, service_version_env_name, current_version, codex_home_env_name, escaped_codex_home },
    );
}

pub fn windowsTaskAction(allocator: std.mem.Allocator, helper_path: []const u8, codex_home: []const u8) ![]u8 {
    const args = try windowsTaskArguments(allocator, codex_home);
    defer allocator.free(args);
    return try std.fmt.allocPrint(
        allocator,
        "\"{s}\" {s}",
        .{ helper_path, args },
    );
}

pub fn windowsRegisterTaskScript(allocator: std.mem.Allocator, helper_path: []const u8, codex_home: []const u8) ![]u8 {
    const escaped_helper_path = try escapePowerShellSingleQuoted(allocator, helper_path);
    defer allocator.free(escaped_helper_path);
    const args = try windowsTaskArguments(allocator, codex_home);
    defer allocator.free(args);
    const escaped_args = try escapePowerShellSingleQuoted(allocator, args);
    defer allocator.free(escaped_args);
    return try std.fmt.allocPrint(
        allocator,
        "$action = New-ScheduledTaskAction -Execute '{s}' -Argument '{s}'; $trigger = New-ScheduledTaskTrigger -AtLogOn; $settings = New-ScheduledTaskSettingsSet -RestartCount {s} -RestartInterval (New-TimeSpan -Minutes 1) -ExecutionTimeLimit (New-TimeSpan -Seconds 0); Register-ScheduledTask -TaskName '{s}' -Action $action -Trigger $trigger -Settings $settings -Force | Out-Null",
        .{ escaped_helper_path, escaped_args, windows_task_restart_count, windows_task_name },
    );
}

pub fn windowsTaskMatchScript(allocator: std.mem.Allocator) ![]u8 {
    return try std.fmt.allocPrint(
        allocator,
        "$task = Get-ScheduledTask -TaskName '{s}' -ErrorAction SilentlyContinue; if ($null -eq $task) {{ exit 1 }}; $action = $task.Actions | Select-Object -First 1; if ($null -eq $action) {{ exit 2 }}; $xml = [xml](Export-ScheduledTask -TaskName '{s}'); $triggers = @($xml.Task.Triggers.ChildNodes | Where-Object {{ $_.NodeType -eq [System.Xml.XmlNodeType]::Element }}); if ($triggers.Count -ne 1) {{ exit 3 }}; $triggerKind = [string]$triggers[0].LocalName; if ([string]::IsNullOrWhiteSpace($triggerKind)) {{ exit 4 }}; $restartNode = $xml.Task.Settings.RestartOnFailure; if ($null -eq $restartNode) {{ exit 5 }}; $restartCount = [string]$restartNode.Count; $restartInterval = [string]$restartNode.Interval; if ([string]::IsNullOrWhiteSpace($restartCount) -or [string]::IsNullOrWhiteSpace($restartInterval)) {{ exit 6 }}; $executionLimit = [string]$xml.Task.Settings.ExecutionTimeLimit; if ([string]::IsNullOrWhiteSpace($executionLimit)) {{ exit 7 }}; $args = if ([string]::IsNullOrWhiteSpace($action.Arguments)) {{ '' }} else {{ ' ' + $action.Arguments }}; Write-Output ($action.Execute + $args + '|TRIGGER:' + $triggerKind + '|RESTART:' + $restartCount + ',' + $restartInterval + '|LIMIT:' + $executionLimit)",
        .{ windows_task_name, windows_task_name },
    );
}

pub fn windowsEndTaskScript(allocator: std.mem.Allocator) ![]u8 {
    return try std.fmt.allocPrint(
        allocator,
        "$task = Get-ScheduledTask -TaskName '{s}' -ErrorAction SilentlyContinue; if ($null -eq $task) {{ exit 0 }}; if ($task.State -eq 4) {{ Stop-ScheduledTask -TaskName '{s}' -ErrorAction SilentlyContinue }}",
        .{ windows_task_name, windows_task_name },
    );
}

pub fn windowsDeleteTaskScript(allocator: std.mem.Allocator) ![]u8 {
    return try std.fmt.allocPrint(
        allocator,
        "$task = Get-ScheduledTask -TaskName '{s}' -ErrorAction SilentlyContinue; if ($null -eq $task) {{ exit 0 }}; Unregister-ScheduledTask -TaskName '{s}' -Confirm:$false",
        .{ windows_task_name, windows_task_name },
    );
}

pub fn windowsTaskStateScript() []const u8 {
    return "$task = Get-ScheduledTask -TaskName '" ++ windows_task_name ++ "' -ErrorAction SilentlyContinue; if ($null -eq $task) { exit 1 }; Write-Output ([int]$task.State)";
}

pub fn parseWindowsTaskStateOutput(output: []const u8) RuntimeState {
    const trimmed = std.mem.trim(u8, output, " \n\r\t");
    if (trimmed.len == 0) return .unknown;
    const value = std.fmt.parseInt(u8, trimmed, 10) catch return .unknown;
    return switch (value) {
        4 => .running,
        0, 1, 2, 3 => .stopped,
        else => .unknown,
    };
}

pub fn escapeXml(allocator: std.mem.Allocator, raw: []const u8) ![]u8 {
    var out = std.ArrayList(u8).empty;
    defer out.deinit(allocator);
    for (raw) |ch| {
        switch (ch) {
            '&' => try out.appendSlice(allocator, "&amp;"),
            '<' => try out.appendSlice(allocator, "&lt;"),
            '>' => try out.appendSlice(allocator, "&gt;"),
            '"' => try out.appendSlice(allocator, "&quot;"),
            '\'' => try out.appendSlice(allocator, "&apos;"),
            else => try out.append(allocator, ch),
        }
    }
    return try out.toOwnedSlice(allocator);
}

fn escapeSystemdValue(allocator: std.mem.Allocator, raw: []const u8) ![]u8 {
    var out = std.ArrayList(u8).empty;
    defer out.deinit(allocator);
    for (raw) |ch| {
        switch (ch) {
            '\\' => try out.appendSlice(allocator, "\\\\"),
            '"' => try out.appendSlice(allocator, "\\\""),
            else => try out.append(allocator, ch),
        }
    }
    return try out.toOwnedSlice(allocator);
}

fn escapePowerShellSingleQuoted(allocator: std.mem.Allocator, input: []const u8) ![]u8 {
    return std.mem.replaceOwned(u8, allocator, input, "'", "''");
}

pub fn windowsTaskArguments(allocator: std.mem.Allocator, codex_home: []const u8) ![]u8 {
    const quoted_codex_home = try quoteWindowsCommandArg(allocator, codex_home);
    defer allocator.free(quoted_codex_home);
    return try std.fmt.allocPrint(
        allocator,
        "--service-version {s} --codex-home {s}",
        .{ version.app_version, quoted_codex_home },
    );
}

fn quoteWindowsCommandArg(allocator: std.mem.Allocator, arg: []const u8) ![]u8 {
    const needs_quotes = blk: {
        if (arg.len == 0) break :blk true;
        for (arg) |ch| {
            if (ch <= ' ' or ch == '"') break :blk true;
        }
        break :blk false;
    };
    if (!needs_quotes) return try allocator.dupe(u8, arg);

    var out = std.ArrayList(u8).empty;
    defer out.deinit(allocator);
    try out.append(allocator, '"');

    var backslash_count: usize = 0;
    for (arg) |byte| {
        switch (byte) {
            '\\' => backslash_count += 1,
            '"' => {
                try out.appendNTimes(allocator, '\\', backslash_count * 2 + 1);
                try out.append(allocator, '"');
                backslash_count = 0;
            },
            else => {
                try out.appendNTimes(allocator, '\\', backslash_count);
                try out.append(allocator, byte);
                backslash_count = 0;
            },
        }
    }
    try out.appendNTimes(allocator, '\\', backslash_count * 2);
    try out.append(allocator, '"');
    return try out.toOwnedSlice(allocator);
}

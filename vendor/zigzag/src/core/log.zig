//! Debug file logging for ZigZag applications.
//! Since stdout is owned by the renderer, this provides file-based logging.

const std = @import("std");

/// Logger that writes timestamped messages to a file
pub const Logger = struct {
    file: std.fs.File,
    mutex: std.Thread.Mutex,

    /// Initialize a logger that writes to the given file path
    pub fn init(path: []const u8) !Logger {
        const file = try std.fs.cwd().createFile(path, .{ .truncate = false });
        // Seek to end for append behavior
        file.seekFromEnd(0) catch {};
        return .{
            .file = file,
            .mutex = .{},
        };
    }

    /// Close the log file
    pub fn deinit(self: *Logger) void {
        self.file.close();
    }

    /// Write a log message with timestamp prefix
    pub fn log(self: *Logger, comptime fmt: []const u8, args: anytype) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        const writer = self.file.writer();

        // Write timestamp
        const now = std.time.timestamp();
        const epoch_seconds = std.time.epoch.EpochSeconds{ .secs = @intCast(now) };
        const day_seconds = epoch_seconds.getDaySeconds();

        writer.print("[{d:0>2}:{d:0>2}:{d:0>2}] ", .{
            day_seconds.getHoursIntoDay(),
            day_seconds.getMinutesIntoHour(),
            day_seconds.getSecondsIntoMinute(),
        }) catch return;

        // Write message
        writer.print(fmt, args) catch return;
        writer.writeByte('\n') catch return;
    }
};

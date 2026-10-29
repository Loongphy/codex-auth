const std = @import("std");

pub const ansi = struct {
    pub const reset = "\x1b[0m";
    pub const bold = "\x1b[1m";
    pub const dim = "\x1b[2m";
    pub const red = "\x1b[31m";
    pub const green = "\x1b[32m";
    pub const cyan = "\x1b[36m";
};

pub const role = struct {
    pub const key = ansi.bold;
    pub const secondary = ansi.dim;
    pub const status = ansi.cyan;
    pub const heading = ansi.bold ++ ansi.cyan;
    pub const success = ansi.green;
    pub const warning = ansi.cyan;
    pub const error_text = ansi.red;
};

/// Platform variants of the few marks that user-facing output needs. Windows
/// default output must stay ASCII and free of check marks, bullets, arrows and
/// box-drawing characters (docs/windows.md); the borderless reset-credit rail
/// therefore uses indentation and color on every platform, and only swaps the
/// separator and success marker here. Every other difference follows a marker
/// the docs or an existing command already use.
///
/// Marks that are already ASCII and established repo-wide are deliberately not
/// part of this set: the cursor `>` of the switch and remove tables, and the
/// `Enter` / `Esc` key names the footers spell out on every platform.
pub const Glyphs = struct {
    /// Separator between compact fields on one line, spacing included.
    separator: []const u8,
    /// Status markers, trailing space included. Windows has no failure marker:
    /// its documented non-success lines are plain sentences.
    success: []const u8,
    failure: []const u8,

    pub fn forPlatform(is_windows: bool) Glyphs {
        if (is_windows) {
            return .{
                .separator = ", ",
                .success = "OK ",
                .failure = "",
            };
        }
        return .{
            .separator = " \u{00b7} ",
            .success = "\u{2713} ",
            .failure = "\u{2717} ",
        };
    }
};

pub const StyledWriter = struct {
    out: *std.Io.Writer,
    color_enabled: bool,

    pub fn init(out: *std.Io.Writer, color_enabled: bool) StyledWriter {
        return .{
            .out = out,
            .color_enabled = color_enabled,
        };
    }

    pub fn writeAll(self: *StyledWriter, bytes: []const u8) !void {
        try self.out.writeAll(bytes);
    }

    pub fn print(self: *StyledWriter, comptime fmt: []const u8, args: anytype) !void {
        try self.out.print(fmt, args);
    }

    pub fn writeStyle(self: *StyledWriter, ansi_style: []const u8) !void {
        if (self.color_enabled and ansi_style.len != 0) try self.out.writeAll(ansi_style);
    }

    pub fn reset(self: *StyledWriter) !void {
        if (self.color_enabled) try self.out.writeAll(ansi.reset);
    }

    pub fn flush(self: *StyledWriter) !void {
        try self.out.flush();
    }
};

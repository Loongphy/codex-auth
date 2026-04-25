const terminal_color = @import("../terminal/color.zig");

pub const ansi = struct {
    pub const reset = "\x1b[0m";
    pub const dim = "\x1b[2m";
    pub const red = "\x1b[31m";
    pub const bold_red = "\x1b[1;31m";
    pub const yellow = "\x1b[33m";
    pub const bold_yellow = "\x1b[1;33m";
    pub const green = "\x1b[32m";
    pub const bold_green = "\x1b[1;32m";
    pub const cyan = "\x1b[36m";
    pub const bold_cyan = "\x1b[1;36m";
    pub const bold = "\x1b[1m";
};

pub fn stdoutColorEnabled() bool {
    return terminal_color.stdoutColorEnabled();
}

pub fn stderrColorEnabled() bool {
    return terminal_color.stderrColorEnabled();
}

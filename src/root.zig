pub const api = struct {
    pub const account = @import("api/account.zig");
    pub const http = @import("api/http.zig");
    pub const usage = @import("api/usage.zig");
};

pub const auth = struct {
    pub const core = @import("auth/auth.zig");
    pub const account = @import("auth/account.zig");
};

pub const auto = @import("auto/root.zig");
pub const cli = @import("cli/root.zig");
pub const workflows = @import("workflows/root.zig");

pub const core = struct {
    pub const compat_fs = @import("core/compat_fs.zig");
    pub const io_util = @import("core/io_util.zig");
    pub const runtime = @import("core/runtime.zig");
};

pub const platform = struct {
    pub const windows = @import("platform/windows.zig");
};

pub const registry = @import("registry/root.zig");
pub const session = @import("session.zig");

pub const terminal = struct {
    pub const color = @import("terminal/color.zig");
};

pub const time = struct {
    pub const relative = @import("time/relative.zig");
};

pub const tui = struct {
    pub const display = @import("tui/display.zig");
    pub const table = @import("tui/table.zig");
};

pub const version = @import("version.zig");

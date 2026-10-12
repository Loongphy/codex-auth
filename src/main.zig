const std = @import("std");
const codex_auth = @import("codex_auth");

pub fn main(init: std.process.Init) !u8 {
    return codex_auth.workflows.main(init);
}

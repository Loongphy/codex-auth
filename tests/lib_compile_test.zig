const std = @import("std");
const codex_auth = @import("codex_auth");

test {
    std.testing.refAllDecls(codex_auth);
}

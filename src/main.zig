const std = @import("std");
const codex_auth = @import("root.zig");

pub fn main(init: std.process.Init.Minimal) !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer std.debug.assert(gpa.deinit() == .ok);
    const allocator = gpa.allocator();
    const self_exe = try std.process.executablePathAlloc(codex_auth.core.runtime.io(), allocator);
    defer allocator.free(self_exe);
    if (codex_auth.app_workflow.isGuardedShimExecutablePath(self_exe)) {
        return codex_auth.app_workflow.runGuardedAppShim(allocator, init);
    }
    return codex_auth.workflows.main(init);
}

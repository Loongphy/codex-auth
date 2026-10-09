const std = @import("std");
const cli = @import("../cli/root.zig");

pub fn handleCompletion(allocator: std.mem.Allocator, codex_home: ?[]const u8, opts: cli.types.CompletionOptions) !void {
    switch (opts) {
        .shell => |shell| try cli.completion.printCompletion(shell),
        .query => |target| try cli.completion.printQueryCompletion(allocator, codex_home.?, target),
    }
}

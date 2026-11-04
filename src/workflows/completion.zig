const std = @import("std");
const cli = @import("../cli/root.zig");

pub fn handleCompletion(opts: cli.types.CompletionShell) !void {
    try cli.completion.printCompletion(opts);
}

pub fn handleCompleteRequest(
    allocator: std.mem.Allocator,
    codex_home: ?[]const u8,
    opts: cli.types.CompleteRequest,
) !void {
    try cli.completion.printCompleteResponse(allocator, codex_home, opts.args, opts.descriptions);
}

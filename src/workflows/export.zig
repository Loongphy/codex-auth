const std = @import("std");
const cli = @import("../cli/root.zig");
const registry = @import("../registry/root.zig");
const io_util = @import("../core/io_util.zig");

pub fn handleExport(allocator: std.mem.Allocator, codex_home: []const u8, opts: cli.types.ExportOptions) !void {
    var reg = try registry.loadRegistry(allocator, codex_home);
    defer reg.deinit(allocator);

    var summary = try registry.exportAccounts(allocator, codex_home, &reg, opts.dest_path, switch (opts.format) {
        .standard => .standard,
        .cpa => .cpa,
    });
    defer summary.deinit(allocator);

    var stdout: io_util.Stdout = undefined;
    stdout.init();
    const out = stdout.out();
    try out.print("Exported {d} {s} to {s}\n", .{
        summary.exported,
        if (summary.exported == 1) "account" else "accounts",
        summary.dest_path,
    });
    try out.flush();
}

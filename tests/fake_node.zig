const std = @import("std");
const builtin = @import("builtin");

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;

    // Count args.
    const arg_count = countArgs(init.minimal.args, gpa);

    // --version support.
    if (arg_count >= 2 and checkVersion(init.minimal.args, gpa)) {
        try writeStdout(init.io, "v22.0.0\n");
        return;
    }

    // Find response directory from env var or exe path.
    const response_dir = getResponseDir(init) orelse ".";
    const response_file = if (arg_count > 4) "me_body_b64.txt" else "batch_body_b64.txt";

    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const response_path = try std.fs.path.join(arena, &.{ response_dir, response_file });
    const body = std.Io.Dir.cwd().readFileAlloc(init.io, response_path, arena, .unlimited) catch |err| {
        std.log.err("fake_node: cannot read {s}: {s}", .{ response_path, @errorName(err) });
        std.process.exit(1);
    };
    const trimmed = std.mem.trim(u8, body, "\r\n");

    try writeStdout(init.io, try std.fmt.allocPrint(arena, "{s}\n200\nok\n", .{trimmed}));
}

fn writeStdout(io: std.Io, msg: []const u8) !void {
    var buf: [4096]u8 = undefined;
    var fw = std.Io.File.stdout().writer(io, &buf);
    try fw.interface.writeAll(msg);
    try fw.flush();
}

fn countArgs(args: std.process.Args, gpa: std.mem.Allocator) usize {
    return switch (builtin.os.tag) {
        .windows, .wasi => blk: {
            var iter = std.process.Args.Iterator.initAllocator(args, gpa) catch return 0;
            defer iter.deinit();
            var n: usize = 0;
            while (iter.next() != null) : (n += 1) {}
            break :blk n;
        },
        else => args.vector.len,
    };
}

fn checkVersion(args: std.process.Args, gpa: std.mem.Allocator) bool {
    var iter = std.process.Args.Iterator.initAllocator(args, gpa) catch return false;
    defer iter.deinit();
    _ = iter.next(); // skip exe
    const arg1 = iter.next() orelse return false;
    return std.mem.eql(u8, arg1, "--version");
}

fn getResponseDir(init: std.process.Init) ?[]const u8 {
    if (init.environ_map.get("CODEX_FAKE_NODE_RESPONSE_DIR")) |dir| return dir;
    var iter = std.process.Args.Iterator.initAllocator(init.minimal.args, init.gpa) catch return null;
    defer iter.deinit();
    const exe_path = iter.next() orelse return null;
    return std.fs.path.dirname(exe_path);
}

const std = @import("std");

fn getEnvVarOwned(allocator: std.mem.Allocator, environ_map: *const std.process.Environ.Map, name: []const u8) ![]u8 {
    const value = environ_map.get(name) orelse return error.EnvironmentVariableNotFound;
    return try allocator.dupe(u8, value);
}

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);

    const home_root = try getEnvVarOwned(arena, init.environ_map, "HOME");
    const codex_home = getEnvVarOwned(arena, init.environ_map, "CODEX_HOME") catch |err| switch (err) {
        error.EnvironmentVariableNotFound => try std.Io.Dir.path.join(arena, &[_][]const u8{ home_root, ".codex" }),
        else => return err,
    };

    var home_dir = try std.Io.Dir.openDirAbsolute(io, home_root, .{});
    defer home_dir.close(io);

    var argv_buf = std.ArrayList(u8).empty;
    defer argv_buf.deinit(arena);
    for (args[1..], 0..) |arg, i| {
        if (i != 0) try argv_buf.append(arena, ' ');
        try argv_buf.appendSlice(arena, arg);
    }
    try argv_buf.append(arena, '\n');

    try home_dir.writeFile(io, .{ .sub_path = "fake-codex-launcher.txt", .data = "exe\n" });
    try home_dir.writeFile(io, .{ .sub_path = "fake-codex-argv.txt", .data = argv_buf.items });

    const codex_home_with_newline = try std.mem.concat(arena, u8, &[_][]const u8{ codex_home, "\n" });
    try home_dir.writeFile(io, .{ .sub_path = "fake-codex-home.txt", .data = codex_home_with_newline });

    try std.Io.Dir.cwd().createDirPath(io, codex_home);
    var codex_home_dir = try std.Io.Dir.openDirAbsolute(io, codex_home, .{});
    defer codex_home_dir.close(io);

    const auth_data = try home_dir.readFileAlloc(io, "fake-auth.json", arena, .limited(1024 * 1024));
    try codex_home_dir.writeFile(io, .{ .sub_path = "auth.json", .data = auth_data });
}

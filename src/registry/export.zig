const std = @import("std");
const app_runtime = @import("../core/runtime.zig");
const auth = @import("../auth/auth.zig");
const common = @import("common.zig");

const Registry = common.Registry;
const accountAuthPath = common.accountAuthPath;
const accountSnapshotFileName = common.accountSnapshotFileName;
const copyManagedFile = common.copyManagedFile;
const ensurePrivateDir = common.ensurePrivateDir;
const readFileAlloc = common.readFileAlloc;
const writeFile = common.writeFile;

pub const ExportFormat = enum { standard, cpa };

pub const ExportSummary = struct {
    dest_path: []u8,
    exported: usize,

    pub fn deinit(self: *ExportSummary, allocator: std.mem.Allocator) void {
        allocator.free(self.dest_path);
    }
};

pub fn defaultExportDirectory(allocator: std.mem.Allocator, codex_home: []const u8) ![]u8 {
    return try std.fs.path.join(allocator, &[_][]const u8{ codex_home, "accounts", "backup" });
}

pub fn exportAccounts(
    allocator: std.mem.Allocator,
    codex_home: []const u8,
    reg: *const Registry,
    maybe_dest_path: ?[]const u8,
    format: ExportFormat,
) !ExportSummary {
    const dest_path = if (maybe_dest_path) |path|
        try allocator.dupe(u8, path)
    else
        try defaultExportDirectory(allocator, codex_home);
    errdefer allocator.free(dest_path);

    try ensurePrivateDir(dest_path);

    var exported: usize = 0;
    for (reg.accounts.items) |rec| {
        const src = try accountAuthPath(allocator, codex_home, rec.account_key);
        defer allocator.free(src);

        const base_name = try accountSnapshotFileName(allocator, rec.account_key);
        defer allocator.free(base_name);

        const dest_name = switch (format) {
            .standard => try allocator.dupe(u8, base_name),
            .cpa => try cpaExportFileName(allocator, base_name),
        };
        defer allocator.free(dest_name);

        const dest = try std.fs.path.join(allocator, &[_][]const u8{ dest_path, dest_name });
        defer allocator.free(dest);

        switch (format) {
            .standard => try copyManagedFile(src, dest),
            .cpa => try exportCpaFile(allocator, src, dest),
        }
        exported += 1;
    }

    return .{
        .dest_path = dest_path,
        .exported = exported,
    };
}

fn cpaExportFileName(allocator: std.mem.Allocator, auth_name: []const u8) ![]u8 {
    if (std.mem.endsWith(u8, auth_name, ".auth.json")) {
        return try std.mem.concat(allocator, u8, &[_][]const u8{ auth_name[0 .. auth_name.len - ".auth.json".len], ".json" });
    }
    return try std.mem.concat(allocator, u8, &[_][]const u8{ auth_name, ".json" });
}

fn exportCpaFile(allocator: std.mem.Allocator, src: []const u8, dest: []const u8) !void {
    var file = try std.Io.Dir.cwd().openFile(app_runtime.io(), src, .{});
    defer file.close(app_runtime.io());
    const data = try readFileAlloc(file, allocator, 10 * 1024 * 1024);
    defer allocator.free(data);

    const converted = try auth.convertStandardAuthJsonToCpa(allocator, data);
    defer allocator.free(converted);
    try writeFile(dest, converted);
}

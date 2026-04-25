const std = @import("std");
const types = @import("../types.zig");
const common = @import("common.zig");

pub fn parse(allocator: std.mem.Allocator, args: []const [:0]const u8) !types.ParseResult {
    if (args.len == 1 and common.isHelpFlag(std.mem.sliceTo(args[0], 0))) {
        return .{ .command = .{ .help = .import_auth } };
    }

    var auth_path: ?[]u8 = null;
    var alias: ?[]u8 = null;
    var purge = false;
    var source: types.ImportSource = .standard;
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = std.mem.sliceTo(args[i], 0);
        if (std.mem.eql(u8, arg, "--alias")) {
            if (i + 1 >= args.len) {
                common.freeImportOptions(allocator, auth_path, alias);
                return common.usageErrorResult(allocator, .import_auth, "missing value for `--alias`.", .{});
            }
            if (alias != null) {
                common.freeImportOptions(allocator, auth_path, alias);
                return common.usageErrorResult(allocator, .import_auth, "duplicate `--alias` for `import`.", .{});
            }
            alias = try allocator.dupe(u8, std.mem.sliceTo(args[i + 1], 0));
            i += 1;
        } else if (std.mem.eql(u8, arg, "--purge")) {
            if (purge) {
                common.freeImportOptions(allocator, auth_path, alias);
                return common.usageErrorResult(allocator, .import_auth, "duplicate `--purge` for `import`.", .{});
            }
            purge = true;
        } else if (std.mem.eql(u8, arg, "--cpa")) {
            if (source == .cpa) {
                common.freeImportOptions(allocator, auth_path, alias);
                return common.usageErrorResult(allocator, .import_auth, "duplicate `--cpa` for `import`.", .{});
            }
            source = .cpa;
        } else if (common.isHelpFlag(arg)) {
            common.freeImportOptions(allocator, auth_path, alias);
            return common.usageErrorResult(allocator, .import_auth, "`--help` must be used by itself for `import`.", .{});
        } else if (std.mem.startsWith(u8, arg, "-")) {
            common.freeImportOptions(allocator, auth_path, alias);
            return common.usageErrorResult(allocator, .import_auth, "unknown flag `{s}` for `import`.", .{arg});
        } else {
            if (auth_path != null) {
                common.freeImportOptions(allocator, auth_path, alias);
                return common.usageErrorResult(allocator, .import_auth, "unexpected extra path `{s}` for `import`.", .{arg});
            }
            auth_path = try allocator.dupe(u8, arg);
        }
    }
    if (purge and source == .cpa) {
        common.freeImportOptions(allocator, auth_path, alias);
        return common.usageErrorResult(allocator, .import_auth, "`--purge` cannot be combined with `--cpa`.", .{});
    }
    if (auth_path == null and !purge and source == .standard) {
        common.freeImportOptions(allocator, auth_path, alias);
        return common.usageErrorResult(allocator, .import_auth, "`import` requires a path unless `--purge` or `--cpa` is used.", .{});
    }
    return .{ .command = .{ .import_auth = .{
        .auth_path = auth_path,
        .alias = alias,
        .purge = purge,
        .source = source,
    } } };
}

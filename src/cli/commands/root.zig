const std = @import("std");
const types = @import("../types.zig");
const common = @import("common.zig");

const clean = @import("clean.zig");
const config = @import("config.zig");
const daemon = @import("daemon.zig");
const import_auth = @import("import.zig");
const list = @import("list.zig");
const login = @import("login.zig");
const remove = @import("remove.zig");
const status = @import("status.zig");
const switch_account = @import("switch.zig");

pub fn parseArgs(allocator: std.mem.Allocator, args: []const [:0]const u8) !types.ParseResult {
    if (args.len < 2) return .{ .command = .{ .help = .top_level } };
    const cmd = std.mem.sliceTo(args[1], 0);

    if (common.isHelpFlag(cmd)) {
        if (args.len > 2) {
            return common.usageErrorResult(allocator, .top_level, "unexpected argument after `{s}`: `{s}`.", .{
                cmd,
                std.mem.sliceTo(args[2], 0),
            });
        }
        return .{ .command = .{ .help = .top_level } };
    }

    if (std.mem.eql(u8, cmd, "help")) return parseHelpArgs(allocator, args[2..]);

    if (std.mem.eql(u8, cmd, "--version") or std.mem.eql(u8, cmd, "-V")) {
        if (args.len > 2) {
            return common.usageErrorResult(allocator, .top_level, "unexpected argument after `{s}`: `{s}`.", .{
                cmd,
                std.mem.sliceTo(args[2], 0),
            });
        }
        return .{ .command = .{ .version = {} } };
    }

    if (std.mem.eql(u8, cmd, "list")) return list.parse(allocator, args[2..]);
    if (std.mem.eql(u8, cmd, "login")) return login.parse(allocator, args[2..]);
    if (std.mem.eql(u8, cmd, "import")) return import_auth.parse(allocator, args[2..]);
    if (std.mem.eql(u8, cmd, "switch")) return switch_account.parse(allocator, args[2..]);
    if (std.mem.eql(u8, cmd, "remove")) return remove.parse(allocator, args[2..]);
    if (std.mem.eql(u8, cmd, "clean")) return clean.parse(allocator, args[2..]);
    if (std.mem.eql(u8, cmd, "status")) return status.parse(allocator, args[2..]);
    if (std.mem.eql(u8, cmd, "config")) return config.parse(allocator, args[2..]);
    if (std.mem.eql(u8, cmd, "daemon")) return daemon.parse(allocator, args[2..]);

    return common.usageErrorResult(allocator, .top_level, "unknown command `{s}`.", .{cmd});
}

pub fn freeParseResult(allocator: std.mem.Allocator, result: *types.ParseResult) void {
    switch (result.*) {
        .command => |*cmd| freeCommand(allocator, cmd),
        .usage_error => |usage_err| allocator.free(usage_err.message),
    }
    result.* = undefined;
}

fn freeCommand(allocator: std.mem.Allocator, cmd: *types.Command) void {
    switch (cmd.*) {
        .import_auth => |opts| common.freeImportOptions(allocator, opts.auth_path, opts.alias),
        .switch_account => |opts| {
            if (opts.query) |query| allocator.free(query);
        },
        .remove_account => |opts| {
            common.freeOwnedStringList(allocator, opts.selectors);
            allocator.free(opts.selectors);
        },
        else => {},
    }
    cmd.* = undefined;
}

fn parseHelpArgs(allocator: std.mem.Allocator, rest: []const [:0]const u8) !types.ParseResult {
    if (rest.len == 0) return .{ .command = .{ .help = .top_level } };
    if (rest.len > 1) {
        return common.usageErrorResult(allocator, .top_level, "unexpected argument after `help`: `{s}`.", .{
            std.mem.sliceTo(rest[1], 0),
        });
    }
    const topic_name = std.mem.sliceTo(rest[0], 0);
    const topic = helpTopicForName(topic_name) orelse
        return common.usageErrorResult(allocator, .top_level, "unknown help topic `{s}`.", .{topic_name});
    return .{ .command = .{ .help = topic } };
}

fn helpTopicForName(name: []const u8) ?types.HelpTopic {
    if (std.mem.eql(u8, name, "list")) return .list;
    if (std.mem.eql(u8, name, "status")) return .status;
    if (std.mem.eql(u8, name, "login")) return .login;
    if (std.mem.eql(u8, name, "import")) return .import_auth;
    if (std.mem.eql(u8, name, "switch")) return .switch_account;
    if (std.mem.eql(u8, name, "remove")) return .remove_account;
    if (std.mem.eql(u8, name, "clean")) return .clean;
    if (std.mem.eql(u8, name, "config")) return .config;
    if (std.mem.eql(u8, name, "daemon")) return .daemon;
    return null;
}

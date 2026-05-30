const std = @import("std");

const me_body = "{\"id\":\"user_api_e2e\",\"email\":\"apikey-flow@example.com\",\"name\":\"API Flow\"}";
const usage_body = "{\"plan_type\":\"plus\",\"rate_limit\":{\"primary_window\":{\"used_percent\":12,\"limit_window_seconds\":18000,\"reset_at\":4102444800},\"secondary_window\":{\"used_percent\":34,\"limit_window_seconds\":604800,\"reset_at\":4103049600}}}";

pub fn main(init: std.process.Init) !void {
    var args = try std.process.Args.Iterator.initAllocator(init.minimal.args, init.gpa);
    defer args.deinit();

    var endpoint: []const u8 = "";
    while (args.next()) |arg| endpoint = arg;
    const body = if (std.mem.endsWith(u8, endpoint, "/v1/me")) me_body else usage_body;

    var buffer: [4096]u8 = undefined;
    var writer = std.Io.File.stdout().writer(init.io, &buffer);
    const out = &writer.interface;
    try out.print("{s}\n200", .{body});
    try out.flush();
}

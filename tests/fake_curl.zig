const std = @import("std");

const me_body = "{\"id\":\"user_api_e2e\",\"email\":\"apikey-flow@example.com\",\"name\":\"API Flow\"}";
const usage_body = "{\"plan_type\":\"plus\",\"rate_limit\":{\"primary_window\":{\"used_percent\":12,\"limit_window_seconds\":18000,\"reset_at\":4102444800},\"secondary_window\":{\"used_percent\":34,\"limit_window_seconds\":604800,\"reset_at\":4103049600}}}";

pub fn main(init: std.process.Init) !void {
    _ = init.minimal.args;
    var read_buffer: [4096]u8 = undefined;
    var stdin_reader = std.Io.File.stdin().reader(init.io, &read_buffer);
    const config = try stdin_reader.interface.allocRemaining(init.gpa, .limited(64 * 1024));
    defer init.gpa.free(config);
    const body = if (std.mem.indexOf(u8, config, "/v1/me") != null) me_body else usage_body;

    var buffer: [4096]u8 = undefined;
    var writer = std.Io.File.stdout().writer(init.io, &buffer);
    const out = &writer.interface;
    try out.print("{s}\n200", .{body});
    try out.flush();
}

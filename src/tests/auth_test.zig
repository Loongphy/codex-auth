const std = @import("std");
const auth = @import("../auth.zig");

fn b64url(allocator: std.mem.Allocator, input: []const u8) ![]u8 {
    const encoder = std.base64.url_safe_no_pad.Encoder;
    const out_len = encoder.calcSize(input.len);
    const buf = try allocator.alloc(u8, out_len);
    _ = encoder.encode(buf, input);
    return buf;
}

test "parse auth info from jwt" {
    const gpa = std.testing.allocator;

    const header = "{\"alg\":\"none\",\"typ\":\"JWT\"}";
    const payload = "{\"email\":\"user@example.com\",\"https://api.openai.com/auth\":{\"chatgpt_account_id\":\"acc:user@example.com\",\"chatgpt_plan_type\":\"pro\"}}";

    const h64 = try b64url(gpa, header);
    defer gpa.free(h64);
    const p64 = try b64url(gpa, payload);
    defer gpa.free(p64);

    const jwt = try std.mem.concat(gpa, u8, &[_][]const u8{ h64, ".", p64, ".sig" });
    defer gpa.free(jwt);

    const json = try std.fmt.allocPrint(gpa,
        "{{\"tokens\":{{\"access_token\":\"access-user@example.com\",\"account_id\":\"acc:user@example.com\",\"id_token\":\"{s}\"}}}}",
        .{jwt},
    );
    defer gpa.free(json);

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(.{ .sub_path = "auth.json", .data = json });
    const tmp_path = try tmp.dir.realpathAlloc(gpa, ".");
    defer gpa.free(tmp_path);
    const auth_path = try std.fs.path.join(gpa, &[_][]const u8{ tmp_path, "auth.json" });
    defer gpa.free(auth_path);

    const info = try auth.parseAuthInfo(gpa, auth_path);
    defer info.deinit(gpa);
    try std.testing.expect(info.email != null);
    try std.testing.expect(std.mem.eql(u8, info.email.?, "user@example.com"));
    try std.testing.expect(info.account_id != null);
    try std.testing.expect(std.mem.eql(u8, info.account_id.?, "acc:user@example.com"));
    try std.testing.expect(info.access_token != null);
    try std.testing.expect(std.mem.eql(u8, info.access_token.?, "access-user@example.com"));
}

test "api key auth" {
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(.{ .sub_path = "auth.json", .data = "{\"OPENAI_API_KEY\":\"sk-test\"}" });
    const tmp_path = try tmp.dir.realpathAlloc(gpa, ".");
    defer gpa.free(tmp_path);
    const auth_path = try std.fs.path.join(gpa, &[_][]const u8{ tmp_path, "auth.json" });
    defer gpa.free(auth_path);
    const info = try auth.parseAuthInfo(gpa, auth_path);
    defer info.deinit(gpa);
    try std.testing.expect(info.auth_mode == .apikey);
}

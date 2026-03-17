const std = @import("std");
const auth = @import("../auth.zig");
const bdd = @import("bdd_helpers.zig");

test "parse auth info from jwt" {
    const gpa = std.testing.allocator;
    const json = try bdd.authJsonWithEmailPlan(gpa, "user@example.com", "pro");
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
    try std.testing.expect(info.plan == .pro);
    try std.testing.expect(info.auth_mode == .chatgpt);
}

test "api key auth has fingerprint" {
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const json = try bdd.apiKeyAuthJson(gpa, "sk-test");
    defer gpa.free(json);
    try tmp.dir.writeFile(.{ .sub_path = "auth.json", .data = json });
    const tmp_path = try tmp.dir.realpathAlloc(gpa, ".");
    defer gpa.free(tmp_path);
    const auth_path = try std.fs.path.join(gpa, &[_][]const u8{ tmp_path, "auth.json" });
    defer gpa.free(auth_path);
    const info = try auth.parseAuthInfo(gpa, auth_path);
    defer info.deinit(gpa);
    try std.testing.expect(info.auth_mode == .apikey);
    try std.testing.expect(info.api_key_fingerprint != null);
}

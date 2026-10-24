const std = @import("std");
const cli = @import("../cli/root.zig");
const registry = @import("../registry/root.zig");
const runtime = @import("../core/runtime.zig");
const io_util = @import("../core/io_util.zig");
const usage = @import("usage.zig");
const usage_api = @import("../api/usage.zig");
const active_auth = @import("active_auth.zig");

pub const Status = enum { held, cooldown, blocked, would_switch, switched };
pub const Decision = struct {
    status: Status,
    target: ?usize = null,
};

// Only a successful fetch from this poll is evidence for automatic mutation.
fn usedPercent(rec: registry.AccountRecord, outcome: usage.ForegroundUsageOutcome, now: i64) ?f64 {
    if (rec.auth_mode == .apikey or outcome.method != .api or !outcome.received_snapshot or
        outcome.missing_auth or outcome.error_name != null or outcome.status_code != 200) return null;
    const snapshot = rec.last_usage orelse return null;
    var used: ?f64 = null;
    for ([_]?registry.RateLimitWindow{ snapshot.primary, snapshot.secondary }) |maybe_window| {
        if (maybe_window) |window| {
            if (!std.math.isFinite(window.used_percent) or window.used_percent < 0 or window.used_percent > 100) return null;
            // A response whose window has already expired cannot establish current headroom.
            if (window.resets_at) |reset| if (reset <= now) return null;
            used = @max(used orelse 0, window.used_percent);
        }
    }
    return used;
}

pub fn evaluate(reg: *const registry.Registry, outcomes: []const usage.ForegroundUsageOutcome, opts: cli.types.AutoOptions, now_ms: i64) Decision {
    const active_key = reg.active_account_key orelse return .{ .status = .blocked };
    const active = registry.findAccountIndexByAccountKey(reg, active_key) orelse return .{ .status = .blocked };
    if (outcomes.len != reg.accounts.items.len) return .{ .status = .blocked };
    const current_used = usedPercent(reg.accounts.items[active], outcomes[active], @divFloor(now_ms, 1000)) orelse return .{ .status = .blocked };
    if (current_used < opts.threshold) return .{ .status = .held };
    if (reg.active_account_activated_at_ms) |activated| {
        if (now_ms -| activated < @as(i64, opts.cooldown_seconds) * 1000) return .{ .status = .cooldown };
    }
    var best: ?usize = null;
    var best_used = opts.threshold;
    for (reg.accounts.items, outcomes, 0..) |rec, outcome, idx| {
        if (idx == active) continue;
        const used = usedPercent(rec, outcome, @divFloor(now_ms, 1000)) orelse continue;
        if (used < best_used) {
            best = idx;
            best_used = used;
        }
    }
    return if (best) |target| .{ .status = .would_switch, .target = target } else .{ .status = .blocked };
}

fn authMatches(allocator: std.mem.Allocator, codex_home: []const u8, key: ?[]const u8) !bool {
    const expected = key orelse return false;
    var current = try active_auth.loadCurrentAuthState(allocator, codex_home);
    defer current.deinit(allocator);
    return current.syncable and current.record_key != null and std.mem.eql(u8, expected, current.record_key.?);
}

fn tick(allocator: std.mem.Allocator, codex_home: []const u8, opts: cli.types.AutoOptions) !void {
    var reg = try registry.loadRegistryReadOnly(allocator, codex_home);
    defer reg.deinit(allocator);
    if (!try authMatches(allocator, codex_home, reg.active_account_key)) {
        try printEvent(opts, .blocked, reg.active_account_key, null);
        return;
    }
    var state = try usage.refreshForegroundUsageForDisplayWithApiFetchersWithPoolInitUsingApiEnabledAndPersist(
        allocator,
        codex_home,
        &reg,
        usage_api.fetchUsageForAuthPathDetailed,
        usage_api.fetchUsageForAuthPathsDetailedBatch,
        usage.initForegroundUsagePool,
        true,
        true,
        false,
    );
    defer state.deinit(allocator);
    const now_ms = std.Io.Timestamp.now(runtime.io(), .real).toMilliseconds();
    var decision = evaluate(&reg, state.outcomes, opts, now_ms);
    const target = if (decision.target) |idx| reg.accounts.items[idx].account_key else null;
    if (decision.status == .would_switch and !opts.dry_run) {
        // Reload after network I/O to retain unrelated edits and detect manual switches.
        var latest = try registry.loadRegistryReadOnly(allocator, codex_home);
        defer latest.deinit(allocator);
        if (!registry.optionalStringEqual(latest.active_account_key, reg.active_account_key) or
            latest.active_account_activated_at_ms != reg.active_account_activated_at_ms or
            !try authMatches(allocator, codex_home, reg.active_account_key))
        {
            decision.status = .blocked;
        } else {
            try registry.activateAccountByKey(allocator, codex_home, &latest, target.?);
            try registry.saveRegistry(allocator, codex_home, &latest);
            decision.status = .switched;
        }
    }
    try printEvent(opts, decision.status, reg.active_account_key, if (decision.status == .blocked) null else target);
}

fn printEvent(opts: cli.types.AutoOptions, status: Status, from: ?[]const u8, to: ?[]const u8) !void {
    var stdout: io_util.Stdout = undefined;
    stdout.init();
    const out = stdout.out();
    if (opts.json) {
        var jw: std.json.Stringify = .{ .writer = out, .options = .{} };
        try jw.write(.{ .schema_version = @as(u32, 1), .command = "auto", .status = @tagName(status), .dry_run = opts.dry_run, .from = from, .to = to });
        try out.writeAll("\n");
    } else {
        try out.print("auto: {s}", .{@tagName(status)});
        if (to) |key| try out.print(" -> {s}", .{key});
        try out.writeAll("\n");
    }
    try out.flush();
}

pub fn handleAuto(allocator: std.mem.Allocator, codex_home: []const u8, opts: cli.types.AutoOptions) !void {
    runAuto(allocator, codex_home, opts) catch |err| {
        if (err == error.OutOfMemory or err == error.RegistryError) return err;
        if (opts.json) try cli.json_output.printError("auto_error", @errorName(err), null) else std.log.err("auto: {s}", .{@errorName(err)});
        return error.RegistryError;
    };
}

fn runAuto(allocator: std.mem.Allocator, codex_home: []const u8, opts: cli.types.AutoOptions) !void {
    // Keep the lock file in place: unlinking it would allow two different lock inodes.
    var lock: ?std.Io.File = null;
    defer if (lock) |file| file.close(runtime.io());
    if (!opts.dry_run) {
        const path = try std.fs.path.join(allocator, &.{ codex_home, "auto.lock" });
        defer allocator.free(path);
        lock = try std.Io.Dir.cwd().createFile(runtime.io(), path, .{ .truncate = false, .permissions = registry.private_file_permissions });
        if (!try lock.?.tryLock(runtime.io(), .exclusive)) {
            if (opts.json) try cli.json_output.printError("auto_running", "Another auto monitor holds the lock.", null) else std.log.err("Another auto monitor holds the lock.", .{});
            return error.RegistryError;
        }
    }
    while (true) {
        tick(allocator, codex_home, opts) catch |err| {
            if (err == error.OutOfMemory) return err;
            if (opts.json) try cli.json_output.printError("auto_error", @errorName(err), null) else std.log.err("auto: {s}", .{@errorName(err)});
            if (opts.once) return error.RegistryError;
        };
        if (opts.once) return;
        try std.Io.sleep(runtime.io(), .fromSeconds(opts.interval_seconds), .awake);
    }
}

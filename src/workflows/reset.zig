const std = @import("std");
const cli = @import("../cli/root.zig");
const registry = @import("../registry/root.zig");
const reset_credits_api = @import("../api/reset_credits.zig");
const transport_mod = @import("../api/transport.zig");
const query_mod = @import("query.zig");
const results = @import("results.zig");

const panel = cli.reset_credits_panel;

pub fn handleReset(allocator: std.mem.Allocator, transport: transport_mod.Transport, codex_home: []const u8, opts: cli.types.ResetOptions) !void {
    if (opts.json) return handleResetJson(allocator, transport, codex_home, opts);
    return handleResetInteractive(allocator, transport, codex_home, opts);
}

/// `collectAvailable` sorts by expiry ascending (no expiry last), so the
/// default redemption target is the first card. `--credit` picks by id
/// instead; a null return means the requested card is not available.
fn selectCardIndex(cards: []const panel.AvailableCard, credit: ?[]const u8) ?usize {
    const wanted = credit orelse return if (cards.len == 0) null else 0;
    for (cards, 0..) |card, index| {
        if (std.mem.eql(u8, card.id, wanted)) return index;
    }
    return null;
}

/// Index of the soonest-expiring card still available once `redeemed_index`
/// leaves the list, or null when none remains.
fn nextCardIndex(cards: []const panel.AvailableCard, redeemed_index: usize) ?usize {
    for (cards, 0..) |_, index| {
        if (index != redeemed_index) return index;
    }
    return null;
}

fn handleResetInteractive(allocator: std.mem.Allocator, transport: transport_mod.Transport, codex_home: []const u8, opts: cli.types.ResetOptions) !void {
    var reg = try registry.loadRegistry(allocator, codex_home);
    defer reg.deinit(allocator);

    var resolution = try query_mod.resolveSwitchQueryLocally(allocator, &reg, opts.selector);
    defer resolution.deinit(allocator);

    const account_key = switch (resolution) {
        .not_found => {
            try cli.output.printResetError("no account matches '{s}'.", .{opts.selector});
            return error.AccountNotFound;
        },
        .direct => |key| key,
        .multiple => {
            try cli.output.printResetError("`{s}` matches multiple accounts; use an exact email, alias, or account key.", .{opts.selector});
            return error.ResetFailed;
        },
    };
    const account_idx = registry.findAccountIndexByAccountKey(&reg, account_key) orelse {
        try cli.output.printResetError("no account matches '{s}'.", .{opts.selector});
        return error.AccountNotFound;
    };
    const rec = &reg.accounts.items[account_idx];

    const cards = try panel.collectAvailable(allocator, rec, &.{});
    defer allocator.free(cards);
    if (cards.len == 0) {
        try cli.output.printResetError("no available reset credits for {s}.", .{rec.email});
        return error.ResetFailed;
    }

    const card_index = selectCardIndex(cards, opts.credit) orelse {
        try cli.output.printResetError("no available reset credit `{s}` for {s}.", .{ opts.credit.?, rec.email });
        return error.ResetFailed;
    };
    const card = cards[card_index];
    const redeem_key = try reset_credits_api.generateIdempotencyKeyAlloc(allocator);
    defer allocator.free(redeem_key);
    var result = try reset_credits_api.consumeCreditForAccount(
        allocator,
        transport,
        codex_home,
        rec.account_key,
        redeem_key,
        card.id,
    );
    defer result.deinit(allocator);

    switch (result.outcome) {
        .reset, .already_redeemed => {
            // The redeemed card's own expiry is spent, so the summary reports only
            // what is left and when the next card expires.
            var next_expiry: ?[]u8 = null;
            if (nextCardIndex(cards, card_index)) |next_index| {
                if (cards[next_index].epoch != null) {
                    next_expiry = try cli.rows.formatCompactTimestampAlloc(allocator, cards[next_index].epoch);
                }
            }
            defer if (next_expiry) |text| allocator.free(text);
            try cli.output.printResetSummary(
                allocator,
                result.outcome == .already_redeemed,
                cards.len - 1,
                next_expiry,
            );
        },
        .no_credit => {
            try cli.output.printResetError("reset credit is no longer available; run `codex-auth list --api` to refresh.", .{});
            return error.ResetFailed;
        },
        .nothing_to_reset => {
            try cli.output.printResetError("usage does not need a reset right now.", .{});
            return error.ResetFailed;
        },
        .unexpected_response => {
            try cli.output.printResetError("reset failed: unexpected consume response (HTTP {?d}).", .{result.status_code});
            return error.ResetFailed;
        },
        .http_error => {
            try cli.output.printResetError("reset failed (HTTP {?d}).", .{result.status_code});
            return error.ResetFailed;
        },
        .request_error => {
            const detail = if (result.error_name) |name|
                reset_credits_api.describeRequestError(name)
            else
                "request error";
            try cli.output.printResetError("reset failed: {s}.", .{detail});
            return error.ResetFailed;
        },
    }
}

fn handleResetJson(allocator: std.mem.Allocator, transport: transport_mod.Transport, codex_home: []const u8, opts: cli.types.ResetOptions) !void {
    var reg = registry.loadRegistry(allocator, codex_home) catch |err| return printJsonWorkflowError(err);
    defer reg.deinit(allocator);

    var resolution = query_mod.resolveSwitchQueryLocally(allocator, &reg, opts.selector) catch |err| return printJsonWorkflowError(err);
    defer resolution.deinit(allocator);

    const account_key = switch (resolution) {
        .not_found => {
            const message = try allocator.print("no account matches \"{s}\"", .{opts.selector});
            defer allocator.free(message);
            try cli.json_output.printError("account_not_found", message, null);
            return error.AccountNotFound;
        },
        .direct => |key| key,
        .multiple => |matches| {
            const candidates = results.buildAccountViewsForIndices(allocator, &reg, null, matches.items) catch |err| return printJsonWorkflowError(err);
            defer results.deinitAccountViews(allocator, candidates);
            const message = try allocator.print("query \"{s}\" matches multiple accounts", .{opts.selector});
            defer allocator.free(message);
            try cli.json_output.printError("ambiguous_query", message, candidates);
            return error.AmbiguousQuery;
        },
    };
    const account_idx = registry.findAccountIndexByAccountKey(&reg, account_key) orelse {
        const message = try allocator.print("no account matches \"{s}\"", .{opts.selector});
        defer allocator.free(message);
        try cli.json_output.printError("account_not_found", message, null);
        return error.AccountNotFound;
    };
    const rec = &reg.accounts.items[account_idx];

    const cards = panel.collectAvailable(allocator, rec, &.{}) catch |err| return printJsonWorkflowError(err);
    defer allocator.free(cards);

    const card_index = selectCardIndex(cards, opts.credit) orelse {
        if (opts.credit) |credit_id| {
            const message = try allocator.print("no available reset credit \"{s}\" for {s}", .{ credit_id, rec.email });
            defer allocator.free(message);
            try cli.json_output.printError("reset_credit_not_found", message, null);
        } else {
            const message = try allocator.print("no available reset credits for {s}", .{rec.email});
            defer allocator.free(message);
            try cli.json_output.printError("no_reset_credit", message, null);
        }
        return error.ResetFailed;
    };
    const card = cards[card_index];
    const redeem_key = try reset_credits_api.generateIdempotencyKeyAlloc(allocator);
    defer allocator.free(redeem_key);
    var consume = reset_credits_api.consumeCreditForAccount(
        allocator,
        transport,
        codex_home,
        rec.account_key,
        redeem_key,
        card.id,
    ) catch |err| return printJsonWorkflowError(err);
    defer consume.deinit(allocator);

    switch (consume.outcome) {
        .reset, .already_redeemed => {
            const next_index = nextCardIndex(cards, card_index);
            var result = results.buildResetResult(
                allocator,
                &reg,
                rec.account_key,
                consume.outcome,
                cards.len - 1,
                if (next_index) |idx| cards[idx].expires_at else null,
            ) catch |err| return printJsonWorkflowError(err);
            defer result.deinit(allocator);
            try cli.json_output.printResetResult(&result);
        },
        .no_credit => {
            try cli.json_output.printError("no_reset_credit", "reset credit is no longer available; run `codex-auth list --api` to refresh.", null);
            return error.ResetFailed;
        },
        .nothing_to_reset => {
            try cli.json_output.printError("nothing_to_reset", "usage does not need a reset right now.", null);
            return error.ResetFailed;
        },
        .unexpected_response => {
            const message = try allocator.print("reset failed: unexpected consume response (HTTP {?d}).", .{consume.status_code});
            defer allocator.free(message);
            try cli.json_output.printError("reset_failed", message, null);
            return error.ResetFailed;
        },
        .http_error => {
            const message = try allocator.print("reset failed (HTTP {?d}).", .{consume.status_code});
            defer allocator.free(message);
            try cli.json_output.printError("reset_failed", message, null);
            return error.ResetFailed;
        },
        .request_error => {
            const detail = if (consume.error_name) |name|
                reset_credits_api.describeRequestError(name)
            else
                "request error";
            const message = try allocator.print("reset failed: {s}.", .{detail});
            defer allocator.free(message);
            try cli.json_output.printError("reset_failed", message, null);
            return error.ResetFailed;
        },
    }
}

fn printJsonWorkflowError(err: anyerror) anyerror {
    switch (err) {
        error.OutOfMemory => return err,
        error.CurlRequired => {
            try cli.json_output.printError(
                "curl_unavailable",
                "curl is required for API requests. Install curl and retry.",
                null,
            );
            return err;
        },
        else => {
            try cli.json_output.printError("registry_error", @errorName(err), null);
            return error.RegistryError;
        },
    }
}

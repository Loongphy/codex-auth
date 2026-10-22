const std = @import("std");
const cli = @import("../cli/root.zig");
const registry = @import("../registry/root.zig");
const reset_credits_api = @import("../api/reset_credits.zig");
const query_mod = @import("query.zig");

const panel = cli.reset_credits_panel;

pub fn handleReset(allocator: std.mem.Allocator, codex_home: []const u8, opts: cli.types.ResetOptions) !void {
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

    // collectAvailable sorts by expiry ascending (no expiry last), so the
    // first card is the one that expires soonest.
    const card = cards[0];
    const redeem_key = try reset_credits_api.generateIdempotencyKeyAlloc(allocator);
    defer allocator.free(redeem_key);
    var result = try reset_credits_api.consumeCreditForAccount(
        allocator,
        codex_home,
        rec.account_key,
        redeem_key,
        card.id,
    );
    defer result.deinit(allocator);

    switch (result.outcome) {
        .reset, .already_redeemed => {
            const expires_local = if (card.epoch) |epoch|
                try cli.rows.formatTimestampAlloc(allocator, epoch)
            else
                null;
            defer if (expires_local) |text| allocator.free(text);
            try cli.output.printResetConsumed(rec.email, card.title, expires_local, result.outcome == .already_redeemed);

            var remaining = std.ArrayList(cli.output.ResetRemainingEntry).empty;
            defer {
                for (remaining.items) |entry| {
                    if (entry.expires_local) |text| allocator.free(text);
                }
                remaining.deinit(allocator);
            }
            for (cards[1..]) |remaining_card| {
                const remaining_expiry = if (remaining_card.epoch) |epoch|
                    try cli.rows.formatTimestampAlloc(allocator, epoch)
                else
                    null;
                try remaining.append(allocator, .{
                    .title = remaining_card.title,
                    .expires_local = remaining_expiry,
                });
            }
            try cli.output.printResetRemaining(rec.email, remaining.items);
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
            try cli.output.printResetError("reset failed: {s}.", .{result.error_name orelse "request error"});
            return error.ResetFailed;
        },
    }
}

const std = @import("std");
const timestamp = @import("codex_auth").time.timestamp;

test "parseIso8601 accepts UTC, numeric offsets, and fractional seconds" {
    try std.testing.expectEqual(
        @as(?i64, 1776920618),
        timestamp.parseIso8601("2026-04-23T05:03:38+00:00"),
    );
    try std.testing.expectEqual(
        @as(?i64, 1791277871),
        timestamp.parseIso8601("2026-10-06T18:11:11+09:00"),
    );
    try std.testing.expectEqual(
        @as(?i64, 1787650573),
        timestamp.parseIso8601("2026-08-25T09:36:13.284171+00:00"),
    );
    try std.testing.expectEqual(
        @as(?i64, 1785326940),
        timestamp.parseIso8601("2026-07-29T12:09:00Z"),
    );
    try std.testing.expectEqual(
        @as(?i64, 1785326940),
        timestamp.parseIso8601("2026-07-29T12:09:00"),
    );
    try std.testing.expectEqual(
        @as(?i64, 1785294540),
        timestamp.parseIso8601("2026-07-29T12:09:00+0900"),
    );
    try std.testing.expectEqual(
        @as(?i64, 1785294540),
        timestamp.parseIso8601("2026-07-29T12:09:00+09"),
    );
}

test "parseIso8601 rejects malformed or impossible timestamps" {
    try std.testing.expectEqual(@as(?i64, null), timestamp.parseIso8601("not-a-date"));
    try std.testing.expectEqual(@as(?i64, null), timestamp.parseIso8601("2026-02-30T00:00:00Z"));
    try std.testing.expectEqual(@as(?i64, null), timestamp.parseIso8601("2026-07-29T12:09:00+090"));
    try std.testing.expectEqual(@as(?i64, null), timestamp.parseIso8601("2026-07-29T12:09:00Zjunk"));
}

test "epochSeconds normalizes seconds, milliseconds, and microseconds" {
    try std.testing.expectEqual(@as(i64, 1_785_326_940), timestamp.epochSeconds(1_785_326_940));
    try std.testing.expectEqual(@as(i64, 1_785_326_940), timestamp.epochSeconds(1_785_326_940_000));
    try std.testing.expectEqual(@as(i64, 1_785_326_940), timestamp.epochSeconds(1_785_326_940_000_000));
    try std.testing.expectEqual(@as(i64, -1_785_326_940), timestamp.epochSeconds(-1_785_326_940_000));
}

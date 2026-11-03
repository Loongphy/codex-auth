const std = @import("std");

/// Parses an RFC 3339 / ISO-8601 timestamp into Unix seconds.
///
/// Accepts an optional fractional second and a `Z`, `±HH`, `±HHMM`, or
/// `±HH:MM` offset. A missing offset is treated as UTC.
pub fn parseIso8601(value: []const u8) ?i64 {
    const text = std.mem.trim(u8, value, &std.ascii.whitespace);
    if (text.len < 19 or text[4] != '-' or text[7] != '-' or
        (text[10] != 'T' and text[10] != 't') or text[13] != ':' or text[16] != ':')
    {
        return null;
    }

    const year = std.fmt.parseInt(i64, text[0..4], 10) catch return null;
    const month = std.fmt.parseInt(i64, text[5..7], 10) catch return null;
    const day = std.fmt.parseInt(i64, text[8..10], 10) catch return null;
    const hour = std.fmt.parseInt(i64, text[11..13], 10) catch return null;
    const minute = std.fmt.parseInt(i64, text[14..16], 10) catch return null;
    const second = std.fmt.parseInt(i64, text[17..19], 10) catch return null;
    if (month < 1 or month > 12 or day < 1 or day > daysInMonth(year, month) or
        hour < 0 or hour > 23 or minute < 0 or minute > 59 or second < 0 or second > 59)
    {
        return null;
    }

    var index: usize = 19;
    if (index < text.len and text[index] == '.') {
        index += 1;
        const fraction_start = index;
        while (index < text.len and std.ascii.isDigit(text[index])) : (index += 1) {}
        if (index == fraction_start) return null;
    }

    var offset_seconds: i64 = 0;
    if (index < text.len) {
        switch (text[index]) {
            'Z', 'z' => index += 1,
            '+', '-' => {
                const sign: i64 = if (text[index] == '+') -1 else 1;
                index += 1;
                const offset_hour_start = index;
                var offset_hour_digits: usize = 0;
                while (offset_hour_digits < 2 and index < text.len and std.ascii.isDigit(text[index])) {
                    index += 1;
                    offset_hour_digits += 1;
                }
                if (offset_hour_digits != 2) return null;
                const offset_hour = std.fmt.parseInt(i64, text[offset_hour_start..index], 10) catch return null;
                if (offset_hour > 23) return null;

                var offset_minute: i64 = 0;
                if (index < text.len) {
                    if (text[index] == ':') index += 1;
                    const offset_minute_start = index;
                    var offset_minute_digits: usize = 0;
                    while (offset_minute_digits < 2 and index < text.len and std.ascii.isDigit(text[index])) {
                        index += 1;
                        offset_minute_digits += 1;
                    }
                    if (offset_minute_digits != 2) return null;
                    offset_minute = std.fmt.parseInt(i64, text[offset_minute_start..index], 10) catch return null;
                    if (offset_minute > 59) return null;
                }
                offset_seconds = sign * (offset_hour * 3600 + offset_minute * 60);
            },
            else => return null,
        }
    }
    if (index != text.len) return null;

    return daysFromCivil(year, month, day) * 86400 +
        hour * 3600 + minute * 60 + second +
        offset_seconds;
}

/// Converts an epoch value expressed in seconds, milliseconds, or microseconds
/// to seconds.
pub fn epochSeconds(value: i64) i64 {
    var result = value;
    while (result >= 1_000_000_000_000 or result <= -1_000_000_000_000) {
        result = @divTrunc(result, 1000);
    }
    return result;
}

fn daysInMonth(year: i64, month: i64) i64 {
    return switch (month) {
        1, 3, 5, 7, 8, 10, 12 => 31,
        4, 6, 9, 11 => 30,
        2 => if (isLeapYear(year)) 29 else 28,
        else => 0,
    };
}

fn isLeapYear(year: i64) bool {
    return @mod(year, 4) == 0 and (@mod(year, 100) != 0 or @mod(year, 400) == 0);
}

/// Howard Hinnant's days_from_civil algorithm.
fn daysFromCivil(year: i64, month: i64, day: i64) i64 {
    var y = year;
    if (month <= 2) y -= 1;
    const era = @divFloor(y, 400);
    const yoe = y - era * 400;
    const mp = @mod(month + 9, 12);
    const doy = @divFloor(153 * mp + 2, 5) + day - 1;
    const doe = yoe * 365 + @divFloor(yoe, 4) - @divFloor(yoe, 100) + doy;
    return era * 146097 + doe - 719468;
}

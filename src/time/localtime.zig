const std = @import("std");
const builtin = @import("builtin");

const c = @import("c_time");

/// One `struct_tm` type for every caller: the translate-c `c_time` module is
/// shared through this file so the conversion and its type live here exactly
/// once.
pub const struct_tm = c.struct_tm;

/// Converts `ts` (Unix seconds) to local time. Returns false when the
/// platform conversion fails or the value does not fit the platform `time_t`.
/// On Windows this binds directly to the exported CRT symbol.
pub fn compat(ts: i64, out_tm: *struct_tm) bool {
    if (comptime builtin.target.os.tag == .windows) {
        if (comptime @hasDecl(c, "_localtime64_s") and @hasDecl(c, "__time64_t")) {
            var t64 = std.math.cast(c.__time64_t, ts) orelse return false;
            return c._localtime64_s(out_tm, &t64) == 0;
        }
        return false;
    }

    var t = std.math.cast(c.time_t, ts) orelse return false;
    if (comptime @hasDecl(c, "localtime_r")) {
        return c.localtime_r(&t, out_tm) != null;
    }

    if (comptime @hasDecl(c, "localtime")) {
        const tm_ptr = c.localtime(&t);
        if (tm_ptr == null) return false;
        out_tm.* = tm_ptr.*;
        return true;
    }

    return false;
}

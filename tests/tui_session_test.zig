const std = @import("std");
const cli = @import("codex_auth").cli;

const TuiNavigation = cli.tui.TuiNavigation;
const TuiEscapeClassification = cli.tui.TuiEscapeClassification;
const TuiEscapeAction = cli.tui.TuiEscapeAction;
const classifyTuiEscapeSuffix = cli.tui.classifyTuiEscapeSuffix;
const readTuiEscapeAction = cli.tui.readTuiEscapeAction;
const appendTuiInputKeysFromEscape = cli.tui.appendTuiInputKeysFromEscape;
const tuiInputKeyFromByte = cli.tui.tuiInputKeyFromByte;
const writeTuiEnterTo = cli.tui.writeTuiEnterTo;
const writeTuiExitTo = cli.tui.writeTuiExitTo;
const writeTuiFrameTo = cli.tui.writeTuiFrameTo;
const writeTuiResetFrameTo = cli.tui.writeTuiResetFrameTo;
const writeTuiPromptLine = cli.tui.writeTuiPromptLine;
const windowsTuiInputMode = cli.tui.windowsTuiInputMode;
const windowsTuiOutputMode = cli.tui.windowsTuiOutputMode;
const win = cli.tui.win32;

test "Scenario: Given tty arrow escape suffixes when classifying them then both CSI and SS3 arrows are recognized" {
    switch (classifyTuiEscapeSuffix("[A")) {
        .navigation => |direction| try std.testing.expectEqual(TuiNavigation.up, direction),
        else => return error.TestUnexpectedResult,
    }
    switch (classifyTuiEscapeSuffix("[1;2B")) {
        .navigation => |direction| try std.testing.expectEqual(TuiNavigation.keyboard_down, direction),
        else => return error.TestUnexpectedResult,
    }
    switch (classifyTuiEscapeSuffix("OA")) {
        .navigation => |direction| try std.testing.expectEqual(TuiNavigation.up, direction),
        else => return error.TestUnexpectedResult,
    }
}

test "Scenario: Given keyboard enhancement responses and keys when classifying them then enhanced arrows stay distinct from alternate scroll arrows" {
    try std.testing.expectEqual(TuiEscapeClassification.keyboard_enhancement_supported, classifyTuiEscapeSuffix("[?7u"));
    // The flags value decides: a `?0u` reply means the query was answered but
    // no pushed flag applied, so legacy bytes still carry real keys. Only the
    // disambiguate bit (1) flips the parser into enhancement mode.
    try std.testing.expectEqual(TuiEscapeClassification.ignore, classifyTuiEscapeSuffix("[?0u"));
    try std.testing.expectEqual(TuiEscapeClassification.ignore, classifyTuiEscapeSuffix("[?2u"));
    try std.testing.expectEqual(TuiEscapeClassification.ignore, classifyTuiEscapeSuffix("[?8u"));
    try std.testing.expectEqual(TuiEscapeClassification.keyboard_enhancement_supported, classifyTuiEscapeSuffix("[?1u"));
    try std.testing.expectEqual(TuiEscapeClassification.keyboard_enhancement_supported, classifyTuiEscapeSuffix("[?9u"));
    switch (classifyTuiEscapeSuffix("[1;1:1A")) {
        .navigation => |direction| try std.testing.expectEqual(TuiNavigation.keyboard_up, direction),
        else => return error.TestUnexpectedResult,
    }
    switch (classifyTuiEscapeSuffix("[57420;1u")) {
        .key => |key| try std.testing.expectEqual(cli.tui.TuiInputKey.keyboard_down, key),
        else => return error.TestUnexpectedResult,
    }

    const result = try readTuiEscapeAction(std.Io.File.stdin(), "[1;1:1A", 0, 0);
    try std.testing.expectEqual(TuiEscapeAction.keyboard_up, result.action);
}

test "Scenario: Given kitty CSI-u key events when classifying them then disambiguated keys keep their meaning" {
    // `\x1b[>7u` asks terminals for the kitty keyboard protocol, where the
    // disambiguate flag reports Esc/Enter/Backspace as CSI-u instead of their
    // legacy bytes — a terminal honoring it would otherwise leave Esc dead.
    const Key = cli.tui.TuiInputKey;
    const cases = .{
        .{ "[27u", Key.quit },
        .{ "[13u", Key.enter },
        .{ "[127u", Key.backspace },
        .{ "[57419u", Key.keyboard_up },
        .{ "[57420;1u", Key.keyboard_down },
        // Ctrl-C arrives as `99;5` (key 'c' + ctrl), not byte 0x03.
        .{ "[99;5u", Key.quit },
        .{ "[99;6u", Key.quit },
    };
    inline for (cases) |case| {
        switch (classifyTuiEscapeSuffix(case[0])) {
            .key => |key| try std.testing.expectEqual(case[1], key),
            else => return error.TestUnexpectedResult,
        }
    }

    // Key releases (event type 3) must not re-fire; press and repeat do.
    try std.testing.expectEqual(TuiEscapeClassification.ignore, classifyTuiEscapeSuffix("[57419;1:3u"));
    try std.testing.expectEqual(TuiEscapeClassification.ignore, classifyTuiEscapeSuffix("[27;1:3u"));
    try std.testing.expectEqual(TuiEscapeClassification.ignore, classifyTuiEscapeSuffix("[97u"));

    // The action a live session sees for a CSI-u Esc is the same quit a bare
    // \x1b produces — closing the rail before exiting.
    const esc_result = try readTuiEscapeAction(std.Io.File.stdin(), "[27u", 0, 0);
    try std.testing.expectEqual(TuiEscapeAction.quit, esc_result.action);
    try std.testing.expectEqual(@as(usize, 4), esc_result.buffered_bytes_consumed);
    const enter_result = try readTuiEscapeAction(std.Io.File.stdin(), "[13u", 0, 0);
    try std.testing.expectEqual(TuiEscapeAction.enter, enter_result.action);
}

test "Scenario: Given kitty letter-form key events when classifying them then releases are ignored" {
    // Kitty reports a release as `key;mods:3` in the CSI-letter forms — the
    // same event type the CSI-u decoder filters. One physical press+release
    // must produce exactly one navigation, not two.
    for ([_][]const u8{ "[1;1:3B", "[1;1:3A", "[1;1:3H", "[1;1:3F", "[5;1:3~", "[6;1:3~" }) |seq| {
        try std.testing.expectEqual(TuiEscapeClassification.ignore, classifyTuiEscapeSuffix(seq));
    }

    // Press (1) and repeat (2) still fire — a held key must keep moving.
    for ([_][]const u8{ "[1;1:1B", "[1;1:2B" }) |seq| {
        switch (classifyTuiEscapeSuffix(seq)) {
            .navigation => |direction| try std.testing.expectEqual(TuiNavigation.keyboard_down, direction),
            else => return error.TestUnexpectedResult,
        }
    }

    // Event-typed or modified home/end/page keys reach the parser instead of
    // being dropped by the old digits-only scan; modifiers stay unbound.
    const nav_cases = .{
        .{ "[1;1:1H", TuiNavigation.home },
        .{ "[1;5F", TuiNavigation.end },
        .{ "[5;1:1~", TuiNavigation.page_up },
        .{ "[6;3~", TuiNavigation.page_down },
        .{ "[6~", TuiNavigation.page_down },
    };
    inline for (nav_cases) |case| {
        switch (classifyTuiEscapeSuffix(case[0])) {
            .navigation => |direction| try std.testing.expectEqual(case[1], direction),
            else => return error.TestUnexpectedResult,
        }
    }
}

test "Scenario: Given a bare Esc followed by a non-sequence byte when reading input then the Esc quits and the byte replays" {
    const gpa = std.testing.allocator;
    _ = gpa;

    // Fast typing / auto-repeat: the `j` lands inside the escape window. The
    // Esc must still quit and the byte must come back as a normal key instead
    // of both vanishing into an unknown-sequence `.ignore`.
    const swallowed_pair = try readTuiEscapeAction(std.Io.File.stdin(), "j", 0, 0);
    try std.testing.expectEqual(TuiEscapeAction.quit, swallowed_pair.action);
    try std.testing.expectEqual(@as(usize, 1), swallowed_pair.buffered_bytes_consumed);
    try std.testing.expectEqual(@as(?u8, 'j'), swallowed_pair.pending_byte);

    // The same for an Esc replaying another Esc (a double-tap of Escape).
    const double_tap = try readTuiEscapeAction(std.Io.File.stdin(), "\x1b", 0, 0);
    try std.testing.expectEqual(TuiEscapeAction.quit, double_tap.action);
    try std.testing.expectEqual(@as(usize, 1), double_tap.buffered_bytes_consumed);
    try std.testing.expectEqual(@as(?u8, 0x1b), double_tap.pending_byte);

    // Sequence bytes are untouched: `[` opens the CSI path and still parses.
    const sequence = try readTuiEscapeAction(std.Io.File.stdin(), "[A", 0, 0);
    try std.testing.expectEqual(TuiEscapeAction.move_up, sequence.action);
    try std.testing.expectEqual(@as(?u8, null), sequence.pending_byte);

    // A bare Esc with nothing following stays the plain quit.
    const bare = try readTuiEscapeAction(std.Io.File.stdin(), "", 0, 0);
    try std.testing.expectEqual(TuiEscapeAction.quit, bare.action);
    try std.testing.expectEqual(@as(?u8, null), bare.pending_byte);
}

test "Scenario: Given raw bytes when mapping them to input keys then Enter Backspace and Ctrl-C stay canonical" {
    try std.testing.expectEqual(cli.tui.TuiInputKey.enter, tuiInputKeyFromByte('\r'));
    try std.testing.expectEqual(cli.tui.TuiInputKey.enter, tuiInputKeyFromByte('\n'));
    try std.testing.expectEqual(cli.tui.TuiInputKey.backspace, tuiInputKeyFromByte(0x7f));
    try std.testing.expectEqual(cli.tui.TuiInputKey.backspace, tuiInputKeyFromByte(0x08));
    // ISIG stays off for the session so Ctrl-C arrives as byte 0x03, mapped to
    // the same quit key as Esc/q — that is what lets deinit restore the tty.
    try std.testing.expectEqual(cli.tui.TuiInputKey.quit, tuiInputKeyFromByte(0x03));
    switch (tuiInputKeyFromByte('j')) {
        .byte => |byte| try std.testing.expectEqual(@as(u8, 'j'), byte),
        else => return error.TestUnexpectedResult,
    }
}

test "Scenario: Given a pending byte after a standalone Esc when replaying it then control bytes keep their normal meaning" {
    const tty = std.Io.File.stdin();
    var keys: [8]cli.tui.TuiInputKey = undefined;
    var supported = false;

    // Esc+Enter inside one read batch: the Enter must still be `.enter`, not a
    // dropped `.byte`, or the key is silently lost.
    var key_count: usize = 0;
    const consumed_enter = try appendTuiInputKeysFromEscape(tty, "\r", &keys, &key_count, &supported);
    try std.testing.expectEqual(@as(usize, 1), consumed_enter);
    try std.testing.expectEqual(@as(usize, 2), key_count);
    try std.testing.expectEqual(cli.tui.TuiInputKey.quit, keys[0]);
    try std.testing.expectEqual(cli.tui.TuiInputKey.enter, keys[1]);

    key_count = 0;
    const consumed_bs = try appendTuiInputKeysFromEscape(tty, "\x7f", &keys, &key_count, &supported);
    try std.testing.expectEqual(@as(usize, 1), consumed_bs);
    try std.testing.expectEqual(@as(usize, 2), key_count);
    try std.testing.expectEqual(cli.tui.TuiInputKey.quit, keys[0]);
    try std.testing.expectEqual(cli.tui.TuiInputKey.backspace, keys[1]);

    // A plain byte still replays as a byte.
    key_count = 0;
    const consumed_j = try appendTuiInputKeysFromEscape(tty, "j", &keys, &key_count, &supported);
    try std.testing.expectEqual(@as(usize, 1), consumed_j);
    try std.testing.expectEqual(@as(usize, 2), key_count);
    try std.testing.expectEqual(cli.tui.TuiInputKey.quit, keys[0]);
    switch (keys[1]) {
        .byte => |byte| try std.testing.expectEqual(@as(u8, 'j'), byte),
        else => return error.TestUnexpectedResult,
    }
}

test "Scenario: Given Esc followed by an escape sequence when replaying it then the sequence is not mistaken for a second Esc" {
    const tty = std.Io.File.stdin();
    var keys: [8]cli.tui.TuiInputKey = undefined;
    var supported = false;

    // Esc+Arrow-Up in one batch (fast typing, a paste, or a wheel the terminal
    // translates): the second Esc heads a real sequence, so the keys are quit
    // plus move_up — never quit plus quit, which would exit a live session.
    var key_count: usize = 0;
    const consumed = try appendTuiInputKeysFromEscape(tty, "\x1b[A", &keys, &key_count, &supported);
    try std.testing.expectEqual(@as(usize, 3), consumed);
    try std.testing.expectEqual(@as(usize, 2), key_count);
    try std.testing.expectEqual(cli.tui.TuiInputKey.quit, keys[0]);
    try std.testing.expectEqual(cli.tui.TuiInputKey.move_up, keys[1]);

    // SS3 arrows take the same path.
    key_count = 0;
    const consumed_ss3 = try appendTuiInputKeysFromEscape(tty, "\x1bOB", &keys, &key_count, &supported);
    try std.testing.expectEqual(@as(usize, 3), consumed_ss3);
    try std.testing.expectEqual(cli.tui.TuiInputKey.quit, keys[0]);
    try std.testing.expectEqual(cli.tui.TuiInputKey.move_down, keys[1]);

    // Esc Esc Esc then a byte: every standalone Esc is its own quit and the
    // trailing byte still replays.
    key_count = 0;
    const consumed_triple = try appendTuiInputKeysFromEscape(tty, "\x1b\x1bj", &keys, &key_count, &supported);
    try std.testing.expectEqual(@as(usize, 3), consumed_triple);
    try std.testing.expectEqual(@as(usize, 4), key_count);
    try std.testing.expectEqual(cli.tui.TuiInputKey.quit, keys[0]);
    try std.testing.expectEqual(cli.tui.TuiInputKey.quit, keys[1]);
    try std.testing.expectEqual(cli.tui.TuiInputKey.quit, keys[2]);
    switch (keys[3]) {
        .byte => |byte| try std.testing.expectEqual(@as(u8, 'j'), byte),
        else => return error.TestUnexpectedResult,
    }
}

test "Scenario: Given a kitty enhancement ACK when reading legacy arrows then they reclassify as wheel scrolls" {
    const tty = std.Io.File.stdin();
    var keys: [8]cli.tui.TuiInputKey = undefined;
    var supported = false;
    var key_count: usize = 0;

    // The contract this branch ships: before any ACK a bare ESC[A stays a
    // cursor key so arrows keep working on terminals that never answer.
    _ = try appendTuiInputKeysFromEscape(tty, "[A", &keys, &key_count, &supported);
    try std.testing.expectEqual(@as(usize, 1), key_count);
    try std.testing.expectEqual(cli.tui.TuiInputKey.move_up, keys[0]);

    // The terminal's `CSI ?1u` reply sets the flag without emitting a key.
    key_count = 0;
    _ = try appendTuiInputKeysFromEscape(tty, "[?1u", &keys, &key_count, &supported);
    try std.testing.expect(supported);
    try std.testing.expectEqual(@as(usize, 0), key_count);

    // After the ACK the only producer of a bare ESC[A/ESC[B is the
    // ?1007h alternate-scroll fallback — it is a wheel notch.
    key_count = 0;
    _ = try appendTuiInputKeysFromEscape(tty, "[A", &keys, &key_count, &supported);
    try std.testing.expectEqual(@as(usize, 1), key_count);
    try std.testing.expectEqual(cli.tui.TuiInputKey.scroll_up, keys[0]);

    key_count = 0;
    _ = try appendTuiInputKeysFromEscape(tty, "[B", &keys, &key_count, &supported);
    try std.testing.expectEqual(cli.tui.TuiInputKey.scroll_down, keys[0]);

    // SS3 arrows take the same reclass path.
    key_count = 0;
    _ = try appendTuiInputKeysFromEscape(tty, "OA", &keys, &key_count, &supported);
    try std.testing.expectEqual(cli.tui.TuiInputKey.scroll_up, keys[0]);

    // Enhanced kitty arrows are not reclassified — they stay keyboard keys.
    key_count = 0;
    _ = try appendTuiInputKeysFromEscape(tty, "[1;1A", &keys, &key_count, &supported);
    try std.testing.expectEqual(cli.tui.TuiInputKey.keyboard_up, keys[0]);
}

test "Scenario: Given tty paging and mouse wheel escape suffixes when classifying them then scrolling actions are recognized" {
    switch (classifyTuiEscapeSuffix("[6~")) {
        .navigation => |direction| try std.testing.expectEqual(TuiNavigation.page_down, direction),
        else => return error.TestUnexpectedResult,
    }
    switch (classifyTuiEscapeSuffix("[5~")) {
        .navigation => |direction| try std.testing.expectEqual(TuiNavigation.page_up, direction),
        else => return error.TestUnexpectedResult,
    }
    switch (classifyTuiEscapeSuffix("[H")) {
        .navigation => |direction| try std.testing.expectEqual(TuiNavigation.home, direction),
        else => return error.TestUnexpectedResult,
    }
    switch (classifyTuiEscapeSuffix("[F")) {
        .navigation => |direction| try std.testing.expectEqual(TuiNavigation.end, direction),
        else => return error.TestUnexpectedResult,
    }
    switch (classifyTuiEscapeSuffix("[<65;12;4M")) {
        .navigation => |direction| try std.testing.expectEqual(TuiNavigation.scroll_down, direction),
        else => return error.TestUnexpectedResult,
    }
    switch (classifyTuiEscapeSuffix("[<64;12;4M")) {
        .navigation => |direction| try std.testing.expectEqual(TuiNavigation.scroll_up, direction),
        else => return error.TestUnexpectedResult,
    }
    // Modifier bits ride the middle of the button code — a shifted or
    // ctrl-held wheel notch is still the same scroll.
    switch (classifyTuiEscapeSuffix("[<68;12;4M")) {
        .navigation => |direction| try std.testing.expectEqual(TuiNavigation.scroll_up, direction),
        else => return error.TestUnexpectedResult,
    }
    switch (classifyTuiEscapeSuffix("[<81;12;4M")) {
        .navigation => |direction| try std.testing.expectEqual(TuiNavigation.scroll_down, direction),
        else => return error.TestUnexpectedResult,
    }
    // `m` releases and motion-coded reports (bit 5) are not wheel notches.
    try std.testing.expectEqual(TuiEscapeClassification.ignore, classifyTuiEscapeSuffix("[<64;12;4m"));
    try std.testing.expectEqual(TuiEscapeClassification.ignore, classifyTuiEscapeSuffix("[<96;12;4M"));
    try std.testing.expectEqual(TuiEscapeClassification.ignore, classifyTuiEscapeSuffix("[<0;12;4M"));
}

test "Scenario: Given long SGR mouse wheel escape suffix when reading it then the full sequence is consumed" {
    const result = try readTuiEscapeAction(std.Io.File.stdin(), "[<65;120;40M", 0, 0);
    try std.testing.expectEqual(TuiEscapeAction.scroll_down, result.action);
    try std.testing.expectEqual(@as(usize, "[<65;120;40M".len), result.buffered_bytes_consumed);
}

test "Scenario: Given X10 mouse reports when reading them then the three coordinate bytes are consumed as one ignored report" {
    // Terminals honouring `?1000h` but not `?1006h` answer wheel notches with
    // X10 `ESC [ M Cb Cx Cy`. The coordinates must be eaten with the report —
    // a digit-shaped column byte would otherwise land in a picker prompt.
    try std.testing.expectEqual(TuiEscapeClassification.incomplete, classifyTuiEscapeSuffix("[M"));
    try std.testing.expectEqual(TuiEscapeClassification.incomplete, classifyTuiEscapeSuffix("[M\x60\x21"));
    try std.testing.expectEqual(TuiEscapeClassification.ignore, classifyTuiEscapeSuffix("[M\x60\x21\x21"));

    const result = try readTuiEscapeAction(std.Io.File.stdin(), "[M\x60\x35\x39", 0, 0);
    try std.testing.expectEqual(TuiEscapeAction.ignore, result.action);
    try std.testing.expectEqual(@as(usize, 5), result.buffered_bytes_consumed);
}

test "Scenario: Given terminal env hints when deciding the kitty request then mis-encoding and byte-less brands are skipped" {
    const builtin = @import("builtin");
    const kittyRequestAllowed = cli.tui.kittyRequestAllowed;

    // The Windows console reads INPUT_RECORDs, so the request is always
    // withheld there regardless of brand.
    if (builtin.target.os.tag == .windows) {
        try std.testing.expect(!kittyRequestAllowed(.{}));
        try std.testing.expect(!kittyRequestAllowed(.{ .term_program = "kitty" }));
        return;
    }

    // The default — unknown terminals included — still gets the request: the
    // `?u` query is the honest fallback when the brand is unrecognized.
    try std.testing.expect(kittyRequestAllowed(.{}));
    try std.testing.expect(kittyRequestAllowed(.{ .term_program = "iTerm.app" }));
    try std.testing.expect(kittyRequestAllowed(.{ .term_program = "kitty" }));
    try std.testing.expect(kittyRequestAllowed(.{ .term_program = "tmux" }));

    // Brands that mis-encode or half-claim the protocol stay on legacy input.
    try std.testing.expect(!kittyRequestAllowed(.{ .term_program = "vscode" }));
    try std.testing.expect(!kittyRequestAllowed(.{ .term_program = "Apple_Terminal" }));
    try std.testing.expect(!kittyRequestAllowed(.{ .term_program = "JetBrains-JediTerm" }));
    try std.testing.expect(!kittyRequestAllowed(.{ .terminal_emulator = "JetBrains-JediTerm" }));
    try std.testing.expect(!kittyRequestAllowed(.{ .wt_session = true }));
    try std.testing.expect(!kittyRequestAllowed(.{ .vte_version = true }));
}

test "Scenario: Given unrelated tty escape suffixes when classifying them then they are ignored instead of acting like quit" {
    try std.testing.expectEqual(TuiEscapeClassification.ignore, classifyTuiEscapeSuffix("x"));
    try std.testing.expectEqual(TuiEscapeClassification.ignore, classifyTuiEscapeSuffix("[200~"));
    try std.testing.expectEqual(TuiEscapeClassification.incomplete, classifyTuiEscapeSuffix("["));
}

test "Scenario: Given shared TUI screen lifecycle when writing it then switch and remove can stay inside the alternate screen" {
    const gpa = std.testing.allocator;
    var aw: std.Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();

    try writeTuiEnterTo(&aw.writer, true);
    try writeTuiExitTo(&aw.writer, true);

    try std.testing.expectEqualStrings(
        "\x1b[?1049h\x1b[?25l\x1b[?1007h\x1b[?1000h\x1b[?1006h" ++
            "\x1b[>7u\x1b[?u" ++
            "\x1b[H\x1b[J" ++
            "\x1b[<1u\x1b[?1006l\x1b[?1000l\x1b[?1007l\x1b[?25h\x1b[?1049l",
        aw.written(),
    );
    try std.testing.expect(std.mem.find(u8, aw.written(), "\x1b[?1007h") != null);
    try std.testing.expect(std.mem.find(u8, aw.written(), "\x1b[?1007l") != null);
    // SGR mouse reporting is the wheel's first-class path; motion and the
    // legacy X10-coordinate modes stay off on purpose.
    try std.testing.expect(std.mem.find(u8, aw.written(), "\x1b[?1000h") != null);
    try std.testing.expect(std.mem.find(u8, aw.written(), "\x1b[?1006h") != null);
    try std.testing.expect(std.mem.find(u8, aw.written(), "\x1b[?1002h") == null);
    try std.testing.expect(std.mem.find(u8, aw.written(), "\x1b[?1005h") == null);
}

test "Scenario: Given the kitty request is withheld when writing the lifecycle then no query push or pop is emitted" {
    const gpa = std.testing.allocator;
    var aw: std.Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();

    try writeTuiEnterTo(&aw.writer, false);
    try writeTuiExitTo(&aw.writer, false);

    // The kitty query, push, and pop all end in 'u' but so could unrelated
    // output — pin the full sequences rather than the bare letter.
    try std.testing.expect(std.mem.find(u8, aw.written(), "\x1b[?u") == null);
    try std.testing.expect(std.mem.find(u8, aw.written(), "\x1b[>") == null);
    try std.testing.expect(std.mem.find(u8, aw.written(), "\x1b[<") == null);
    try std.testing.expect(std.mem.find(u8, aw.written(), "\x1b[?1049h") != null);
    try std.testing.expect(std.mem.find(u8, aw.written(), "\x1b[?1049l") != null);
}

test "Scenario: Given shared TUI frame redraw when writing it then it clears only the alternate screen frame instead of appending full screens" {
    const gpa = std.testing.allocator;
    var aw: std.Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();

    try writeTuiResetFrameTo(&aw.writer);

    try std.testing.expectEqualStrings("\x1b[H\x1b[J", aw.written());
    try std.testing.expect(std.mem.find(u8, aw.written(), "\x1b[2J\x1b[H") == null);
}

test "Scenario: Given live TUI frame output when writing it then redraw moves home without pre-clearing the screen" {
    const gpa = std.testing.allocator;
    var aw: std.Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();

    const line_count = try writeTuiFrameTo(&aw.writer, "abc\ndef\n", 4);

    try std.testing.expectEqual(@as(usize, 2), line_count);
    try std.testing.expect(std.mem.startsWith(u8, aw.written(), "\x1b[?2026h\x1b[H"));
    try std.testing.expect(std.mem.find(u8, aw.written(), "\x1b[H\x1b[J") == null);
    try std.testing.expect(std.mem.find(u8, aw.written(), "abc\x1b[K\r\ndef\x1b[K") != null);
    try std.testing.expect(std.mem.find(u8, aw.written(), "def\x1b[K\r\n\x1b[K") == null);
    try std.testing.expect(std.mem.find(u8, aw.written(), "\r\n\x1b[2K") != null);
    try std.testing.expect(std.mem.endsWith(u8, aw.written(), "\x1b[?2026l"));
}

test "Scenario: Given TUI prompt with numeric input when rendering then the current digits stay inline with the title" {
    const gpa = std.testing.allocator;
    var with_digits: std.Io.Writer.Allocating = .init(gpa);
    defer with_digits.deinit();
    var without_digits: std.Io.Writer.Allocating = .init(gpa);
    defer without_digits.deinit();

    try writeTuiPromptLine(&with_digits.writer, "Select account to activate:", "123");
    try std.testing.expectEqualStrings("Select account to activate: 123\n", with_digits.written());

    try writeTuiPromptLine(&without_digits.writer, "Select account to activate:", "");
    try std.testing.expectEqualStrings("Select account to activate:\n", without_digits.written());
}

test "Scenario: Given Windows TUI console modes when configuring them then resize and wheel input stay enabled while cooked input stays disabled" {
    const saved_input_mode: win.DWORD =
        win.ENABLE_MOUSE_INPUT |
        win.ENABLE_WINDOW_INPUT |
        win.ENABLE_LINE_INPUT |
        win.ENABLE_ECHO_INPUT;
    const configured_input_mode = windowsTuiInputMode(saved_input_mode);

    try std.testing.expect((configured_input_mode & win.ENABLE_WINDOW_INPUT) != 0);
    try std.testing.expect((configured_input_mode & win.ENABLE_EXTENDED_FLAGS) != 0);
    // Mouse events are what deliver MOUSE_WHEELED; QuickEdit stays off so the
    // wheel reaches the app instead of arming a selection.
    try std.testing.expect((configured_input_mode & win.ENABLE_MOUSE_INPUT) != 0);
    try std.testing.expect((configured_input_mode & win.ENABLE_QUICK_EDIT_MODE) == 0);
    try std.testing.expect((configured_input_mode & win.ENABLE_LINE_INPUT) == 0);
    try std.testing.expect((configured_input_mode & win.ENABLE_ECHO_INPUT) == 0);
    try std.testing.expect((configured_input_mode & win.ENABLE_VIRTUAL_TERMINAL_INPUT) == 0);

    const configured_output_mode = windowsTuiOutputMode(0);
    try std.testing.expect((configured_output_mode & win.ENABLE_PROCESSED_OUTPUT) != 0);
    try std.testing.expect((configured_output_mode & win.ENABLE_VIRTUAL_TERMINAL_PROCESSING) != 0);
}

test "Scenario: Given Windows console mouse records when mapping them then only vertical wheel deltas scroll" {
    const mouseRecord = struct {
        fn call(flags: win.DWORD, button_state: win.DWORD) win.INPUT_RECORD {
            return .{
                .EventType = win.MOUSE_EVENT,
                .Event = .{ .MouseEvent = .{
                    .dwMousePosition = .{ .X = 10, .Y = 5 },
                    .dwButtonState = button_state,
                    .dwControlKeyState = 0,
                    .dwEventFlags = flags,
                } },
            };
        }
    }.call;

    // The wheel delta rides in the high word of dwButtonState (±120/notch):
    // sign picks the direction, magnitude folds into one key like an SGR
    // report does.
    try std.testing.expectEqual(cli.tui.TuiInputKey.scroll_up, cli.tui.windowsMouseScrollKey(mouseRecord(win.MOUSE_WHEELED, 120 << 16)));
    try std.testing.expectEqual(cli.tui.TuiInputKey.scroll_down, cli.tui.windowsMouseScrollKey(mouseRecord(win.MOUSE_WHEELED, 0xFF88_0000)));
    try std.testing.expectEqual(cli.tui.TuiInputKey.scroll_up, cli.tui.windowsMouseScrollKey(mouseRecord(win.MOUSE_WHEELED, 240 << 16)));

    // Anything that is not a vertical wheel notch is drained, not mapped:
    // horizontal wheel, button press/move (flags 0), and non-mouse records.
    try std.testing.expectEqual(@as(?cli.tui.TuiInputKey, null), cli.tui.windowsMouseScrollKey(mouseRecord(win.MOUSE_HWHEELED, 120 << 16)));
    try std.testing.expectEqual(@as(?cli.tui.TuiInputKey, null), cli.tui.windowsMouseScrollKey(mouseRecord(0, 1)));

    const key_record: win.INPUT_RECORD = .{
        .EventType = win.KEY_EVENT,
        .Event = .{ .KeyEvent = .{
            .bKeyDown = .TRUE,
            .wRepeatCount = 1,
            .wVirtualKeyCode = win.VK_DOWN,
            .wVirtualScanCode = 0,
            .uChar = .{ .UnicodeChar = 0 },
            .dwControlKeyState = 0,
        } },
    };
    try std.testing.expectEqual(@as(?cli.tui.TuiInputKey, null), cli.tui.windowsMouseScrollKey(key_record));
}

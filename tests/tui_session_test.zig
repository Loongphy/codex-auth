const std = @import("std");
const cli = @import("codex_auth").cli;

const TuiNavigation = cli.tui.TuiNavigation;
const TuiEscapeClassification = cli.tui.TuiEscapeClassification;
const TuiEscapeAction = cli.tui.TuiEscapeAction;
const classifyTuiEscapeSuffix = cli.tui.classifyTuiEscapeSuffix;
const readTuiEscapeAction = cli.tui.readTuiEscapeAction;
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
    switch (classifyTuiEscapeSuffix("[1;1:1A")) {
        .navigation => |direction| try std.testing.expectEqual(TuiNavigation.keyboard_up, direction),
        else => return error.TestUnexpectedResult,
    }
    switch (classifyTuiEscapeSuffix("[57420;1u")) {
        .navigation => |direction| try std.testing.expectEqual(TuiNavigation.keyboard_down, direction),
        else => return error.TestUnexpectedResult,
    }

    const result = try readTuiEscapeAction(std.Io.File.stdin(), "[1;1:1A", 0, 0);
    try std.testing.expectEqual(TuiEscapeAction.keyboard_up, result.action);
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
}

test "Scenario: Given long SGR mouse wheel escape suffix when reading it then the full sequence is consumed" {
    const result = try readTuiEscapeAction(std.Io.File.stdin(), "[<65;120;40M", 0, 0);
    try std.testing.expectEqual(TuiEscapeAction.scroll_down, result.action);
    try std.testing.expectEqual(@as(usize, "[<65;120;40M".len), result.buffered_bytes_consumed);
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

    try writeTuiEnterTo(&aw.writer);
    try writeTuiExitTo(&aw.writer);

    try std.testing.expectEqualStrings(
        "\x1b[?1049h\x1b[?25l\x1b[?1007h\x1b[?u\x1b[>7u" ++
            "\x1b[H\x1b[J" ++
            "\x1b[<1u\x1b[?1007l\x1b[?25h\x1b[?1049l",
        aw.written(),
    );
    try std.testing.expect(std.mem.indexOf(u8, aw.written(), "\x1b[?1007h") != null);
    try std.testing.expect(std.mem.indexOf(u8, aw.written(), "\x1b[?1007l") != null);
    try std.testing.expect(std.mem.indexOf(u8, aw.written(), "\x1b[?1000h") == null);
    try std.testing.expect(std.mem.indexOf(u8, aw.written(), "\x1b[?1006h") == null);
}

test "Scenario: Given shared TUI frame redraw when writing it then it clears only the alternate screen frame instead of appending full screens" {
    const gpa = std.testing.allocator;
    var aw: std.Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();

    try writeTuiResetFrameTo(&aw.writer);

    try std.testing.expectEqualStrings("\x1b[H\x1b[J", aw.written());
    try std.testing.expect(std.mem.indexOf(u8, aw.written(), "\x1b[2J\x1b[H") == null);
}

test "Scenario: Given live TUI frame output when writing it then redraw moves home without pre-clearing the screen" {
    const gpa = std.testing.allocator;
    var aw: std.Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();

    const line_count = try writeTuiFrameTo(&aw.writer, "abc\ndef\n", 4);

    try std.testing.expectEqual(@as(usize, 2), line_count);
    try std.testing.expect(std.mem.startsWith(u8, aw.written(), "\x1b[?2026h\x1b[H"));
    try std.testing.expect(std.mem.indexOf(u8, aw.written(), "\x1b[H\x1b[J") == null);
    try std.testing.expect(std.mem.indexOf(u8, aw.written(), "abc\x1b[K\r\ndef\x1b[K") != null);
    try std.testing.expect(std.mem.indexOf(u8, aw.written(), "def\x1b[K\r\n\x1b[K") == null);
    try std.testing.expect(std.mem.indexOf(u8, aw.written(), "\r\n\x1b[2K") != null);
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

test "Scenario: Given Windows TUI console modes when configuring them then resize stays enabled while mouse and cooked input stay disabled" {
    const saved_input_mode: win.DWORD =
        win.ENABLE_MOUSE_INPUT |
        win.ENABLE_WINDOW_INPUT |
        win.ENABLE_LINE_INPUT |
        win.ENABLE_ECHO_INPUT;
    const configured_input_mode = windowsTuiInputMode(saved_input_mode);

    try std.testing.expect((configured_input_mode & win.ENABLE_WINDOW_INPUT) != 0);
    try std.testing.expect((configured_input_mode & win.ENABLE_EXTENDED_FLAGS) != 0);
    try std.testing.expect((configured_input_mode & win.ENABLE_MOUSE_INPUT) == 0);
    try std.testing.expect((configured_input_mode & win.ENABLE_LINE_INPUT) == 0);
    try std.testing.expect((configured_input_mode & win.ENABLE_ECHO_INPUT) == 0);
    try std.testing.expect((configured_input_mode & win.ENABLE_VIRTUAL_TERMINAL_INPUT) == 0);

    const configured_output_mode = windowsTuiOutputMode(0);
    try std.testing.expect((configured_output_mode & win.ENABLE_PROCESSED_OUTPUT) != 0);
    try std.testing.expect((configured_output_mode & win.ENABLE_VIRTUAL_TERMINAL_PROCESSING) != 0);
}

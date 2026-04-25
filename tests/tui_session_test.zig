const std = @import("std");
const cli = @import("codex_auth").cli;

const TuiNavigation = cli.tui.TuiNavigation;
const TuiEscapeClassification = cli.tui.TuiEscapeClassification;
const classifyTuiEscapeSuffix = cli.tui.classifyTuiEscapeSuffix;
const writeTuiEnterTo = cli.tui.writeTuiEnterTo;
const writeTuiExitTo = cli.tui.writeTuiExitTo;
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
        .navigation => |direction| try std.testing.expectEqual(TuiNavigation.down, direction),
        else => return error.TestUnexpectedResult,
    }
    switch (classifyTuiEscapeSuffix("OA")) {
        .navigation => |direction| try std.testing.expectEqual(TuiNavigation.up, direction),
        else => return error.TestUnexpectedResult,
    }
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
        "\x1b[?1049h\x1b[?25l" ++
            "\x1b[H\x1b[J" ++
            "\x1b[?25h\x1b[?1049l",
        aw.written(),
    );
}

test "Scenario: Given shared TUI frame redraw when writing it then it clears only the alternate screen frame instead of appending full screens" {
    const gpa = std.testing.allocator;
    var aw: std.Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();

    try writeTuiResetFrameTo(&aw.writer);

    try std.testing.expectEqualStrings("\x1b[H\x1b[J", aw.written());
    try std.testing.expect(std.mem.indexOf(u8, aw.written(), "\x1b[2J\x1b[H") == null);
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

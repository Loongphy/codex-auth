# Terminal input

Live views (`list --live`, `switch --live`, `remove --live`) run as a
fullscreen TUI on the terminal's alternate screen. This page describes which
terminal features the TUI asks for and how input reaches the application on
each platform. Exact byte sequences and key mappings are pinned by
`tests/tui_session_test.zig`.

## Screen modes

- The TUI switches to the alternate screen and hides the cursor on entry;
  both are restored on exit, along with every input mode it enabled.
- Mouse reporting is requested at the button level, which includes wheel
  notches, in the SGR coordinate encoding. Button press and release
  reports do reach the application and are consumed-and-ignored; only
  drag and pointer-motion tracking stay off, so moving the mouse
  generates nothing.
- Alternate scroll stays enabled as a fallback. On terminals that implement
  alternate scroll but not mouse reporting, the wheel arrives as arrow keys
  and keeps whatever meaning that command's arrow keys already have.

## Mouse wheel

- A wheel notch is a small fixed-step scroll — `live_tui.mouse_wheel_lines`
  — while an arrow-key scroll uses the larger viewport-scaled step. Wheel
  reports carry a direction rather than a magnitude, so the TUI tells
  gestures apart by timing: events arriving within
  `live_tui.scroll_stream_gap_ms` of each other count as one continuous gesture (a
  trackpad flick or a spun wheel) and step a single line each, so a flick
  glides instead of jumping a full notch per event.
- The notch scrolls the account-list viewport; while the reset-credit rail
  is open it moves the credit highlight instead, the same surface the
  command's arrow keys act on.
- A terminal that reports buttons but not the SGR encoding falls back to
  the legacy X10 report. Those reports are consumed and ignored, so their
  coordinate bytes can never leak into a digit prompt or key mapping.

## Keyboard enhancement

- On POSIX terminals the TUI pushes its kitty flag set and then queries the
  flags in effect, but only when the terminal environment suggests the
  protocol will be honored. The reply must confirm the disambiguate flag
  took effect before enhanced key sequences are trusted.
- The request is withheld for terminal families known to mis-encode or
  half-claim the protocol — VS Code's integrated terminal (an exact
  `TERM_PROGRAM=vscode` match, which covers forks that reuse that value),
  Apple Terminal, JediTerm, VTE-based terminals, and Windows Terminal —
  and on native Windows, where input is not a byte stream.
- Nothing depends on the enhancement: legacy byte input is fully supported
  either way. Enhanced mode only lets the TUI tell a physical arrow key
  apart from a wheel-generated one, which is what makes `↑`/`↓` and `j`/`k`
  diverge on capable terminals.

## Windows console

- On native Windows, input arrives as `INPUT_RECORD`s rather than escape
  sequences: wheel events map to the same scroll actions as SGR reports,
  resize records trigger a redraw, and key records map to the same key set.
- The console mode keeps mouse input enabled and Quick Edit disabled so
  wheel records reach the application instead of starting a text selection.
- The full record-to-scroll path is exercised end to end on a real console
  by `tests/tui_conhost_test.zig`; see `docs/tests.md` for how it runs.

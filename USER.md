# User-Confirmed Features

## Copy-Friendly Live TUI Scrolling

### Feature

Live terminal views keep native mouse text selection available while still
supporting responsive mouse-wheel scrolling.

This applies to live TUI screens such as `list --live`, `switch --live`, and
`remove --live`.

When the terminal supports Kitty keyboard enhancement, real keyboard Up/Down
input is kept distinct from alternate-scroll mouse-wheel input:

- keyboard Up/Down moves the cursor in `switch --live` and `remove --live`
- mouse-wheel movement scrolls the viewport in `list --live`, `switch --live`,
  and `remove --live`
- translated wheel scrolling uses the shared live-list wheel step

When the terminal does not confirm keyboard enhancement support, the TUI keeps
the legacy copy-friendly fallback. In that fallback, terminals may translate
mouse-wheel movement into the same Up/Down bytes as real keyboard arrows, so
`switch --live` and `remove --live` preserve the existing cursor movement and
edge-scroll compensation behavior.

### Technical Implementation

- The TUI enters the alternate screen with `?1049h`.
- The cursor is hidden while the TUI is active with `?25l`.
- XTerm alternate scroll is enabled with `?1007h`.
- Mouse reporting is not enabled with `?1000h` or `?1006h`.
- Kitty keyboard enhancement support is queried with `?u`.
- Keyboard enhancement flags `7` are pushed with `>7u` and popped with `<1u`
  on exit.
- Terminals that support alternate scroll translate mouse-wheel movement in the
  alternate screen into Up/Down-style input.
- The TUI only treats traditional `Esc [ A` and `Esc [ B` as mouse-wheel
  viewport scrolling after it has received a keyboard-enhancement response.
- Enhanced keyboard Up/Down sequences are parsed as keyboard-only cursor
  movement and do not trigger viewport edge-scroll compensation.
- Without a keyboard-enhancement response, traditional Up/Down input keeps the
  legacy behavior so unsupported terminals do not lose keyboard navigation.
- `list --live` treats that Up/Down-style input as viewport scrolling so the
  translated wheel input remains responsive.

### Problems Solved

- Users can drag-select and copy text normally without holding `Shift`.
- Mouse-wheel scrolling remains usable in live TUI screens.
- On terminals with keyboard enhancement support, mouse-wheel scrolling and
  keyboard Up/Down navigation no longer conflict in `switch --live` and
  `remove --live`.
- The TUI avoids taking ownership of mouse clicks, drags, and coordinates when
  those interactions are not needed.
- Long live lists can scroll without sacrificing native terminal selection.

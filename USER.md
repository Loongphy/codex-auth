# User-Confirmed Features

## Copy-Friendly Live TUI Scrolling

### Feature

Live terminal views keep native mouse text selection available while still
supporting responsive mouse-wheel scrolling.

This applies to live TUI screens such as `list --live`, `switch --live`, and
`remove --live`.

### Technical Implementation

- The TUI enters the alternate screen with `?1049h`.
- The cursor is hidden while the TUI is active with `?25l`.
- XTerm alternate scroll is enabled with `?1007h`.
- Mouse reporting is not enabled with `?1000h` or `?1006h`.
- Terminals that support alternate scroll translate mouse-wheel movement in the
  alternate screen into Up/Down-style input.
- `list --live` treats that Up/Down-style input as viewport scrolling so the
  translated wheel input remains responsive.

### Problems Solved

- Users can drag-select and copy text normally without holding `Shift`.
- Mouse-wheel scrolling remains usable in live TUI screens.
- The TUI avoids taking ownership of mouse clicks, drags, and coordinates when
  those interactions are not needed.
- Long live lists can scroll without sacrificing native terminal selection.

# User-Confirmed Features

## First-Class Live TUI Mouse-Wheel Scrolling

### Feature

Live terminal views support responsive, first-class mouse-wheel scrolling.

This applies to live TUI screens such as `list --live`, `switch --live`, and
`remove --live`.

Wheel input is first-class on both platforms: POSIX terminals report real
wheel events (SGR encoding), and native Windows delivers `MOUSE_WHEELED`
console records. A wheel notch scrolls the viewport by a small fixed step;
a dense gesture (trackpad flick, spun wheel) steps a single line per event
so it glides instead of jumping.

When the terminal confirms Kitty keyboard enhancement, real keyboard
Up/Down input is kept distinct from wheel input:

- keyboard Up/Down moves the cursor in `switch --live` and `remove --live`
- mouse-wheel movement scrolls the viewport in `list --live`, `switch --live`,
  and `remove --live`

When the terminal does not confirm keyboard enhancement support, the legacy
alternate-scroll fallback still applies: terminals may translate wheel
movement into the same Up/Down bytes as real keyboard arrows, so
`switch --live` and `remove --live` preserve the existing cursor movement
and edge-scroll compensation behavior.

Because button-level mouse reporting is active, click press/release reports
reach the application and are consumed-and-ignored. While the TUI is active,
native drag text selection requires the terminal's mouse-bypass modifier
(`Shift` on most terminals). Pointer motion is never reported, so moving the
mouse costs nothing.

### Technical Implementation

- The TUI enters the alternate screen with `?1049h`.
- The cursor is hidden while the TUI is active with `?25l`.
- XTerm alternate scroll is enabled with `?1007h` as a fallback for
  terminals without mouse reporting.
- Mouse reporting is enabled with `?1000h` in the SGR coordinate encoding
  (`?1006h`); drag and motion modes (`?1002h`, `?1003h`, `?1005h`) stay off.
- Button press/release reports are consumed-and-ignored; X10 reports
  (`ESC [ M` + 3 coordinate bytes) are consumed so coordinate bytes can
  never leak into prompts or key handling.
- Keyboard enhancement flags `7` are pushed with `>7u`, the flags in effect
  are then queried with `?u`, and the push is popped with `<1u` on exit.
- The TUI only treats traditional `Esc [ A` and `Esc [ B` as mouse-wheel
  viewport scrolling after it has received a keyboard-enhancement response.
- Enhanced keyboard Up/Down sequences are parsed as keyboard-only cursor
  movement and do not trigger viewport edge-scroll compensation.
- Without a keyboard-enhancement response, traditional Up/Down input keeps
  the legacy behavior so unsupported terminals do not lose keyboard
  navigation.
- `Enter` opens the reset-credit rail for an account row that has at least
  one available credit; while the rail is open, Up/Down input — including
  `j`/`k` and wheel-generated input — moves the credit highlight instead,
  and `Esc` closes the rail and returns to account-row movement.
- On native Windows the same wheel contract is delivered by console
  `MOUSE_WHEELED` input records rather than escape sequences.

### Problems Solved

- Mouse-wheel scrolling is responsive and behaves consistently across
  terminals, multiplexers, and native Windows consoles.
- On terminals with keyboard enhancement support, mouse-wheel scrolling and
  keyboard Up/Down navigation no longer conflict in `switch --live` and
  `remove --live`.
- A dense wheel gesture scrolls smoothly instead of jumping full notches
  per event.
- Long live lists can scroll far beyond one screen.

# Terminal Style Guide

This guide covers user-facing terminal output, including shared output and command-specific interactive states.

# Text Roles

- **Header / table header:** Use ANSI `cyan`.
- **Primary text:** Use the terminal's default foreground color.
- **Secondary text:** Use ANSI `dim`.
- **Footer / key hints:** Use ANSI `cyan`.
- **Live refresh status line:** Use ANSI `cyan`.

# Foreground Colors

| UI element | Color |
| --- | --- |
| Header / table header | `cyan` |
| Live refresh status line | `cyan` |
| Footer / key hints | `cyan` |
| Primary content | Default terminal foreground |
| Success message | `green` |
| Error / failure message | `red` |
| Hints and user input labels | `cyan` |

## Interactive Account Tables

These rules only cover special interactive states. Shared header, footer, live refresh, normal text, success, and error colors still follow the common rules above.

### switch

| UI element | Color |
| --- | --- |
| Active row | `green` |
| Cursor row | `green` |

The switch cursor is the row marked with `>`. It is the account that Enter would switch to. The active row is marked with `*`.

Priority:

1. Active row: `green`
2. Cursor row: `green`
3. Error / unavailable row: `red`
4. Normal row: default terminal foreground

### remove

| UI element | Color |
| --- | --- |
| Active row | `green` |
| Cursor row | `green` |
| Checked row | `green` |

Priority:

1. Active row: `green`
2. Cursor row: `green`
3. Error / unavailable row: `red`
4. Checked row: `green`
5. Normal row: default terminal foreground

# Avoid

- Avoid custom colors because there is no guarantee that they will contrast well or look good in different terminal themes.
- Avoid ANSI `black` and `white` as foreground colors because the terminal's default foreground usually provides better contrast. Use `reset` to return to the default foreground.
- Avoid ANSI `blue` and `yellow`. Prefer a foreground color listed above.

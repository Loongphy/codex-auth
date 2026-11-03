# Terminal Style Guide

This guide covers user-facing terminal output, including shared output and command-specific interactive states.

# Text Roles

User-facing output code should use the semantic roles in `src/cli/style.zig`
instead of referencing raw ANSI colors directly. Keep raw ANSI constants as the
low-level palette only; changing a role mapping should update all matching
output without searching business workflows for individual color names.

- **Header / table header:** Use ANSI `cyan`.
- **Primary text:** Use the terminal's default foreground color.
- **Secondary text:** Use ANSI `dim`.
- **Footer / key hints:** Use ANSI `cyan`.
- **Live refresh status line:** Use ANSI `cyan`.
- **Status / in-progress action:** Use ANSI `cyan`.
- **Configuration key:** Use ANSI `bold`.
- **Warning / non-fatal status:** Use ANSI `cyan`.

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

### list --live table and reset credits rail

The live list separates columns with whitespace instead of `|`. The account
table header is bold `cyan`; an active row is `green`; an error row is `red`.
The reset credits rail is borderless on every platform:

| UI element | Color |
| --- | --- |
| `RESETS` heading | bold `cyan` |
| Selected credit | `green` |
| Other credit rows | Default terminal foreground |
| Spent (just-redeemed) card line | `dim` + strikethrough |
| `redeemed` tag on a spent line | `green` |
| Failure status line | `red` |
| Informational status line | `cyan` |
| Rail key legend | `dim` |

The rail draws inside the live list body, so its status line follows the shared
error role instead of introducing its own palette; a successful redeem needs no
status line at all because the struck card tagged `redeemed` is the report.
`Enter` and the `>` cursor mark are spelled the same on every platform, matching
the footers and the switch and remove tables. On Windows the rail keeps the
same borderless layout, spells the separator as a comma, and leaves failures
unmarked; see `docs/windows.md`.

# Avoid

- Avoid custom colors because there is no guarantee that they will contrast well or look good in different terminal themes.
- Avoid ANSI `black` and `white` as foreground colors because the terminal's default foreground usually provides better contrast. Use `reset` to return to the default foreground.
- Avoid ANSI `blue` and `yellow`. Prefer a foreground color listed above.

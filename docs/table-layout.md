# Table Layout

Every table view uses the same responsive allocator in
`src/cli/table_layout.zig`. The full column model is:

`ACCOUNT`, `PLAN`, `CREDITS`, `RESET CREDITS`, `5H`, `WEEKLY`, `LAST ACTIVITY`,
and a deferred `PLAN EXPIRE`.

The plain `list` table enables all eight columns. The live `switch` and
`remove` views disable `CREDITS`, `RESET CREDITS`, and the deferred
`PLAN EXPIRE`: those columns are absent from the layout, and their width and
separator budget is redistributed to the remaining columns. `list --live`
uses its own account-detail table.

## Column Allocation

The allocator receives the content width of each column and the available
terminal width. A column with content width `0` is treated as disabled.

### First pass: reserve useful targets by priority

```text
ACCOUNT (10)
  -> 5H (4)
  -> WEEKLY (6)
  -> CREDITS (2)
  -> PLAN (4)
  -> RESET CREDITS (2)
  -> LAST (4)
```

`PLAN EXPIRE` is deferred: it is not part of the first pass or the grow pass.
It only receives leftover width after every other visible column has had a
chance to grow. On mid-sized terminals this keeps usage and status values from
being squeezed by the extra column.

- Separators are charged only for columns that are actually visible.
- A non-account column is shown only when its target width and separator fit.
- `ACCOUNT` may use a partial width down to 2 columns when the terminal is
  very narrow.
- A column that cannot receive a useful width is hidden instead of being
  rendered as a one-column `.` cell.

### Second pass: grow toward content width

Visible columns grow in this order:

```text
CREDITS -> 5H -> WEEKLY -> PLAN -> RESET CREDITS -> LAST -> ACCOUNT
```

The credit cell is grown first so values such as `unlimited` do not collapse to
`u.`. Usage and error-name cells grow before `LAST`, and `ACCOUNT` grows last so
a long account label cannot starve the values beside it. In the live views,
`CREDITS` and `RESET CREDITS` are disabled, so the effective order is:

```text
5H -> WEEKLY -> PLAN -> LAST -> ACCOUNT
```

Columns with width `0` are skipped entirely, including their headers, cells,
and separators.

## Headers

Wide headers use their full label. When a column is narrower than its full
label, compact labels are used:

| Column | Compact |
|---|---|
| `CREDITS` | `CR` |
| `RESET CREDITS` | `RESET`, then `RC` |

## Account Truncation

Account labels should prefer the most recognizable label already selected by the
display model. Grouped accounts can therefore show aliases or account names,
while singleton rows can still show the email label.

When an account cell is wider than the available column width:

- very narrow cells keep the existing prefix-only form with a single `.`;
- wider cells keep a prefix and a short suffix, separated by a single `.`;
- cells wide enough for the full label render it unchanged.

Examples for `very-long-account-name@example.com`:

| Width | Output |
| ---: | --- |
| 4 | `ver.` |
| 8 | `very-lo.` |
| 10 | `very-l.com` |
| 14 | `very-l.ple.com` |
| 32 | `very-l.-account-name@example.com` |
| 34 | `very-long-account-name@example.com` |

Indentation for grouped child rows consumes account column width before the
label is truncated.

## Examples

Plain `list`, where all eight columns are enabled on a wide terminal:

```text
ACCOUNT     PLAN  CREDITS    RC  5H        WEEKLY  LAST  PLAN EXPIRE
------------------------------------------------------------------
very-long.  Pro   -          -   100%      58%     -     2026-11-22
work-main.  Pro   unlimited  3   31%       42%     -     2026-12-01
```

At 70 columns, the deferred `PLAN EXPIRE` column is omitted so `FileNotFound`
and other status cells stay readable.

Live view, where `CREDITS`, `RESET CREDITS`, and `PLAN EXPIRE` are disabled and
their space is redistributed:

```text
ACCOUNT      PLAN      5H    WEEKLY
-----------------------------------
very-l..com  Business  100%  42%
```

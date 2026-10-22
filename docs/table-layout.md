# Table Layout

Every table view uses one responsive allocator. Each view supplies its own
visual column order and the fields it supports; unsupported fields are hidden by
passing a zero content width.

| View | Visible columns |
|---|---|
| `list` | `ACCOUNT`, `PLAN`, `CREDITS`, `RESET CREDITS`, `5H`, `WEEKLY`, `LAST ACTIVITY` |
| `list --live` | `#*`, `ACCOUNT`, `PLAN`, `5H`, `WEEKLY`, `LAST`, `AUTH EXPIRE`, `RESET CREDITS` |
| `switch`, `remove` | `ACCOUNT`, `PLAN`, `5H`, `WEEKLY`, `LAST` |

Visual order never changes when columns are hidden. Width and separator budget
from a hidden column are redistributed to the remaining columns.

## Allocation

The allocator receives each column's content width and the terminal width.
Columns reserve width in priority order; a column is skipped when its target
width and separator do not fit. `ACCOUNT` may use a partial width down to 2
columns. Columns with width `0` are skipped entirely, including their headers,
cells, and separators.

### Plain `list`

Reserve order:

```text
ACCOUNT (10) -> 5H (4) -> WEEKLY (6) -> CREDITS (2)
            -> PLAN (4) -> RESET CREDITS (2) -> LAST (4)
```

Grow order:

```text
CREDITS -> 5H -> WEEKLY -> PLAN -> RESET CREDITS -> LAST -> ACCOUNT
```

### `list --live`

Reserve order:

```text
#* -> ACCOUNT (10) -> 5H (4) -> WEEKLY (6)
   -> PLAN (4) -> LAST (4) -> AUTH EXPIRE (10) -> RESET CREDITS (2)
```

Grow order:

```text
AUTH EXPIRE -> RESET CREDITS -> PLAN -> LAST -> 5H -> WEEKLY -> ACCOUNT
```

### `switch`, `remove`

Reserve order:

```text
ACCOUNT (10) -> 5H (4) -> WEEKLY (6) -> PLAN (4) -> LAST (4)
```

Grow order:

```text
5H -> WEEKLY -> PLAN -> LAST -> ACCOUNT
```

## Headers

Wide headers use their full label. Narrow columns use compact labels:

| Column | Compact labels |
|---|---|
| `CREDITS` | `CR` |
| `RESET CREDITS` | `RESET`, then `RC` |
| `AUTH EXPIRE` | `AUTH EXP`, then `AUTH` |

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

Plain `list`:

```text
ACCOUNT     PLAN  CREDITS    RC  5H        WEEKLY  LAST
--------------------------------------------------------
very-long.  Pro   -          -   100%      58%     -
work-main.  Pro   unlimited  3   31%       42%     -
```

`list --live` at a medium width:

```text
#*  | ACCOUNT    | PLAN | 5H    | WEEKLY
 1  | very-l.om) | Pro  | 100%  | 58%
```

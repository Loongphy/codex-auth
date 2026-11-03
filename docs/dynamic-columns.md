# Dynamic Column Layout

All table views use one responsive allocator in `src/cli/table_layout.zig`.
The allocator separates a column's semantic identity (`ColumnId`) from its
position on screen, so each view keeps its own visual order while sharing the
same width policy, header ladders, and cell truncation rules.

## Model

Each view supplies:

- `columns`: the visual order and content width of its supported columns;
- `first_order`, `grow_order`, `deferred_order`: the shared priority lists;
- `prefix_width`: width of the row prefix (`#`, checkbox, index);
- `separator_width`: width of the separator between visible columns.

A column with width `0` is hidden by that view. Hidden columns are skipped
completely — header, cells, and separators — and their budget redistributes to
the remaining columns.

Content width measures **cells, never headers**. A header can no longer inflate
its column: `RESETS` sizes to the credit count, not to a 13-character label.
Compact header ladders (below) keep a column named at any width.

## Visual Order

The order of each view is fixed. Unsupported columns are simply omitted.

| View | Visual order |
|---|---|
| `list` | `ACCOUNT`, `PLAN`, `PLAN EXP`, `CREDITS`, `RESETS`, `5H`, `WEEKLY`, `TOKEN EXPIRE`, `LAST` |
| `list --live` | marker, `ACCOUNT`, `PLAN`, `PLAN EXP`, `RESETS`, `5H`, `WEEKLY`, `TOKEN EXPIRE`, `LAST` |
| `switch`, `remove` | `ACCOUNT`, `PLAN`, `5H`, `WEEKLY`, `LAST` |

The tables in this document name columns, not rendered headers: `TOKEN EXPIRE`
is the access-token expiry column and `LAST` is the column whose wide header
reads `LAST ACTIVITY`. See [Headers](#headers).

## Shared Priority

Every view uses the same ordered lists. A view with an unsupported column
(content width `0`) skips that entry without changing the order.

### Reserve order (highest to lowest)

```text
#* -> ACCOUNT (10) -> 5H (4) -> WEEKLY (6) -> PLAN (4)
   -> RESETS (2) -> CREDITS (2)
```

`PLAN EXP`, `TOKEN EXPIRE`, and `LAST` are not in this list; they are deferred.

### Grow order

```text
5H -> WEEKLY -> PLAN -> RESETS -> CREDITS
```

### Deferred order

```text
PLAN EXP (10) -> LAST (4) -> TOKEN EXPIRE (10)
```

Deferred columns are considered only after every normal column has grown. Each
still needs its target width and separator to fit, so deferred columns never
become one-column dot cells. `PLAN EXP` returns first because the subscription
date is the only forward-looking business fact; `TOKEN EXPIRE` returns last
because the access token refreshes automatically and is the widest, lowest-value
detail.

`ACCOUNT` is expanded last, after the deferred pass, using only leftover width.
A long account label therefore cannot hide `PLAN EXP`, `TOKEN EXPIRE`, or
`LAST`.

## Shared Hide Order

From wide to narrow, columns disappear in the reverse admission order. The
complete shared order is:

```text
TOKEN EXPIRE
-> LAST
-> PLAN EXP
-> CREDITS
-> RESETS
-> PLAN
-> WEEKLY
-> 5H
-> ACCOUNT
-> #*
```

Unsupported columns are already absent from a view:

- plain `list` has no `#*`: `TOKEN EXPIRE -> LAST -> PLAN EXP -> CREDITS -> RESETS -> PLAN -> WEEKLY -> 5H -> ACCOUNT`.
- `list --live` has no `CREDITS`: `TOKEN EXPIRE -> LAST -> PLAN EXP -> RESETS -> PLAN -> WEEKLY -> 5H -> ACCOUNT -> #*`.
- `switch` / `remove` support none of the credits or expiry columns: `LAST -> PLAN -> WEEKLY -> 5H -> ACCOUNT`.

`TOKEN EXPIRE` is the absolute lowest-priority detail and hides first.
`RESETS`, which carries the actionable reset count, stays above `CREDITS` and
the scan-critical usage columns.

## Allocation Phases

1. **Reserve targets** in `first_order`. A column is admitted only when its
   target width and separator fit. `ACCOUNT` may use a partial width down to
   2 columns.
2. **Grow** visible columns in `grow_order` toward their content width.
3. **Admit deferred columns** in `deferred_order`, only when their target
   width and separator still fit after every normal column has grown.

Separators are charged only when a column becomes visible. A line never exceeds
the requested terminal width, and the final visible column is never padded, so
rows carry no trailing whitespace.

## Target Widths

| Column | Target |
|---|---:|
| `#*` | index width + marker |
| `ACCOUNT` | 10 (minimum 2) |
| `PLAN` | 4 |
| `PLAN EXP` | 10, deferred |
| `CREDITS` | 2 |
| `RESETS` | 2 |
| `5H` | 4 |
| `WEEKLY` | 6 |
| `LAST` | 4, deferred |
| `TOKEN EXPIRE` | 10, deferred |

## Headers

Headers shrink through a semantic ladder before they ever prefix-truncate.
Each rung is chosen by the column's rendered width:

| Column | Ladder (wide → narrow) |
|---|---|
| `PLAN EXP` | `PLAN EXPIRE` → `PLAN EXP` → `PLAN` → `PE` → `P` |
| `CREDITS` | `CREDITS` → `CR` → `C` |
| `RESETS` | `RESETS` → `RESET` → `RST` → `R` |
| `TOKEN EXPIRE` | `TOKEN EXPIRE` → `TOKEN EXP` → `TOKEN` → `TK` → `T` |
| `LAST` | `LAST ACTIVITY` → `LAST` |
| `5H`, `WEEKLY`, `PLAN`, `ACCOUNT` | fixed label, prefix-truncated if needed |

`TOKEN EXPIRE` (not `AUTH EXPIRE`) names what the column contains: the
access-token expiry, which refreshing credentials can extend. `RESETS` (not
`RESET CREDITS`) is the count of redeemable reset credits.

## Width-Aware Cells

Cells prefer a semantic compact form before falling back to a `.`-terminated
prefix, so a narrow column never shows a mid-word cut:

| Column | Compact behavior |
|---|---|
| `PLAN EXP`, `TOKEN EXPIRE` | `YYYY-MM-DD HH:MM` drops the time, keeping the full date, before truncating |
| `LAST` | `Nd ago`/`Nh ago` drops ` ago` before truncating |
| `CREDITS` | `unlimited` becomes `inf` below its natural width |
| `RESETS` | `N (exp MM-DD)` degrades to the bare count `N` |
| `5H`, `WEEKLY` | `N% (HH:MM on D Mon)` drops the clock (`N% (D Mon)`), then the parenthetical (`N%`) |
| `ACCOUNT` | prefix + `.` + suffix truncation (`very-l.ple.com`) once the column is wide enough for a useful suffix; see [table-layout.md](table-layout.md) |
| everything | `prefix.` truncation, display-width and UTF-8 safe |

Missing or invalid values always render `-`, in every view.

## Adding a Column

1. Add a `ColumnId` and its default target width.
2. Add it to the visual order of each view that supports it. Unsupported views
   pass content width `0`.
3. Add it to the shared `first_order`, `grow_order`, or `deferred_order`
   according to its priority.
4. Add a `headerFor` ladder rung and a `writeCellFor` case when the generic
   truncation would be misleading.
5. Add a width-sweep test for hidden/visible behavior, line length, and any
   value that must stay complete (for example `100%`).

## Related

- Account-label truncation: [table-layout.md](table-layout.md)
- `list` column contents: [commands/list.md](commands/list.md)

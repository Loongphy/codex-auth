# Dynamic Column Layout

All table views use one responsive allocator in `src/cli/table_layout.zig`.
The allocator separates a column's semantic identity from its position on
screen, so each view can keep its own visual order while sharing the same width
policy and hide order.

## Model

Each view supplies:

- `columns`: the visual order and content width of its supported columns;
- `first_order`, `grow_order`, `deferred_order`: the shared priority lists;
- `prefix_width`: width of the row prefix (`#`, checkbox, index);
- `separator_width`: width of the separator between visible columns.

A column with content width `0` is unsupported or hidden by that view. Hidden
columns are skipped completely, including their header, cells, and separators.
Their width and separator budget is redistributed to the remaining columns.

## Visual Order

The order of each view is fixed. Unsupported columns are simply omitted.

| View | Visual order |
|---|---|
| `list` | `ACCOUNT`, `PLAN`, `PLAN EXPIRE`, `CREDITS`, `RESET CREDITS`, `5H`, `WEEKLY`, `AUTH EXPIRE`, `LAST ACTIVITY` |
| `list --live` | `#*`, `ACCOUNT`, `PLAN`, `PLAN EXPIRE`, `RESET CREDITS`, `5H`, `WEEKLY`, `AUTH EXPIRE`, `LAST` |
| `switch`, `remove` | `ACCOUNT`, `PLAN`, `5H`, `WEEKLY`, `LAST` |

## Shared Priority

Every view uses the same ordered lists. A view with an unsupported column
(content width `0`) skips that entry without changing the order.

### Reserve order (highest to lowest)

```text
#* -> ACCOUNT (10) -> 5H (4) -> WEEKLY (6) -> PLAN (4)
   -> RESET CREDITS (2) -> CREDITS (2)
```

`PLAN EXPIRE`, `AUTH EXPIRE`, and `LAST` are not in this list; they are deferred.

### Grow order

```text
5H -> WEEKLY -> PLAN -> RESET CREDITS -> CREDITS
```

### Deferred order

```text
AUTH EXPIRE (10) -> PLAN EXPIRE (10) -> LAST (4)
```

Deferred columns are considered only after every normal column has grown. Each
still needs its target width and separator to fit, so deferred columns never
become one-column dot cells.

`ACCOUNT` is expanded last, after the deferred pass, using only leftover width.
A long account label therefore cannot hide `AUTH EXPIRE`, `PLAN EXPIRE`, or
`LAST ACTIVITY`.

## Shared Hide Order

From wide to narrow, columns disappear in the reverse priority order. The
complete shared order is:

```text
LAST
-> PLAN EXPIRE
-> AUTH EXPIRE
-> CREDITS
-> RESET CREDITS
-> PLAN
-> WEEKLY
-> 5H
-> ACCOUNT
-> #*
```

Unsupported columns are already absent from a view:

- plain `list` has no `#*`: `LAST -> PLAN EXPIRE -> AUTH EXPIRE -> CREDITS -> RESET CREDITS -> PLAN -> WEEKLY -> 5H -> ACCOUNT`.
- `list --live` has no `CREDITS`: `LAST -> PLAN EXPIRE -> AUTH EXPIRE -> RESET CREDITS -> PLAN -> WEEKLY -> 5H -> ACCOUNT -> #*`.
- `switch` / `remove` support none of the credits, auth-expiry, or plan-expiry columns: `LAST -> PLAN -> WEEKLY -> 5H -> ACCOUNT`.

`LAST` is the absolute lowest-priority column and hides first. `CREDITS` sits
just above the deferred expiry fields; `RESET CREDITS`, which carries the
actionable reset count, stays above it.

## Allocation Phases

1. **Reserve targets** in `first_order`. A column is admitted only when its
   target width and separator fit. `ACCOUNT` may use a partial width down to
   2 columns.
2. **Grow** visible columns in `grow_order` toward their content width.
3. **Admit deferred columns** in `deferred_order`, only when their target
   width and separator still fit after every normal column has grown.

Separators are charged only when a column becomes visible. A line never exceeds
the requested terminal width.

## Target Widths

| Column | Target |
|---|---:|
| `#*` | index width (at least `#*`) |
| `ACCOUNT` | 10 (minimum 2) |
| `PLAN` | 4 |
| `PLAN EXPIRE` | 10, deferred |
| `CREDITS` | 2 |
| `RESET CREDITS` | 2 |
| `5H` | 4 |
| `WEEKLY` | 6 |
| `LAST` | 4, deferred |
| `AUTH EXPIRE` | 10, deferred |

## Headers

Wide headers use their full label. Narrow columns use compact labels:

| Column | Compact labels |
|---|---|
| `CREDITS` | `CR` |
| `RESET CREDITS` | `RESET`, then `RC` |
| `AUTH EXPIRE` | `AUTH EXP`, then `AUTH` |
| `PLAN EXPIRE` | `PLAN EXP`, then `PLAN` |

## Adding a Column

1. Add a `ColumnId` and its default target width.
2. Add it to the visual order of each view that supports it. Unsupported views
   pass content width `0`.
3. Add it to the shared `first_order`, `grow_order`, or `deferred_order`
   according to its priority.
4. Add width-aware cell formatting and a compact header when needed.
5. Add a width-sweep test for hidden/visible behavior, line length, and any
   value that must stay complete (for example `100%`).

## Related

- Account-label truncation: [table-layout.md](table-layout.md)
- `list` column contents: [commands/list.md](commands/list.md)

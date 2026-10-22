# Dynamic Column Layout

All table views use one responsive allocator in `src/cli/table_layout.zig`.
The allocator separates a column's semantic identity from its position on
screen, so each view can keep its own visual order while sharing the same width
policy.

## Model

Each view supplies:

- `columns`: the visual order and content width of its supported columns;
- `first_order`: columns that reserve a useful target width first;
- `grow_order`: visible columns that may grow toward their content width;
- `deferred_order`: low-priority columns admitted only after every normal
  column has had a chance to grow;
- `prefix_width`: width of the row prefix (`#`, checkbox, index);
- `separator_width`: width of the separator between visible columns.

A column with content width `0` is unsupported or hidden by that view. Hidden
columns are skipped completely, including their header, cells, and separators.
Their width and separator budget is redistributed to the remaining columns.

## Visual Order

The order of each view is fixed and independent of priority:

| View | Visual order |
|---|---|
| `list` | `ACCOUNT`, `PLAN`, `CREDITS`, `RESET CREDITS`, `5H`, `WEEKLY`, `LAST ACTIVITY`, `PLAN EXPIRE` |
| `list --live` | `#*`, `ACCOUNT`, `PLAN`, `PLAN EXPIRE`, `5H`, `WEEKLY`, `LAST`, `AUTH EXPIRE`, `RESET CREDITS` |
| `switch`, `remove` | `ACCOUNT`, `PLAN`, `5H`, `WEEKLY`, `LAST` |

`switch` and `remove` hide `CREDITS`, `RESET CREDITS`, `AUTH EXPIRE`, and
`PLAN EXPIRE`. The plain `list` hides `AUTH EXPIRE`.

## Allocation Phases

1. **Reserve targets** in `first_order`. A column is admitted only when its
   target width and separator fit. `ACCOUNT` may use a partial width down to
   2 columns; hidden columns are not emitted as a missing separator or a
   one-column dot.
2. **Grow** visible columns in `grow_order` toward their content width.
3. **Admit deferred columns** in `deferred_order`, in order, only when their
   target width and separator still fit after every normal column has grown.

Separators are charged only when the next column becomes visible. A line never
exceeds the requested terminal width.

## Per-View Priority

### Plain `list`

```text
reserve:  ACCOUNT (10) -> 5H (4) -> WEEKLY (6) -> CREDITS (2)
          -> PLAN (4) -> RESET CREDITS (2) -> LAST (4)
grow:     CREDITS -> 5H -> WEEKLY -> PLAN -> RESET CREDITS -> LAST -> ACCOUNT
deferred: PLAN EXPIRE (10)
```

### `list --live`

```text
reserve:  #* -> ACCOUNT (10) -> 5H (4) -> WEEKLY (6) -> PLAN (4)
          -> LAST (4) -> AUTH EXPIRE (10) -> RESET CREDITS (2)
grow:     AUTH EXPIRE -> RESET CREDITS -> PLAN -> LAST -> 5H -> WEEKLY -> ACCOUNT
deferred: PLAN EXPIRE (10)
```

### `switch`, `remove`

```text
reserve:  ACCOUNT (10) -> 5H (4) -> WEEKLY (6) -> PLAN (4) -> LAST (4)
grow:     5H -> WEEKLY -> PLAN -> LAST -> ACCOUNT
deferred: none
```

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
3. Put it in `first_order`, `grow_order`, or `deferred_order` according to its
   importance. A new low-priority metadata column normally belongs in
   `deferred_order`, not in a hardcoded special case in the allocator.
4. Add width-aware cell formatting and a compact header when needed.
5. Add a width-sweep test for hidden/visible behavior, line length, and any
   value that must stay complete (for example `100%`).

## Related

- Account-label truncation: [table-layout.md](table-layout.md)
- `list` column contents: [commands/list.md](commands/list.md)

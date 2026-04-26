# Table Layout

The shared account table keeps each rendered line within the terminal width.
When space is limited, the table should preserve the most useful live status
before expanding long labels.

This applies to `switch`, `remove`, `list`, and `list --live` because they all
render through the shared table code in `src/cli/table_layout.zig` and are
called by the renderers in `src/cli/render.zig`. The
width-priority rules only matter when a viewport width is known, which is
typically the live case.

## Column Width Priority

The account table uses two account-width phases:

1. Give `ACCOUNT` enough width to remain identifiable.
2. Give live status columns room in priority order: `5H`, `WEEKLY`, `PLAN`,
   then `LAST`.
3. Expand `5H`, `WEEKLY`, `PLAN`, and `LAST` to their requested widths.
4. Use any remaining width to expand `ACCOUNT` toward its requested width.

This means `ACCOUNT` is always considered first, but a long account label should
not consume the whole table before `5H` and `WEEKLY` are visible.

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
| 14 | `very-long-.com` |
| 32 | `very-long-account-name@example.com` |

Indentation for grouped child rows consumes account column width before the
label is truncated.

## Narrow Width Examples

The visible column order remains `ACCOUNT`, `PLAN`, `5H`, `WEEKLY`, `LAST`, but
width is assigned by usefulness rather than visual order.

Wide enough:

```text
ACCOUNT                          PLAN      5H USAGE  WEEKLY USAGE  LAST ACTIVITY
work-main                        Business  31%       42%           Now
very-long-account-name@example.com Team     88%       71%           -
```

Medium:

```text
ACCOUNT          PLAN      5H    WEEKLY  LAST
work-main        Business  31%   42%     Now
very-l.mple.com   Team     88%   71%     -
```

Narrow:

```text
ACCOUNT     5H    WEEKLY
work-main   31%   42%
very-l.com  88%   71%
```

Very narrow:

```text
ACCOUNT   5H
work-m.   31%
very-l.   88%
```

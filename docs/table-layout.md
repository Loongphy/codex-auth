# Table Layout

The responsive column policy is documented in
[dynamic-columns.md](dynamic-columns.md). This page covers the account cell and
the shared row-numbering form.

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

## Row Numbering

Plain `list`, `list --live`, `switch`, and `remove` share one numbering form:
a marker column plus the row number right-aligned to the index width, with no
zero padding — ` 1`, ` 7`, `10`. The marker is a separate column: `* 7` is the
active account, `> 6` the live cursor row, `[x] 2` a checked remove row.

## Examples

The rendered frames at each width are exercised by width-sweep tests
(`tests/table_layout_test.zig`); the column priorities, header ladders, and
cell forms those frames follow are specified in
[dynamic-columns.md](dynamic-columns.md).

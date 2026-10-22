# Table Layout

The responsive column policy is documented in
[dynamic-columns.md](dynamic-columns.md). This page covers the account cell and
a few rendered examples.

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

Plain `list` at a wide width:

```text
ACCOUNT     PLAN  CREDITS    RC  5H        WEEKLY  LAST  PLAN EXPIRE
------------------------------------------------------------------
very-long.  Pro   -          -   100%      58%     -     2026-11-22
work-main.  Pro   unlimited  3   31%       42%     -     2026-12-01
```

Plain `list` at 70 columns hides the deferred `PLAN EXPIRE` column so status
and usage values stay readable:

```text
ACCOUNT     PLAN  CR  RC  5H          WEEKLY  LAST
--------------------------------------------------
very-long.  Pro   -   -   100%        58%     -
```

`list --live` at a medium width:

```text
#*  | ACCOUNT    | PLAN | 5H    | WEEKLY
 1  | very-l.om) | Pro  | 100%  | 58%
```

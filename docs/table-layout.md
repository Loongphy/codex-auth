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

## Row Numbering

Plain `list`, `list --live`, `switch`, and `remove` share one numbering form:
a marker column plus the row number right-aligned to the index width, with no
zero padding — ` 1`, ` 7`, `10`. The marker is a separate column: `* 7` is the
active account, `> 6` the live cursor row, `[x] 2` a checked remove row.

## Examples

Plain `list` at a wide width (headers pick the widest rung that fits the
content-sized column — `PLAN EXP` at 10, `RESETS` over `N (exp MM-DD)` cells):

```text
    ACCOUNT                     PLAN      PLAN EXP    CREDITS    RESETS         5H           WEEKLY                TOKEN EXPIRE      LAST
  1 bot(api-bot@example.com)    API_KEY   -           -          -              -            -                     -                 -
    shared@example.com
  2   shared-a                  Plus      2026-11-30  -          -              100%         80% (08:11 on 3 Nov)  -                 4d ago
  5 team(team@example.com)      Business  -           0          1 (exp 11-05)  100%         10% (08:11 on 7 Nov)  2026-11-03 09:00  3h ago
  6 person.t-name@example.com)  Pro       2026-11-22  unlimited  3 (exp 11-10)  100%         58% (08:11 on 4 Nov)  2027-01-15 16:00  1h ago
* 7 work(w.k-main@example.com)  Pro       2027-01-01  12         0              31% (10:11)  42% (08:11 on 5 Nov)  2026-12-20 16:00  1h ago
```

Plain `list` at 70 columns hides the deferred `PLAN EXP`, `LAST`, and
`TOKEN EXPIRE` columns so status and usage values stay readable:

```text
    ACCOUNT     PLAN      CR  RESET  5H           WEEKLY
  1 bot(ap.om)  API_KEY   -   -      -            -
    shared@example.com
  2   shared-a  Plus      -   -      100%         80% (08:11 on 3 Nov)
  5 team(t.om)  Business  0   1      100%         10% (08:11 on 7 Nov)
* 7 work(w.om)  Pro       12  0      31% (10:11)  42% (08:11 on 5 Nov)
```

`list --live` at a medium width (the marker column has no header text; `>`
marks the row cursor, `*` the active account; error rows are red):

```text
     ACCOUNT     PLAN  5H     WEEKLY
> 6  person.om)  Pro   100%   58%
```

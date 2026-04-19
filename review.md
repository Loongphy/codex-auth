## Review Notes

## Account Model

`chatgpt_user_id` is the primary user identity for account-name sync.

- One `chatgpt_user_id` represents one user.
- A user can have multiple workspace `chatgpt_account_id` values.
- Those workspace records can cover personal and Team workspaces under the same email.
- We do not treat "same email but different `chatgpt_user_id`" as the grouping rule for this flow.

### P2

Rejected for the reported downgrade scenario.

`account_id` is a workspace identifier. Personal plans (`free`, `plus`, `pro`) can upgrade or downgrade while keeping the same personal workspace, so their `account_id` stays stable. Team workspaces are different: each team has its own `account_id`, and one user may belong to multiple teams.

The registry identity is `chatgpt_user_id::chatgpt_account_id`, so a team workspace and a personal workspace are different records by construction. Because of that, the reported "Team account downgraded into plus/pro/free and reused the old Team record" path does not match the account model here.

In practice:

- Personal account transitions such as `free -> plus -> pro` keep the same personal `account_id`.
- Team membership is represented by separate workspace `account_id` values.
- A Team workspace record does not become a personal workspace record in place just because the user's personal plan changed.
- Personal accounts do not receive synced workspace `account_name` values in this flow, so the claimed stale Team workspace name does not transfer through the personal upgrade/downgrade path described in the review.

### P3

Accepted.

The race is not that names are written onto the wrong record by `account_id` matching. The problem is earlier: the detached background refresh is scheduled by one `switch`, but when the child process starts it re-reads the latest `auth.json`, so it may refresh the later active workspace instead of the workspace that triggered the job.

Current effect:

- `switch` to workspace A schedules a refresh for A
- before the child starts, another `switch` updates `auth.json` to workspace B
- the first child reads B and refreshes B
- workspace A is left without the expected name backfill

Simpler direction:

- let both `list` and `switch` trigger the same detached background refresh
- make that background refresh scan registry snapshots instead of re-reading the current `auth.json`
- for each `chatgpt_user_id` scope that still has grouped Team accounts missing `account_name`, load a stored ChatGPT snapshot token and call the account API once
- apply returned names by `account_id` against the latest registry state

Multiple workspace records under the same `chatgpt_user_id` are allowed to resolve to the same `account_name`. In that case, duplicate child labels are acceptable, and we do not need to preserve the old grouped fallback labels such as `team #1` and `team #2` once a synced `account_name` is available.

Example:

- `user@example.com` / plan=`team` / `account_name="Acme"`
- `user@example.com` / plan=`team` / `account_name="Acme"`

Rendered output:

```text
user@example.com
  Acme
  Acme
```

This is acceptable for the new behavior.

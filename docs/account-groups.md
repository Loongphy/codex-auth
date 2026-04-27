# Account Groups

Account groups let one `codex-auth` installation manage multiple isolated Codex homes.
Each group has its own `auth.json`, account registry, account snapshots, and sessions.

The `default` group is the normal Codex home at `~/.codex`. Named groups are created under `~/codex-auth/groups/<name>`.

## Create and Inspect Groups

Create an empty group:

```shell
codex-auth group create work
```

List all groups:

```shell
codex-auth group list
```

Print a group's Codex home:

```shell
codex-auth group work path
codex-auth group path work
```

Group names may contain letters, numbers, `_`, and `-`.

## Login Into a Group

Login directly into a group:

```shell
codex-auth group work login
codex-auth group work login --device-auth
```

The top-level login command can also target a group:

```shell
codex-auth login --group work
codex-auth login --group work --device-auth
```

If the group does not exist, login creates it first.

## Copy or Import Accounts

Copy existing accounts into a group by row number, alias, email, account name, or account key:

```shell
codex-auth group work add 01
codex-auth group work add jane@example.com personal
```

The source account remains in its original group. When the selector matches the `default` group, that match is used first. Other groups are searched only when `default` has no match.

Create a group and copy accounts in one command:

```shell
codex-auth group create work 01 jane@example.com
```

Import an auth file directly into a group:

```shell
codex-auth group work import /path/to/auth.json --alias work-main
```

Remove accounts from one group:

```shell
codex-auth group work remove 01
codex-auth group work remove jane@example.com
```

Removing an account from one group does not remove it from other groups.

## Use a Group

List accounts in a group:

```shell
codex-auth group work list
codex-auth group work list --skip-api
```

Switch the active account inside a group:

```shell
codex-auth group work switch
codex-auth group work switch 02
codex-auth group work switch --live --auto
```

Launch `codext` with a group's `CODEX_HOME`:

```shell
codex-auth group work launch
codex-auth group work launch -- --model gpt-5.4
```

Arguments after `--` are passed to `codext`.

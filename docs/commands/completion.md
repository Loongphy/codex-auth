# `codex-auth completion`

## Usage

```shell
codex-auth completion bash
codex-auth completion zsh
codex-auth completion fish
```

## Bash

`completion bash` prints a Bash completion script to stdout.

Install it with:

```shell
mkdir -p ~/.local/share/bash-completion/completions
codex-auth completion bash > ~/.local/share/bash-completion/completions/codex-auth
```

Or load it dynamically from `~/.bashrc` so upgrades apply automatically:

```shell
source <(codex-auth completion bash)
```

## Zsh

`completion zsh` prints a Zsh completion script to stdout.

Install it with:

```shell
mkdir -p ~/.zsh/completions
codex-auth completion zsh > ~/.zsh/completions/_codex-auth
```

Or load it dynamically from `~/.zshrc` so upgrades apply automatically:

```shell
source <(codex-auth completion zsh)
```

## Fish

`completion fish` prints a Fish completion script to stdout.

Install it with:

```shell
mkdir -p ~/.config/fish/completions
codex-auth completion fish > ~/.config/fish/completions/codex-auth.fish
source ~/.config/fish/completions/codex-auth.fish
```

Or load it dynamically from `~/.config/fish/config.fish` so upgrades apply automatically:

```shell
codex-auth completion fish | source
```

## Dynamic Account Candidates

Account-taking arguments (`switch`, `remove`, `alias set`, `alias clear`) query the CLI at completion time through the hidden `codex-auth completion query account` subcommand. It prints tab-separated `candidate<TAB>description` rows: display numbers, aliases, and emails.

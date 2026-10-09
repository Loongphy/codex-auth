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

## Zsh

`completion zsh` prints a Zsh completion script to stdout.

Install it with:

```shell
mkdir -p ~/.zsh/completions
codex-auth completion zsh > ~/.zsh/completions/_codex-auth
```

## Fish

`completion fish` prints a Fish completion script to stdout.

Install it with:

```shell
mkdir -p ~/.config/fish/completions
codex-auth completion fish > ~/.config/fish/completions/codex-auth.fish
source ~/.config/fish/completions/codex-auth.fish
```

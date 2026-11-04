# `codex-auth completion`

## Usage

```shell
codex-auth completion bash
codex-auth completion zsh
codex-auth completion fish
codex-auth completion pwsh
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

Install it with (the directory must be in `fpath` before `compinit` runs):

```shell
mkdir -p ~/.zsh/completions
codex-auth completion zsh > ~/.zsh/completions/_codex-auth
echo 'fpath=(~/.zsh/completions $fpath)' >> ~/.zshrc
autoload -Uz compinit && compinit
```

Or load it dynamically from `~/.zshrc` so upgrades apply automatically — place this after `compinit`, since the generated script calls `compdef`:

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

## PowerShell

`completion pwsh` (or `powershell`) prints a PowerShell completion script to stdout (Windows PowerShell 5.1 and PowerShell 7+).

Install it by appending to your profile so upgrades apply automatically:

```powershell
codex-auth completion pwsh >> $PROFILE
```

Or load it for the current session only:

```powershell
codex-auth completion pwsh | Invoke-Expression
```

## Runtime Completion Protocol

The generated scripts are thin trampolines: on every Tab they forward the current command-line words to a hidden endpoint and let the binary decide what to offer.

```shell
codex-auth __complete <word>... <current-word>
codex-auth __completeNoDesc <word>... <current-word>
```

The last argument is the word being completed (possibly empty); the arguments before it are the already-typed words after `codex-auth`. `__complete` prints `candidate<TAB>description` rows; `__completeNoDesc` prints bare `candidate` rows for shells that cannot render descriptions. Both end with a `:<directive>` line — a bitmask compatible with Cobra's `ShellCompDirective`: `0` allow file completion, `1` error, `2` no trailing space, `4` no file completion, `16` directories only, `32` keep output order.

Account-taking arguments (`switch`, `remove`, `reset`, `alias set`, `alias clear`) emit one selector hint per account — the unique alias, else the unique email, else the account key — so every offered value resolves to a single stable account identity.

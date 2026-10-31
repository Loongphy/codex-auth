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

## PowerShell

`completion pwsh` prints a PowerShell completion script to stdout (requires PowerShell 7+).

Install it by appending to your profile so upgrades apply automatically:

```powershell
codex-auth completion pwsh >> $PROFILE
```

Or load it for the current session only:

```powershell
codex-auth completion pwsh | Invoke-Expression
```

## Runtime Completion Protocol

The generated scripts are thin trampolines: on every Tab they forward the current command-line words to the hidden `codex-auth __complete` endpoint and let the binary decide what to offer.

```shell
codex-auth __complete <word>... <current-word>
```

The last argument is the word being completed (possibly empty); the arguments before it are the already-typed words after `codex-auth`. The endpoint prints `candidate<TAB>description` rows followed by a final `:<directive>` line. The directive is a bitmask compatible with Cobra's `ShellCompDirective`: `0` allow file completion, `1` error, `2` no trailing space, `4` no file completion, `16` directories only, `32` keep output order.

Account-taking arguments (`switch`, `remove`, `alias set`, `alias clear`) emit `NN:email` composites plus alias and bare-email candidates, so the inserted value always resolves to a stable account identity rather than a bare list position.

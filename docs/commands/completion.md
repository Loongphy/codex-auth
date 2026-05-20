# `codex-auth completion`

## Usage

```shell
codex-auth completion fish
```

## Fish

`completion fish` prints a Fish completion script to stdout.

Install it with:

```shell
mkdir -p ~/.config/fish/completions
codex-auth completion fish > ~/.config/fish/completions/codex-auth.fish
codex-auth completion fish > ~/.config/fish/completions/cx.fish
source ~/.config/fish/completions/cx.fish
```

Writing `~/.config/fish/completions/cx.fish` replaces any older `cx` Fish completion on your system.

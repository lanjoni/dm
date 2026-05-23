# dm

`dm` is a dotfiles manager written in Zig.

It synchronizes a directory that mirrors your `$HOME` with your real `$HOME`. It is designed for people who keep their dotfiles in a Git repository and want changes to flow in both directions.

`dm` is **not** a symlink-based manager. It copies files and directories directly, while preserving symlinks as symlinks when they are part of the managed tree.

## How it works

Your config points `dm` at a directory that mirrors `$HOME`:

```text
dotfiles-path = ~/gh/dotfiles/home
```

Then paths map like this:

```text
~/gh/dotfiles/home/.zshrc             <->  ~/.zshrc
~/gh/dotfiles/home/.config/nvim       <->  ~/.config/nvim
~/gh/dotfiles/home/.config/git/config <->  ~/.config/git/config
```

Only paths inside `dotfiles-path` are managed. If a file exists only in `$HOME`, `dm` ignores it.

When both sides contain the same managed path, the newer modified file wins.

Before replacing anything, `dm` backs up the existing destination under:

```text
/tmp/dm/<timestamp>/
```

## Install / build

Install with Homebrew:

```sh
brew install lanjoni/tap/dm
```

Or add the tap first:

```sh
brew tap lanjoni/tap
brew install dm
```

To build from source:

```sh
zig build
```

The binary is written to:

```text
zig-out/bin/dm
```

Run it directly:

```sh
./zig-out/bin/dm help
```

Or through Zig:

```sh
zig build run -- help
```

## Config

Default config path:

```text
~/.config/dm/config
```

Example:

```text
# Directory that mirrors $HOME
dotfiles-path = ~/gh/dotfiles/home

# Exact paths relative to dotfiles-path to ignore
excludes = README.md, .config/ghostty
```

### Config keys

#### `dotfiles-path`

Required.

Points directly to the directory that mirrors `$HOME`.

```text
dotfiles-path = ~/gh/dotfiles/home
```

Rules:

- `~` expansion is supported.
- Environment variable expansion is not supported yet.

#### `excludes`

Optional.

Comma-separated exact paths relative to `dotfiles-path`.

```text
excludes = README.md, .config/ghostty
```

This excludes both sides of the mapping:

```text
~/gh/dotfiles/home/.config/ghostty
~/.config/ghostty
```

Globs are not supported yet.

## Commands

Show help:

```sh
dm help
```

Show current sync status:

```sh
dm status
```

Show status with an explicit config file:

```sh
dm status --config ./config
```

Preview sync operations without changing files:

```sh
dm sync --dry-run
```

Run sync:

```sh
dm sync
```

Run sync with an explicit config file:

```sh
dm sync --config ./config
```

Running `dm` with no arguments shows help.

## Sync behavior

- Managed paths are discovered by walking `dotfiles-path` recursively.
- Directories are synced recursively, file by file.
- Empty directories under `dotfiles-path` are created in `$HOME`.
- If a managed file exists on both sides, the newer modification time wins.
- If a managed path exists only in `dotfiles-path`, it is created in `$HOME`.
- If a file exists only in `$HOME`, it is ignored.
- Deletion syncing is not implemented; `dm sync` does not delete files to mirror deletions.
- Symlinks are preserved as symlinks.
- Copies attempt to preserve metadata such as permissions and timestamps.

## Backups

Before replacing a path, `dm` moves the previous destination into a timestamped backup directory:

```text
/tmp/dm/<timestamp>/home/<relative-path>
/tmp/dm/<timestamp>/dotfiles/<relative-path>
```

Examples:

```text
~/.zshrc
```

may be backed up to:

```text
/tmp/dm/1779501649654723000/home/.zshrc
```

and:

```text
~/gh/dotfiles/home/.config/nvim/init.lua
```

may be backed up to:

```text
/tmp/dm/1779501649654723000/dotfiles/.config/nvim/init.lua
```

## Development

Format, test, and build:

```sh
zig fmt src/*.zig
zig build test
zig build
```

Run smoke tests manually:

```sh
zig build run -- help
zig build run -- status --config /path/to/config
zig build run -- sync --dry-run --config /path/to/config
```

Project docs and plans live in `docs/`.

The initial design plan is in:

```text
docs/plans/initial-cli-sync-plan.md
```



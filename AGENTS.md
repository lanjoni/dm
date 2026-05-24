# AGENTS.md

Guidance for coding agents working on `dm`.

## Project overview

`dm` is a dotfiles manager written in Zig. It synchronizes a configured dotfiles mirror directory with the current user's `$HOME` directory.

This project is **not** a symlink-based dotfiles manager. Managed files are copied between two locations:

```text
dotfiles-path/<relative-path>  <->  $HOME/<relative-path>
```

Example:

```text
~/gh/dotfiles/home/.zshrc       <->  ~/.zshrc
~/gh/dotfiles/home/.config/nvim <->  ~/.config/nvim
```

Only paths that already exist under `dotfiles-path` are managed. Extra files that exist only in `$HOME` are ignored.

## Core behavior

- `dotfiles-path` points directly to the directory that mirrors `$HOME`.
- `dm status` reports pending operations without modifying files.
- `dm sync --dry-run` reports the operations that would be performed.
- `dm sync` performs the operations.
- If a managed path exists on both sides, newer modification time wins.
- If a managed path exists only in `dotfiles-path`, it is created in `$HOME`.
- If a path exists only in `$HOME`, it is ignored unless that relative path exists under `dotfiles-path`.
- `dm sync` should not delete files to mirror deletions.
- Before replacing a destination, the old destination is backed up under `/tmp/dm/<timestamp>/`.
- Symlinks should be preserved as symlinks, not followed.

See `docs/plans/initial-cli-sync-plan.md` for the original design plan.

## Config

Default config path:

```text
~/.config/dm/config
```

Format is a simple key/value file:

```text
# Directory that mirrors $HOME
dotfiles-path = ~/gh/dotfiles/home

# Relative paths and patterns under dotfiles-path to ignore
excludes = README.md, .config/ghostty, */.cpcache
```

Rules:

- `dotfiles-path` is required.
- `excludes` is optional and comma-separated.
- Spaces around `=` and commas are allowed.
- Blank lines and `#` comments are allowed.
- `~` expansion is supported.
- Environment variable expansion is out of scope for now.
- Excludes are exact relative paths or `*` segment patterns.
- In excludes, `*` is only special as a full path segment and matches zero or more path segments.

## Source layout

Keep implementation in `src/`.

Current module responsibilities:

- `src/main.zig` — executable entrypoint, environment, stdout, exit code
- `src/root.zig` — top-level orchestration for commands
- `src/cli.zig` — CLI parsing and help output
- `src/config.zig` — config parsing/loading and `~` expansion
- `src/plan.zig` — managed path discovery and sync planning
- `src/sync.zig` — backup creation and sync execution
- `src/output.zig` — status/dry-run/sync output formatting
- `src/types.zig` — shared types
- `src/colors.zig` — ANSI colors
- `src/paths.zig` — path helpers

Keep project documentation, notes, and plans in `docs/`.

## Commands

Build:

```sh
zig build
```

Run all tests:

```sh
zig build test
```

Run the CLI through Zig:

```sh
zig build run -- help
zig build run -- status --config /path/to/config
zig build run -- sync --dry-run --config /path/to/config
```

Build then run binary directly:

```sh
zig build
./zig-out/bin/dm help
```

## Validation checklist

After code changes, run:

```sh
zig fmt src/*.zig
zig build test
zig build
```

For behavior changes, also smoke-test with a temporary config and directories when practical:

```sh
zig build run -- status --config /tmp/dm-test/config
zig build run -- sync --dry-run --config /tmp/dm-test/config
```

## Development conventions

- Prefer small, focused changes.
- Keep `root.zig` thin; put behavior in focused modules.
- Add tests near the module being changed.
- Use `std.testing.tmpDir` for filesystem tests.
- Preserve the current safety model: back up before replacing, never delete unmanaged files.
- Do not introduce symlink-following behavior unless explicitly requested.
- Keep user-facing output concise and colored.
- Run `zig build test` after code changes.

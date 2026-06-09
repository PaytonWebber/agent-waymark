# Changelog

## 0.1.3 (2026-06-09)

### Added

- `agent-waymark --version`.
- `agent-waymark mcp-config <claude|codex>` for printing copyable MCP server
  config for external config managers.

### Changed

- `agent-waymark doctor` now checks both project and user-level Claude/Codex
  config, so user installs are visible from any working directory.

## 0.1.2 (2026-06-09)

### Added

- `touch` / `confirm` for marking an existing entry as still valid without
  rewriting it.
- Freshness metadata on entries: `created_at`, `updated_at`, and `confirmed_at`.
- Stale-entry signals for entries that have not been updated or confirmed for
  two weeks.
- Near-duplicate warnings on `record`, with suggestions to `supersede` or
  `touch` the existing entry.
- File-ref tracking with `record --ref PATH[:line]`. Waymark stores a file hash
  and later flags entries whose referenced files changed or disappeared.
- Linked worktree support. Worktrees share repo-wide state while file refs
  resolve against the active worktree.
- Prompt-activity nudges when several user prompts pass without any state write.

### Changed

- Header entries are ranked by latest update or confirmation instead of creation
  order alone.
- Automatic recall and MCP/CLI output include freshness and ref-status signals.

## 0.1.1 (2026-06-08)

### Added

- `agent-waymark --doctor` alias.
- `--help` / `-h` usage output.

### Fixed

- macOS Unix socket startup for the native client.

## 0.1.0 (2026-06-08)

### Added

- Durable shared working-state daemon for structured entries:
  `decision`, `finding`, `rejected`, `todo`, `artifact`, and `note`.
- MCP tools: `record`, `recall`, `timeline`, `supersede`, `done`, and `pin`.
- Claude Code hook kit for `SessionStart`, `SubagentStart`,
  `UserPromptSubmit`, and `PreCompact`.
- Project and user-level installers for Claude Code and Codex.
- Supersede chains, resolved todos, pinned entries, hierarchical scopes, and
  branch-local entries.
- npm packaging with per-platform optional native binary packages.
- Claude Code plugin packaging with bundled native binaries.

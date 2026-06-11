# Changelog

## 0.2.0 (2026-06-10)

### Changed

- The embedding model is now compiled into the binary: potion-retrieval-32M
  via model2vec, 512-dimensional static embeddings quantized to int8 (~32 MB
  in the binary, byte-identical to the reference quantizer, ~0.9997 cosine
  vs f32). `record` and `recall` work offline with nothing installed;
  embedding takes microseconds in-process instead of a 20-30ms round trip to
  a local model server, and paraphrase recall on our eval suite matches the
  old nomic-embed-text stack. Ollama and the `nomic-embed-text` model are no
  longer required; Ollama remains optional for the `PreCompact` extraction
  sweep only. `-Dmodel=potion-base-8M` builds a smaller variant.
- Recall is hybrid: the semantic ranking is fused (reciprocal-rank fusion)
  with a BM25 ranking over the same candidates, so exact identifiers (file
  paths, symbols, env var names) match even when the embedding misses them.
  Hit scores remain cosine similarity; fusion only decides the order.
- Stores written at a different embedding dimension migrate automatically:
  entries are re-embedded on first load and the snapshot is rewritten once.
- `AGENT_WAYMARK_EMBED_URL`, `AGENT_WAYMARK_EMBED_MODEL`, and
  `AGENT_WAYMARK_EMBED_KEEP_ALIVE` are gone. `AGENT_WAYMARK_MODEL_DIR` loads a
  different model2vec model from disk (its dimension must match the build).

## 0.1.5 (2026-06-09)

### Added

- Injected context now includes a `Current truth` section for active decisions
  and artifacts that do not need review.
- Missing file refs can show a possible same-directory replacement when a
  similarly named file exists.

### Changed

- Injected context deduplicates entries across header sections, so an entry
  that needs review is not repeated under recent decisions.
- Stale and changed-ref entries now include direct maintenance actions in hook,
  CLI, and MCP output.
- Hook output now ends with a newline and the integration smoke test checks that
  raw response JSON does not leak into injected context.

## 0.1.4 (2026-06-09)

### Added

- `agent-waymark handoff` and the MCP `handoff` tool for a compact next-agent
  summary grouped by decisions, todos, findings, dead ends, artifacts, and
  entries needing review.
- `agent-waymark refs refresh|move|dismiss` and the MCP `refs` tool for closing
  stale file-ref warnings after validation, intentional renames, or expected
  removals.

### Changed

- Project installs now pin the daemon store under the shared git repo root, so
  linked worktrees for the same repo use the same Waymark store by default.
- `agent-waymark doctor` now reports the daemon's actual opened store path.
- MCP recall and timeline descriptions now explain that an empty scope searches
  or lists all scopes in the current store.

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

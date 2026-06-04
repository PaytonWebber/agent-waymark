# Changelog

## 0.1.0 (unreleased)

First release.

- Durable shared working-state for agent orchestration: structured entries
  (decision / finding / rejected / todo / artifact / note) over a quantal vector
  index, owned by a single unix-socket daemon; thin MCP, hook, and CLI clients.
- MCP server (`record`, `recall`, `timeline`, `supersede`, `done`, `pin`).
- Claude Code hook kit: `SessionStart` and `SubagentStart` inject the scope
  header; `UserPromptSubmit` injects prompt-relevant recall (gated on a cosine
  relevance floor so off-topic prompts add nothing).
- `cairn install` merges the MCP server + hooks into Claude Code config
  (project or `--user`), preserving existing config and idempotent on re-run.
- Entry lifecycle: `done`/resolve, supersede chain-head resolution with ref
  inheritance, and pin/unpin so foundational entries stay in the header.
- Concurrency: the daemon serves from a worker pool under an RwLock, so a
  long-lived client never blocks transient ones.
- L2-normalized embeddings (cosine scores).
- Packaging: npm (per-platform binary via optional dependencies) and a
  Claude Code plugin (bundled binaries). Linux x64/arm64, macOS arm64/x64.

Requires Zig 0.16 to build from source, and a local Ollama embedding model at
runtime.

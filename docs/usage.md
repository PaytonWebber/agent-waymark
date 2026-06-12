# Usage reference

## What belongs in waymark

Waymark is for live working state, not permanent project documentation. Good
entries are things a later session should not have to re-discover:

- Decisions: "use a daemon to own the store."
- Findings: "the Apple Silicon npm package resolves to darwin-arm64."
- Rejected paths: "do not keep per-process stores; sub-agents corrupt state."
- Todos: "wire the hosted backend auth check."

Do not record every thought. Do not use it as a replacement for README files,
architecture docs, issue trackers, or source comments. When an entry becomes
a stable project fact, move it into the repo. When a todo is done, mark it
done. When an old decision is still true, `touch` it instead of rewriting it.
Before handing work to another agent, run `handoff` to produce a compact
summary of the decisions, open todos, findings, dead ends, artifacts, and
entries that need review.

## Freshness, duplicates, and injected context

Entries show freshness in recall, timeline, and injected context. Freshness
is based on the last confirmation if present, otherwise the last update.
Entries older than two weeks are flagged `stale?`, which means "verify before
relying on this." `record` also checks for near-duplicates. If a new entry
looks very close to an existing active entry, it still records it but warns
you to consider `supersede` or `touch`. Injected context groups active
decisions and artifacts under `Current truth`, then shows entries that need
review and open todos below that. An entry is shown once per injected block.

## File refs

If an entry records a file ref, waymark stores a hash of that file at write
time. Later recall, timeline, and injected context flag the entry if the file
changed or disappeared. This does not prove a decision is wrong; it tells the
agent to verify it before trusting it. After verification, use
`refs refresh <id>` when the current file is still the right ref, use
`refs move <id> <old-ref> <new-ref>` after an intentional rename, or use
`refs dismiss <id> <ref>` when the ref is no longer useful. When a referenced
file is missing, waymark may suggest a similarly named replacement from the
same directory.

## Scoping

State is scoped to the **git repository**. Linked git worktrees share the
same repo-wide scope and, for project installs, the same default store. File
refs are resolved against the active worktree where the entry was recorded.
Within a repo, scope is hierarchical:

- **Repo-wide** (`repo:<root>`) is the default for writes and is visible from
  every branch. This is where durable decisions, findings, and rejected paths
  live.
- **Branch-local** (`repo:<root>/branch/<name>`) is opt-in (`--branch-local`,
  or the `branch_local` tool arg) for work specific to a feature branch. It
  shows only on that branch; the default branch and other branches don't see
  it, and it's flagged `[branch]` in the header.

Reads run at the current branch and return repo-wide plus current-branch
entries. The default branch (detected from the remote's `origin/HEAD`,
falling back to `main`/`master` for local-only repos) is treated as
repo-wide. Outside a git repo, everything is repo-wide for that directory.
`AGENT_WAYMARK_SCOPE` overrides detection with a fixed scope.

## CLI

Any subcommand auto-starts the daemon if it isn't running. `record` writes
repo-wide by default; add `--branch-local` for branch-specific entries. Pass
`--scope ""` to span all scopes.

```bash
agent-waymark record decision "use a daemon to own the store"
agent-waymark record finding "auth middleware owns tenant lookup" --ref src/auth.ts:42
agent-waymark record todo "wire up the new endpoint" --branch-local
agent-waymark recall  "who owns the store?"
agent-waymark timeline
agent-waymark header                        # the always-on session summary
agent-waymark handoff                       # grouped summary for the next agent
agent-waymark done <id>                     # finish a todo (kept for history)
agent-waymark touch <id>                    # confirm an entry is still valid
agent-waymark refs refresh <id>             # accept current file-ref hashes
agent-waymark refs move <id> old.ts new.ts  # update a ref after a rename
agent-waymark refs dismiss <id> old.ts      # remove an expected stale ref
agent-waymark pin <id>                      # always show an entry in the header
agent-waymark unpin <id>
```

## Environment knobs

`AGENT_WAYMARK_SOCKET`, `AGENT_WAYMARK_STORE` (socket/snapshot paths);
`AGENT_WAYMARK_MODEL_DIR` (load a different model2vec embedding model from
disk; its dimension must match the build); `AGENT_WAYMARK_SCOPE`,
`AGENT_WAYMARK_AUTHOR`; `AGENT_WAYMARK_MIN_SCORE` (recall floor for the
prompt hook); and for the PreCompact sweep, `AGENT_WAYMARK_EXTRACT_URL`,
`AGENT_WAYMARK_EXTRACT_MODEL` (default `llama3.2`), and
`AGENT_WAYMARK_SWEEP_DEDUP` (cosine above which a swept entry is treated as
already known, default `0.85`).

## The PreCompact sweep

The `PreCompact` hook extracts decisions, findings, and todos from the
session transcript with a local chat model and records the new ones, so
state survives even when nothing was recorded by hand. It is the one
optional feature with an external dependency:

```bash
ollama pull llama3.2
```

Without it, `PreCompact` no-ops and everything else works. The sweep is
best-effort and runs after the hook returns, so slow local generation cannot
block compaction. Extraction quality scales with
`AGENT_WAYMARK_EXTRACT_MODEL` (a small model may miss entries or
occasionally record a paraphrase of one already stored), so use a capable
local model for it.

## Latency and migration

The `UserPromptSubmit` hook embeds each prompt before the turn proceeds.
Embedding runs in-process against the bundled static-embedding model and
takes a few microseconds, so the hook's end-to-end cost is the unix socket
round trip: well under a millisecond, with no warm-up and no cold start.

A store written by an older build with a different embedding dimension or a
different bundled matrix (the snapshot records the model's fingerprint) is
migrated automatically: the daemon re-embeds every entry on first load (also
microseconds each) and rewrites the snapshot once.

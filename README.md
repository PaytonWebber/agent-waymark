# Agent Waymark

Durable, shared working-state for agent orchestration. Not another semantic
memory store. The unit of state is a structured **entry**: a decision, a
finding, a rejected path, or a todo that one agent, sub-agent, or session leaves
for the next, so they stop re-discovering and re-deciding what an earlier one
already worked out.

## Why

The loud, repeated, quantifiable pains in agent work are not "the model forgot a
fact." They are context lost across handoffs and sessions, state lost to
compaction, and sub-agents re-solving what the parent already solved. Two facts
shape the design:

- An MCP server can't inject context on its own; it only answers tool calls the
  model chooses to make, which is why memory MCPs so often go unused. Agent
  **hooks** can push context into the model before it responds. So agent-waymark is an
  MCP server **plus a hook kit**. The hooks are the point.
- A user's main session and its sub-agents are separate processes, so none of
  them can own the store without corrupting it. A single **daemon owns the
  store**; everything else is a thin client. Add auth and a network bind and the
  same daemon is a team server.

## Prerequisites

Supported platforms:

- Linux x64
- Linux arm64
- macOS Apple Silicon
- macOS Intel

Runtime requirements:

- Node.js 18 or newer for the npm launcher and plugin bundle.
- A local [Ollama](https://ollama.com) server.
- The `nomic-embed-text` Ollama model. This is the default embedding model and
  must match the 768-dimensional index build.

```bash
ollama pull nomic-embed-text   # 768-d, the default (required, for recall)
```

Optional:

```bash
ollama pull llama3.2           # enables the PreCompact extraction sweep
```

Without the optional extraction model, `PreCompact` no-ops and everything else
works. To build from source, install Zig 0.16 and Node.js 18 or newer.

## Install

### As a Claude Code plugin (recommended)

```
/plugin marketplace add PaytonWebber/agent-waymark
/plugin install agent-waymark@agent-waymark
```

Restart Claude Code after installing. Use `/mcp` to confirm the MCP server is
connected.

This registers both halves, which is the whole point of the design:

- The **MCP server** (`record`, `recall`, `timeline`, `supersede`, `touch`,
  `done`, `pin`, `refs`, `handoff`) is how the model writes, curates, and
  explicitly queries state.
- The **hooks** are how recall actually happens, since a tool-only server can't
  inject context on its own:
  - `SessionStart` injects the scope header (pinned entries, open todos, recent
    decisions), including after a compaction, so a session starts oriented.
  - `UserPromptSubmit` recalls entries relevant to each prompt and injects the
    strong matches, so recall doesn't depend on the model choosing to ask.
  - `SubagentStart` seeds a fresh sub-agent with the header, so it doesn't
    re-discover what the parent already worked out.
  - `PreCompact` extracts decisions, findings, and todos from the session
    transcript with a local chat model and records the new ones, so state
    survives even when nothing was recorded by hand. Best-effort and opt-in by
    model availability (see below); it runs in a detached worker and no-ops if
    no extraction model is present.

### As a CLI (npm)

```bash
npm install -g agent-waymark
```

This gives you the `agent-waymark` command. To wire a project, run:

```bash
agent-waymark install
```

That writes `.claude/settings.json` and `.mcp.json` in the current project. It
preserves existing config and replaces only agent-waymark's own entries on
repeat runs. Project installs pin the daemon store under the shared git repo
root, so linked worktrees for the same repo use the same Waymark store.

To install Claude hooks and the MCP server at user scope:

```bash
agent-waymark install --user
```

That writes `~/.claude/settings.json` and `~/.claude.json`. To keep hooks in the
current project but register the MCP server globally:

```bash
agent-waymark install --global-mcp
```

To choose the daemon snapshot location, pass `--store PATH`:

```bash
agent-waymark install --store ~/.agent-waymark/work-state.json
```

The installer also derives the Unix socket path from that file
(`PATH.sock`) and generates commands that create the parent directory before
starting the daemon. Use the same flag with `--codex`, `--user`, or
`--global-mcp`.

To print a copyable MCP server config for an external config manager:

```bash
agent-waymark mcp-config claude
agent-waymark mcp-config codex --store ~/.agent-waymark/work-state.json
```

Without `--store`, `mcp-config` uses `~/.agent-waymark/agent-waymark-state.json`
and `~/.agent-waymark/agent-waymark.sock`.

For Codex, run:

```bash
agent-waymark install --codex
```

That writes `.codex/config.toml` and `.codex/hooks.json` in the current project.
For a user-level Codex install, run `agent-waymark install --codex --user`.
To keep project hooks but register the Codex MCP server globally, run
`agent-waymark install --codex --global-mcp`.
Codex requires non-managed command hooks to be reviewed and trusted before they
run; after installing, restart Codex and use `/hooks` to trust agent-waymark's hooks.
Project installs keep daemon state in the shared git repo root's
`.agent-waymark/` directory instead of `/tmp`, so linked worktrees for the same
repo share entries. Some sandboxed shell surfaces may still require approval for
Unix socket binding; after restart, verify Codex sees agent-waymark with `/mcp`
and `/hooks`. The hook config uses Codex's documented hook events/trust flow and
the `additionalContext` output shape verified in current Codex sessions.

### From source

```bash
zig build                # build the `agent-waymark` binary (Zig 0.16)
zig build test           # unit tests (offline, no Ollama)
zig build integration    # daemon + MCP + hook smoke test (offline, no Ollama)
```

The integration smoke test also requires Node.js 18 or newer.

The Zig build uses [quantal](https://github.com/PaytonWebber/quantal) for the
embedded vector index and [zig-mcp-sdk](https://github.com/PaytonWebber/zig-mcp-sdk)
for the MCP protocol and server wiring.

Run `agent-waymark doctor` to check the effective socket/store paths, the
daemon's actual opened store, current scope, daemon reachability, and whether
Claude/Codex project or user config contains agent-waymark entries. Use
`agent-waymark doctor --json` for CI or package smoke tests.

## Quick Check

After installing and restarting your agent client:

```bash
agent-waymark doctor
agent-waymark --version
agent-waymark record decision "use agent-waymark for project state"
agent-waymark recall "project state"
```

If Ollama is not running, `record` and `recall` will report an embedding service
error. Start Ollama and try again.

### What belongs in waymark

Waymark is for live working state, not permanent project documentation. Good
entries are things a later session should not have to re-discover:

- Decisions: "use a daemon to own the store."
- Findings: "the Apple Silicon npm package resolves to darwin-arm64."
- Rejected paths: "do not keep per-process stores; sub-agents corrupt state."
- Todos: "wire the hosted backend auth check."

Do not record every thought. Do not use it as a replacement for README files,
architecture docs, issue trackers, or source comments. When an entry becomes a
stable project fact, move it into the repo. When a todo is done, mark it done.
When an old decision is still true, `touch` it instead of rewriting it.
Before handing work to another agent, run `handoff` to produce a compact summary
of the decisions, open todos, findings, dead ends, artifacts, and entries that
need review.

Entries show freshness in recall, timeline, and injected context. Freshness is
based on the last confirmation if present, otherwise the last update. Entries
older than two weeks are flagged `stale?`, which means "verify before relying on
this." `record` also checks for near-duplicates. If a new entry looks very close
to an existing active entry, it still records it but warns you to consider
`supersede` or `touch`.

File refs are checked too. If an entry records a file ref, waymark stores a hash
of that file at write time. Later recall, timeline, and injected context flag
the entry if the file changed or disappeared. This does not prove a decision is
wrong; it tells the agent to verify it before trusting it. After verification,
use `refs refresh <id>` when the current file is still the right ref, use
`refs move <id> <old-ref> <new-ref>` after an intentional rename, or use
`refs dismiss <id> <ref>` when the ref is no longer useful.

### Scoping

State is scoped to the **git repository**. Linked git worktrees share the same
repo-wide scope and, for project installs, the same default store. File refs are
resolved against the active worktree where the entry was recorded. Within a repo,
scope is hierarchical:

- **Repo-wide** (`repo:<root>`) is the default for writes and is visible from
  every branch. This is where durable decisions, findings, and rejected paths
  live.
- **Branch-local** (`repo:<root>/branch/<name>`) is opt-in (`--branch-local`, or
  the `branch_local` tool arg) for work specific to a feature branch. It shows
  only on that branch; the default branch and other branches don't see it, and
  it's flagged `[branch]` in the header.

Reads run at the current branch and return repo-wide plus current-branch
entries. The default branch (detected from the remote's `origin/HEAD`, falling
back to `main`/`master` for local-only repos) is treated as repo-wide. Outside a
git repo, everything is repo-wide for that directory. `AGENT_WAYMARK_SCOPE` overrides
detection with a fixed scope.

### CLI

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

Environment knobs: `AGENT_WAYMARK_SOCKET`, `AGENT_WAYMARK_STORE` (socket/snapshot paths);
`AGENT_WAYMARK_EMBED_URL`, `AGENT_WAYMARK_EMBED_MODEL`, `AGENT_WAYMARK_EMBED_KEEP_ALIVE` (embedding
endpoint/model and warm-up window); `AGENT_WAYMARK_SCOPE`, `AGENT_WAYMARK_AUTHOR`; `AGENT_WAYMARK_MIN_SCORE`
(recall floor for the prompt hook); and for the PreCompact sweep,
`AGENT_WAYMARK_EXTRACT_URL`, `AGENT_WAYMARK_EXTRACT_MODEL` (default `llama3.2`), and
`AGENT_WAYMARK_SWEEP_DEDUP` (cosine above which a swept entry is treated as already
known, default `0.85`).

The sweep is best-effort and runs after the PreCompact hook returns, so slow
local generation cannot block compaction. Extraction quality scales with
`AGENT_WAYMARK_EXTRACT_MODEL` (a small model may miss entries or occasionally
record a paraphrase of one already stored), so use a capable local model for it.

### Latency

The `UserPromptSubmit` hook embeds each prompt before the turn proceeds. With a
warm model that is ~20-30ms; the only slow case is a cold load after an idle
gap, which `AGENT_WAYMARK_EMBED_KEEP_ALIVE` (default `30m`) is there to avoid. If you
want it faster still, point `AGENT_WAYMARK_EMBED_MODEL` at a smaller model (e.g.
`all-minilm`); the query and stored vectors must use the same model, so delete
the store (or re-record) when you switch.

Still ahead: a cross-machine team backend (TCP + auth).

## License

MIT.

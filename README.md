# cairn

Durable, shared working-state for agent orchestration. Not another semantic
memory store. The unit of state is a structured **entry** — a decision, a
finding, a rejected path, a todo — that one agent, sub-agent, or session leaves
for the next, so they stop re-discovering and re-deciding what an earlier one
already worked out.

> Working name. Branding is not final.

## Why

The loud, repeated, quantifiable pains in agent work are not "the model forgot a
fact." They are context lost across handoffs and sessions, state lost to
compaction, and sub-agents re-solving what the parent already solved. Two facts
shape the design:

- An MCP server can't inject context on its own; it only answers tool calls the
  model chooses to make, which is why memory MCPs so often go unused. Only
  Claude Code **hooks** can push context into the model before it responds. So
  cairn is an MCP server **plus a hook kit** — the hooks are the point.
- A user's main session and its sub-agents are separate processes, so none of
  them can own the store without corrupting it. A single **daemon owns the
  store**; everything else is a thin client. Add auth and a network bind and the
  same daemon is a team server.

See [PLAN.md](PLAN.md) for the architecture and roadmap.

## Requirements

A local [Ollama](https://ollama.com) with an embedding model:

```bash
ollama pull nomic-embed-text   # 768-d, the default (required, for recall)
ollama pull llama3.2           # optional: enables the PreCompact sweep
```

The second model is only for the `PreCompact` sweep; without it, that hook
no-ops and everything else works. Supported platforms: Linux (x64, arm64) and
macOS (Apple Silicon, Intel).

## Install

### As a Claude Code plugin (recommended)

```
/plugin marketplace add PaytonWebber/cairn
/plugin install cairn@cairn
```

This registers both halves, which is the whole point of the design:

- The **MCP server** (`record`, `recall`, `timeline`, `supersede`, `done`,
  `pin`) is how the model writes and explicitly queries state.
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
    model availability (see below); it no-ops if no extraction model is present.

### As a CLI (npm)

```bash
npm install -g cairn
```

Gives you the `cairn` command. To wire a project (or all projects) into Claude
Code without the plugin, `cairn install` merges the MCP server and hooks into
your Claude Code config (idempotent, preserves existing hooks):

```bash
cairn install            # this project: .claude/settings.json + .mcp.json
cairn install --user     # every project: ~/.claude/settings.json
```

### From source

```bash
zig build                # build the `cairn` binary (Zig 0.16)
zig build test           # unit tests (offline, no Ollama)
```

### Scoping

State is scoped to the **git repository** (the toplevel, so subdirectories and
worktrees of one repo share it). Within a repo, scope is hierarchical:

- **Repo-wide** (`repo:<root>`) is the default for writes and is visible from
  every branch — this is where durable decisions, findings, and rejected paths
  live.
- **Branch-local** (`repo:<root>/branch/<name>`) is opt-in (`--branch-local`, or
  the `branch_local` tool arg) for work specific to a feature branch. It shows
  only on that branch; the default branch and other branches don't see it, and
  it's flagged `[branch]` in the header.

Reads run at the current branch and return repo-wide plus current-branch
entries. The default branch (detected from the remote's `origin/HEAD`, falling
back to `main`/`master` for local-only repos) is treated as repo-wide. Outside a
git repo, everything is repo-wide for that directory. `CAIRN_SCOPE` overrides
detection with a fixed scope.

### CLI

Any subcommand auto-starts the daemon if it isn't running. `record` writes
repo-wide by default; add `--branch-local` for branch-specific entries. Pass
`--scope ""` to span all scopes.

```bash
cairn record decision "use a daemon to own the store"
cairn record todo "wire up the new endpoint" --branch-local
cairn recall  "who owns the store?"
cairn timeline
cairn header                        # the always-on session summary
cairn done <id>                     # finish a todo (kept for history)
cairn pin <id>                      # always show an entry in the header
cairn unpin <id>
```

Environment knobs: `CAIRN_SOCKET`, `CAIRN_STORE` (socket/snapshot paths);
`CAIRN_EMBED_URL`, `CAIRN_EMBED_MODEL`, `CAIRN_EMBED_KEEP_ALIVE` (embedding
endpoint/model and warm-up window); `CAIRN_SCOPE`, `CAIRN_AUTHOR`; `CAIRN_MIN_SCORE`
(recall floor for the prompt hook); and for the PreCompact sweep,
`CAIRN_EXTRACT_URL`, `CAIRN_EXTRACT_MODEL` (default `llama3.2`), and
`CAIRN_SWEEP_DEDUP` (cosine above which a swept entry is treated as already
known, default `0.85`).

The sweep is best-effort: extraction quality scales with `CAIRN_EXTRACT_MODEL`
(a small model may miss entries or occasionally record a paraphrase of one
already stored), so use a capable local model for it.

### Latency

The `UserPromptSubmit` hook embeds each prompt before the turn proceeds. With a
warm model that is ~20-30ms; the only slow case is a cold load after an idle
gap, which `CAIRN_EMBED_KEEP_ALIVE` (default `30m`) is there to avoid. If you
want it faster still, point `CAIRN_EMBED_MODEL` at a smaller model (e.g.
`all-minilm`); the query and stored vectors must use the same model, so delete
the store (or re-record) when you switch.

Packaging for npm and the Claude plugin is in place; see [RELEASE.md](RELEASE.md).
Still ahead: a cross-machine team backend (TCP + auth).

## License

MIT.

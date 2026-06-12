# Agent Waymark

[![CI](https://github.com/PaytonWebber/agent-waymark/actions/workflows/ci.yml/badge.svg)](https://github.com/PaytonWebber/agent-waymark/actions/workflows/ci.yml)
[![npm](https://img.shields.io/npm/v/agent-waymark)](https://www.npmjs.com/package/agent-waymark)
[![License: MIT](https://img.shields.io/github/license/PaytonWebber/agent-waymark)](LICENSE)

**Not another semantic memory store.** Memory tools wait to be asked, which is
why models rarely use them. Waymark's hooks push prior state into the model
before it says a word.

A session decides "the daemon owns the store; per-process stores corrupt."
Then the context window fills, compaction eats the reasoning, a sub-agent
spawns blank, or you switch models, and the next turn re-derives the decision
from scratch, or decides differently. Waymark ends that: every new session,
prompt, and sub-agent starts with the project's standing decisions, findings,
and open todos already in context.

```bash
# the session records as it works (or the model does, via MCP):
$ agent-waymark record decision "the daemon owns the store; per-process stores corrupt"
recorded #14
```

```
# after compaction, in a fresh session, or in a new sub-agent,
# before your first message:

## agent-waymark state: repo:your-project

Current truth:
- #14 [decision, confirmed 2d ago] the daemon owns the store; per-process stores corrupt

Open todos (1):
- #21 [todo, created 1d ago] wire the hosted backend auth check
```

The unit of state is a structured **entry**: a decision, a finding, a rejected
path, or a todo that one agent, sub-agent, or session leaves for the next, so
they stop re-discovering and re-deciding what an earlier one already worked
out.

## Why

The loud, repeated, quantifiable pains in agent work are not "the model forgot a
fact." They are context lost across handoffs and sessions, state lost to
compaction, and sub-agents re-solving what the parent already solved. Two facts
shape the design:

- An MCP server can't inject context on its own; it only answers tool calls the
  model chooses to make, which is why memory MCPs so often go unused. Agent
  **hooks** can push context into the model before it responds. So agent-waymark
  is an MCP server **plus a hook kit**. The hooks are the point.
- A user's main session and its sub-agents are separate processes, so none of
  them can own the store without corrupting it. A single **daemon owns the
  store**; everything else is a thin client. Add auth and a network bind and the
  same daemon is a team server.

## How this differs from a memory MCP

| | typical memory MCP | agent-waymark |
|---|---|---|
| Recall | passive: the model must decide to call a search tool | hooks inject relevant state into every session, prompt, and sub-agent |
| Unit of state | free-text fact or conversation snippet | structured entry: decision, finding, rejected path, todo, artifact |
| Lifecycle | write and hope | `done`, `supersede`, `touch`, `pin`; staleness and file-ref drift are flagged |
| Store ownership | per-process | one daemon owns the store; sessions and sub-agents are thin clients |
| Sub-agents | start blank | seeded with the parent's decisions and open todos |

## Quickstart

As a Claude Code plugin (recommended):

```
/plugin marketplace add PaytonWebber/agent-waymark
/plugin install agent-waymark@agent-waymark
```

Restart Claude Code, then confirm with `/mcp`. Or via npm:

```bash
npm install -g agent-waymark
agent-waymark install        # wires hooks + MCP for the current project
```

Then check it end to end:

```bash
agent-waymark doctor
agent-waymark record decision "use agent-waymark for project state"
agent-waymark recall "project state"
```

No services need to be running: the embedding model lives inside the binary,
and any subcommand auto-starts the daemon.

Codex installs (`agent-waymark install --codex`), user-scope and global-MCP
modes, custom store paths, a table of exactly what install writes, and
uninstall are in [docs/install.md](docs/install.md).

## How recall happens

The MCP server (`record`, `recall`, `timeline`, `supersede`, `touch`, `done`,
`pin`, `refs`, `handoff`) is how the model writes, curates, and explicitly
queries state. The hooks are how recall actually happens, since a tool-only
server can't inject context on its own:

- **`SessionStart`** injects the scope header (pinned entries, open todos,
  recent decisions), including after a compaction, so a session starts
  oriented.
- **`UserPromptSubmit`** recalls entries relevant to each prompt and injects
  the strong matches, so recall doesn't depend on the model choosing to ask.
  Recall is hybrid: semantic similarity and exact-token matching (BM25),
  fused, so paraphrases and identifiers like file paths or env var names both
  land.
- **`SubagentStart`** seeds a fresh sub-agent with the header, so it doesn't
  re-discover what the parent already worked out.
- **`PreCompact`** extracts decisions, findings, and todos from the session
  transcript with a local chat model (optional, via Ollama) and records the
  new ones, so state survives even when nothing was recorded by hand.

**Hooks fail open.** A hook must never block or break a session: on any
failure (daemon down, malformed input) it exits 0 with no output, and the
agent proceeds exactly as if waymark were not installed. The worst case is
missing context, never a broken session.

## Footprint

Linux x64/arm64 and macOS Apple Silicon/Intel; Node.js 18+ for the npm
launcher. That is the whole list. The embedding model
(potion-retrieval-32M, 512-d static embeddings in
[model2vec-zig](https://github.com/PaytonWebber/model2vec-zig)'s 4-bit tq4
format, ~16 MB, measured within 0.002 NDCG@10 of f32 on MTEB retrieval) is
compiled into the ~31 MB binary, so `record` and `recall` work offline,
immediately, with nothing else installed. Embedding a text takes a few
microseconds in-process, a hook round trip stays well under a millisecond
with no warm-up, and the daemon runs around 30 MB resident.

The one optional external dependency is a local Ollama model for the
`PreCompact` transcript sweep; without it that hook no-ops and everything
else works.

## Using it

Waymark is for live working state, not permanent documentation: decisions,
findings, rejected paths, and todos that a later session should not have to
re-discover. Entries have a lifecycle (`done`, `supersede`, `touch`, `pin`),
go `stale?` after two weeks unconfirmed, and carry file refs that are flagged
when the referenced file changes.

```bash
agent-waymark record finding "auth middleware owns tenant lookup" --ref src/auth.ts:42
agent-waymark recall  "who owns the store?"
agent-waymark handoff          # grouped summary for the next agent
agent-waymark done <id>        # finish a todo (kept for history)
agent-waymark touch <id>       # confirm an entry is still valid
```

The full CLI, repo/branch scoping rules, file-ref workflows, freshness and
duplicate handling, environment knobs, and the PreCompact sweep are in
[docs/usage.md](docs/usage.md). Building from source is in
[docs/install.md](docs/install.md#building-from-source).

## Roadmap

A cross-machine team backend (TCP + auth): the daemon already owns the store
behind a socket, so a team server is the same daemon with a network bind.

## License

MIT.

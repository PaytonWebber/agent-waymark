# cairn — implementation plan

A durable, shared working-state layer for agent orchestration. Not "semantic
memory." The unit of state is a structured **entry** (a decision, a finding, a
rejected path, a todo) left in a shared store so the next agent, sub-agent, or
session does not re-discover what an earlier one already worked out.

Working name `cairn` is provisional; branding is locked before any public push.

## Why this, and not another memory MCP

Research finding (see the conversation that produced this plan): generic
semantic memory is a crowded commodity and the wrong layer. The loud, repeated,
quantifiable pains in agent orchestration are context loss across handoffs and
sessions, lost state after compaction, and sub-agents re-solving what the parent
already solved (Claude Code #4908 and #43696, both declined upstream; Berkeley
MAST attributes failure to coordination and design, not "forgot a fact").

Two structural facts shape the architecture:

1. An MCP server cannot inject context on its own; it only answers tool calls
   the model chooses to make, which is why memory MCPs "never get called." Only
   Claude Code **hooks** (`SessionStart`, `UserPromptSubmit`, `PreCompact`,
   `SubagentStart`) can push text into the model before it responds. So the
   product is an MCP server **paired with a hook kit**. The hooks are the
   feature, not a footnote.
2. A user's Claude Code main session and its sub-agents are separate OS
   processes. They cannot each own the store, or they corrupt it. So a single
   long-lived **daemon owns the store**; the MCP server and hooks are thin
   clients. Add auth and a network bind to that daemon and it is the team
   server. "Solo first" and "team ready" become one architecture.

## Architecture

```
Claude Code (main)  ─┐
Claude Code (subagent)│  stdio MCP bridge (thin client) ─┐
hooks (shell → CLI)  ─┘                                  ├─ unix socket ─→  cairnd (daemon)
                        cairn CLI (record/recall/...) ───┘                   owns Store
                                                                             ├ quantal index
                                                                             ├ entry log + JSON snapshot
                                                                             └ embedder (Ollama)
```

- **Internal protocol**: line-delimited JSON over a unix socket. Small and
  fully under our control. This is the seam reused for the HTTP/team transport
  (the MCP SDK already ships Streamable HTTP, so phase 5 is mostly wiring).
- **Embedding** happens daemon-side: clients send text, the daemon embeds it, so
  the Ollama dependency lives in one place. Clients may also send a precomputed
  vector (used by tests; keeps `zig build test` offline).

## The entry

```
id          u64
ts          i64           seconds
kind        decision | finding | rejected | todo | artifact | note
scope       string        repo identity + optional branch/task, e.g. "repo:/p@main"
body        string        the reasoning / content
refs        []string      file paths, symbols, "entry:NN"
author      string        "session:<id>/agent:<name>"
supersedes  ?u64          prior entry this replaces
superseded_by ?u64        derived; set on the prior entry when superseded
embedding   []f32         quantal vector over body
```

`kind` + `supersedes` are what make this orchestration state, not a fact blob:
`rejected` keeps dead ends visible, `decision` + `supersedes` keeps the temporal
chain the incumbents flatten into embeddings.

## Phases

1. **Daemon + Store interface (this phase).** Structured `Store` over quantal
   (record / recall / timeline / supersede / header / forget) with JSON
   snapshot persistence; the internal protocol codec; the `cairnd` unix-socket
   daemon that owns one Store; a thin client; a `cairn` CLI exercising it.
   Tests: store ops and protocol codec offline; a scripted socket smoke.
2. **MCP bridge.** [done] Comptime-schema MCP server as a thin daemon client.
   Tools: `record`, `recall`, `timeline`, `supersede`. Auto-starts the daemon;
   defaults each tool's scope to the launch directory. Standard stdio `command`
   config for Claude Code (`cairn mcp`).
3. **Hook kit + installer.** [done] `cairn hook <Event>` reads the event JSON on
   stdin and injects context: `SessionStart` / `SubagentStart` inject the scope
   header (SessionStart also fires on the `compact` source, re-injecting state
   after a compaction); `UserPromptSubmit` injects prompt-relevant recall. Hooks
   never block the session (any failure exits 0 silently). `cairn install`
   merges the hooks + MCP server into Claude Code config (project or `--user`),
   preserving existing config and idempotent on re-run. Deeper PreCompact
   extraction (auto-recording decisions from the transcript before it's
   summarized) is deferred; SessionStart(compact) re-injection covers continuity
   for now.
4. **Entry lifecycle + header polish.** [partial] Done: `done`/`resolve` to
   finish a todo (kept for audit, dropped from header/active timeline/recall);
   supersede follows to the chain head instead of forking and carries forward
   refs; header shows per-kind counts and an overflow hint. Deferred:
   git-repo/branch/task scoping (left raw-cwd pending experiments) and
   per-scope markdown materialization.
5. **Team backend.** Network bind + auth on the daemon via the SDK's Streamable
   HTTP transport; concurrency (RwLock + per-reader search contexts).

## Phase 1 file map

- `src/embedder.zig`   text → vector via Ollama (seeded from zig-agentic-memory).
- `src/entry.zig`      `EntryKind`, `Entry`, JSON DTOs, scope helpers.
- `src/store.zig`      structured store over quantal; persistence.
- `src/store_test.zig` store unit tests (offline, vector-based).
- `src/protocol.zig`   `Request`/`Response` types + line-JSON codec + tests.
- `src/daemon.zig`     unix-socket server owning a Store.
- `src/client.zig`     thin daemon client.
- `src/main.zig`       CLI: `daemon | record | recall | timeline`; test root.
- `build.zig`, `build.zig.zon`

## Verification

- `zig build test` — store ops, persistence reopen, protocol round-trip.
- `zig build` then a bash smoke: start `cairnd`, `cairn record`, `cairn recall`,
  assert the recalled entry comes back; kill the daemon.
- Build under `-Doptimize=ReleaseSafe` once to catch UB the debug build misses.

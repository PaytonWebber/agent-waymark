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

## Status

Phases 1–2 are in: the daemon + store + protocol + CLI, and the MCP bridge.
Built on [quantal](../quantajump) for the vector index and a local
[Ollama](https://ollama.com) model for embeddings.

```bash
zig build                         # build the `cairn` binary
zig build test                    # unit tests (offline, no Ollama)

# CLI (any subcommand auto-starts the daemon if it isn't running):
cairn record decision "use a daemon to own the store" --scope repo:x@main
cairn recall  "who owns the store?" --scope repo:x@main
cairn timeline --scope repo:x@main
cairn header   --scope repo:x@main      # the always-on session summary
```

### Use with Claude Code

```bash
zig build
claude mcp add --transport stdio cairn -- $(pwd)/zig-out/bin/cairn mcp
```

The bridge exposes `record`, `recall`, `timeline`, and `supersede`, auto-starts
the daemon, and defaults each tool's scope to the project it was launched in.
Automatic context injection (the part a tool-only server can't do) arrives with
the hook kit in phase 3.

`CAIRN_SOCKET`, `CAIRN_STORE`, `CAIRN_EMBED_URL`, `CAIRN_EMBED_MODEL`, `CAIRN_SCOPE`,
and `CAIRN_AUTHOR` configure the socket/snapshot paths, embedding endpoint/model,
the default scope, and the author tag.

Next: the hook kit (phase 3) — the headline.

## License

MIT.

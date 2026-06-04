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

Phases 1–3 are in: the daemon + store + protocol + CLI, the MCP bridge, and the
hook kit. Built on [quantal](../quantajump) for the vector index and a local
[Ollama](https://ollama.com) model for embeddings.

```bash
zig build                         # build the `cairn` binary
zig build test                    # unit tests (offline, no Ollama)
```

### Use with Claude Code

```bash
zig build
./zig-out/bin/cairn install          # this project (writes .claude/settings.json + .mcp.json)
./zig-out/bin/cairn install --user   # every project (writes ~/.claude/settings.json)
```

`install` registers both halves and is the whole point of the design:

- The **MCP bridge** (`record`, `recall`, `timeline`, `supersede`) is how the
  model writes and explicitly queries state.
- The **hooks** are how recall actually happens, since a tool-only server can't
  inject context on its own:
  - `SessionStart` injects the scope header (open todos + recent decisions),
    including after a compaction, so a session starts oriented.
  - `UserPromptSubmit` recalls entries relevant to each prompt and injects them,
    so recall doesn't depend on the model choosing to ask.
  - `SubagentStart` seeds a fresh sub-agent with the same header, so it doesn't
    re-discover what the parent already worked out.

The merge preserves any hooks you already have and is idempotent. Everything is
scoped to the project it runs in, so one `--user` install covers every repo.

### CLI

Any subcommand auto-starts the daemon if it isn't running. Scope defaults to the
current project; pass `--scope ""` to span all scopes.

```bash
cairn record decision "use a daemon to own the store"
cairn recall  "who owns the store?"
cairn timeline
cairn header                        # the always-on session summary
cairn done <id>                     # finish a todo (kept for history)
```

`CAIRN_SOCKET`, `CAIRN_STORE`, `CAIRN_EMBED_URL`, `CAIRN_EMBED_MODEL`, `CAIRN_SCOPE`,
and `CAIRN_AUTHOR` configure the socket/snapshot paths, embedding endpoint/model,
the default scope, and the author tag.

Next: phase 5 (the team HTTP backend). Git-repo-aware scoping is intentionally
left raw-cwd for now, pending some experiments.

## License

MIT.

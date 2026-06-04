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
ollama pull nomic-embed-text   # 768-d, the default
```

Supported platforms: Linux (x64, arm64) and macOS (Apple Silicon, Intel).

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

### CLI

Any subcommand auto-starts the daemon if it isn't running. Scope defaults to the
current project; pass `--scope ""` to span all scopes.

```bash
cairn record decision "use a daemon to own the store"
cairn recall  "who owns the store?"
cairn timeline
cairn header                        # the always-on session summary
cairn done <id>                     # finish a todo (kept for history)
cairn pin <id>                      # always show an entry in the header
cairn unpin <id>
```

`CAIRN_SOCKET`, `CAIRN_STORE`, `CAIRN_EMBED_URL`, `CAIRN_EMBED_MODEL`, `CAIRN_SCOPE`,
and `CAIRN_AUTHOR` configure the socket/snapshot paths, embedding endpoint/model,
the default scope, and the author tag.

Packaging for npm and the Claude plugin is in place; see [RELEASE.md](RELEASE.md).
Still ahead: a cross-machine team backend (TCP + auth), and git-repo-aware
scoping (left raw-cwd for now, pending some experiments).

## License

MIT.

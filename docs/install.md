# Installation reference

The fast path is in the [README](../README.md#quickstart). This page covers
every install mode, what each one writes, and how to remove it.

## Claude Code plugin

```
/plugin marketplace add PaytonWebber/agent-waymark
/plugin install agent-waymark@agent-waymark
```

Restart Claude Code after installing. Use `/mcp` to confirm the MCP server is
connected. To remove it, use `/plugin uninstall agent-waymark@agent-waymark`.

## CLI installs (Claude Code)

```bash
npm install -g agent-waymark
agent-waymark install
```

`install` writes `.claude/settings.json` and `.mcp.json` in the current
project. It preserves existing config and replaces only agent-waymark's own
entries on repeat runs. Project installs pin the daemon store under the
shared git repo root, so linked worktrees for the same repo use the same
store.

To install Claude hooks and the MCP server at user scope:

```bash
agent-waymark install --user
```

That writes `~/.claude/settings.json` and `~/.claude.json`. To keep hooks in
the current project but register the MCP server globally:

```bash
agent-waymark install --global-mcp
```

To choose the daemon snapshot location, pass `--store PATH`:

```bash
agent-waymark install --store ~/.agent-waymark/work-state.json
```

The installer also derives the Unix socket path from that file (`PATH.sock`)
and generates commands that create the parent directory before starting the
daemon. Use the same flag with `--codex`, `--user`, or `--global-mcp`.

To print a copyable MCP server config for an external config manager:

```bash
agent-waymark mcp-config claude
agent-waymark mcp-config codex --store ~/.agent-waymark/work-state.json
```

Without `--store`, `mcp-config` uses
`~/.agent-waymark/agent-waymark-state.json` and
`~/.agent-waymark/agent-waymark.sock`.

## Codex

```bash
agent-waymark install --codex
```

That writes `.codex/config.toml` and `.codex/hooks.json` in the current
project. For a user-level Codex install, run
`agent-waymark install --codex --user`. To keep project hooks but register
the Codex MCP server globally, run
`agent-waymark install --codex --global-mcp`.

Codex requires non-managed command hooks to be reviewed and trusted before
they run; after installing, restart Codex and use `/hooks` to trust
agent-waymark's hooks. Project installs keep daemon state in the shared git
repo root's `.agent-waymark/` directory instead of `/tmp`, so linked
worktrees for the same repo share entries. Some sandboxed shell surfaces may
still require approval for Unix socket binding; after restart, verify Codex
sees agent-waymark with `/mcp` and `/hooks`. The hook config uses Codex's
documented hook events/trust flow and the `additionalContext` output shape
verified in current Codex sessions.

## What install writes (and how to remove it)

The installer touches only the files below, is idempotent, and preserves
everything in them that is not agent-waymark's own entries. All data stays on
your machine: the store is a JSON file on disk and embeddings are computed
in-process.

| Mode | Files written | Store and socket |
|---|---|---|
| `install` | `.claude/settings.json` (hooks), `.mcp.json` (MCP) | `<shared git root>/.agent-waymark/` |
| `install --user` | `~/.claude/settings.json`, `~/.claude.json` | `~/.agent-waymark/` |
| `install --global-mcp` | `.claude/settings.json` (hooks), `~/.claude.json` (MCP) | `~/.agent-waymark/` |
| `install --codex` | `.codex/hooks.json`, `.codex/config.toml` | `<shared git root>/.agent-waymark/` |
| `install --codex --user` | `~/.codex/hooks.json`, `~/.codex/config.toml` | `~/.agent-waymark/` |

`--store PATH` overrides the store location for any mode; the socket becomes
`PATH.sock`.

To remove agent-waymark, run `uninstall` with the same flags you installed
with; it removes agent-waymark's entries from the files in the table and
leaves everything else in them untouched:

```bash
agent-waymark uninstall                  # project Claude install
agent-waymark uninstall --user           # user-level Claude install
agent-waymark uninstall --codex          # project Codex install
```

Uninstall does not stop a running daemon
(`pkill -f 'agent-waymark daemon'`) and keeps your recorded entries; delete
the state directory from the table if you don't want them.

## Building from source

```bash
./scripts/fetch-model.sh potion-retrieval-32M  # download the model once (~125 MB)
zig build quantize-model                       # quantize it to tq4 in place (~16 MB)
zig build                                      # build the binary (Zig 0.16)
zig build test                                 # unit tests (offline)
zig build integration                          # daemon + MCP + hook smoke test (offline)
```

The integration smoke test requires Node.js 18 or newer. The build uses
[quantal](https://github.com/PaytonWebber/quantal) for the embedded vector
index, [zig-mcp-sdk](https://github.com/PaytonWebber/zig-mcp-sdk) for the MCP
protocol and server wiring, and
[model2vec-zig](https://github.com/PaytonWebber/model2vec-zig) for the
embedding model.

For a smaller binary at some cost in paraphrase recall, build with the 256-d
model instead:

```bash
./scripts/fetch-model.sh potion-base-8M
zig build quantize-model -Dmodel=potion-base-8M
zig build -Dmodel=potion-base-8M
```

An existing store migrates itself on first load, in either direction: the
snapshot records the embedding matrix's fingerprint, and the daemon re-embeds
every entry once when it changes.

## Checking an install

```bash
agent-waymark doctor
```

reports the effective socket/store paths, the daemon's actual opened store,
current scope, daemon reachability, and whether Claude/Codex project or user
config contains agent-waymark entries. Use `agent-waymark doctor --json` for
CI or package smoke tests.

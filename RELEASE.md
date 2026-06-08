# Releasing agent-waymark

agent-waymark ships through two channels from one repo:

- **npm**: `npm i -g agent-waymark` installs the `agent-waymark` CLI. The native binary is
  delivered as a per-platform optional dependency (`@agent-waymark/<platform>`), selected
  automatically; `bin/cli.js` execs it.
- **Claude Code plugin**: a git-source plugin that bundles the per-platform
  binaries under `binaries/` and launches them with `node bin/cli.js`. Installs
  via a marketplace.

Supported platforms: `linux-x64`, `linux-arm64`, `darwin-arm64`, `darwin-x64`.
Windows is not supported yet (the daemon uses unix domain sockets).

Runtime prerequisite for users: a local [Ollama](https://ollama.com) with an
embedding model (`ollama pull nomic-embed-text`, the 768-d default).

## Step 1: build the binaries

```bash
ZIG=/path/to/zig-0.16 node scripts/build-dist.mjs
```

This cross-compiles all four platforms and writes:

- `npm/<platform>/`: the publishable `@agent-waymark/<platform>` packages.
- `binaries/<platform>/`: the same binaries, for the plugin bundle.

## Step 2: publish to npm

Publish the platform packages first so the main package's optional dependencies
already exist, then the main package:

```bash
for p in linux-x64 linux-arm64 darwin-arm64 darwin-x64; do
  npm publish "npm/$p" --access public
done
npm publish .
```

Validate without publishing first with `npm pack --dry-run` (and inspect a
platform tarball with `tar -tzf`).

## Step 3: publish the plugin

The git-source plugin needs the binaries committed (plugins have no install
step):

```bash
git add -f binaries/
git commit -m "Release vX.Y.Z binaries"
git tag vX.Y.Z
git push --tags
```

Users then:

```
/plugin marketplace add <owner>/<repo>
/plugin install <name>@<name>
```

### Lighter alternative (no committed binaries)

Instead of bundling, point the plugin at the npm package by setting the commands
in `.mcp.json` and `hooks/hooks.json` to `npx -y <name> mcp` / `npx -y <name>
hook <Event>`. This keeps the repo small but adds npx resolution latency to every
prompt (the per-prompt `UserPromptSubmit` hook), so the bundled binary is the
default.

## Verify

- `npm pack --dry-run` lists `bin/cli.js`, `lib/`, the plugin manifests.
- In a scratch dir: install the packed tarballs and run `npx agent-waymark ping`.
- Plugin: `claude --plugin-dir .` in a checkout with `binaries/` present, then
  `/mcp` shows agent-waymark connected and the SessionStart header appears.

"use strict";

// Resolves the agent-waymark native binary for the current platform. Works in two
// contexts from the same launcher:
//   - npm install: the binary ships in an optional dependency @agent-waymark/<platform>.
//   - Claude plugin: the binary is bundled in <root>/binaries/<platform>/.
// Set AGENT_WAYMARK_BINARY_PATH to override (development, custom builds).

const path = require("node:path");
const fs = require("node:fs");

// Keys are `${process.platform}-${process.arch}`.
const PLATFORMS = {
  "linux-x64": "@agent-waymark/linux-x64",
  "linux-arm64": "@agent-waymark/linux-arm64",
  "darwin-arm64": "@agent-waymark/darwin-arm64",
  "darwin-x64": "@agent-waymark/darwin-x64",
};

function binaryName() {
  return process.platform === "win32" ? "agent-waymark.exe" : "agent-waymark";
}

function platformKey() {
  return `${process.platform}-${process.arch}`;
}

function getBinaryPath() {
  if (process.env.AGENT_WAYMARK_BINARY_PATH) return process.env.AGENT_WAYMARK_BINARY_PATH;

  const key = platformKey();
  const bin = binaryName();

  // Plugin context: a binary bundled alongside this launcher.
  const bundled = path.join(__dirname, "..", "binaries", key, bin);
  if (fs.existsSync(bundled)) return bundled;

  // npm context: the per-platform optional dependency.
  const pkg = PLATFORMS[key];
  if (pkg) {
    try {
      return require.resolve(`${pkg}/bin/${bin}`);
    } catch (_) {
      // fall through to the error below
    }
  }

  const supported = Object.keys(PLATFORMS).join(", ");
  throw new Error(
    `agent-waymark: no binary for platform "${key}".\n` +
      (pkg
        ? `The "${pkg}" package was not installed. If you used ` +
          `--omit=optional or --no-optional, reinstall without it; or delete ` +
          `node_modules and the lockfile and reinstall.`
        : `Supported platforms: ${supported}.`),
  );
}

module.exports = { getBinaryPath, platformKey, binaryName, PLATFORMS };

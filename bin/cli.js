#!/usr/bin/env node
"use strict";

// Thin launcher: locate the platform-native cairn binary and exec it,
// forwarding argv, stdio, and the exit code / terminating signal. spawnSync
// (not execFileSync) so a non-zero exit propagates instead of throwing.

const { spawnSync } = require("node:child_process");
const { getBinaryPath } = require("../lib/get-binary-path.js");

let binary;
try {
  binary = getBinaryPath();
} catch (err) {
  console.error(err.message);
  process.exit(1);
}

const result = spawnSync(binary, process.argv.slice(2), {
  stdio: "inherit",
  windowsHide: true,
});

if (result.error) {
  console.error(result.error.message);
  process.exit(1);
}
if (result.signal) {
  process.kill(process.pid, result.signal);
} else {
  process.exit(result.status ?? 0);
}

#!/usr/bin/env node
// Cross-compile agent-waymark for every supported platform and lay out the release
// artifacts:
//   npm/<key>/        a publishable @agent-waymark/<key> platform package (optionalDep)
//   binaries/<key>/   the same binary, bundled into the Claude plugin
//
// Run from the repo root: `node scripts/build-dist.mjs` (set ZIG to the Zig 0.16
// binary if it is not on PATH). Versions are taken from package.json so the
// platform packages always match the launcher.

import { execFileSync } from "node:child_process";
import { mkdirSync, copyFileSync, writeFileSync, chmodSync, rmSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const root = join(dirname(fileURLToPath(import.meta.url)), "..");
const pkg = JSON.parse(await import("node:fs").then((fs) => fs.readFileSync(join(root, "package.json"), "utf8")));
const version = pkg.version;
const zig = process.env.ZIG || "zig";

// npm platform key -> { zig target triple, os, cpu }
const TARGETS = {
  "linux-x64": { triple: "x86_64-linux-musl", os: "linux", cpu: "x64" },
  "linux-arm64": { triple: "aarch64-linux-musl", os: "linux", cpu: "arm64" },
  "darwin-arm64": { triple: "aarch64-macos", os: "darwin", cpu: "arm64" },
  "darwin-x64": { triple: "x86_64-macos", os: "darwin", cpu: "x64" },
};

rmSync(join(root, "npm"), { recursive: true, force: true });
rmSync(join(root, "binaries"), { recursive: true, force: true });

for (const [key, t] of Object.entries(TARGETS)) {
  const prefix = join(root, ".dist", key);
  console.log(`building ${key} (${t.triple})`);
  execFileSync(zig, ["build", "-Doptimize=ReleaseSafe", `-Dtarget=${t.triple}`, "--prefix", prefix], {
    cwd: root,
    stdio: "inherit",
  });
  const built = join(prefix, "bin", "agent-waymark");

  // npm platform package: npm/<key>/{package.json, bin/agent-waymark}
  const npmBin = join(root, "npm", key, "bin");
  mkdirSync(npmBin, { recursive: true });
  copyFileSync(built, join(npmBin, "agent-waymark"));
  chmodSync(join(npmBin, "agent-waymark"), 0o755);
  writeFileSync(
    join(root, "npm", key, "package.json"),
    JSON.stringify(
      {
        name: `@agent-waymark/${key}`,
        version,
        description: `agent-waymark native binary for ${key}`,
        os: [t.os],
        cpu: [t.cpu],
        files: ["bin/agent-waymark"],
        license: pkg.license,
      },
      null,
      2,
    ) + "\n",
  );

  // Plugin bundle: binaries/<key>/agent-waymark
  const plugBin = join(root, "binaries", key);
  mkdirSync(plugBin, { recursive: true });
  copyFileSync(built, join(plugBin, "agent-waymark"));
  chmodSync(join(plugBin, "agent-waymark"), 0o755);
}

rmSync(join(root, ".dist"), { recursive: true, force: true });
console.log(`\ndone. built ${Object.keys(TARGETS).length} platforms at version ${version}.`);
console.log("npm/      -> publish each @agent-waymark/<key>, then the main package");
console.log("binaries/ -> commit for the Claude plugin (git-source install)");

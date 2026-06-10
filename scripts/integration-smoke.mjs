#!/usr/bin/env node

const { mkdtempSync, rmSync, writeFileSync } = await import("node:fs");
const net = await import("node:net");
const os = await import("node:os");
const path = await import("node:path");
const { spawn } = await import("node:child_process");

const exe = process.argv[2];
const dim = Number(process.argv[3] ?? "768");

if (!exe || !Number.isInteger(dim) || dim <= 0) {
  throw new Error("usage: integration-smoke.mjs <agent-waymark-exe> <embedding-dim>");
}

const tmp = mkdtempSync(path.join(os.tmpdir(), "agent-waymark-integration-"));
const socketPath = path.join(tmp, "agent-waymark.sock");
const storePath = path.join(tmp, "agent-waymark-state.json");
const env = {
  ...process.env,
  AGENT_WAYMARK_SOCKET: socketPath,
  AGENT_WAYMARK_STORE: storePath,
};

let daemon;
try {
  daemon = spawn(exe, ["daemon"], { env, stdio: ["ignore", "pipe", "pipe"] });
  const daemonLog = collectOutput(daemon);
  await waitForDaemon(socketPath, daemon, daemonLog);
  await runVersion(exe, env);
  await runMcpConfig(exe, env, tmp);
  await runDoctor(exe, env, socketPath, storePath);

  const scope = `repo:${process.cwd()}`;
  const body = "integration decision uses precomputed embeddings";
  const vec = unitVec(dim, 0);

  const record = await rpc(socketPath, {
    op: "record",
    kind: "decision",
    scope,
    body,
    text: body,
    author: "integration",
    embedding: vec,
  });
  assert(record.ok && record.id === 1, `record failed: ${JSON.stringify(record)}`);

  const duplicate = await rpc(socketPath, {
    op: "record",
    kind: "finding",
    scope,
    body: "integration duplicate uses the same vector",
    text: "integration duplicate uses the same vector",
    author: "integration",
    embedding: vec,
  });
  assert(duplicate.ok && duplicate.id === 2, `duplicate record failed: ${JSON.stringify(duplicate)}`);
  assert(
    duplicate.warning?.includes("similar to #1"),
    `duplicate record did not warn about the existing entry: ${JSON.stringify(duplicate)}`,
  );

  const touch = await rpc(socketPath, { op: "touch", id: 1 });
  assert(touch.ok, `touch failed: ${JSON.stringify(touch)}`);

  const trackedPath = path.join(tmp, "tracked.txt");
  writeFileSync(trackedPath, "one\n");
  const refEntry = await rpc(socketPath, {
    op: "record",
    kind: "finding",
    scope,
    body: "integration tracked ref starts clean",
    text: "integration tracked ref starts clean",
    refs: [trackedPath],
    author: "integration",
    embedding: unitVec(dim, 3),
  });
  assert(refEntry.ok && refEntry.id === 3, `ref record failed: ${JSON.stringify(refEntry)}`);

  writeFileSync(trackedPath, "two\n");
  const changedTimeline = await rpc(socketPath, { op: "timeline", scope, kind: "finding", limit: 5 });
  const changedRef = changedTimeline.hits?.find((hit) => hit.id === refEntry.id);
  assert(
    changedRef?.ref_statuses?.some((status) => status.status === "changed" && status.ref === trackedPath),
    `timeline did not report changed ref: ${JSON.stringify(changedTimeline)}`,
  );

  const changedHook = await runHook(exe, env);
  const changedContext = changedHook.hookSpecificOutput?.additionalContext ?? "";
  assert(!changedContext.includes(',"hits":['), `hook context leaked raw response JSON: ${changedContext}`);
  assert(changedContext.includes("Needs review:"), `hook context did not include Needs review:\n${changedContext}`);
  assert(changedContext.includes("refs refresh"), `hook context did not include ref maintenance actions:\n${changedContext}`);
  assert(
    countOccurrences(changedContext, "integration tracked ref starts clean") === 1,
    `hook context repeated the same ref entry:\n${changedContext}`,
  );

  const refreshedRef = await rpc(socketPath, { op: "refs", action: "refresh", id: refEntry.id });
  assert(
    refreshedRef.ok && refreshedRef.text?.includes(`Refreshed #${refEntry.id}`),
    `ref refresh failed: ${JSON.stringify(refreshedRef)}`,
  );
  const cleanTimeline = await rpc(socketPath, { op: "timeline", scope, kind: "finding", limit: 5 });
  const cleanRef = cleanTimeline.hits?.find((hit) => hit.id === refEntry.id);
  assert(cleanRef?.ref_statuses?.length === 0, `ref refresh did not clear status: ${JSON.stringify(cleanTimeline)}`);

  const handoff = await rpc(socketPath, { op: "handoff", scope, limit: 3 });
  assert(
    handoff.ok && handoff.text?.includes("# For the next agent") && handoff.text?.includes("Current decisions:"),
    `handoff failed: ${JSON.stringify(handoff)}`,
  );

  const cliHandoff = await runChild(exe, ["handoff", "--scope", scope], env, "");
  assert(cliHandoff.stdout.includes("# For the next agent"), `CLI handoff missing heading:\n${cliHandoff.stdout}`);

  for (let i = 0; i < 3; i += 1) {
    const activity = await rpc(socketPath, { op: "activity" });
    assert(activity.ok && !activity.text, `activity should stay quiet before threshold: ${JSON.stringify(activity)}`);
  }
  const activityNudge = await rpc(socketPath, { op: "activity" });
  assert(
    activityNudge.ok && activityNudge.text?.includes("4 user prompts"),
    `activity did not nudge after four prompts: ${JSON.stringify(activityNudge)}`,
  );

  const recall = await rpc(socketPath, {
    op: "recall",
    scope,
    text: "precomputed embeddings",
    embedding: vec,
    limit: 3,
  });
  assert(recall.ok, `recall failed: ${JSON.stringify(recall)}`);
  const recalledOriginal = recall.hits?.find((hit) => hit.body === body);
  assert(recalledOriginal, `recall did not return recorded body: ${JSON.stringify(recall)}`);
  assert(
    recalledOriginal.freshness?.includes("confirmed"),
    `recall did not show confirmation freshness: ${JSON.stringify(recall)}`,
  );

  const mcpLines = await runMcp(exe, env);
  assert(mcpLines.length === 3, `expected 3 MCP responses, got ${mcpLines.length}: ${mcpLines.join("\n")}`);
  const init = JSON.parse(mcpLines[0]);
  const tools = JSON.parse(mcpLines[1]);
  const timeline = JSON.parse(mcpLines[2]);
  assert(init.result?.serverInfo?.name === "agent-waymark", `bad MCP init: ${mcpLines[0]}`);
  assert(tools.result?.tools?.some((tool) => tool.name === "record"), `MCP tools/list missing record: ${mcpLines[1]}`);
  assert(tools.result?.tools?.some((tool) => tool.name === "refs"), `MCP tools/list missing refs: ${mcpLines[1]}`);
  assert(tools.result?.tools?.some((tool) => tool.name === "handoff"), `MCP tools/list missing handoff: ${mcpLines[1]}`);
  assert(
    timeline.result?.content?.some((item) => item.text?.includes(body) && item.text?.includes("confirmed")),
    `MCP timeline missing recorded body: ${mcpLines[2]}`,
  );

  const hook = await runHook(exe, env);
  assert(hook.hookSpecificOutput?.hookEventName === "SessionStart", `bad hook event: ${JSON.stringify(hook)}`);
  assert(
    hook.hookSpecificOutput?.additionalContext?.includes(body),
    `hook context missing recorded body: ${JSON.stringify(hook)}`,
  );

  await runPreCompactHook(exe, env, tmp);
} finally {
  if (daemon && daemon.exitCode === null) {
    daemon.kill("SIGTERM");
    await onceClose(daemon).catch(() => {});
  }
  rmSync(tmp, { recursive: true, force: true });
}

function collectOutput(child) {
  const chunks = [];
  child.stdout.on("data", (chunk) => chunks.push(chunk));
  child.stderr.on("data", (chunk) => chunks.push(chunk));
  return () => Buffer.concat(chunks).toString("utf8");
}

async function waitForDaemon(socketPath, child, logs) {
  const deadline = Date.now() + 5000;
  while (Date.now() < deadline) {
    if (child.exitCode !== null) {
      throw new Error(`daemon exited early with ${child.exitCode}\n${logs()}`);
    }
    try {
      const ping = await rpc(socketPath, { op: "ping" });
      if (ping.ok && ping.text === "pong") return;
    } catch {}
    await sleep(50);
  }
  throw new Error(`daemon did not become ready\n${logs()}`);
}

function rpc(socketPath, request) {
  return new Promise((resolve, reject) => {
    const socket = net.createConnection(socketPath);
    let data = "";
    socket.setEncoding("utf8");
    socket.on("connect", () => socket.write(`${JSON.stringify(request)}\n`));
    socket.on("data", (chunk) => {
      data += chunk;
      const idx = data.indexOf("\n");
      if (idx >= 0) {
        const line = data.slice(0, idx);
        socket.end();
        try {
          resolve(JSON.parse(line));
        } catch (err) {
          reject(new Error(`invalid JSON response: ${line}\n${err.message}`));
        }
      }
    });
    socket.on("error", reject);
    socket.on("end", () => {
      if (!data.includes("\n")) reject(new Error("socket closed before response"));
    });
  });
}

function runMcp(exe, env) {
  const input = [
    {
      jsonrpc: "2.0",
      method: "initialize",
      params: {
        protocolVersion: "2025-03-26",
        capabilities: {},
        clientInfo: { name: "integration", version: "1.0" },
      },
      id: 1,
    },
    { jsonrpc: "2.0", method: "notifications/initialized" },
    { jsonrpc: "2.0", method: "tools/list", id: 2 },
    { jsonrpc: "2.0", method: "tools/call", params: { name: "timeline", arguments: { limit: 3 } }, id: 3 },
  ]
    .map((msg) => JSON.stringify(msg))
    .join("\n") + "\n";

  return runChild(exe, ["mcp"], env, input).then(({ stdout }) => stdout.trim().split("\n").filter(Boolean));
}

async function runHook(exe, env) {
  const input = JSON.stringify({ hook_event_name: "SessionStart", cwd: process.cwd(), source: "startup" }) + "\n";
  const { stdout } = await runChild(exe, ["hook", "SessionStart"], env, input);
  assert(stdout.trim().length > 0, "hook emitted no output");
  return JSON.parse(stdout);
}

async function runPreCompactHook(exe, env, dir) {
  const transcriptPath = path.join(dir, "empty-transcript.jsonl");
  writeFileSync(transcriptPath, "");
  const input = JSON.stringify({
    hook_event_name: "PreCompact",
    cwd: process.cwd(),
    transcript_path: transcriptPath,
  }) + "\n";

  const started = Date.now();
  const { stdout } = await runChild(exe, ["hook", "PreCompact"], env, input);
  const elapsed = Date.now() - started;
  assert(stdout.trim().length === 0, `PreCompact hook should not emit context: ${stdout}`);
  assert(elapsed < 1000, `PreCompact hook took too long: ${elapsed}ms`);
}

async function runDoctor(exe, env, socketPath, storePath) {
  const { stdout } = await runChild(exe, ["doctor"], env, "");
  assert(stdout.includes("ok  daemon: reachable"), `doctor did not see daemon:\n${stdout}`);
  assert(stdout.includes(`ok  socket: ${socketPath}`), `doctor did not report socket path:\n${stdout}`);
  assert(stdout.includes(`ok  store: ${storePath}`), `doctor did not report store path:\n${stdout}`);
  assert(stdout.includes(`ok  daemon store: ${storePath}`), `doctor did not report daemon store path:\n${stdout}`);

  const json = await runChild(exe, ["doctor", "--json"], env, "");
  const report = JSON.parse(json.stdout);
  assert(report.ok === true, `doctor JSON marked report not ok: ${json.stdout}`);
  assert(report.status === "ok" || report.status === "warn", `doctor JSON had bad status: ${json.stdout}`);
  assert(
    report.checks?.some((check) => check.status === "ok" && check.name === "daemon" && check.detail === "reachable"),
    `doctor JSON did not report reachable daemon: ${json.stdout}`,
  );
  assert(
    report.checks?.some((check) => check.status === "ok" && check.name === "socket" && check.detail === socketPath),
    `doctor JSON did not report socket path: ${json.stdout}`,
  );
  assert(
    report.checks?.some((check) => check.status === "ok" && check.name === "store" && check.detail === storePath),
    `doctor JSON did not report store path: ${json.stdout}`,
  );
  assert(
    report.checks?.some((check) => check.status === "ok" && check.name === "daemon store" && check.detail.includes(storePath)),
    `doctor JSON did not report daemon store path: ${json.stdout}`,
  );
}

async function runVersion(exe, env) {
  const { stdout } = await runChild(exe, ["--version"], env, "");
  assert(/^agent-waymark \d+\.\d+\.\d+$/.test(stdout.trim()), `bad --version output: ${stdout}`);
}

async function runMcpConfig(exe, env, dir) {
  const configStore = path.join(dir, "external-state.json");
  const claude = await runChild(exe, ["mcp-config", "claude", "--store", configStore], env, "");
  const claudeJson = JSON.parse(claude.stdout);
  assert(
    claudeJson.mcpServers?.["agent-waymark"]?.command === "sh",
    `Claude MCP config did not emit a server entry: ${claude.stdout}`,
  );
  assert(
    claude.stdout.includes(`AGENT_WAYMARK_STORE='${configStore}'`),
    `Claude MCP config did not include explicit store path: ${claude.stdout}`,
  );

  const codex = await runChild(exe, ["mcp-config", "codex", "--store", configStore], env, "");
  assert(codex.stdout.includes("[mcp_servers.agent-waymark]"), `Codex MCP config missing table: ${codex.stdout}`);
  assert(
    codex.stdout.includes(`AGENT_WAYMARK_SOCKET='${configStore}.sock'`),
    `Codex MCP config did not include derived socket path: ${codex.stdout}`,
  );
}

function runChild(exe, args, env, input) {
  return new Promise((resolve, reject) => {
    const child = spawn(exe, args, { env, stdio: ["pipe", "pipe", "pipe"] });
    const stdout = [];
    const stderr = [];
    child.stdout.on("data", (chunk) => stdout.push(chunk));
    child.stderr.on("data", (chunk) => stderr.push(chunk));
    child.on("error", reject);
    child.on("close", (code, signal) => {
      const out = Buffer.concat(stdout).toString("utf8");
      const err = Buffer.concat(stderr).toString("utf8");
      if (code === 0) resolve({ stdout: out, stderr: err });
      else reject(new Error(`${exe} ${args.join(" ")} failed: code=${code} signal=${signal}\nstdout:\n${out}\nstderr:\n${err}`));
    });
    child.stdin.end(input);
  });
}

function unitVec(len, axis) {
  const vec = Array(len).fill(0);
  vec[axis] = 1;
  return vec;
}

function assert(condition, message) {
  if (!condition) throw new Error(message);
}

function countOccurrences(haystack, needle) {
  let count = 0;
  let start = 0;
  while (true) {
    const idx = haystack.indexOf(needle, start);
    if (idx < 0) return count;
    count += 1;
    start = idx + needle.length;
  }
}

function sleep(ms) {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

function onceClose(child) {
  return new Promise((resolve) => child.once("close", resolve));
}

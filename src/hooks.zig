//! Hook engine. Agent clients run `agent-waymark hook <Event>` for registered hooks,
//! passing the event as JSON on stdin. This is where agent-waymark does what a
//! tool-only MCP server cannot: push context into the model before it responds.
//!
//!   SessionStart / SubagentStart  → inject the scope header (open todos +
//!                                    recent decisions), so a session or a
//!                                    fresh sub-agent starts oriented. Firing
//!                                    on the `compact` source re-injects state
//!                                    after a compaction.
//!   UserPromptSubmit              → recall entries relevant to the prompt and
//!                                    inject them, so recall happens reliably
//!                                    instead of depending on the model to ask.
//!
//! A hook must never block the user: any failure (daemon down, embedding
//! service down, malformed input) exits 0 with no output.

const std = @import("std");
const Allocator = std.mem.Allocator;

const daemon = @import("daemon.zig");
const client_mod = @import("client.zig");
const protocol = @import("protocol.zig");
const scope_mod = @import("scope.zig");
const Client = client_mod.Client;

const HookInput = struct {
    hook_event_name: ?[]const u8 = null,
    cwd: ?[]const u8 = null,
    prompt: ?[]const u8 = null, // UserPromptSubmit
    source: ?[]const u8 = null, // SessionStart: startup|resume|clear|compact
    transcript_path: ?[]const u8 = null, // PreCompact
};

/// How much of the transcript tail the PreCompact sweep sends for extraction.
const max_transcript_bytes = 24 * 1024;

/// Minimum cosine score for a recall hit to be auto-injected on a prompt.
/// Embeddings are L2-normalized so scores are comparable across queries.
/// Calibrated for the bundled static-embedding model, whose cosine spread is
/// wider than a transformer's: measured relevant paraphrase matches land
/// 0.20-0.49 and unrelated prompts top out around 0.17, so the floor sits
/// just above the noise ceiling. Override with AGENT_WAYMARK_MIN_SCORE.
const default_min_score: f32 = 0.20;

/// Re-surfaced at every SessionStart (and after compaction) so the agent keeps
/// writing to agent-waymark instead of letting the store go stale. The MCP server's
/// instructions carry the same guidance; this repeats it where it is most
/// likely to be acted on.
const session_nudge =
    "agent-waymark is active. As you work, record decisions, dead ends, and todos " ++
    "(record / supersede / touch / done), and recall before re-investigating something, " ++
    "so this work carries to later sessions and sub-agents.";

/// Never returns an error: a hook that fails must not break the session.
pub fn run(allocator: Allocator, io: std.Io, env: *std.process.Environ.Map, cfg: daemon.Config, event: []const u8) void {
    body(allocator, io, env, cfg, event) catch return;
}

fn body(allocator: Allocator, io: std.Io, env: *std.process.Environ.Map, cfg: daemon.Config, event_arg: []const u8) !void {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var fr = std.Io.File.stdin().reader(io, try a.alloc(u8, 64 * 1024));
    const raw = fr.interface.allocRemaining(a, .unlimited) catch "";
    const input: HookInput = if (raw.len > 0)
        (std.json.parseFromSlice(HookInput, a, raw, .{ .ignore_unknown_fields = true }) catch return).value
    else
        .{};

    const event = if (event_arg.len > 0) event_arg else (input.hook_event_name orelse return);
    const scope = scope_mod.detect(a, io, env, input.cwd);

    var client: Client = undefined;
    client.connectOrStart(allocator, io, cfg.socket_path) catch return;
    defer client.deinit();

    // PreCompact: extract durable entries from the transcript and record them
    // (a side effect on the daemon), so state survives even when the agent
    // didn't record as it went. Swept entries are repo-wide. Injects nothing.
    if (std.mem.eql(u8, event, "PreCompact")) {
        const tpath = input.transcript_path orelse return;
        spawnSweepFile(allocator, io, tpath, scope.repo_scope) catch return;
        return;
    }

    const min_score = if (env.get("AGENT_WAYMARK_MIN_SCORE")) |s|
        std.fmt.parseFloat(f32, s) catch default_min_score
    else
        default_min_score;

    const text = blk: {
        if (std.mem.eql(u8, event, "UserPromptSubmit")) {
            const nudge = try activityContext(a, &client);
            const recall = try recallContext(a, &client, scope.branch_scope, input.prompt orelse return, min_score);
            break :blk try joinBlocks(a, nudge, recall);
        }
        const header = try headerContext(a, &client, scope.branch_scope);
        // SessionStart re-surfaces the write-discipline nudge every session and
        // after each compaction, even when the store is empty. Other events
        // (SubagentStart) just get the header, and stay silent if it is empty.
        if (std.mem.eql(u8, event, "SessionStart")) {
            break :blk if (header.len > 0)
                try std.fmt.allocPrint(a, "{s}\n\n{s}", .{ session_nudge, header })
            else
                session_nudge;
        }
        break :blk header;
    };

    if (text.len == 0) return; // nothing relevant: stay silent
    try emit(io, a, event, text);
}

/// Last `max` bytes of the file at `path`, or "" on any failure. The tail is
/// what a sweep cares about; the file is JSONL and the model tolerates a partial
/// leading line.
fn readTail(a: Allocator, io: std.Io, path: []const u8, max: usize) []const u8 {
    const bytes = std.Io.Dir.cwd().readFileAlloc(io, path, a, .limited(8 * 1024 * 1024)) catch return "";
    return if (bytes.len <= max) bytes else bytes[bytes.len - max ..];
}

fn spawnSweepFile(allocator: Allocator, io: std.Io, transcript_path: []const u8, scope: []const u8) !void {
    const exe = try std.process.executablePathAlloc(io, allocator);
    defer allocator.free(exe);

    var child = try std.process.spawn(io, .{
        .argv = &.{ exe, "sweep-file", transcript_path, scope },
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .ignore,
    });
    _ = &child;
}

/// Detached PreCompact worker. This may spend time in local generation and
/// embeddings, so hooks launch it out-of-band and return immediately.
pub fn runSweepFile(allocator: Allocator, io: std.Io, cfg: daemon.Config, args: []const []const u8) void {
    sweepFile(allocator, io, cfg, args) catch return;
}

fn sweepFile(allocator: Allocator, io: std.Io, cfg: daemon.Config, args: []const []const u8) !void {
    if (args.len < 2) return;

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const tail = readTail(a, io, args[0], max_transcript_bytes);
    if (tail.len == 0) return;

    var client: Client = undefined;
    client.connectOrStart(allocator, io, cfg.socket_path) catch return;
    defer client.deinit();

    _ = client.call(a, .{ .op = "sweep", .text = tail, .scope = args[1] }) catch return;
}

/// The always-on scope header for SessionStart / SubagentStart.
fn headerContext(a: Allocator, client: *Client, scope: []const u8) ![]const u8 {
    const parsed = try client.call(a, .{ .op = "header", .scope = scope, .limit = 5 });
    if (!parsed.value.ok) return "";
    return parsed.value.text orelse "";
}

fn activityContext(a: Allocator, client: *Client) ![]const u8 {
    const parsed = try client.call(a, .{ .op = "activity" });
    if (!parsed.value.ok) return "";
    return parsed.value.text orelse "";
}

fn joinBlocks(a: Allocator, first: []const u8, second: []const u8) ![]const u8 {
    if (first.len == 0) return second;
    if (second.len == 0) return first;
    return std.fmt.allocPrint(a, "{s}\n\n{s}", .{ first, second });
}

/// Prompt-relevant recall for UserPromptSubmit, formatted as a compact block.
/// Only hits at or above `min_score` are injected, so an off-topic prompt adds
/// nothing rather than padding the context with weak matches.
fn recallContext(a: Allocator, client: *Client, scope: []const u8, prompt: []const u8, min_score: f32) ![]const u8 {
    const parsed = try client.call(a, .{ .op = "recall", .text = prompt, .scope = scope, .limit = 5 });
    if (!parsed.value.ok) return "";
    const hits = parsed.value.hits orelse return "";

    var out: std.Io.Writer.Allocating = .init(a);
    const w = &out.writer;
    var shown: usize = 0;
    for (hits) |h| {
        if (h.score < min_score) continue; // hits are sorted desc, so this is the tail
        if (shown == 0) try w.writeAll("Possibly relevant prior context from agent-waymark (recall to confirm):\n");
        try w.print("- #{d} [{s}, recalled, {s}", .{ h.id, h.kind, h.freshness });
        if (h.ref_statuses.len > 0) {
            try w.writeAll(", needs review");
        }
        if (h.ref_statuses.len > 0) {
            try w.writeAll(", refs ");
            for (h.ref_statuses[0..@min(h.ref_statuses.len, 2)], 0..) |status, i| {
                if (i != 0) try w.writeAll(", ");
                try w.print("{s}: {s}", .{ status.status, status.ref });
                if (status.suggestion) |suggestion| try w.print(" -> {s}", .{suggestion});
            }
        }
        try w.print("] {s}\n", .{h.body});
        if (h.ref_statuses.len > 0 or h.stale) {
            try w.print("  actions: touch #{d}, supersede #{d}", .{ h.id, h.id });
            if (std.mem.eql(u8, h.kind, "todo")) try w.print(", done #{d}", .{h.id});
            if (h.ref_statuses.len > 0) {
                try w.print(", refs refresh #{d}, refs move #{d} <old-ref> <new-ref>, refs dismiss #{d} <ref>", .{ h.id, h.id, h.id });
            }
            try w.writeByte('\n');
        }
        shown += 1;
    }
    if (shown == 0) return "";
    return out.toOwnedSlice();
}

/// Emit the hook result: current Claude Code and Codex builds consume this
/// additionalContext payload and inject it into the model's context.
fn emit(io: std.Io, a: Allocator, event: []const u8, text: []const u8) !void {
    const Out = struct {
        hookSpecificOutput: struct {
            hookEventName: []const u8,
            additionalContext: []const u8,
        },
    };
    const payload: Out = .{ .hookSpecificOutput = .{ .hookEventName = event, .additionalContext = text } };

    var buf: [64 * 1024]u8 = undefined;
    var fw: std.Io.File.Writer = .init(.stdout(), io, &buf);
    const bytes = try std.json.Stringify.valueAlloc(a, payload, .{});
    try fw.interface.writeAll(bytes);
    try fw.interface.writeByte('\n');
    try fw.interface.flush();
}

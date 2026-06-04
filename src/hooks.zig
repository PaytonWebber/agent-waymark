//! Hook engine. Claude Code runs `cairn hook <Event>` for registered hooks,
//! passing the event as JSON on stdin. This is where cairn does what a
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
};

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
    const scope = try scope_mod.forCwd(a, io, env, input.cwd);

    var client: Client = undefined;
    client.connectOrStart(allocator, io, cfg.socket_path) catch return;
    defer client.deinit();

    const text = if (std.mem.eql(u8, event, "UserPromptSubmit"))
        try recallContext(a, &client, scope, input.prompt orelse return)
    else
        try headerContext(a, &client, scope);

    if (text.len == 0) return; // nothing relevant: stay silent
    try emit(io, a, event, text);
}

/// The always-on scope header for SessionStart / SubagentStart.
fn headerContext(a: Allocator, client: *Client, scope: []const u8) ![]const u8 {
    const parsed = try client.call(a, .{ .op = "header", .scope = scope, .limit = 5 });
    if (!parsed.value.ok) return "";
    return parsed.value.text orelse "";
}

/// Prompt-relevant recall for UserPromptSubmit, formatted as a compact block.
fn recallContext(a: Allocator, client: *Client, scope: []const u8, prompt: []const u8) ![]const u8 {
    const parsed = try client.call(a, .{ .op = "recall", .text = prompt, .scope = scope, .limit = 4 });
    if (!parsed.value.ok) return "";
    const hits = parsed.value.hits orelse return "";
    if (hits.len == 0) return "";

    var out: std.Io.Writer.Allocating = .init(a);
    const w = &out.writer;
    try w.writeAll("Possibly relevant prior context from cairn (recall to confirm):\n");
    for (hits) |h| {
        try w.print("- #{d} [{s}] {s}\n", .{ h.id, h.kind, h.body });
    }
    return out.toOwnedSlice();
}

/// Emit the hook result: additionalContext is injected into the model's context
/// as a system reminder.
fn emit(io: std.Io, a: Allocator, event: []const u8, text: []const u8) !void {
    const Out = struct {
        hookSpecificOutput: struct {
            hookEventName: []const u8,
            additionalContext: []const u8,
        },
    };
    const payload: Out = .{ .hookSpecificOutput = .{ .hookEventName = event, .additionalContext = text } };

    var buf: [4096]u8 = undefined;
    var fw: std.Io.File.Writer = .init(.stdout(), io, &buf);
    const bytes = try std.json.Stringify.valueAlloc(a, payload, .{});
    try fw.interface.writeAll(bytes);
    try fw.interface.flush();
}

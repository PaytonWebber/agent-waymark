//! MCP bridge: exposes agent-waymark's tools to an agent over stdio, as a thin client
//! of the daemon. The model writes and reads orchestration state through these
//! tools; the hook kit (phase 3) handles automatic injection, which is the
//! part a tool-only server can't do.
//!
//! Tools default their `scope` to the bridge's scope (derived from the working
//! directory it was launched in), so an agent gets per-project state without
//! having to reason about scope strings.

const std = @import("std");
const mcp = @import("zig_mcp_sdk");
const types = mcp.types;
const Allocator = std.mem.Allocator;

const client_mod = @import("client.zig");
const protocol = @import("protocol.zig");
const Client = client_mod.Client;
const Request = protocol.Request;

// ---- tool argument schemas ------------------------------------------------

const kinds_doc = "One of: decision, finding, rejected, todo, artifact, note.";

const RecordArgs = struct {
    kind: []const u8,
    body: []const u8,
    scope: ?[]const u8 = null,
    refs: ?[]const []const u8 = null,
    supersedes: ?i64 = null,
    branch_local: bool = false,
    pub const descriptions = .{
        .kind = "Kind of entry. " ++ kinds_doc,
        .body = "The content: the decision made, the finding, the rejected path and why, or the todo.",
        .scope = "Project/task scope. Defaults to the whole repo.",
        .refs = "Optional related file paths, symbols, or \"entry:N\" references.",
        .supersedes = "Id of an earlier entry this replaces (e.g. a changed decision).",
        .branch_local = "Scope this to the current git branch only (use for work specific to this branch). Defaults to repo-wide.",
    };
};

const RecallArgs = struct {
    query: []const u8,
    scope: ?[]const u8 = null,
    kind: ?[]const u8 = null,
    limit: i64 = 5,
    pub const descriptions = .{
        .query = "What you want to recall, in natural language.",
        .scope = "Restrict to a scope. Defaults to the current project. Use an empty string to search all scopes in the current store.",
        .kind = "Restrict to one kind. " ++ kinds_doc,
        .limit = "Maximum results (1-50).",
    };
};

const TimelineArgs = struct {
    scope: ?[]const u8 = null,
    kind: ?[]const u8 = null,
    limit: i64 = 20,
    pub const descriptions = .{
        .scope = "Restrict to a scope. Defaults to the current project. Use an empty string to list all scopes in the current store.",
        .kind = "Restrict to one kind. " ++ kinds_doc,
        .limit = "Maximum results (1-200).",
    };
};

const SupersedeArgs = struct {
    supersedes: i64,
    kind: []const u8,
    body: []const u8,
    scope: ?[]const u8 = null,
    refs: ?[]const []const u8 = null,
    pub const descriptions = .{
        .supersedes = "Id of the entry being replaced.",
        .kind = "Kind of the replacement entry. " ++ kinds_doc,
        .body = "The new content.",
        .scope = "Project/task scope. Defaults to the current project.",
        .refs = "Optional related file paths, symbols, issue keys, PRs, or \"entry:N\" references.",
    };
};

const DoneArgs = struct {
    id: i64,
    pub const descriptions = .{ .id = "Id of the todo (or entry) to mark done." };
};

const TouchArgs = struct {
    id: i64,
    pub const descriptions = .{ .id = "Id of the entry to confirm as still valid." };
};

const PinArgs = struct {
    id: i64,
    unpin: bool = false,
    pub const descriptions = .{
        .id = "Id of the entry to pin (or unpin).",
        .unpin = "Set true to remove an existing pin.",
    };
};

const RefsArgs = struct {
    action: []const u8,
    id: i64,
    ref_name: ?[]const u8 = null,
    new_ref: ?[]const u8 = null,
    pub const descriptions = .{
        .action = "One of: refresh, move, dismiss. refresh accepts current hashes, move updates a renamed ref, dismiss removes an expected stale ref.",
        .id = "Id of the entry whose refs should be maintained.",
        .ref_name = "Existing ref for move or dismiss.",
        .new_ref = "Replacement ref for move.",
    };
};

const HandoffArgs = struct {
    scope: ?[]const u8 = null,
    limit: i64 = 3,
    pub const descriptions = .{
        .scope = "Restrict to a scope. Defaults to the current project. Use an empty string to summarize all scopes in the current store.",
        .limit = "Maximum entries per section (1-10).",
    };
};

/// Connection state and scope defaults shared by every tool handler. The
/// MCP-facing handler type is `Tools` below, generated from these methods.
pub const Bridge = struct {
    client: *Client,
    repo_scope: []const u8, // default write level
    branch_scope: []const u8, // reads and branch-local writes
    worktree_root: []const u8,
    author: []const u8,

    fn pin(self: *Bridge, a: Allocator, args: PinArgs) !types.CallToolResult {
        if (args.id < 0) return types.CallToolResult.err(a, "id must be non-negative");
        const op: []const u8 = if (args.unpin) "unpin" else "pin";
        const parsed = self.client.call(a, .{ .op = op, .id = @intCast(args.id) }) catch return daemonDown(a);
        if (!parsed.value.ok) return types.CallToolResult.err(a, parsed.value.@"error" orelse "pin failed");
        const verb = if (args.unpin) "Unpinned" else "Pinned";
        return types.CallToolResult.text(a, try std.fmt.allocPrint(a, "{s} #{d}.", .{ verb, args.id }));
    }

    fn done(self: *Bridge, a: Allocator, args: DoneArgs) !types.CallToolResult {
        if (args.id < 0) return types.CallToolResult.err(a, "id must be non-negative");
        const parsed = self.client.call(a, .{ .op = "done", .id = @intCast(args.id) }) catch return daemonDown(a);
        if (!parsed.value.ok) return types.CallToolResult.err(a, parsed.value.@"error" orelse "done failed");
        return types.CallToolResult.text(a, try std.fmt.allocPrint(a, "Marked #{d} done.", .{args.id}));
    }

    fn touch(self: *Bridge, a: Allocator, args: TouchArgs) !types.CallToolResult {
        if (args.id < 0) return types.CallToolResult.err(a, "id must be non-negative");
        const parsed = self.client.call(a, .{ .op = "touch", .id = @intCast(args.id) }) catch return daemonDown(a);
        if (!parsed.value.ok) return types.CallToolResult.err(a, parsed.value.@"error" orelse "touch failed");
        return types.CallToolResult.text(a, try std.fmt.allocPrint(a, "Confirmed #{d} still valid.", .{args.id}));
    }

    fn record(self: *Bridge, a: Allocator, args: RecordArgs) !types.CallToolResult {
        return self.doRecord(a, .{
            .op = "record",
            .kind = args.kind,
            .body = args.body,
            .text = args.body,
            .scope = args.scope orelse (if (args.branch_local) self.branch_scope else self.repo_scope),
            .worktree_root = self.worktree_root,
            .refs = args.refs,
            .author = self.author,
            .supersedes = optId(args.supersedes),
        });
    }

    fn supersede(self: *Bridge, a: Allocator, args: SupersedeArgs) !types.CallToolResult {
        return self.doRecord(a, .{
            .op = "record",
            .kind = args.kind,
            .body = args.body,
            .text = args.body,
            .scope = args.scope orelse self.repo_scope,
            .worktree_root = self.worktree_root,
            .refs = args.refs,
            .author = self.author,
            .supersedes = optId(args.supersedes),
        });
    }

    fn refs(self: *Bridge, a: Allocator, args: RefsArgs) !types.CallToolResult {
        if (args.id < 0) return types.CallToolResult.err(a, "id must be non-negative");
        if (std.mem.eql(u8, args.action, "move")) {
            if (args.ref_name == null or args.new_ref == null) {
                return types.CallToolResult.err(a, "refs move requires ref_name and new_ref");
            }
        } else if (std.mem.eql(u8, args.action, "dismiss")) {
            if (args.ref_name == null) return types.CallToolResult.err(a, "refs dismiss requires ref_name");
        } else if (!std.mem.eql(u8, args.action, "refresh")) {
            return types.CallToolResult.err(a, "unknown refs action");
        }

        const parsed = self.client.call(a, .{
            .op = "refs",
            .action = args.action,
            .id = @intCast(args.id),
            .ref_name = args.ref_name,
            .new_ref = args.new_ref,
            .worktree_root = self.worktree_root,
        }) catch return daemonDown(a);
        if (!parsed.value.ok) return types.CallToolResult.err(a, parsed.value.@"error" orelse "refs failed");
        return types.CallToolResult.text(a, parsed.value.text orelse "Updated refs.");
    }

    fn handoff(self: *Bridge, a: Allocator, args: HandoffArgs) !types.CallToolResult {
        const parsed = self.client.call(a, .{
            .op = "handoff",
            .scope = args.scope orelse self.branch_scope,
            .limit = clamp(args.limit, 1, 10),
        }) catch return daemonDown(a);
        if (!parsed.value.ok) return types.CallToolResult.err(a, parsed.value.@"error" orelse "handoff failed");
        return types.CallToolResult.text(a, parsed.value.text orelse "");
    }

    fn doRecord(self: *Bridge, a: Allocator, req: Request) !types.CallToolResult {
        const parsed = self.client.call(a, req) catch return daemonDown(a);
        const resp = parsed.value;
        if (!resp.ok) return types.CallToolResult.err(a, resp.@"error" orelse "record failed");
        const base = if (req.supersedes) |old|
            try std.fmt.allocPrint(a, "Recorded #{d} (supersedes #{d}).", .{ resp.id orelse 0, old })
        else
            try std.fmt.allocPrint(a, "Recorded #{d}.", .{resp.id orelse 0});
        const msg = if (resp.warning) |warning|
            try std.fmt.allocPrint(a, "{s}\nWarning: {s}.", .{ base, warning })
        else
            base;
        return types.CallToolResult.text(a, msg);
    }

    fn recall(self: *Bridge, a: Allocator, args: RecallArgs) !types.CallToolResult {
        return self.hits(a, .{
            .op = "recall",
            .text = args.query,
            .scope = args.scope orelse self.branch_scope,
            .kind = args.kind,
            .limit = clamp(args.limit, 1, 50),
        }, true);
    }

    fn timeline(self: *Bridge, a: Allocator, args: TimelineArgs) !types.CallToolResult {
        return self.hits(a, .{
            .op = "timeline",
            .scope = args.scope orelse self.branch_scope,
            .kind = args.kind,
            .limit = clamp(args.limit, 1, 200),
        }, false);
    }

    fn hits(self: *Bridge, a: Allocator, req: Request, show_score: bool) !types.CallToolResult {
        const parsed = self.client.call(a, req) catch return daemonDown(a);
        const resp = parsed.value;
        if (!resp.ok) return types.CallToolResult.err(a, resp.@"error" orelse "query failed");
        const rows = resp.hits orelse return types.CallToolResult.text(a, "No matching entries.");
        if (rows.len == 0) return types.CallToolResult.text(a, "No matching entries.");

        const content = try a.alloc(types.Content, rows.len);
        for (rows, content) |h, *c| c.* = types.Content.text_content(try formatHit(a, h, show_score));
        return .{ .content = content };
    }
};

/// The MCP handler type: one declaration per tool. The SDK generates the
/// schemas (from the Bridge methods' arg structs), the tools/list entries,
/// name dispatch, and typed argument parsing.
pub const Tools = mcp.StatefulToolPack(Bridge, .{
    .record = .{
        .description = "Record a decision, finding, rejected path, or todo into shared project state so later sessions and sub-agents don't re-derive it.",
        .handler = Bridge.record,
    },
    .recall = .{
        .description = "Search shared project state for entries relevant to a query.",
        .handler = Bridge.recall,
        .annotations = .{ .readOnlyHint = true },
    },
    .timeline = .{
        .description = "List recent project state newest-first (the decision/finding log), for browsing rather than search.",
        .handler = Bridge.timeline,
        .annotations = .{ .readOnlyHint = true },
    },
    .supersede = .{
        .description = "Replace an earlier entry with a new one, preserving the chain (e.g. a decision that changed).",
        .handler = Bridge.supersede,
    },
    .done = .{
        .description = "Mark a todo done so it drops out of the session header. Kept for history.",
        .handler = Bridge.done,
    },
    .touch = .{
        .description = "Confirm an existing entry is still valid without rewriting it. Use this for old decisions or findings that still hold.",
        .handler = Bridge.touch,
    },
    .pin = .{
        .description = "Pin a foundational entry so it always appears in the session header, not subject to recency truncation. Use sparingly. Set unpin to remove.",
        .handler = Bridge.pin,
    },
    .refs = .{
        .description = "Maintain file refs on an entry: refresh current hashes, move a ref after a rename, or dismiss an expected stale ref.",
        .handler = Bridge.refs,
    },
    .handoff = .{
        .description = "Emit a compact next-agent summary grouped by decisions, todos, findings, dead ends, artifacts, and entries needing review.",
        .handler = Bridge.handoff,
        .annotations = .{ .readOnlyHint = true },
    },
});

fn formatHit(a: Allocator, h: protocol.HitJson, show_score: bool) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(a);
    const w = &out.writer;
    try w.print("#{d} [{s}] ({s})", .{ h.id, h.kind, h.freshness });
    if (h.stale or h.ref_statuses.len > 0) try w.writeAll(" needs review");
    if (show_score) try w.print(" (score {d:.3})", .{h.score});
    if (h.supersedes) |s| try w.print(" (supersedes #{d})", .{s});
    if (h.refs.len > 0) {
        try w.writeAll(" refs: ");
        for (h.refs, 0..) |r, i| {
            if (i != 0) try w.writeAll(", ");
            try w.writeAll(r);
        }
    }
    if (h.ref_statuses.len > 0) {
        try w.writeAll(" ref-status: ");
        for (h.ref_statuses, 0..) |status, i| {
            if (i != 0) try w.writeAll(", ");
            try w.print("{s} {s}", .{ status.status, status.ref });
            if (status.suggestion) |suggestion| try w.print(" -> {s}", .{suggestion});
        }
    }
    try w.print("\n{s}", .{h.body});
    if (h.stale or h.ref_statuses.len > 0) {
        try w.print("\nactions: touch #{d}, supersede #{d}", .{ h.id, h.id });
        if (std.mem.eql(u8, h.kind, "todo")) try w.print(", done #{d}", .{h.id});
        if (h.ref_statuses.len > 0) {
            try w.print(", refs refresh #{d}, refs move #{d} <old-ref> <new-ref>, refs dismiss #{d} <ref>", .{ h.id, h.id, h.id });
        }
    }
    return out.toOwnedSlice();
}

fn daemonDown(a: Allocator) !types.CallToolResult {
    return types.CallToolResult.err(a, "the agent-waymark daemon is unreachable");
}

fn clamp(v: i64, lo: i64, hi: i64) usize {
    if (v < lo) return @intCast(lo);
    if (v > hi) return @intCast(hi);
    return @intCast(v);
}

fn optId(v: ?i64) ?u64 {
    return if (v) |x| (if (x < 0) null else @intCast(x)) else null;
}

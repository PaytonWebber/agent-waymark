//! MCP bridge: exposes cairn's tools to an agent over stdio, as a thin client
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
    pub const descriptions = .{
        .kind = "Kind of entry. " ++ kinds_doc,
        .body = "The content: the decision made, the finding, the rejected path and why, or the todo.",
        .scope = "Project/task scope. Defaults to the current project.",
        .refs = "Optional related file paths, symbols, or \"entry:N\" references.",
        .supersedes = "Id of an earlier entry this replaces (e.g. a changed decision).",
    };
};

const RecallArgs = struct {
    query: []const u8,
    scope: ?[]const u8 = null,
    kind: ?[]const u8 = null,
    limit: i64 = 5,
    pub const descriptions = .{
        .query = "What you want to recall, in natural language.",
        .scope = "Restrict to a scope. Defaults to the current project.",
        .kind = "Restrict to one kind. " ++ kinds_doc,
        .limit = "Maximum results (1-50).",
    };
};

const TimelineArgs = struct {
    scope: ?[]const u8 = null,
    kind: ?[]const u8 = null,
    limit: i64 = 20,
    pub const descriptions = .{
        .scope = "Restrict to a scope. Defaults to the current project.",
        .kind = "Restrict to one kind. " ++ kinds_doc,
        .limit = "Maximum results (1-200).",
    };
};

const SupersedeArgs = struct {
    supersedes: i64,
    kind: []const u8,
    body: []const u8,
    scope: ?[]const u8 = null,
    pub const descriptions = .{
        .supersedes = "Id of the entry being replaced.",
        .kind = "Kind of the replacement entry. " ++ kinds_doc,
        .body = "The new content.",
        .scope = "Project/task scope. Defaults to the current project.",
    };
};

pub const Handler = struct {
    client: *Client,
    default_scope: []const u8,
    author: []const u8,

    pub fn listTools(_: *Handler, _: Allocator) !types.ListToolsResult {
        return .{
            .tools = &.{
                .{
                    .name = "record",
                    .description = "Record a decision, finding, rejected path, or todo into shared project state so later sessions and sub-agents don't re-derive it.",
                    .inputSchema = comptime types.schemaForStruct(RecordArgs),
                },
                .{
                    .name = "recall",
                    .description = "Search shared project state for entries relevant to a query.",
                    .inputSchema = comptime types.schemaForStruct(RecallArgs),
                    .annotations = .{ .readOnlyHint = true },
                },
                .{
                    .name = "timeline",
                    .description = "List recent project state newest-first (the decision/finding log), for browsing rather than search.",
                    .inputSchema = comptime types.schemaForStruct(TimelineArgs),
                    .annotations = .{ .readOnlyHint = true },
                },
                .{
                    .name = "supersede",
                    .description = "Replace an earlier entry with a new one, preserving the chain (e.g. a decision that changed).",
                    .inputSchema = comptime types.schemaForStruct(SupersedeArgs),
                },
            },
        };
    }

    pub fn callTool(self: *Handler, a: Allocator, params: types.CallToolParams) !types.CallToolResult {
        if (std.mem.eql(u8, params.name, "record")) return self.record(a, params);
        if (std.mem.eql(u8, params.name, "recall")) return self.recall(a, params);
        if (std.mem.eql(u8, params.name, "timeline")) return self.timeline(a, params);
        if (std.mem.eql(u8, params.name, "supersede")) return self.supersede(a, params);
        return error.ToolNotFound;
    }

    fn record(self: *Handler, a: Allocator, params: types.CallToolParams) !types.CallToolResult {
        const args = try types.parseArgs(RecordArgs, a, params.arguments);
        return self.doRecord(a, .{
            .op = "record",
            .kind = args.kind,
            .body = args.body,
            .text = args.body,
            .scope = args.scope orelse self.default_scope,
            .refs = args.refs,
            .author = self.author,
            .supersedes = optId(args.supersedes),
        });
    }

    fn supersede(self: *Handler, a: Allocator, params: types.CallToolParams) !types.CallToolResult {
        const args = try types.parseArgs(SupersedeArgs, a, params.arguments);
        return self.doRecord(a, .{
            .op = "record",
            .kind = args.kind,
            .body = args.body,
            .text = args.body,
            .scope = args.scope orelse self.default_scope,
            .author = self.author,
            .supersedes = optId(args.supersedes),
        });
    }

    fn doRecord(self: *Handler, a: Allocator, req: Request) !types.CallToolResult {
        const parsed = self.client.call(a, req) catch return daemonDown(a);
        const resp = parsed.value;
        if (!resp.ok) return types.CallToolResult.err(a, resp.@"error" orelse "record failed");
        const msg = if (req.supersedes) |old|
            try std.fmt.allocPrint(a, "Recorded #{d} (supersedes #{d}).", .{ resp.id orelse 0, old })
        else
            try std.fmt.allocPrint(a, "Recorded #{d}.", .{resp.id orelse 0});
        return types.CallToolResult.text(a, msg);
    }

    fn recall(self: *Handler, a: Allocator, params: types.CallToolParams) !types.CallToolResult {
        const args = try types.parseArgs(RecallArgs, a, params.arguments);
        return self.hits(a, .{
            .op = "recall",
            .text = args.query,
            .scope = args.scope orelse self.default_scope,
            .kind = args.kind,
            .limit = clamp(args.limit, 1, 50),
        }, true);
    }

    fn timeline(self: *Handler, a: Allocator, params: types.CallToolParams) !types.CallToolResult {
        const args = try types.parseArgs(TimelineArgs, a, params.arguments);
        return self.hits(a, .{
            .op = "timeline",
            .scope = args.scope orelse self.default_scope,
            .kind = args.kind,
            .limit = clamp(args.limit, 1, 200),
        }, false);
    }

    fn hits(self: *Handler, a: Allocator, req: Request, show_score: bool) !types.CallToolResult {
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

fn formatHit(a: Allocator, h: protocol.HitJson, show_score: bool) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(a);
    const w = &out.writer;
    try w.print("#{d} [{s}]", .{ h.id, h.kind });
    if (show_score) try w.print(" (score {d:.3})", .{h.score});
    if (h.supersedes) |s| try w.print(" (supersedes #{d})", .{s});
    if (h.refs.len > 0) {
        try w.writeAll(" refs: ");
        for (h.refs, 0..) |r, i| {
            if (i != 0) try w.writeAll(", ");
            try w.writeAll(r);
        }
    }
    try w.print("\n{s}", .{h.body});
    return out.toOwnedSlice();
}

fn daemonDown(a: Allocator) !types.CallToolResult {
    return types.CallToolResult.err(a, "the cairn daemon is unreachable");
}

fn clamp(v: i64, lo: i64, hi: i64) usize {
    if (v < lo) return @intCast(lo);
    if (v > hi) return @intCast(hi);
    return @intCast(v);
}

fn optId(v: ?i64) ?u64 {
    return if (v) |x| (if (x < 0) null else @intCast(x)) else null;
}

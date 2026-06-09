//! The internal request/response protocol between clients (the MCP bridge, the
//! hook CLI) and the daemon. One JSON object per line over a unix socket.
//! std.json emits no raw newlines, so newline-delimiting is safe. This wire
//! shape is the seam reused for the team HTTP transport in phase 5.

const std = @import("std");
const entry_mod = @import("entry.zig");
const Hit = entry_mod.Hit;
const RefStatus = entry_mod.RefStatus;

/// A request carries `op` plus whichever fields that op needs; the daemon reads
/// only the relevant ones. Optionals default to null so a client sends a
/// minimal object. A client supplies either `text` (the daemon embeds it) or a
/// precomputed `embedding` (tests and clients that already hold a vector).
pub const Request = struct {
    op: []const u8,
    kind: ?[]const u8 = null,
    scope: ?[]const u8 = null,
    worktree_root: ?[]const u8 = null,
    body: ?[]const u8 = null,
    refs: ?[]const []const u8 = null,
    author: ?[]const u8 = null,
    supersedes: ?u64 = null,
    text: ?[]const u8 = null,
    embedding: ?[]const f32 = null,
    limit: ?usize = null,
    id: ?u64 = null,
};

pub const HitJson = struct {
    id: u64,
    score: f32,
    kind: []const u8,
    scope: []const u8,
    body: []const u8,
    refs: []const []const u8,
    ref_statuses: []const RefStatus,
    author: []const u8,
    supersedes: ?u64 = null,
    created_at: i64,
    updated_at: i64,
    confirmed_at: ?i64 = null,
    freshness: []const u8,
    stale: bool,

    pub fn from(a: std.mem.Allocator, h: Hit, now: i64) !HitJson {
        return .{
            .id = h.id,
            .score = h.score,
            .kind = h.kind.toString(),
            .scope = h.scope,
            .body = h.body,
            .refs = h.refs,
            .ref_statuses = h.ref_statuses,
            .author = h.author,
            .supersedes = h.supersedes,
            .created_at = h.created_at,
            .updated_at = h.updated_at,
            .confirmed_at = h.confirmed_at,
            .freshness = try entry_mod.formatFreshness(a, h.created_at, h.updated_at, h.confirmed_at, now),
            .stale = entry_mod.isStale(h.created_at, h.updated_at, h.confirmed_at, now),
        };
    }
};

pub const Response = struct {
    ok: bool,
    @"error": ?[]const u8 = null,
    id: ?u64 = null,
    count: ?usize = null,
    text: ?[]const u8 = null,
    hits: ?[]const HitJson = null,
    warning: ?[]const u8 = null,

    pub fn err(message: []const u8) Response {
        return .{ .ok = false, .@"error" = message };
    }
};

/// Serialize `value` as one JSON line (terminating newline included) and flush.
pub fn writeLine(allocator: std.mem.Allocator, w: *std.Io.Writer, value: anytype) !void {
    const bytes = try std.json.Stringify.valueAlloc(allocator, value, .{});
    defer allocator.free(bytes);
    try w.writeAll(bytes);
    try w.writeByte('\n');
    try w.flush();
}

/// Read one JSON line and parse it into `T`. The returned `Parsed(T)` owns its
/// allocations; the caller deinits it (or uses an arena and ignores deinit).
///
/// Uses the inclusive delimiter read so the trailing newline is consumed from
/// the buffer; the exclusive variant leaves it behind, jamming the next read on
/// an empty line. A clean client disconnect surfaces as `error.EndOfStream`.
pub fn readLine(comptime T: type, allocator: std.mem.Allocator, r: *std.Io.Reader) !std.json.Parsed(T) {
    const line = try r.takeDelimiterInclusive('\n');
    return std.json.parseFromSlice(T, allocator, line[0 .. line.len - 1], .{ .ignore_unknown_fields = true });
}

test "request round-trips through the line codec" {
    const testing = std.testing;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const refs = [_][]const u8{ "src/main.zig", "entry:7" };
    const req: Request = .{
        .op = "record",
        .kind = "decision",
        .scope = "repo:/x@main",
        .body = "use a daemon, not per-process stores",
        .refs = &refs,
        .author = "session:abc/agent:main",
        .supersedes = 7,
    };

    const bytes = try std.json.Stringify.valueAlloc(a, req, .{});
    try testing.expect(std.mem.indexOfScalar(u8, bytes, '\n') == null); // one line

    const parsed = try std.json.parseFromSlice(Request, a, bytes, .{});
    const got = parsed.value;
    try testing.expectEqualStrings("record", got.op);
    try testing.expectEqualStrings("decision", got.kind.?);
    try testing.expectEqualStrings("repo:/x@main", got.scope.?);
    try testing.expectEqual(@as(u64, 7), got.supersedes.?);
    try testing.expectEqual(@as(usize, 2), got.refs.?.len);
    try testing.expectEqualStrings("entry:7", got.refs.?[1]);
}

test "response error helper" {
    const r = Response.err("nope");
    try std.testing.expect(!r.ok);
    try std.testing.expectEqualStrings("nope", r.@"error".?);
}

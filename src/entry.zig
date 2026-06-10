//! The unit of shared state: a structured entry left by one agent/session for
//! the next. `kind` and `supersedes` are what make this orchestration state
//! rather than a flat fact store. `rejected` keeps dead ends visible, and
//! `decision` + `supersedes` preserves the temporal chain of how a choice
//! changed, instead of flattening everything into an embedding.

const std = @import("std");

pub const EntryKind = enum {
    decision,
    finding,
    rejected,
    todo,
    artifact,
    note,

    pub fn fromString(s: []const u8) ?EntryKind {
        inline for (@typeInfo(EntryKind).@"enum".fields) |f| {
            if (std.mem.eql(u8, s, f.name)) return @enumFromInt(f.value);
        }
        return null;
    }

    pub fn toString(self: EntryKind) []const u8 {
        return @tagName(self);
    }
};

/// In-memory entry. All slices are owned by the store's long-lived allocator,
/// so they outlive any single request.
pub const Entry = struct {
    id: u64,
    created_at: i64,
    updated_at: i64,
    confirmed_at: ?i64,
    kind: EntryKind,
    scope: []u8,
    body: []u8,
    refs: [][]u8,
    ref_states: []RefState,
    author: []u8,
    supersedes: ?u64,
    superseded_by: ?u64,
    resolved: bool,
    pinned: bool,
    embedding: []f32,

    /// True unless a later entry has replaced this one or it was marked done.
    /// Inactive entries are kept (audit trail) but dropped from headers, the
    /// active timeline, and default recall.
    pub fn isActive(self: Entry) bool {
        return self.superseded_by == null and !self.resolved;
    }
};

/// A search/list result hydrated into the caller's (request-scoped) allocator.
pub const Hit = struct {
    id: u64,
    score: f32,
    kind: EntryKind,
    scope: []const u8,
    body: []const u8,
    refs: []const []const u8,
    ref_statuses: []const RefStatus,
    author: []const u8,
    supersedes: ?u64,
    created_at: i64,
    updated_at: i64,
    confirmed_at: ?i64,
};

pub const RefState = struct {
    ref: []u8,
    path: []u8,
    hash: u64,
};

pub const RefStateJson = struct {
    ref: []const u8,
    path: []const u8,
    hash: u64,
};

pub const RefStatus = struct {
    ref: []const u8,
    status: []const u8,
    suggestion: ?[]const u8 = null,
};

/// On-disk / on-wire form. `kind` is serialized as its tag name so the snapshot
/// stays readable and stable across enum reordering.
pub const EntryJson = struct {
    id: u64,
    created_at: i64,
    updated_at: i64,
    confirmed_at: ?i64 = null,
    kind: []const u8,
    scope: []const u8,
    body: []const u8,
    refs: []const []const u8,
    ref_states: []const RefStateJson = &.{},
    author: []const u8,
    supersedes: ?u64 = null,
    superseded_by: ?u64 = null,
    resolved: bool = false,
    pinned: bool = false,
    embedding: []const f32,
};

pub const Snapshot = struct {
    next_id: u64,
    /// Identifies the embedding matrix the vectors were produced with (see
    /// model2vec's Model.fingerprint). Vectors from a different matrix are
    /// not comparable, even at the same dimension: a quantized rebuild or a
    /// swapped AGENT_WAYMARK_MODEL_DIR changes the basis. Null in snapshots
    /// from older builds.
    embedder_fingerprint: ?u64 = null,
    entries: []const EntryJson,
};

pub const stale_after_seconds: i64 = 14 * 24 * 60 * 60;

pub fn freshnessTime(created_at: i64, updated_at: i64, confirmed_at: ?i64) i64 {
    _ = created_at;
    return confirmed_at orelse updated_at;
}

pub fn isStale(created_at: i64, updated_at: i64, confirmed_at: ?i64, now: i64) bool {
    return now - freshnessTime(created_at, updated_at, confirmed_at) >= stale_after_seconds;
}

pub fn formatFreshness(
    a: std.mem.Allocator,
    created_at: i64,
    updated_at: i64,
    confirmed_at: ?i64,
    now: i64,
) ![]const u8 {
    const label: []const u8 = if (confirmed_at != null)
        "confirmed"
    else if (updated_at > created_at)
        "updated"
    else
        "created";
    const age = try formatAge(a, @max(@as(i64, 0), now - freshnessTime(created_at, updated_at, confirmed_at)));
    defer a.free(age);
    if (isStale(created_at, updated_at, confirmed_at, now)) {
        return std.fmt.allocPrint(a, "{s} {s}, stale?", .{ label, age });
    }
    return std.fmt.allocPrint(a, "{s} {s}", .{ label, age });
}

fn formatAge(a: std.mem.Allocator, seconds: i64) ![]const u8 {
    if (seconds < 60) return a.dupe(u8, "just now");
    if (seconds < 60 * 60) return std.fmt.allocPrint(a, "{d}m ago", .{@divFloor(seconds, 60)});
    if (seconds < 24 * 60 * 60) return std.fmt.allocPrint(a, "{d}h ago", .{@divFloor(seconds, 60 * 60)});
    if (seconds < 7 * 24 * 60 * 60) return std.fmt.allocPrint(a, "{d}d ago", .{@divFloor(seconds, 24 * 60 * 60)});
    return std.fmt.allocPrint(a, "{d}w ago", .{@divFloor(seconds, 7 * 24 * 60 * 60)});
}

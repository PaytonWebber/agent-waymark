//! The unit of shared state: a structured entry left by one agent/session for
//! the next. `kind` and `supersedes` are what make this orchestration state
//! rather than a flat fact store — `rejected` keeps dead ends visible, and
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
    ts: i64,
    kind: EntryKind,
    scope: []u8,
    body: []u8,
    refs: [][]u8,
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
    author: []const u8,
    supersedes: ?u64,
    ts: i64,
};

/// On-disk / on-wire form. `kind` is serialized as its tag name so the snapshot
/// stays readable and stable across enum reordering.
pub const EntryJson = struct {
    id: u64,
    ts: i64,
    kind: []const u8,
    scope: []const u8,
    body: []const u8,
    refs: []const []const u8,
    author: []const u8,
    supersedes: ?u64 = null,
    superseded_by: ?u64 = null,
    resolved: bool = false,
    pinned: bool = false,
    embedding: []const f32,
};

pub const Snapshot = struct {
    next_id: u64,
    entries: []const EntryJson,
};

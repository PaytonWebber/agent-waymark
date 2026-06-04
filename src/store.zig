//! Durable shared working-state store.
//!
//! Holds an in-memory map of `id -> Entry` and a quantal vector index over the
//! entry bodies' embeddings. The on-disk form is a single JSON snapshot that
//! includes each embedding, so the vector index is a pure runtime structure
//! rebuilt from the snapshot at startup — no separate index file to keep
//! consistent, and recovery needs no embedding service.
//!
//! Durability: every mutation rewrites the snapshot to a temp file and renames
//! it over the live file, so a crash leaves either the old or the new snapshot,
//! never a torn one. O(n) per write, appropriate for the hundreds-to-thousands
//! of entries an agent accumulates; an append log + periodic index snapshot is
//! the scale-up path.
//!
//! Concurrency: the daemon owns exactly one Store and drives it from a single
//! thread (the accept loop handles one request at a time), which satisfies
//! quantal's single-writer/many-reader contract. The team backend (phase 5)
//! adds an RwLock here and one SearchContext per reader thread.

const std = @import("std");
const quantal = @import("quantal");
const embedder = @import("embedder.zig");
const entry_mod = @import("entry.zig");

const Allocator = std.mem.Allocator;
const Entry = entry_mod.Entry;
const EntryKind = entry_mod.EntryKind;
const Hit = entry_mod.Hit;
const EntryJson = entry_mod.EntryJson;
const Snapshot = entry_mod.Snapshot;

/// quantal index instantiation. `dim` matches the embedding model; 32 edges is
/// a solid graph degree; `autoRoutingBits` picks the SimHash code length the
/// library recommends for this dimension.
pub const Index = quantal.Index(embedder.dim, 32, quantal.index.autoRoutingBits(embedder.dim));

/// Fields for a new entry. `embedding` must already be `embedder.dim` long.
pub const NewEntry = struct {
    kind: EntryKind,
    scope: []const u8,
    body: []const u8,
    refs: []const []const u8 = &.{},
    author: []const u8 = "",
    supersedes: ?u64 = null,
    embedding: []const f32,
};

pub const Store = struct {
    allocator: Allocator,
    io: std.Io,
    path: []const u8,
    tmp_path: []const u8,
    index: Index,
    entries: std.AutoHashMapUnmanaged(u64, Entry) = .empty,
    next_id: u64 = 1,

    /// Open (or create) the store backed by the snapshot at `path`. `path` and
    /// `io` are borrowed and must outlive the store.
    pub fn init(allocator: Allocator, io: std.Io, path: []const u8) !Store {
        const tmp_path = try std.fmt.allocPrint(allocator, "{s}.tmp", .{path});
        errdefer allocator.free(tmp_path);

        var store: Store = .{
            .allocator = allocator,
            .io = io,
            .path = try allocator.dupe(u8, path),
            .tmp_path = tmp_path,
            .index = try Index.init(allocator, 200, 0x5EED),
        };
        errdefer store.allocator.free(store.path);
        errdefer store.index.deinit(allocator);

        try store.load();
        return store;
    }

    pub fn deinit(self: *Store) void {
        var it = self.entries.valueIterator();
        while (it.next()) |e| self.freeEntry(e.*);
        self.entries.deinit(self.allocator);
        self.index.deinit(self.allocator);
        self.allocator.free(self.path);
        self.allocator.free(self.tmp_path);
        self.* = undefined;
    }

    pub fn count(self: *Store) usize {
        return self.entries.count();
    }

    /// Record a new entry. If it supersedes an existing active entry, that
    /// entry is marked superseded (kept for audit, dropped from headers and
    /// default recall). Returns the assigned id. On failure the store is
    /// unchanged.
    pub fn record(self: *Store, ne: NewEntry) !u64 {
        if (ne.embedding.len != embedder.dim) return error.EmbeddingDimMismatch;

        // Supersede the head of the chain: if the named entry was itself already
        // replaced, replace its current version instead of forking history.
        var supersede_head: ?u64 = null;
        if (ne.supersedes) |old| {
            if (!self.entries.contains(old)) return error.SupersedesUnknownId;
            supersede_head = self.chainHead(old);
        }

        var effective = ne;
        effective.supersedes = supersede_head;
        // Carry forward the replaced entry's refs when the caller gives none.
        if (effective.refs.len == 0) {
            if (supersede_head) |head| {
                if (self.entries.get(head)) |old_e| effective.refs = old_e.refs;
            }
        }

        const id = self.next_id;
        const e = try self.allocEntry(id, effective);
        errdefer self.freeEntry(e);

        try self.index.add(self.allocator, id, e.embedding);
        errdefer _ = self.index.remove(self.allocator, id) catch {};

        try self.entries.put(self.allocator, id, e);
        errdefer _ = self.entries.remove(id);

        // Link the superseded entry only after the new one is committed to the
        // map, so a failure above leaves the old entry untouched.
        var relinked = false;
        if (supersede_head) |head| {
            if (self.entries.getPtr(head)) |old_ptr| {
                old_ptr.superseded_by = id;
                relinked = true;
            }
        }
        errdefer if (relinked) {
            if (self.entries.getPtr(supersede_head.?)) |old_ptr| old_ptr.superseded_by = null;
        };

        self.next_id += 1;
        errdefer self.next_id -= 1;

        try self.persist();
        return id;
    }

    /// Mark an entry done (a finished todo). It stays in the store for the audit
    /// trail but drops out of headers, the active timeline, and default recall.
    /// Returns false if the id is unknown.
    pub fn resolve(self: *Store, id: u64) !bool {
        const ptr = self.entries.getPtr(id) orelse return false;
        if (ptr.resolved) return true;
        ptr.resolved = true;
        errdefer ptr.resolved = false;
        try self.persist();
        return true;
    }

    /// Follow a supersede chain to its current (un-superseded) head.
    fn chainHead(self: *Store, start: u64) u64 {
        var id = start;
        var guard: usize = 0;
        while (self.entries.get(id)) |e| {
            const next = e.superseded_by orelse break;
            id = next;
            guard += 1;
            if (guard > self.entries.count()) break; // cycle guard
        }
        return id;
    }

    /// Delete an entry by id. Returns false if the id is unknown. Any entry it
    /// superseded is left superseded (the deletion does not resurrect history).
    pub fn forget(self: *Store, id: u64) !bool {
        const removed = try self.index.remove(self.allocator, id);
        if (!removed) return false;
        if (self.entries.fetchRemove(id)) |kv| self.freeEntry(kv.value);
        try self.persist();
        return true;
    }

    /// Semantic search over active entries, optionally restricted to a scope
    /// and/or kind. Returns up to `limit` hits hydrated into `arena`, sorted by
    /// descending score.
    pub fn recall(
        self: *Store,
        arena: Allocator,
        query: []const f32,
        scope: []const u8,
        kind: ?EntryKind,
        limit: usize,
    ) ![]Hit {
        if (self.entries.count() == 0 or limit == 0) return &.{};

        // Overfetch because the scope/kind/active filters run after ranking.
        const filtering = scope.len > 0 or kind != null;
        const want = if (filtering)
            @min(self.entries.count(), @max(limit * 8, 64))
        else
            @min(self.entries.count(), limit);

        var ctx = try Index.SearchContext.init(self.allocator, &self.index, @max(want, 64));
        defer ctx.deinit(self.allocator);

        const out = try arena.alloc(quantal.SearchResult, want);
        const n = self.index.search(&ctx, query, out);

        var hits = try std.ArrayList(Hit).initCapacity(arena, @min(n, limit));
        for (out[0..n]) |sr| {
            const e = self.entries.get(sr.id) orelse continue;
            if (!e.isActive()) continue;
            if (scope.len > 0 and !std.mem.eql(u8, e.scope, scope)) continue;
            if (kind) |k| if (e.kind != k) continue;
            try hits.append(arena, try hydrate(arena, sr.score, e));
            if (hits.items.len >= limit) break;
        }
        return hits.items;
    }

    /// Active entries in a scope, newest-first (ids are monotonic), optionally
    /// filtered by kind, hydrated into `arena`. The chronological decision log.
    pub fn timeline(
        self: *Store,
        arena: Allocator,
        scope: []const u8,
        kind: ?EntryKind,
        limit: usize,
    ) ![]Hit {
        var ids = try std.ArrayList(u64).initCapacity(arena, self.entries.count());
        var it = self.entries.iterator();
        while (it.next()) |kv| {
            const e = kv.value_ptr.*;
            if (!e.isActive()) continue;
            if (scope.len > 0 and !std.mem.eql(u8, e.scope, scope)) continue;
            if (kind) |k| if (e.kind != k) continue;
            try ids.append(arena, kv.key_ptr.*);
        }
        std.mem.sort(u64, ids.items, {}, std.sort.desc(u64));

        const take = @min(ids.items.len, limit);
        var hits = try std.ArrayList(Hit).initCapacity(arena, take);
        for (ids.items[0..take]) |id| {
            const e = self.entries.get(id).?;
            try hits.append(arena, try hydrate(arena, 0, e));
        }
        return hits.items;
    }

    /// A compact, always-on summary for SessionStart injection: open todos and
    /// recent decisions in a scope, newest-first, bodies clipped. Returns an
    /// empty string when the scope has neither.
    pub fn header(
        self: *Store,
        arena: Allocator,
        scope: []const u8,
        max_todos: usize,
        max_decisions: usize,
    ) ![]u8 {
        const todo_total = self.countActive(scope, .todo);
        const dec_total = self.countActive(scope, .decision);
        if (todo_total == 0 and dec_total == 0) return "";

        var out: std.Io.Writer.Allocating = .init(arena);
        const w = &out.writer;
        try w.print("## cairn state — {s}\n", .{if (scope.len > 0) scope else "all scopes"});
        try self.writeSection(arena, w, scope, .todo, "Open todos", todo_total, max_todos);
        try self.writeSection(arena, w, scope, .decision, "Recent decisions", dec_total, max_decisions);
        return out.toOwnedSlice();
    }

    fn writeSection(
        self: *Store,
        arena: Allocator,
        w: *std.Io.Writer,
        scope: []const u8,
        kind: EntryKind,
        label: []const u8,
        total: usize,
        max: usize,
    ) !void {
        if (total == 0) return;
        const rows = try self.timeline(arena, scope, kind, max);
        try w.print("\n{s} ({d}):\n", .{ label, total });
        for (rows) |h| try writeHeaderLine(w, h);
        if (total > rows.len) try w.print("  …and {d} more (recall to see them)\n", .{total - rows.len});
    }

    fn countActive(self: *Store, scope: []const u8, kind: EntryKind) usize {
        var n: usize = 0;
        var it = self.entries.valueIterator();
        while (it.next()) |e| {
            if (!e.isActive()) continue;
            if (e.kind != kind) continue;
            if (scope.len > 0 and !std.mem.eql(u8, e.scope, scope)) continue;
            n += 1;
        }
        return n;
    }

    pub fn nowSeconds(self: *Store) i64 {
        return std.Io.Timestamp.now(self.io, .real).toSeconds();
    }

    // ---- internals --------------------------------------------------------

    fn load(self: *Store) !void {
        const bytes = std.Io.Dir.cwd().readFileAlloc(self.io, self.path, self.allocator, .unlimited) catch |err| switch (err) {
            error.FileNotFound => return,
            else => return err,
        };
        defer self.allocator.free(bytes);

        const parsed = try std.json.parseFromSlice(Snapshot, self.allocator, bytes, .{ .ignore_unknown_fields = true });
        defer parsed.deinit();

        for (parsed.value.entries) |r| {
            if (r.embedding.len != embedder.dim) return error.SnapshotDimMismatch;
            const kind = EntryKind.fromString(r.kind) orelse return error.SnapshotBadKind;
            const ne: NewEntry = .{
                .kind = kind,
                .scope = r.scope,
                .body = r.body,
                .refs = r.refs,
                .author = r.author,
                .supersedes = r.supersedes,
                .embedding = r.embedding,
            };
            var e = try self.allocEntry(r.id, ne);
            e.ts = r.ts; // preserve the saved timestamp rather than re-stamping
            e.superseded_by = r.superseded_by;
            e.resolved = r.resolved;
            errdefer self.freeEntry(e);
            try self.index.add(self.allocator, r.id, e.embedding);
            try self.entries.put(self.allocator, r.id, e);
        }
        self.next_id = parsed.value.next_id;
    }

    fn persist(self: *Store) !void {
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        const a = arena.allocator();

        const rows = try a.alloc(EntryJson, self.entries.count());
        var it = self.entries.iterator();
        var i: usize = 0;
        while (it.next()) |kv| : (i += 1) {
            const e = kv.value_ptr.*;
            rows[i] = .{
                .id = e.id,
                .ts = e.ts,
                .kind = e.kind.toString(),
                .scope = e.scope,
                .body = e.body,
                .refs = castRefs(e.refs),
                .author = e.author,
                .supersedes = e.supersedes,
                .superseded_by = e.superseded_by,
                .resolved = e.resolved,
                .embedding = e.embedding,
            };
        }

        const bytes = try std.json.Stringify.valueAlloc(a, Snapshot{ .next_id = self.next_id, .entries = rows }, .{});

        const cwd = std.Io.Dir.cwd();
        try cwd.writeFile(self.io, .{ .sub_path = self.tmp_path, .data = bytes });
        try cwd.rename(self.tmp_path, cwd, self.path, self.io);
    }

    fn allocEntry(self: *Store, id: u64, ne: NewEntry) !Entry {
        const a = self.allocator;
        const scope_copy = try a.dupe(u8, ne.scope);
        errdefer a.free(scope_copy);
        const body_copy = try a.dupe(u8, ne.body);
        errdefer a.free(body_copy);
        const author_copy = try a.dupe(u8, ne.author);
        errdefer a.free(author_copy);
        const emb_copy = try a.dupe(f32, ne.embedding);
        errdefer a.free(emb_copy);

        const refs_copy = try a.alloc([]u8, ne.refs.len);
        var filled: usize = 0;
        errdefer {
            for (refs_copy[0..filled]) |r| a.free(r);
            a.free(refs_copy);
        }
        for (ne.refs, refs_copy) |src, *dst| {
            dst.* = try a.dupe(u8, src);
            filled += 1;
        }

        return .{
            .id = id,
            .ts = self.nowSeconds(),
            .kind = ne.kind,
            .scope = scope_copy,
            .body = body_copy,
            .refs = refs_copy,
            .author = author_copy,
            .supersedes = ne.supersedes,
            .superseded_by = null,
            .resolved = false,
            .embedding = emb_copy,
        };
    }

    fn freeEntry(self: *Store, e: Entry) void {
        const a = self.allocator;
        a.free(e.scope);
        a.free(e.body);
        a.free(e.author);
        a.free(e.embedding);
        for (e.refs) |r| a.free(r);
        a.free(e.refs);
    }
};

fn castRefs(refs: [][]u8) []const []const u8 {
    return @ptrCast(refs);
}

fn writeHeaderLine(w: *std.Io.Writer, h: Hit) !void {
    const clipped = clip(h.body, 200);
    try w.print("- #{d} {s}", .{ h.id, clipped });
    if (clipped.len < h.body.len) try w.writeAll("…");
    if (h.supersedes) |s| try w.print(" (supersedes #{d})", .{s});
    try w.writeByte('\n');
}

/// Clip to at most `max` bytes without splitting a UTF-8 sequence, and stop at
/// the first newline so a multi-line body stays one header line.
fn clip(s: []const u8, max: usize) []const u8 {
    var end = @min(s.len, max);
    if (std.mem.indexOfScalar(u8, s[0..end], '\n')) |nl| end = nl;
    while (end > 0 and s[end - 1] & 0xC0 == 0x80) end -= 1; // back off into a continuation byte
    return s[0..end];
}

fn hydrate(arena: Allocator, score: f32, e: Entry) !Hit {
    const refs = try arena.alloc([]const u8, e.refs.len);
    for (e.refs, refs) |src, *dst| dst.* = try arena.dupe(u8, src);
    return .{
        .id = e.id,
        .score = score,
        .kind = e.kind,
        .scope = try arena.dupe(u8, e.scope),
        .body = try arena.dupe(u8, e.body),
        .refs = refs,
        .author = try arena.dupe(u8, e.author),
        .supersedes = e.supersedes,
        .ts = e.ts,
    };
}

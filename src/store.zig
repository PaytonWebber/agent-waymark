//! Durable shared working-state store.
//!
//! Holds an in-memory map of `id -> Entry` and a quantal vector index over the
//! entry bodies' embeddings. The on-disk form is a single JSON snapshot that
//! includes each embedding, so the vector index is a pure runtime structure
//! rebuilt from the snapshot at startup. There is no separate index file to keep
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
const RefState = entry_mod.RefState;
const RefStateJson = entry_mod.RefStateJson;
const RefStatus = entry_mod.RefStatus;
const Snapshot = entry_mod.Snapshot;

/// quantal index instantiation. `dim` matches the embedding model; 32 edges is
/// a solid graph degree; `autoRoutingBits` picks the SimHash code length the
/// library recommends for this dimension.
pub const Index = quantal.Index(embedder.dim, 32, quantal.index.autoRoutingBits(embedder.dim));

/// Cap on pinned entries shown in the header, to keep the always-on context
/// compact even if pinning is overused.
const max_pinned = 5;

/// Fields for a new entry. `embedding` must already be `embedder.dim` long.
pub const NewEntry = struct {
    kind: EntryKind,
    scope: []const u8,
    worktree_root: ?[]const u8 = null,
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
    prompts_since_write: usize = 0,
    last_nudge_prompt_count: usize = 0,

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
        const now = self.nowSeconds();

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
        const e = try self.allocEntry(id, effective, now, null);
        errdefer self.freeEntry(e);

        try self.index.add(self.allocator, id, e.embedding);
        errdefer _ = self.index.remove(self.allocator, id) catch {};

        try self.entries.put(self.allocator, id, e);
        errdefer _ = self.entries.remove(id);

        // Link the superseded entry only after the new one is committed to the
        // map, so a failure above leaves the old entry untouched.
        var relinked = false;
        var old_updated_at: i64 = 0;
        if (supersede_head) |head| {
            if (self.entries.getPtr(head)) |old_ptr| {
                old_ptr.superseded_by = id;
                old_updated_at = old_ptr.updated_at;
                old_ptr.updated_at = now;
                relinked = true;
            }
        }
        errdefer if (relinked) {
            if (self.entries.getPtr(supersede_head.?)) |old_ptr| {
                old_ptr.superseded_by = null;
                old_ptr.updated_at = old_updated_at;
            }
        };

        self.next_id += 1;
        errdefer self.next_id -= 1;

        try self.persist();
        self.noteWrite();
        return id;
    }

    pub fn nearestDuplicate(
        self: *Store,
        arena: Allocator,
        query: []const f32,
        scope: []const u8,
        threshold: f32,
    ) !?Hit {
        const hits = try self.recall(arena, query, scope, null, 1);
        if (hits.len > 0 and hits[0].score >= threshold) return hits[0];
        return null;
    }

    /// Mark an entry done (a finished todo). It stays in the store for the audit
    /// trail but drops out of headers, the active timeline, and default recall.
    /// Returns false if the id is unknown.
    pub fn resolve(self: *Store, id: u64) !bool {
        const ptr = self.entries.getPtr(id) orelse return false;
        if (ptr.resolved) return true;
        const old_updated_at = ptr.updated_at;
        ptr.resolved = true;
        ptr.updated_at = self.nowSeconds();
        errdefer {
            ptr.resolved = false;
            ptr.updated_at = old_updated_at;
        }
        try self.persist();
        self.noteWrite();
        return true;
    }

    /// Confirm that an entry is still valid without rewriting it. This is the
    /// cheap "still current" action for old decisions and findings.
    pub fn touch(self: *Store, id: u64) !bool {
        const ptr = self.entries.getPtr(id) orelse return false;
        const old_updated_at = ptr.updated_at;
        const old_confirmed_at = ptr.confirmed_at;
        const now = self.nowSeconds();
        ptr.updated_at = now;
        ptr.confirmed_at = now;
        errdefer {
            ptr.updated_at = old_updated_at;
            ptr.confirmed_at = old_confirmed_at;
        }
        try self.persist();
        self.noteWrite();
        return true;
    }

    /// Pin or unpin an entry. A pinned entry is always shown in the header
    /// (until superseded or resolved), so a foundational decision is not lost to
    /// recency truncation. Returns false if the id is unknown.
    pub fn setPinned(self: *Store, id: u64, pinned: bool) !bool {
        const ptr = self.entries.getPtr(id) orelse return false;
        if (ptr.pinned == pinned) return true;
        const old_updated_at = ptr.updated_at;
        ptr.pinned = pinned;
        ptr.updated_at = self.nowSeconds();
        errdefer {
            ptr.pinned = !pinned;
            ptr.updated_at = old_updated_at;
        }
        try self.persist();
        self.noteWrite();
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
        self.noteWrite();
        return true;
    }

    pub fn promptActivity(self: *Store, arena: Allocator) !?[]const u8 {
        self.prompts_since_write += 1;
        if (self.prompts_since_write < 4) return null;
        if (self.prompts_since_write < self.last_nudge_prompt_count + 4) return null;
        self.last_nudge_prompt_count = self.prompts_since_write;
        const nudge = try std.fmt.allocPrint(
            arena,
            "agent-waymark: {d} user prompts since the last state write. If this investigation produced a decision, finding, rejected path, or todo, record it.",
            .{self.prompts_since_write},
        );
        return nudge;
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
            if (!scopeVisible(e.scope, scope)) continue;
            if (kind) |k| if (e.kind != k) continue;
            try hits.append(arena, try self.hydrate(arena, sr.score, e));
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
        return self.collect(arena, scope, kind, null, limit);
    }

    /// A compact, always-on summary for SessionStart injection: pinned entries
    /// first (always shown, so a foundational decision is never truncated by
    /// recency), then open todos and recent decisions, bodies clipped. Empty
    /// string when the scope has nothing to show.
    pub fn header(
        self: *Store,
        arena: Allocator,
        scope: []const u8,
        max_todos: usize,
        max_decisions: usize,
    ) ![]u8 {
        const now = self.nowSeconds();
        const pinned = try self.collect(arena, scope, null, true, max_pinned);
        const review = try self.collectNeedsReview(arena, scope, 5, now);
        // The kind sections exclude pinned entries, which appear above.
        const todo_total = self.countMatching(scope, .todo, false);
        const dec_total = self.countMatching(scope, .decision, false);
        if (pinned.len == 0 and review.len == 0 and todo_total == 0 and dec_total == 0) return "";

        var out: std.Io.Writer.Allocating = .init(arena);
        const w = &out.writer;
        try w.print("## agent-waymark state: {s}\n", .{if (scope.len > 0) scope else "all scopes"});
        if (pinned.len > 0) {
            try w.writeAll("\nPinned:\n");
            for (pinned) |h| try writeHeaderLine(arena, w, h, now);
        }
        if (review.len > 0) {
            try w.writeAll("\nNeeds review:\n");
            for (review) |h| try writeHeaderLine(arena, w, h, now);
        }
        try self.writeSection(arena, w, scope, .todo, "Open todos", todo_total, max_todos, now);
        try self.writeSection(arena, w, scope, .decision, "Recent decisions", dec_total, max_decisions, now);
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
        now: i64,
    ) !void {
        if (total == 0) return;
        const rows = try self.collect(arena, scope, kind, false, max);
        try w.print("\n{s} ({d}):\n", .{ label, total });
        for (rows) |h| try writeHeaderLine(arena, w, h, now);
        if (total > rows.len) try w.print("  …and {d} more (recall to see them)\n", .{total - rows.len});
    }

    /// Active entries matching the filters, newest-first, hydrated into `arena`.
    /// `kind == null` matches any kind; `want_pinned == null` ignores the pin
    /// flag, `true`/`false` require it.
    fn collect(
        self: *Store,
        arena: Allocator,
        scope: []const u8,
        kind: ?EntryKind,
        want_pinned: ?bool,
        limit: usize,
    ) ![]Hit {
        var ids = try std.ArrayList(u64).initCapacity(arena, self.entries.count());
        var it = self.entries.iterator();
        while (it.next()) |kv| {
            if (matches(kv.value_ptr.*, scope, kind, want_pinned)) try ids.append(arena, kv.key_ptr.*);
        }
        std.mem.sort(u64, ids.items, self, newerEntry);

        const take = @min(ids.items.len, limit);
        var hits = try std.ArrayList(Hit).initCapacity(arena, take);
        for (ids.items[0..take]) |id| {
            try hits.append(arena, try self.hydrate(arena, 0, self.entries.get(id).?));
        }
        return hits.items;
    }

    fn countMatching(self: *Store, scope: []const u8, kind: ?EntryKind, want_pinned: ?bool) usize {
        var n: usize = 0;
        var it = self.entries.valueIterator();
        while (it.next()) |e| {
            if (matches(e.*, scope, kind, want_pinned)) n += 1;
        }
        return n;
    }

    fn collectNeedsReview(self: *Store, arena: Allocator, scope: []const u8, limit: usize, now: i64) ![]Hit {
        var ids = try std.ArrayList(u64).initCapacity(arena, self.entries.count());
        var it = self.entries.iterator();
        while (it.next()) |kv| {
            const e = kv.value_ptr.*;
            if (!matches(e, scope, null, null)) continue;
            if (e.pinned) continue;
            if (entry_mod.isStale(e.created_at, e.updated_at, e.confirmed_at, now) or self.hasRefIssue(e)) {
                try ids.append(arena, kv.key_ptr.*);
            }
        }
        std.mem.sort(u64, ids.items, self, newerEntry);

        const take = @min(ids.items.len, limit);
        var hits = try std.ArrayList(Hit).initCapacity(arena, take);
        for (ids.items[0..take]) |id| {
            try hits.append(arena, try self.hydrate(arena, 0, self.entries.get(id).?));
        }
        return hits.items;
    }

    pub fn nowSeconds(self: *Store) i64 {
        return std.Io.Timestamp.now(self.io, .real).toSeconds();
    }

    fn noteWrite(self: *Store) void {
        self.prompts_since_write = 0;
        self.last_nudge_prompt_count = 0;
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
            var e = try self.allocEntry(r.id, ne, r.created_at, r.ref_states);
            e.created_at = r.created_at;
            e.updated_at = r.updated_at;
            e.confirmed_at = r.confirmed_at;
            e.superseded_by = r.superseded_by;
            e.resolved = r.resolved;
            e.pinned = r.pinned;
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
                .created_at = e.created_at,
                .updated_at = e.updated_at,
                .confirmed_at = e.confirmed_at,
                .kind = e.kind.toString(),
                .scope = e.scope,
                .body = e.body,
                .refs = castRefs(e.refs),
                .ref_states = try jsonRefStates(a, e.ref_states),
                .author = e.author,
                .supersedes = e.supersedes,
                .superseded_by = e.superseded_by,
                .resolved = e.resolved,
                .pinned = e.pinned,
                .embedding = e.embedding,
            };
        }

        const bytes = try std.json.Stringify.valueAlloc(a, Snapshot{ .next_id = self.next_id, .entries = rows }, .{});

        const cwd = std.Io.Dir.cwd();
        try cwd.writeFile(self.io, .{ .sub_path = self.tmp_path, .data = bytes });
        try cwd.rename(self.tmp_path, cwd, self.path, self.io);
    }

    fn allocEntry(self: *Store, id: u64, ne: NewEntry, now: i64, stored_ref_states: ?[]const RefStateJson) !Entry {
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

        const ref_states = if (stored_ref_states) |states|
            try self.dupeRefStates(states)
        else
            try self.captureRefStates(ne.scope, ne.worktree_root, ne.refs);
        errdefer self.freeRefStates(ref_states);

        return .{
            .id = id,
            .created_at = now,
            .updated_at = now,
            .confirmed_at = null,
            .kind = ne.kind,
            .scope = scope_copy,
            .body = body_copy,
            .refs = refs_copy,
            .ref_states = ref_states,
            .author = author_copy,
            .supersedes = ne.supersedes,
            .superseded_by = null,
            .resolved = false,
            .pinned = false,
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
        self.freeRefStates(e.ref_states);
    }

    fn captureRefStates(self: *Store, scope: []const u8, worktree_root: ?[]const u8, refs: []const []const u8) ![]RefState {
        var states: std.ArrayList(RefState) = .empty;
        errdefer {
            for (states.items) |state| {
                self.allocator.free(state.ref);
                self.allocator.free(state.path);
            }
            states.deinit(self.allocator);
        }
        for (refs) |ref| {
            if (try self.captureRefState(scope, worktree_root, ref)) |state| {
                try states.append(self.allocator, state);
            }
        }
        return states.toOwnedSlice(self.allocator);
    }

    fn captureRefState(self: *Store, scope: []const u8, worktree_root: ?[]const u8, ref: []const u8) !?RefState {
        const path = try refToPath(self.allocator, scope, worktree_root, ref) orelse return null;
        errdefer self.allocator.free(path);
        const hash = self.hashPath(path) orelse {
            self.allocator.free(path);
            return null;
        };
        const ref_copy = try self.allocator.dupe(u8, ref);
        return .{ .ref = ref_copy, .path = path, .hash = hash };
    }

    fn dupeRefStates(self: *Store, states: []const RefStateJson) ![]RefState {
        const out = try self.allocator.alloc(RefState, states.len);
        var filled: usize = 0;
        errdefer {
            for (out[0..filled]) |state| {
                self.allocator.free(state.ref);
                self.allocator.free(state.path);
            }
            self.allocator.free(out);
        }
        for (states, out) |src, *dst| {
            const ref = try self.allocator.dupe(u8, src.ref);
            errdefer self.allocator.free(ref);
            const path = try self.allocator.dupe(u8, src.path);
            dst.* = .{
                .ref = ref,
                .path = path,
                .hash = src.hash,
            };
            filled += 1;
        }
        return out;
    }

    fn freeRefStates(self: *Store, states: []RefState) void {
        for (states) |state| {
            self.allocator.free(state.ref);
            self.allocator.free(state.path);
        }
        self.allocator.free(states);
    }

    fn hashPath(self: *Store, path: []const u8) ?u64 {
        const bytes = std.Io.Dir.cwd().readFileAlloc(self.io, path, self.allocator, .limited(8 * 1024 * 1024)) catch return null;
        defer self.allocator.free(bytes);
        return std.hash.Wyhash.hash(0, bytes);
    }

    fn refStatuses(self: *Store, arena: Allocator, states: []const RefState) ![]RefStatus {
        var statuses: std.ArrayList(RefStatus) = .empty;
        for (states) |state| {
            const current = self.hashPath(state.path);
            const status: ?[]const u8 = if (current) |hash|
                if (hash == state.hash) null else "changed"
            else
                "missing";
            if (status) |s| {
                try statuses.append(arena, .{
                    .ref = try arena.dupe(u8, state.ref),
                    .status = s,
                });
            }
        }
        return statuses.toOwnedSlice(arena);
    }

    fn hasRefIssue(self: *Store, e: Entry) bool {
        for (e.ref_states) |state| {
            const current = self.hashPath(state.path) orelse return true;
            if (current != state.hash) return true;
        }
        return false;
    }

    fn hydrate(self: *Store, arena: Allocator, score: f32, e: Entry) !Hit {
        const refs = try arena.alloc([]const u8, e.refs.len);
        for (e.refs, refs) |src, *dst| dst.* = try arena.dupe(u8, src);
        return .{
            .id = e.id,
            .score = score,
            .kind = e.kind,
            .scope = try arena.dupe(u8, e.scope),
            .body = try arena.dupe(u8, e.body),
            .refs = refs,
            .ref_statuses = try self.refStatuses(arena, e.ref_states),
            .author = try arena.dupe(u8, e.author),
            .supersedes = e.supersedes,
            .created_at = e.created_at,
            .updated_at = e.updated_at,
            .confirmed_at = e.confirmed_at,
        };
    }
};

fn castRefs(refs: [][]u8) []const []const u8 {
    return @ptrCast(refs);
}

fn jsonRefStates(a: Allocator, states: []const RefState) ![]const RefStateJson {
    const out = try a.alloc(RefStateJson, states.len);
    for (states, out) |src, *dst| {
        dst.* = .{ .ref = src.ref, .path = src.path, .hash = src.hash };
    }
    return out;
}

fn newerEntry(store: *Store, lhs: u64, rhs: u64) bool {
    const l = store.entries.get(lhs).?;
    const r = store.entries.get(rhs).?;
    const lt = entry_mod.freshnessTime(l.created_at, l.updated_at, l.confirmed_at);
    const rt = entry_mod.freshnessTime(r.created_at, r.updated_at, r.confirmed_at);
    if (lt == rt) return lhs > rhs;
    return lt > rt;
}

/// Whether an entry is active and matches the optional scope/kind/pin filters.
fn matches(e: Entry, scope: []const u8, kind: ?EntryKind, want_pinned: ?bool) bool {
    if (!e.isActive()) return false;
    if (!scopeVisible(e.scope, scope)) return false;
    if (kind) |k| if (e.kind != k) return false;
    if (want_pinned) |wp| if (e.pinned != wp) return false;
    return true;
}

/// Hierarchical scope visibility: an entry is visible from a query when the
/// entry's scope is an ancestor of (or equal to) the query. So a repo-wide
/// entry (`repo:R`) shows from a branch query (`repo:R/branch/x`), a
/// branch-local entry shows only from that branch (or deeper), and a repo-wide
/// query does not pull in branch-local entries. An empty query matches all; an
/// empty (global) entry scope is visible everywhere.
pub fn scopeVisible(entry_scope: []const u8, query: []const u8) bool {
    if (query.len == 0) return true;
    if (entry_scope.len == 0) return true;
    if (std.mem.eql(u8, entry_scope, query)) return true;
    // entry is an ancestor of query: query == entry_scope ++ "/" ++ rest
    return query.len > entry_scope.len and
        std.mem.startsWith(u8, query, entry_scope) and
        query[entry_scope.len] == '/';
}

fn refToPath(a: Allocator, scope: []const u8, worktree_root: ?[]const u8, ref: []const u8) !?[]u8 {
    const candidate = refPathCandidate(ref) orelse return null;
    if (std.fs.path.isAbsolute(candidate)) return try a.dupe(u8, candidate);
    if (worktree_root) |root| {
        if (root.len > 0) return try std.fs.path.join(a, &.{ root, candidate });
    }
    if (repoRoot(scope)) |root| {
        if (root.len > 0) return try std.fs.path.join(a, &.{ root, candidate });
    }
    return try a.dupe(u8, candidate);
}

fn repoRoot(scope: []const u8) ?[]const u8 {
    if (!std.mem.startsWith(u8, scope, "repo:")) return null;
    const rest = scope["repo:".len..];
    if (std.mem.indexOf(u8, rest, "/branch/")) |idx| return rest[0..idx];
    return rest;
}

fn refPathCandidate(ref: []const u8) ?[]const u8 {
    const trimmed = std.mem.trim(u8, ref, " \t\r\n");
    if (trimmed.len == 0) return null;
    if (std.mem.startsWith(u8, trimmed, "entry:")) return null;
    if (std.mem.indexOf(u8, trimmed, "://") != null) return null;

    var end = trimmed.len;
    for (trimmed, 0..) |c, i| {
        if (std.ascii.isWhitespace(c)) {
            end = i;
            break;
        }
    }
    if (std.mem.indexOfScalar(u8, trimmed[0..end], '#')) |idx| end = idx;
    if (std.mem.lastIndexOfScalar(u8, trimmed[0..end], ':')) |idx| {
        if (idx + 1 < end and allDigits(trimmed[idx + 1 .. end])) end = idx;
    }

    const candidate = std.mem.trim(u8, trimmed[0..end], " \t\r\n");
    if (candidate.len == 0) return null;
    return candidate;
}

fn allDigits(s: []const u8) bool {
    if (s.len == 0) return false;
    for (s) |c| if (!std.ascii.isDigit(c)) return false;
    return true;
}

fn writeHeaderLine(a: Allocator, w: *std.Io.Writer, h: Hit, now: i64) !void {
    const clipped = clip(h.body, 200);
    const freshness = try entry_mod.formatFreshness(a, h.created_at, h.updated_at, h.confirmed_at, now);
    try w.print("- #{d} [{s}] {s}", .{ h.id, freshness, clipped });
    if (clipped.len < h.body.len) try w.writeAll("…");
    if (h.supersedes) |s| try w.print(" (supersedes #{d})", .{s});
    if (h.ref_statuses.len > 0) {
        try w.writeAll(" [refs ");
        for (h.ref_statuses[0..@min(h.ref_statuses.len, 2)], 0..) |status, i| {
            if (i != 0) try w.writeAll(", ");
            try w.print("{s}: {s}", .{ status.status, status.ref });
        }
        if (h.ref_statuses.len > 2) try w.print(", +{d}", .{h.ref_statuses.len - 2});
        try w.writeByte(']');
    }
    // Flag branch-local entries so it's clear which are scoped to this branch
    // rather than repo-wide.
    if (std.mem.indexOf(u8, h.scope, "/branch/") != null) try w.writeAll(" [branch]");
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

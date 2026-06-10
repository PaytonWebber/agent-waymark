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
const lexical = @import("lexical.zig");
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

pub const RefMaintenance = struct {
    touched: usize = 0,
    missing: usize = 0,
    refs: usize = 0,
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
    /// Fingerprint of the embedder whose vectors this store holds; null when
    /// opened without one (tests).
    embedder_fingerprint: ?u64 = null,
    /// Test-only fixed clock; see nowSeconds.
    now_override: ?i64 = null,

    /// Open (or create) the store backed by the snapshot at `path`. `path` and
    /// `io` are borrowed and must outlive the store.
    pub fn init(allocator: Allocator, io: std.Io, path: []const u8) !Store {
        return initWithEmbedder(allocator, io, path, null);
    }

    /// Like `init`, but snapshots written at a different embedding dimension
    /// (an older build, a different model) are migrated by re-embedding every
    /// body instead of failing to load. Embedding is local and takes
    /// microseconds per entry, so migration is invisible.
    pub fn initWithEmbedder(allocator: Allocator, io: std.Io, path: []const u8, emb: ?*const embedder.Embedder) !Store {
        const store_path = try std.fs.path.resolve(allocator, &.{path});
        errdefer allocator.free(store_path);
        const tmp_path = try std.fmt.allocPrint(allocator, "{s}.tmp", .{store_path});
        errdefer allocator.free(tmp_path);

        var store: Store = .{
            .allocator = allocator,
            .io = io,
            .path = store_path,
            .tmp_path = tmp_path,
            .index = try Index.init(allocator, 200, 0x5EED),
            .embedder_fingerprint = if (emb) |e| e.fingerprint() else null,
        };
        errdefer store.index.deinit(allocator);

        try store.load(emb);
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

    pub fn refreshRefs(self: *Store, id: u64) !?RefMaintenance {
        const ptr = self.entries.getPtr(id) orelse return null;
        var result: RefMaintenance = .{ .refs = ptr.refs.len };
        const old_updated_at = ptr.updated_at;
        errdefer ptr.updated_at = old_updated_at;

        for (ptr.ref_states) |*state| {
            if (self.hashPath(state.path)) |hash| {
                state.hash = hash;
                result.touched += 1;
            } else {
                result.missing += 1;
            }
        }

        for (ptr.refs) |ref| {
            if (findRefState(ptr.ref_states, ref) != null) continue;
            if (try self.captureRefState(ptr.scope, null, ref)) |state| {
                try self.appendRefState(ptr, state);
                result.touched += 1;
            } else {
                result.missing += 1;
            }
        }

        ptr.updated_at = self.nowSeconds();
        try self.persist();
        self.noteWrite();
        return result;
    }

    pub fn moveRef(self: *Store, id: u64, old_ref: []const u8, new_ref: []const u8, worktree_root: ?[]const u8) !?RefMaintenance {
        const ptr = self.entries.getPtr(id) orelse return null;
        const idx = findRef(ptr.refs, old_ref) orelse return error.RefNotFound;

        const new_state = try self.captureRefState(ptr.scope, worktree_root, new_ref) orelse return error.RefTargetMissing;
        var state_owned = true;
        errdefer if (state_owned) self.freeRefState(new_state);

        const new_ref_copy = try self.allocator.dupe(u8, new_ref);
        var ref_owned = true;
        errdefer if (ref_owned) self.allocator.free(new_ref_copy);

        const old_ref_copy = ptr.refs[idx];
        ptr.refs[idx] = new_ref_copy;
        ref_owned = false;
        self.allocator.free(old_ref_copy);
        try self.replaceRefState(ptr, old_ref, new_state);
        state_owned = false;
        ptr.updated_at = self.nowSeconds();

        try self.persist();
        self.noteWrite();
        return .{ .touched = 1, .refs = ptr.refs.len };
    }

    pub fn dismissRef(self: *Store, id: u64, ref: []const u8) !?RefMaintenance {
        const ptr = self.entries.getPtr(id) orelse return null;
        const had_ref = findRef(ptr.refs, ref) != null;
        const had_state = findRefState(ptr.ref_states, ref) != null;
        if (!had_ref and !had_state) return error.RefNotFound;

        try self.removeRef(ptr, ref);
        try self.removeRefState(ptr, ref);
        ptr.updated_at = self.nowSeconds();
        try self.persist();
        self.noteWrite();
        return .{ .touched = 1, .refs = ptr.refs.len };
    }

    /// A deterministic handoff summary for the next session or sub-agent. It
    /// groups the live entries by their operational role instead of returning a
    /// raw timeline, so overlapping notes do not all look equally important.
    pub fn handoff(self: *Store, arena: Allocator, scope: []const u8, limit: usize) ![]u8 {
        const now = self.nowSeconds();
        const max = @max(limit, 1);
        var out: std.Io.Writer.Allocating = .init(arena);
        const w = &out.writer;

        try w.writeAll("# For the next agent\n\n");
        try w.print("Scope: {s}\n", .{if (scope.len > 0) scope else "all scopes"});

        const review = try self.collectNeedsReview(arena, scope, max, now);
        const decisions = try self.collect(arena, scope, .decision, null, max);
        const todos = try self.collect(arena, scope, .todo, null, max);
        const findings = try self.collect(arena, scope, .finding, null, max);
        const rejected = try self.collect(arena, scope, .rejected, null, max);
        const artifacts = try self.collect(arena, scope, .artifact, null, max);

        var sections: usize = 0;
        sections += try writeHandoffSection(arena, w, "Needs review", review, &.{}, now);
        sections += try writeHandoffSection(arena, w, "Current decisions", decisions, review, now);
        sections += try writeHandoffSection(arena, w, "Open todos", todos, review, now);
        sections += try writeHandoffSection(arena, w, "Open risks and findings", findings, review, now);
        sections += try writeHandoffSection(arena, w, "Dead ends to avoid", rejected, review, now);
        sections += try writeHandoffSection(arena, w, "Relevant artifacts", artifacts, review, now);

        if (sections == 0) {
            try w.writeAll("\nNo active waymarks matched this scope.\n");
            return out.toOwnedSlice();
        }

        try w.writeAll("\nClose loop:\n");
        try w.writeAll("- Mark finished todos with `done <id>`.\n");
        try w.writeAll("- Confirm durable entries with `touch <id>`.\n");
        try w.writeAll("- Resolve stale file refs with `refs refresh`, `refs move`, or `refs dismiss`.\n");
        return out.toOwnedSlice();
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

    /// Hybrid recall: the dense ranking (paraphrase matching) and a BM25
    /// ranking over the same candidates (exact identifiers: paths, symbols,
    /// env var names) fused with reciprocal-rank fusion, so a query matches
    /// whether it shares meaning or tokens with an entry. Hit scores remain
    /// cosine similarity so downstream relevance floors keep their meaning;
    /// fusion only decides the order.
    pub fn recallHybrid(
        self: *Store,
        arena: Allocator,
        query_text: []const u8,
        query_vec: []const f32,
        scope: []const u8,
        kind: ?EntryKind,
        limit: usize,
    ) ![]Hit {
        if (self.entries.count() == 0 or limit == 0) return &.{};

        const want = @min(self.entries.count(), @max(limit * 8, 64));

        // Dense ranking, filtered the same way recall filters.
        var ctx = try Index.SearchContext.init(self.allocator, &self.index, @max(want, 64));
        defer ctx.deinit(self.allocator);
        const out = try arena.alloc(quantal.SearchResult, want);
        const n = self.index.search(&ctx, query_vec, out);

        var dense_ids = try std.ArrayList(u64).initCapacity(arena, n);
        for (out[0..n]) |sr| {
            const e = self.entries.get(sr.id) orelse continue;
            if (!eligible(e, scope, kind)) continue;
            dense_ids.appendAssumeCapacity(sr.id);
        }

        // Lexical ranking over every eligible entry; the corpus is small
        // enough that the candidate set is simply all of it.
        var docs: std.ArrayList(lexical.Doc) = .empty;
        var it = self.entries.iterator();
        while (it.next()) |kv| {
            const e = kv.value_ptr.*;
            if (!eligible(e, scope, kind)) continue;
            try docs.append(arena, .{ .id = kv.key_ptr.*, .text = e.body });
        }
        const lex = try lexical.rank(arena, docs.items, query_text);
        var lex_ids = try std.ArrayList(u64).initCapacity(arena, @min(lex.len, want));
        for (lex[0..@min(lex.len, want)]) |s| lex_ids.appendAssumeCapacity(s.id);

        const fused = try lexical.rrf(arena, &.{ dense_ids.items, lex_ids.items });

        var hits = try std.ArrayList(Hit).initCapacity(arena, @min(fused.len, limit));
        for (fused) |id| {
            if (hits.items.len >= limit) break;
            const e = self.entries.get(id) orelse continue;
            try hits.append(arena, try self.hydrate(arena, cosine(query_vec, e.embedding), e));
        }
        return hits.items;
    }

    fn eligible(e: Entry, scope: []const u8, kind: ?EntryKind) bool {
        if (!e.isActive()) return false;
        if (!scopeVisible(e.scope, scope)) return false;
        if (kind) |k| if (e.kind != k) return false;
        return true;
    }

    /// Both vectors are unit length (the embedder normalizes), so the dot
    /// product is cosine similarity.
    fn cosine(a: []const f32, b: []const f32) f32 {
        var sum: f32 = 0;
        for (a, b) |x, y| sum += x * y;
        return sum;
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
        const truth_decisions = try self.collect(arena, scope, .decision, false, max_decisions);
        const truth_artifacts = try self.collect(arena, scope, .artifact, false, max_decisions);
        // The kind sections exclude pinned entries, which appear above.
        const todo_total = self.countMatching(scope, .todo, false);
        const dec_total = self.countMatching(scope, .decision, false);
        if (pinned.len == 0 and review.len == 0 and truth_decisions.len == 0 and truth_artifacts.len == 0 and todo_total == 0 and dec_total == 0) return "";

        var out: std.Io.Writer.Allocating = .init(arena);
        const w = &out.writer;
        var seen: std.ArrayList(u64) = .empty;
        try w.print("## agent-waymark state: {s}\n", .{if (scope.len > 0) scope else "all scopes"});
        if (pinned.len > 0) {
            try w.writeAll("\nPinned:\n");
            _ = try writeHeaderRows(arena, w, pinned, &.{}, &seen, now, pinned.len);
        }

        const truth_written = try writeCurrentTruth(arena, w, truth_decisions, truth_artifacts, review, &seen, now, max_decisions);
        _ = truth_written;

        if (review.len > 0) {
            try w.writeAll("\nNeeds review:\n");
            _ = try writeHeaderRows(arena, w, review, &.{}, &seen, now, review.len);
        }
        try self.writeSection(arena, w, scope, .todo, "Open todos", todo_total, max_todos, now, &seen);
        try self.writeSection(arena, w, scope, .decision, "Recent decisions", dec_total, max_decisions, now, &seen);
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
        seen: *std.ArrayList(u64),
    ) !void {
        if (total == 0) return;
        const rows = try self.collect(arena, scope, kind, false, @min(total, max + seen.items.len + 8));
        const writable = countWritableRows(rows, &.{}, seen, max);
        if (writable == 0) return;
        try w.print("\n{s} ({d}):\n", .{ label, total });
        const written = try writeHeaderRows(arena, w, rows, &.{}, seen, now, max);
        std.debug.assert(written > 0);
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
        // Tests pin the clock so entry ordering and freshness never depend
        // on where a wall-clock second boundary happens to fall mid-test.
        if (self.now_override) |t| return t;
        return std.Io.Timestamp.now(self.io, .real).toSeconds();
    }

    fn noteWrite(self: *Store) void {
        self.prompts_since_write = 0;
        self.last_nudge_prompt_count = 0;
    }

    // ---- internals --------------------------------------------------------

    fn load(self: *Store, emb: ?*const embedder.Embedder) !void {
        const bytes = std.Io.Dir.cwd().readFileAlloc(self.io, self.path, self.allocator, .unlimited) catch |err| switch (err) {
            error.FileNotFound => return,
            else => return err,
        };
        defer self.allocator.free(bytes);

        const parsed = try std.json.parseFromSlice(Snapshot, self.allocator, bytes, .{ .ignore_unknown_fields = true });
        defer parsed.deinit();

        var reembed_arena = std.heap.ArenaAllocator.init(self.allocator);
        defer reembed_arena.deinit();
        var migrated = false;

        // The same dimension is not the same basis: a different model, a
        // quantized rebuild (tq4 in particular), or an older snapshot without
        // a fingerprint all mean the stored vectors may not be comparable
        // with new ones, so re-embed everything. Only possible when an
        // embedder is present; without one (tests) trust matching dims.
        const stale_basis = emb != null and
            (parsed.value.embedder_fingerprint == null or
                parsed.value.embedder_fingerprint.? != self.embedder_fingerprint.?);

        for (parsed.value.entries) |r| {
            const embedding: []const f32 = if (r.embedding.len == embedder.dim and !stale_basis)
                r.embedding
            else if (emb) |e| blk: {
                migrated = true;
                break :blk try e.embed(reembed_arena.allocator(), r.body);
            } else return error.SnapshotDimMismatch;
            const kind = EntryKind.fromString(r.kind) orelse return error.SnapshotBadKind;
            const ne: NewEntry = .{
                .kind = kind,
                .scope = r.scope,
                .body = r.body,
                .refs = r.refs,
                .author = r.author,
                .supersedes = r.supersedes,
                .embedding = embedding,
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

        // Rewrite the snapshot at the new dimension so migration runs once.
        if (migrated) try self.persist();
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

        const bytes = try std.json.Stringify.valueAlloc(a, Snapshot{ .next_id = self.next_id, .embedder_fingerprint = self.embedder_fingerprint, .entries = rows }, .{});

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
            self.freeRefState(state);
        }
        self.allocator.free(states);
    }

    fn freeRefState(self: *Store, state: RefState) void {
        self.allocator.free(state.ref);
        self.allocator.free(state.path);
    }

    fn appendRefState(self: *Store, e: *Entry, state: RefState) !void {
        errdefer self.freeRefState(state);
        const out = try self.allocator.alloc(RefState, e.ref_states.len + 1);
        @memcpy(out[0..e.ref_states.len], e.ref_states);
        out[e.ref_states.len] = state;
        self.allocator.free(e.ref_states);
        e.ref_states = out;
    }

    fn replaceRefState(self: *Store, e: *Entry, old_ref: []const u8, state: RefState) !void {
        if (findRefState(e.ref_states, old_ref)) |idx| {
            self.freeRefState(e.ref_states[idx]);
            e.ref_states[idx] = state;
            return;
        }
        try self.appendRefState(e, state);
    }

    fn removeRef(self: *Store, e: *Entry, ref: []const u8) !void {
        const idx = findRef(e.refs, ref) orelse return;
        const out = try self.allocator.alloc([]u8, e.refs.len - 1);
        var j: usize = 0;
        for (e.refs, 0..) |existing, i| {
            if (i == idx) {
                self.allocator.free(existing);
                continue;
            }
            out[j] = existing;
            j += 1;
        }
        self.allocator.free(e.refs);
        e.refs = out;
    }

    fn removeRefState(self: *Store, e: *Entry, ref: []const u8) !void {
        const idx = findRefState(e.ref_states, ref) orelse return;
        const out = try self.allocator.alloc(RefState, e.ref_states.len - 1);
        var j: usize = 0;
        for (e.ref_states, 0..) |state, i| {
            if (i == idx) {
                self.freeRefState(state);
                continue;
            }
            out[j] = state;
            j += 1;
        }
        self.allocator.free(e.ref_states);
        e.ref_states = out;
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
                    .suggestion = if (std.mem.eql(u8, s, "missing")) try replacementSuggestion(arena, self.io, state.path) else null,
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

fn findRef(refs: [][]u8, needle: []const u8) ?usize {
    for (refs, 0..) |ref, i| {
        if (std.mem.eql(u8, ref, needle)) return i;
    }
    return null;
}

fn findRefState(states: []const RefState, needle: []const u8) ?usize {
    for (states, 0..) |state, i| {
        if (std.mem.eql(u8, state.ref, needle)) return i;
    }
    return null;
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

fn writeCurrentTruth(
    a: Allocator,
    w: *std.Io.Writer,
    decisions: []const Hit,
    artifacts: []const Hit,
    review: []const Hit,
    seen: *std.ArrayList(u64),
    now: i64,
    max: usize,
) !usize {
    const dec_count = countWritableRows(decisions, review, seen, max);
    const art_count = countWritableRows(artifacts, review, seen, max -| dec_count);
    if (dec_count + art_count == 0) return 0;

    try w.writeAll("\nCurrent truth:\n");
    var written = try writeHeaderRows(a, w, decisions, review, seen, now, max);
    if (written < max) {
        written += try writeHeaderRows(a, w, artifacts, review, seen, now, max - written);
    }
    return written;
}

fn writeHeaderRows(
    a: Allocator,
    w: *std.Io.Writer,
    rows: []const Hit,
    skip: []const Hit,
    seen: *std.ArrayList(u64),
    now: i64,
    max: usize,
) !usize {
    var written: usize = 0;
    for (rows) |h| {
        if (written >= max) break;
        if (containsHit(skip, h.id) or containsId(seen.items, h.id)) continue;
        try seen.append(a, h.id);
        try writeHeaderLine(a, w, h, now);
        written += 1;
    }
    return written;
}

fn countWritableRows(rows: []const Hit, skip: []const Hit, seen: *const std.ArrayList(u64), max: usize) usize {
    var count: usize = 0;
    for (rows) |h| {
        if (count >= max) break;
        if (containsHit(skip, h.id) or containsId(seen.items, h.id)) continue;
        count += 1;
    }
    return count;
}

fn writeHeaderLine(a: Allocator, w: *std.Io.Writer, h: Hit, now: i64) !void {
    const clipped = clip(h.body, 200);
    const freshness = try entry_mod.formatFreshness(a, h.created_at, h.updated_at, h.confirmed_at, now);
    const stale = entry_mod.isStale(h.created_at, h.updated_at, h.confirmed_at, now);
    try w.print("- #{d} [{s}, {s}", .{ h.id, h.kind.toString(), freshness });
    if (stale or h.ref_statuses.len > 0) try w.writeAll(", needs review");
    try w.print("] {s}", .{clipped});
    if (clipped.len < h.body.len) try w.writeAll("…");
    if (h.supersedes) |s| try w.print(" (supersedes #{d})", .{s});
    if (h.ref_statuses.len > 0) {
        try w.writeAll(" [refs ");
        for (h.ref_statuses[0..@min(h.ref_statuses.len, 2)], 0..) |status, i| {
            if (i != 0) try w.writeAll(", ");
            try w.print("{s}: {s}", .{ status.status, status.ref });
            if (status.suggestion) |suggestion| try w.print(" -> {s}", .{suggestion});
        }
        if (h.ref_statuses.len > 2) try w.print(", +{d}", .{h.ref_statuses.len - 2});
        try w.writeByte(']');
    }
    if (stale or h.ref_statuses.len > 0) try writeActionHints(w, h);
    // Flag branch-local entries so it's clear which are scoped to this branch
    // rather than repo-wide.
    if (std.mem.indexOf(u8, h.scope, "/branch/") != null) try w.writeAll(" [branch]");
    try w.writeByte('\n');
}

fn writeActionHints(w: *std.Io.Writer, h: Hit) !void {
    try w.print(" [actions: touch #{d}, supersede #{d}", .{ h.id, h.id });
    if (h.kind == .todo) try w.print(", done #{d}", .{h.id});
    if (h.ref_statuses.len > 0) {
        try w.print(", refs refresh #{d}, refs move #{d} <old-ref> <new-ref>, refs dismiss #{d} <ref>", .{ h.id, h.id, h.id });
    }
    try w.writeByte(']');
}

fn writeHandoffSection(
    a: Allocator,
    w: *std.Io.Writer,
    label: []const u8,
    rows: []const Hit,
    skip: []const Hit,
    now: i64,
) !usize {
    var wrote_header = false;
    var written: usize = 0;
    for (rows) |h| {
        if (containsHit(skip, h.id)) continue;
        if (!wrote_header) {
            try w.print("\n{s}:\n", .{label});
            wrote_header = true;
        }
        try writeHeaderLine(a, w, h, now);
        written += 1;
    }
    return if (written > 0) 1 else 0;
}

fn containsHit(rows: []const Hit, id: u64) bool {
    for (rows) |h| {
        if (h.id == id) return true;
    }
    return false;
}

fn containsId(rows: []const u64, id: u64) bool {
    for (rows) |row| {
        if (row == id) return true;
    }
    return false;
}

fn replacementSuggestion(a: Allocator, io: std.Io, path: []const u8) !?[]const u8 {
    const dir_name = std.fs.path.dirname(path) orelse ".";
    const old_name = std.fs.path.basename(path);
    const old_ext = std.fs.path.extension(old_name);

    var dir = std.Io.Dir.cwd().openDir(io, dir_name, .{ .iterate = true }) catch return null;
    defer dir.close(io);

    var best_path: ?[]const u8 = null;
    var best_score: usize = 0;
    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        if (entry.kind != .file) continue;
        if (std.mem.eql(u8, entry.name, old_name)) continue;
        if (!std.mem.eql(u8, std.fs.path.extension(entry.name), old_ext)) continue;
        const score = try replacementScore(a, old_name, entry.name);
        if (score > best_score) {
            best_score = score;
            best_path = try std.fs.path.join(a, &.{ dir_name, entry.name });
        }
    }

    if (best_score < 3) return null;
    return best_path;
}

fn replacementScore(a: Allocator, old_name: []const u8, candidate_name: []const u8) !usize {
    const tokens = try nameTokens(a, old_name);
    const candidate = try lowerAlloc(a, candidate_name);
    var score: usize = 0;
    for (tokens) |token| {
        if (std.mem.indexOf(u8, candidate, token) != null) score += token.len;
    }
    return score;
}

fn nameTokens(a: Allocator, name: []const u8) ![]const []const u8 {
    const stem = name[0 .. name.len - std.fs.path.extension(name).len];
    var tokens: std.ArrayList([]const u8) = .empty;
    var start: ?usize = null;
    for (stem, 0..) |c, i| {
        if (!std.ascii.isAlphanumeric(c)) {
            try appendNameToken(a, &tokens, stem, start, i);
            start = null;
            continue;
        }
        if (start) |s| {
            const prev = stem[i - 1];
            if (i > s and std.ascii.isUpper(c) and std.ascii.isLower(prev)) {
                try appendNameToken(a, &tokens, stem, start, i);
                start = i;
            }
        } else {
            start = i;
        }
    }
    try appendNameToken(a, &tokens, stem, start, stem.len);
    return tokens.toOwnedSlice(a);
}

fn appendNameToken(a: Allocator, tokens: *std.ArrayList([]const u8), source: []const u8, start: ?usize, end: usize) !void {
    const s = start orelse return;
    if (end <= s) return;
    const raw = source[s..end];
    if (raw.len < 3) return;
    try tokens.append(a, try lowerAlloc(a, raw));
}

fn lowerAlloc(a: Allocator, s: []const u8) ![]const u8 {
    const out = try a.alloc(u8, s.len);
    return std.ascii.lowerString(out, s);
}

/// Clip to at most `max` bytes without splitting a UTF-8 sequence, and stop at
/// the first newline so a multi-line body stays one header line.
fn clip(s: []const u8, max: usize) []const u8 {
    var end = @min(s.len, max);
    if (std.mem.indexOfScalar(u8, s[0..end], '\n')) |nl| end = nl;
    while (end > 0 and s[end - 1] & 0xC0 == 0x80) end -= 1; // back off into a continuation byte
    return s[0..end];
}

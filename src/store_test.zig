//! Store tests using deterministic hand-built vectors (no embedding service).

const std = @import("std");
const testing = std.testing;
const embedder = @import("embedder.zig");
const store_mod = @import("store.zig");
const Store = store_mod.Store;

const dim = embedder.dim;

/// A unit vector with `1.0` at index `axis`. Distinct axes are orthogonal, so
/// inner-product ranking is predictable.
fn axisVec(a: std.mem.Allocator, axis: usize) ![]f32 {
    const v = try a.alloc(f32, dim);
    @memset(v, 0);
    v[axis % dim] = 1.0;
    return v;
}

const test_path = "agent-waymark-test.json";

fn cleanup(io: std.Io) void {
    const cwd = std.Io.Dir.cwd();
    cwd.deleteFile(io, test_path) catch {};
    cwd.deleteFile(io, test_path ++ ".tmp") catch {};
}

fn countOccurrences(haystack: []const u8, needle: []const u8) usize {
    var count: usize = 0;
    var start: usize = 0;
    while (std.mem.indexOf(u8, haystack[start..], needle)) |idx| {
        count += 1;
        start += idx + needle.len;
    }
    return count;
}

fn testIo() std.Io {
    const S = struct {
        var threaded = std.Io.Threaded.init_single_threaded;
    };
    return S.threaded.io();
}

test "record then recall ranks the nearest entry first" {
    const io = testIo();
    cleanup(io);
    defer cleanup(io);

    var store = try Store.init(testing.allocator, io, test_path);
    defer store.deinit();

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    _ = try store.record(.{ .kind = .finding, .scope = "repo:x", .body = "about apples", .embedding = try axisVec(a, 0) });
    const banana = try store.record(.{ .kind = .finding, .scope = "repo:x", .body = "about bananas", .embedding = try axisVec(a, 1) });
    _ = try store.record(.{ .kind = .finding, .scope = "repo:x", .body = "about cars", .embedding = try axisVec(a, 2) });

    try testing.expectEqual(@as(usize, 3), store.count());

    const hits = try store.recall(a, try axisVec(a, 1), "", null, 3);
    try testing.expect(hits.len >= 1);
    try testing.expectEqual(banana, hits[0].id);
    try testing.expectEqualStrings("about bananas", hits[0].body);
}

test "recallHybrid lets an exact identifier rescue a dense miss" {
    const io = testIo();
    cleanup(io);
    defer cleanup(io);

    var store = try Store.init(testing.allocator, io, test_path);
    defer store.deinit();

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // The query vector points at the apples entry, but the query text names
    // an identifier only the darwin entry contains. Fusion must surface the
    // lexical match despite the dense ranking disagreeing.
    _ = try store.record(.{ .kind = .finding, .scope = "repo:x", .body = "about apples", .embedding = try axisVec(a, 0) });
    const darwin = try store.record(.{ .kind = .finding, .scope = "repo:x", .body = "npm resolves to darwin-arm64", .embedding = try axisVec(a, 1) });

    const hits = try store.recallHybrid(a, "darwin-arm64", try axisVec(a, 0), "", null, 2);
    try testing.expectEqual(@as(usize, 2), hits.len);
    try testing.expectEqual(darwin, hits[0].id);

    // Without a lexical match the dense ranking decides, unchanged.
    const dense_only = try store.recallHybrid(a, "zzz qqq", try axisVec(a, 0), "", null, 2);
    try testing.expectEqualStrings("about apples", dense_only[0].body);
}

test "recall filters by scope and kind" {
    const io = testIo();
    cleanup(io);
    defer cleanup(io);

    var store = try Store.init(testing.allocator, io, test_path);
    defer store.deinit();

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    _ = try store.record(.{ .kind = .decision, .scope = "repo:a", .body = "decision in a", .embedding = try axisVec(a, 0) });
    _ = try store.record(.{ .kind = .todo, .scope = "repo:a", .body = "todo in a", .embedding = try axisVec(a, 1) });
    _ = try store.record(.{ .kind = .decision, .scope = "repo:b", .body = "decision in b", .embedding = try axisVec(a, 1) });

    // Query nearest to axis 1 (the todo / repo:b decision) but restrict to repo:a decisions.
    const hits = try store.recall(a, try axisVec(a, 1), "repo:a", .decision, 5);
    try testing.expectEqual(@as(usize, 1), hits.len);
    try testing.expectEqualStrings("decision in a", hits[0].body);
}

test "supersede marks the old entry inactive and links the new one" {
    const io = testIo();
    cleanup(io);
    defer cleanup(io);

    var store = try Store.init(testing.allocator, io, test_path);
    defer store.deinit();

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const old = try store.record(.{ .kind = .decision, .scope = "repo:x", .body = "use JWT", .embedding = try axisVec(a, 0) });
    const new = try store.record(.{ .kind = .decision, .scope = "repo:x", .body = "use sessions", .supersedes = old, .embedding = try axisVec(a, 0) });

    // Timeline of active decisions shows only the new one, linked back.
    const active = try store.timeline(a, "repo:x", .decision, 10);
    try testing.expectEqual(@as(usize, 1), active.len);
    try testing.expectEqual(new, active[0].id);
    try testing.expectEqual(old, active[0].supersedes.?);

    try testing.expectError(error.SupersedesUnknownId, store.record(.{
        .kind = .decision,
        .scope = "repo:x",
        .body = "bad",
        .supersedes = 9999,
        .embedding = try axisVec(a, 0),
    }));
}

test "header surfaces open todos and recent decisions, skipping superseded" {
    const io = testIo();
    cleanup(io);
    defer cleanup(io);

    var store = try Store.init(testing.allocator, io, test_path);
    defer store.deinit();

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    _ = try store.record(.{ .kind = .todo, .scope = "repo:x", .body = "wire up the hook kit", .embedding = try axisVec(a, 0) });
    const d1 = try store.record(.{ .kind = .decision, .scope = "repo:x", .body = "store owned by a daemon", .embedding = try axisVec(a, 1) });
    _ = try store.record(.{ .kind = .decision, .scope = "repo:x", .body = "store owned by the MCP process", .supersedes = d1, .embedding = try axisVec(a, 1) });
    _ = try store.record(.{ .kind = .note, .scope = "repo:other", .body = "unrelated", .embedding = try axisVec(a, 2) });

    const header = try store.header(a, "repo:x", 5, 5);
    try testing.expect(std.mem.indexOf(u8, header, "Current truth:") != null);
    try testing.expect(std.mem.indexOf(u8, header, "wire up the hook kit") != null);
    try testing.expect(std.mem.indexOf(u8, header, "store owned by a daemon") == null); // superseded
    try testing.expect(std.mem.indexOf(u8, header, "store owned by the MCP process") != null);
    try testing.expectEqual(@as(usize, 1), countOccurrences(header, "store owned by the MCP process"));
    try testing.expect(std.mem.indexOf(u8, header, "unrelated") == null); // other scope
}

test "done marks a todo inactive but keeps it" {
    const io = testIo();
    cleanup(io);
    defer cleanup(io);

    var store = try Store.init(testing.allocator, io, test_path);
    defer store.deinit();

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const t1 = try store.record(.{ .kind = .todo, .scope = "repo:x", .body = "ship hooks", .embedding = try axisVec(a, 0) });
    _ = try store.record(.{ .kind = .todo, .scope = "repo:x", .body = "ship installer", .embedding = try axisVec(a, 1) });

    try testing.expect(try store.resolve(t1));
    try testing.expect(!try store.resolve(9999)); // unknown id

    // Resolved todo drops out of the active timeline but the entry remains.
    const open = try store.timeline(a, "repo:x", .todo, 10);
    try testing.expectEqual(@as(usize, 1), open.len);
    try testing.expectEqualStrings("ship installer", open[0].body);
    try testing.expectEqual(@as(usize, 2), store.count());

    const header = try store.header(a, "repo:x", 5, 5);
    try testing.expect(std.mem.indexOf(u8, header, "ship installer") != null);
    try testing.expect(std.mem.indexOf(u8, header, "ship hooks") == null);
    try testing.expect(std.mem.indexOf(u8, header, "Open todos (1)") != null);
}

test "superseding a superseded entry follows to the chain head and inherits refs" {
    const io = testIo();
    cleanup(io);
    defer cleanup(io);

    var store = try Store.init(testing.allocator, io, test_path);
    defer store.deinit();

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const refs = [_][]const u8{"src/store.zig"};
    const v1 = try store.record(.{ .kind = .decision, .scope = "repo:x", .body = "v1", .refs = &refs, .embedding = try axisVec(a, 0) });
    const v2 = try store.record(.{ .kind = .decision, .scope = "repo:x", .body = "v2", .supersedes = v1, .embedding = try axisVec(a, 0) });

    // Supersede v1 again: it should replace the current head (v2), not fork.
    const v3 = try store.record(.{ .kind = .decision, .scope = "repo:x", .body = "v3", .supersedes = v1, .embedding = try axisVec(a, 0) });

    const active = try store.timeline(a, "repo:x", .decision, 10);
    try testing.expectEqual(@as(usize, 1), active.len);
    try testing.expectEqual(v3, active[0].id);
    try testing.expectEqual(v2, active[0].supersedes.?); // replaced the head, not v1
    // refs carried forward from v1 -> v2 -> v3 without being restated.
    try testing.expectEqual(@as(usize, 1), active[0].refs.len);
    try testing.expectEqualStrings("src/store.zig", active[0].refs[0]);
}

test "pinned entry stays in the header regardless of recency" {
    const io = testIo();
    cleanup(io);
    defer cleanup(io);

    var store = try Store.init(testing.allocator, io, test_path);
    defer store.deinit();
    store.now_override = 1_750_000_000;

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // A foundational decision, then enough newer decisions to push it past the
    // header's display limit.
    const thesis = try store.record(.{ .kind = .decision, .scope = "repo:x", .body = "THESIS: shared working-state, not generic memory", .embedding = try axisVec(a, 0) });
    for (0..6) |i| {
        _ = try store.record(.{ .kind = .decision, .scope = "repo:x", .body = "later decision", .embedding = try axisVec(a, i + 1) });
    }

    // Without a pin, the thesis is truncated out of the (max 3) decisions shown.
    {
        const h = try store.header(a, "repo:x", 3, 3);
        try testing.expect(std.mem.indexOf(u8, h, "THESIS") == null);
        try testing.expect(std.mem.indexOf(u8, h, "Pinned:") == null);
    }

    try testing.expect(try store.setPinned(thesis, true));
    try testing.expect(!try store.setPinned(9999, true)); // unknown id

    // Pinned, it appears in the Pinned section and no longer in the recency list.
    {
        const h = try store.header(a, "repo:x", 3, 3);
        try testing.expect(std.mem.indexOf(u8, h, "Pinned:") != null);
        try testing.expect(std.mem.indexOf(u8, h, "THESIS") != null);
        // The decisions count excludes the pinned thesis (6 later ones remain).
        try testing.expect(std.mem.indexOf(u8, h, "Recent decisions (6)") != null);
    }

    // Unpin returns it to recency-only behavior (truncated again).
    try testing.expect(try store.setPinned(thesis, false));
    {
        const h = try store.header(a, "repo:x", 3, 3);
        try testing.expect(std.mem.indexOf(u8, h, "Pinned:") == null);
        try testing.expect(std.mem.indexOf(u8, h, "THESIS") == null);
    }
}

test "touch confirms an existing entry without rewriting it" {
    const io = testIo();
    cleanup(io);
    defer cleanup(io);

    var store = try Store.init(testing.allocator, io, test_path);
    defer store.deinit();

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const id = try store.record(.{ .kind = .decision, .scope = "repo:x", .body = "still valid", .embedding = try axisVec(a, 0) });
    try testing.expect(try store.touch(id));
    try testing.expect(!try store.touch(9999));

    const hits = try store.timeline(a, "repo:x", .decision, 10);
    try testing.expectEqual(@as(usize, 1), hits.len);
    try testing.expectEqual(id, hits[0].id);
    try testing.expect(hits[0].confirmed_at != null);
    try testing.expect(hits[0].updated_at >= hits[0].created_at);

    const header = try store.header(a, "repo:x", 5, 5);
    try testing.expect(std.mem.indexOf(u8, header, "confirmed") != null);
}

test "nearestDuplicate finds a similar active entry" {
    const io = testIo();
    cleanup(io);
    defer cleanup(io);

    var store = try Store.init(testing.allocator, io, test_path);
    defer store.deinit();

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const first = try store.record(.{ .kind = .finding, .scope = "repo:x", .body = "same vector", .embedding = try axisVec(a, 0) });
    const duplicate = try store.nearestDuplicate(a, try axisVec(a, 0), "repo:x", 0.92);
    try testing.expect(duplicate != null);
    try testing.expectEqual(first, duplicate.?.id);

    const unrelated = try store.nearestDuplicate(a, try axisVec(a, 1), "repo:x", 0.92);
    try testing.expect(unrelated == null);
}

test "prompt activity nudges after several prompts and resets on write" {
    const io = testIo();
    cleanup(io);
    defer cleanup(io);

    var store = try Store.init(testing.allocator, io, test_path);
    defer store.deinit();

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    try testing.expect((try store.promptActivity(a)) == null);
    try testing.expect((try store.promptActivity(a)) == null);
    try testing.expect((try store.promptActivity(a)) == null);
    const nudge = try store.promptActivity(a);
    try testing.expect(nudge != null);
    try testing.expect(std.mem.indexOf(u8, nudge.?, "4 user prompts") != null);
    try testing.expect((try store.promptActivity(a)) == null);

    _ = try store.record(.{ .kind = .finding, .scope = "repo:x", .body = "reset counter", .embedding = try axisVec(a, 0) });
    try testing.expect((try store.promptActivity(a)) == null);
    try testing.expect((try store.promptActivity(a)) == null);
    try testing.expect((try store.promptActivity(a)) == null);
    try testing.expect((try store.promptActivity(a)) != null);
}

test "file refs are flagged when the referenced file changes" {
    const io = testIo();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var cwd = try TempCwd.enter(io, tmp.dir);
    defer cwd.restore();

    cleanup(io);
    defer cleanup(io);

    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = "tracked.txt", .data = "one\n" });

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const root = try std.process.currentPathAlloc(io, a);
    const scope = try std.fmt.allocPrint(a, "repo:{s}", .{root});
    const refs = [_][]const u8{"tracked.txt:1"};

    var store = try Store.init(testing.allocator, io, test_path);
    defer store.deinit();

    const id = try store.record(.{
        .kind = .finding,
        .scope = scope,
        .worktree_root = root,
        .body = "tracked file says one",
        .refs = &refs,
        .embedding = try axisVec(a, 0),
    });

    {
        const hits = try store.timeline(a, scope, .finding, 10);
        try testing.expectEqual(@as(usize, 1), hits.len);
        try testing.expectEqual(@as(usize, 0), hits[0].ref_statuses.len);
    }

    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = "tracked.txt", .data = "two\n" });

    {
        const hits = try store.timeline(a, scope, .finding, 10);
        try testing.expectEqual(@as(usize, 1), hits.len);
        try testing.expectEqual(@as(usize, 1), hits[0].ref_statuses.len);
        try testing.expectEqualStrings("changed", hits[0].ref_statuses[0].status);
        try testing.expectEqualStrings("tracked.txt:1", hits[0].ref_statuses[0].ref);
    }

    const header = try store.header(a, scope, 5, 5);
    try testing.expect(std.mem.indexOf(u8, header, "refs changed: tracked.txt:1") != null);
    try testing.expect(std.mem.indexOf(u8, header, "refs refresh") != null);
    try testing.expect(std.mem.indexOf(u8, header, "refs move") != null);
    try testing.expect(std.mem.indexOf(u8, header, "refs dismiss") != null);
    try testing.expect(std.mem.indexOf(u8, header, try std.fmt.allocPrint(a, "touch #{d}", .{id})) != null);
    try testing.expectEqual(@as(usize, 1), countOccurrences(header, "tracked file says one"));
}

test "ref maintenance refreshes, moves, and dismisses file refs" {
    const io = testIo();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var cwd = try TempCwd.enter(io, tmp.dir);
    defer cwd.restore();

    cleanup(io);
    defer cleanup(io);

    const dir = std.Io.Dir.cwd();
    try dir.writeFile(io, .{ .sub_path = "ChatSessionHandler.ts", .data = "one\n" });

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const root = try std.process.currentPathAlloc(io, a);
    const scope = try std.fmt.allocPrint(a, "repo:{s}", .{root});
    const refs = [_][]const u8{"ChatSessionHandler.ts:1"};

    var store = try Store.init(testing.allocator, io, test_path);
    defer store.deinit();

    const id = try store.record(.{
        .kind = .finding,
        .scope = scope,
        .worktree_root = root,
        .body = "session handler says one",
        .refs = &refs,
        .embedding = try axisVec(a, 0),
    });

    try dir.writeFile(io, .{ .sub_path = "ChatSessionHandler.ts", .data = "two\n" });
    {
        const hits = try store.timeline(a, scope, .finding, 10);
        try testing.expectEqual(@as(usize, 1), hits[0].ref_statuses.len);
        try testing.expectEqualStrings("changed", hits[0].ref_statuses[0].status);
    }

    const refreshed = (try store.refreshRefs(id)).?;
    try testing.expectEqual(@as(usize, 1), refreshed.touched);
    try testing.expectEqual(@as(usize, 0), refreshed.missing);
    {
        const hits = try store.timeline(a, scope, .finding, 10);
        try testing.expectEqual(@as(usize, 0), hits[0].ref_statuses.len);
    }

    try dir.rename("ChatSessionHandler.ts", dir, "AgentSessionLifecycleService.ts", io);
    {
        const hits = try store.timeline(a, scope, .finding, 10);
        try testing.expectEqual(@as(usize, 1), hits[0].ref_statuses.len);
        try testing.expectEqualStrings("missing", hits[0].ref_statuses[0].status);
        try testing.expect(hits[0].ref_statuses[0].suggestion != null);
        try testing.expect(std.mem.endsWith(u8, hits[0].ref_statuses[0].suggestion.?, "AgentSessionLifecycleService.ts"));
    }

    _ = (try store.moveRef(id, "ChatSessionHandler.ts:1", "AgentSessionLifecycleService.ts:1", root)).?;
    {
        const hits = try store.timeline(a, scope, .finding, 10);
        try testing.expectEqual(@as(usize, 1), hits[0].refs.len);
        try testing.expectEqualStrings("AgentSessionLifecycleService.ts:1", hits[0].refs[0]);
        try testing.expectEqual(@as(usize, 0), hits[0].ref_statuses.len);
    }

    try dir.deleteFile(io, "AgentSessionLifecycleService.ts");
    {
        const hits = try store.timeline(a, scope, .finding, 10);
        try testing.expectEqual(@as(usize, 1), hits[0].ref_statuses.len);
        try testing.expectEqualStrings("missing", hits[0].ref_statuses[0].status);
    }

    _ = (try store.dismissRef(id, "AgentSessionLifecycleService.ts:1")).?;
    {
        const hits = try store.timeline(a, scope, .finding, 10);
        try testing.expectEqual(@as(usize, 0), hits[0].refs.len);
        try testing.expectEqual(@as(usize, 0), hits[0].ref_statuses.len);
    }
}

test "handoff groups active entries by role" {
    const io = testIo();
    cleanup(io);
    defer cleanup(io);

    var store = try Store.init(testing.allocator, io, test_path);
    defer store.deinit();

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    _ = try store.record(.{ .kind = .decision, .scope = "repo:x", .body = "use the daemon-owned store", .embedding = try axisVec(a, 0) });
    _ = try store.record(.{ .kind = .todo, .scope = "repo:x", .body = "close the stale refs", .embedding = try axisVec(a, 1) });
    _ = try store.record(.{ .kind = .finding, .scope = "repo:x", .body = "sub-agents share the socket", .embedding = try axisVec(a, 2) });
    _ = try store.record(.{ .kind = .rejected, .scope = "repo:x", .body = "do not keep per-process stores", .embedding = try axisVec(a, 3) });
    _ = try store.record(.{ .kind = .artifact, .scope = "repo:x", .body = "PR #42 contains the migration", .embedding = try axisVec(a, 4) });

    const handoff = try store.handoff(a, "repo:x", 3);
    try testing.expect(std.mem.indexOf(u8, handoff, "# For the next agent") != null);
    try testing.expect(std.mem.indexOf(u8, handoff, "Current decisions:") != null);
    try testing.expect(std.mem.indexOf(u8, handoff, "Open todos:") != null);
    try testing.expect(std.mem.indexOf(u8, handoff, "Open risks and findings:") != null);
    try testing.expect(std.mem.indexOf(u8, handoff, "Dead ends to avoid:") != null);
    try testing.expect(std.mem.indexOf(u8, handoff, "Relevant artifacts:") != null);
    try testing.expect(std.mem.indexOf(u8, handoff, "Close loop:") != null);
}

test "handoff lists cleanup candidates for duplicates and addressed todos" {
    const io = testIo();
    cleanup(io);
    defer cleanup(io);

    var store = try Store.init(testing.allocator, io, test_path);
    defer store.deinit();

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // Two decisions on the same axis: cosine 1.0, a duplicate pair.
    _ = try store.record(.{ .kind = .decision, .scope = "repo:x", .body = "daemon owns the store", .embedding = try axisVec(a, 0) });
    _ = try store.record(.{ .kind = .decision, .scope = "repo:x", .body = "the store is owned by the daemon", .embedding = try axisVec(a, 0) });

    // A todo, then a later finding at cosine 0.8 to it: addressed candidate.
    _ = try store.record(.{ .kind = .todo, .scope = "repo:x", .body = "fix the socket race", .embedding = try axisVec(a, 1) });
    const mixed = try a.alloc(f32, dim);
    @memset(mixed, 0);
    mixed[1] = 0.8;
    mixed[2] = 0.6;
    _ = try store.record(.{ .kind = .finding, .scope = "repo:x", .body = "socket race fixed by the accept loop rewrite", .embedding = mixed });

    const handoff = try store.handoff(a, "repo:x", 5);
    try testing.expect(std.mem.indexOf(u8, handoff, "Cleanup candidates:") != null);
    try testing.expect(std.mem.indexOf(u8, handoff, "#1 and #2 look like duplicates") != null);
    try testing.expect(std.mem.indexOf(u8, handoff, "todo #3 may already be addressed by #4 (finding)") != null);
}

test "scopeVisible is hierarchical (repo-wide inherited, branch isolated)" {
    const v = store_mod.scopeVisible;
    const repo = "repo:/p";
    const branch = "repo:/p/branch/feature-x";
    const other = "repo:/p/branch/other";

    // Repo-wide entry is visible from a branch query and the repo query.
    try testing.expect(v(repo, branch));
    try testing.expect(v(repo, repo));
    // Branch-local entry: visible on its branch, not on repo-wide or other branch.
    try testing.expect(v(branch, branch));
    try testing.expect(!v(branch, repo));
    try testing.expect(!v(other, branch));
    // Segment-safe: a prefix that isn't a path boundary doesn't match.
    try testing.expect(!v("repo:/p/branch/feat", branch));
    // Empty query matches all; empty (global) entry scope is visible anywhere.
    try testing.expect(v(branch, ""));
    try testing.expect(v("", branch));
}

test "recall and timeline see repo-wide entries from a branch scope" {
    const io = testIo();
    cleanup(io);
    defer cleanup(io);

    var store = try Store.init(testing.allocator, io, test_path);
    defer store.deinit();

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const repo = "repo:/p";
    const branch = "repo:/p/branch/feature-x";
    _ = try store.record(.{ .kind = .decision, .scope = repo, .body = "repo-wide decision", .embedding = try axisVec(a, 0) });
    _ = try store.record(.{ .kind = .todo, .scope = branch, .body = "branch task", .embedding = try axisVec(a, 1) });

    // From the branch: both the repo-wide decision and the branch todo are visible.
    const on_branch = try store.timeline(a, branch, null, 10);
    try testing.expectEqual(@as(usize, 2), on_branch.len);

    // From repo-wide scope: only the repo-wide decision (branch todo hidden).
    const on_repo = try store.timeline(a, repo, null, 10);
    try testing.expectEqual(@as(usize, 1), on_repo.len);
    try testing.expectEqualStrings("repo-wide decision", on_repo[0].body);

    // Recall at the branch scope can still reach the repo-wide entry.
    const hits = try store.recall(a, try axisVec(a, 0), branch, null, 5);
    try testing.expect(hits.len >= 1);
    try testing.expectEqualStrings("repo-wide decision", hits[0].body);
}

test "forget removes an entry" {
    const io = testIo();
    cleanup(io);
    defer cleanup(io);

    var store = try Store.init(testing.allocator, io, test_path);
    defer store.deinit();

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const id = try store.record(.{ .kind = .note, .scope = "repo:x", .body = "ephemeral", .embedding = try axisVec(a, 0) });
    try testing.expectEqual(@as(usize, 1), store.count());
    try testing.expect(try store.forget(id));
    try testing.expectEqual(@as(usize, 0), store.count());
    try testing.expect(!try store.forget(id));
}

test "persistence survives reopen" {
    const io = testIo();
    cleanup(io);
    defer cleanup(io);

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var first_id: u64 = undefined;
    {
        var store = try Store.init(testing.allocator, io, test_path);
        defer store.deinit();
        const refs = [_][]const u8{"src/store.zig"};
        first_id = try store.record(.{ .kind = .decision, .scope = "repo:x", .body = "durable decision", .refs = &refs, .embedding = try axisVec(a, 3) });
        _ = try store.record(.{ .kind = .finding, .scope = "repo:x", .body = "another", .embedding = try axisVec(a, 4) });
    }

    // Reopen from disk. Vectors and metadata rebuild from the snapshot.
    var store = try Store.init(testing.allocator, io, test_path);
    defer store.deinit();
    try testing.expectEqual(@as(usize, 2), store.count());

    const hits = try store.recall(a, try axisVec(a, 3), "", null, 1);
    try testing.expectEqual(@as(usize, 1), hits.len);
    try testing.expectEqual(first_id, hits[0].id);
    try testing.expectEqualStrings("durable decision", hits[0].body);
    try testing.expectEqual(@as(usize, 1), hits[0].refs.len);
    try testing.expectEqualStrings("src/store.zig", hits[0].refs[0]);

    // next_id must continue past the reloaded ids (no reuse).
    const new_id = try store.record(.{ .kind = .note, .scope = "repo:x", .body = "post-reload", .embedding = try axisVec(a, 5) });
    try testing.expect(new_id > first_id);
}

const TempCwd = struct {
    io: std.Io,
    old_path: [:0]u8,

    fn enter(io: std.Io, dir: std.Io.Dir) !TempCwd {
        const old_path = try std.process.currentPathAlloc(io, std.testing.allocator);
        errdefer std.testing.allocator.free(old_path);
        try std.process.setCurrentDir(io, dir);
        return .{ .io = io, .old_path = old_path };
    }

    fn restore(self: *TempCwd) void {
        std.process.setCurrentPath(self.io, self.old_path) catch {};
        std.testing.allocator.free(self.old_path);
        self.* = undefined;
    }
};

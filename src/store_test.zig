//! Store tests using deterministic hand-built vectors (no embedding service).

const std = @import("std");
const testing = std.testing;
const embedder = @import("embedder.zig");
const store_mod = @import("store.zig");
const Store = store_mod.Store;

const dim = embedder.dim;

/// A unit vector with `1.0` at index `axis` — distinct axes are orthogonal, so
/// inner-product ranking is predictable.
fn axisVec(a: std.mem.Allocator, axis: usize) ![]f32 {
    const v = try a.alloc(f32, dim);
    @memset(v, 0);
    v[axis % dim] = 1.0;
    return v;
}

const test_path = "cairn-test.json";

fn cleanup(io: std.Io) void {
    const cwd = std.Io.Dir.cwd();
    cwd.deleteFile(io, test_path) catch {};
    cwd.deleteFile(io, test_path ++ ".tmp") catch {};
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
    try testing.expect(std.mem.indexOf(u8, header, "wire up the hook kit") != null);
    try testing.expect(std.mem.indexOf(u8, header, "store owned by a daemon") == null); // superseded
    try testing.expect(std.mem.indexOf(u8, header, "store owned by the MCP process") != null);
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

    // Reopen from disk — vectors and metadata rebuild from the snapshot.
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

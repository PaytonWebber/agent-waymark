//! Lexical ranking for hybrid recall: BM25 over a candidate slice, plus
//! reciprocal-rank fusion to combine it with the dense ranking.
//!
//! Waymark entries are identifier-heavy (file paths, symbols, env var names),
//! and exact rare tokens are precisely where a small static embedding model
//! is weakest. BM25 covers that side; the dense index covers paraphrase. At
//! this store's scale (hundreds to low thousands of short entries) scoring is
//! brute force over the candidates, which is far below a millisecond; an
//! inverted index would be pure overhead.

const std = @import("std");

const k1: f32 = 1.2;
const b: f32 = 0.75;

pub const Doc = struct {
    id: u64,
    text: []const u8,
};

pub const Scored = struct {
    id: u64,
    score: f32,
};

/// Rank `docs` against `query` with BM25, descending, dropping zero scores.
/// Everything is allocated from `arena`.
pub fn rank(arena: std.mem.Allocator, docs: []const Doc, query: []const u8) ![]Scored {
    if (docs.len == 0) return &.{};

    var terms = try tokenize(arena, query);
    if (terms.items.len == 0) return &.{};
    dedup(&terms);

    // One token-frequency map per doc; docs are short, so this is cheap.
    const doc_tfs = try arena.alloc(std.StringHashMapUnmanaged(u32), docs.len);
    var total_len: usize = 0;
    for (docs, doc_tfs) |doc, *tf| {
        tf.* = .empty;
        const tokens = try tokenize(arena, doc.text);
        total_len += tokens.items.len;
        for (tokens.items) |t| {
            const gop = try tf.getOrPut(arena, t);
            gop.value_ptr.* = if (gop.found_existing) gop.value_ptr.* + 1 else 1;
        }
    }
    const avg_len: f32 = @as(f32, @floatFromInt(total_len)) / @as(f32, @floatFromInt(docs.len));

    var scored = try std.ArrayList(Scored).initCapacity(arena, docs.len);
    const n: f32 = @floatFromInt(docs.len);
    for (terms.items) |term| {
        var df: f32 = 0;
        for (doc_tfs) |tf| {
            if (tf.contains(term)) df += 1;
        }
        if (df == 0) continue;
        // Terms in more than half the candidates are effectively stopwords
        // ("the", "how", a ubiquitous module name). Scoring them lets fusion
        // promote noise over a clean dense ranking, so drop them; a corpus
        // frequency cut adapts to the store's own vocabulary where a fixed
        // stopword list would not.
        if (df / n > 0.5) continue;
        const idf = @log(1.0 + (n - df + 0.5) / (df + 0.5));

        for (docs, doc_tfs, 0..) |_, tf, i| {
            const freq: f32 = @floatFromInt(tf.get(term) orelse continue);
            var doc_len: f32 = 0;
            var it = tf.valueIterator();
            while (it.next()) |v| doc_len += @floatFromInt(v.*);
            const norm = freq * (k1 + 1) / (freq + k1 * (1 - b + b * doc_len / @max(avg_len, 1)));

            ensureScoredLen(&scored, docs, i);
            scored.items[i].score += idf * norm;
        }
    }

    var out = try std.ArrayList(Scored).initCapacity(arena, scored.items.len);
    for (scored.items) |s| {
        if (s.score > 0) out.appendAssumeCapacity(s);
    }
    std.mem.sort(Scored, out.items, {}, scoreDesc);
    return out.items;
}

fn ensureScoredLen(scored: *std.ArrayList(Scored), docs: []const Doc, idx: usize) void {
    while (scored.items.len <= idx) {
        scored.appendAssumeCapacity(.{ .id = docs[scored.items.len].id, .score = 0 });
    }
}

fn scoreDesc(_: void, a: Scored, x: Scored) bool {
    return a.score > x.score;
}

/// Reciprocal-rank fusion: combine ranked id lists into one ranking. An id's
/// fused score is the sum of 1/(60+rank) over the lists it appears in, so
/// agreement between rankings outranks a high position in just one.
pub fn rrf(arena: std.mem.Allocator, rankings: []const []const u64) ![]u64 {
    var scores: std.AutoArrayHashMapUnmanaged(u64, f32) = .empty;
    for (rankings) |ranking| {
        for (ranking, 0..) |id, pos| {
            const gop = try scores.getOrPut(arena, id);
            const contribution = 1.0 / (60.0 + @as(f32, @floatFromInt(pos)) + 1.0);
            gop.value_ptr.* = if (gop.found_existing) gop.value_ptr.* + contribution else contribution;
        }
    }

    const Pair = struct { id: u64, score: f32 };
    var pairs = try std.ArrayList(Pair).initCapacity(arena, scores.count());
    var it = scores.iterator();
    while (it.next()) |entry| {
        pairs.appendAssumeCapacity(.{ .id = entry.key_ptr.*, .score = entry.value_ptr.* });
    }
    std.mem.sort(Pair, pairs.items, {}, struct {
        fn desc(_: void, a: Pair, x: Pair) bool {
            return a.score > x.score;
        }
    }.desc);

    const out = try arena.alloc(u64, pairs.items.len);
    for (pairs.items, out) |p, *o| o.* = p.id;
    return out;
}

/// Lowercased runs of alphanumerics plus '_', so identifiers like
/// AGENT_WAYMARK_SOCKET stay one token while darwin-arm64 splits in two.
/// Stopwords are dropped here as well as by the corpus-frequency cut in
/// `rank`: in a small store, "and" or "a" can have low document frequency,
/// and their matches would otherwise let fusion bury a clean dense ranking
/// under cosine-0.03 noise.
fn tokenize(arena: std.mem.Allocator, text: []const u8) !std.ArrayList([]const u8) {
    var out: std.ArrayList([]const u8) = .empty;
    var start: ?usize = null;
    for (text, 0..) |c, i| {
        const word_char = std.ascii.isAlphanumeric(c) or c == '_';
        if (word_char and start == null) start = i;
        if (!word_char and start != null) {
            try appendToken(arena, &out, text[start.?..i]);
            start = null;
        }
    }
    if (start) |s| try appendToken(arena, &out, text[s..]);
    return out;
}

fn appendToken(arena: std.mem.Allocator, out: *std.ArrayList([]const u8), raw: []const u8) !void {
    const lowered = try std.ascii.allocLowerString(arena, raw);
    if (isStopword(lowered)) return;
    try out.append(arena, lowered);
}

const stopwords = [_][]const u8{
    "a",    "an",   "and",  "are",  "as",    "at",    "be",   "but",  "by",
    "do",   "does", "for",  "from", "had",   "has",   "have", "how",  "i",
    "if",   "in",   "is",   "it",   "its",   "no",    "not",  "of",   "on",
    "or",   "so",   "that", "the",  "their", "there", "they", "this", "to",
    "was",  "we",   "what", "when", "where", "which", "who",  "why",  "will",
    "with", "you",  "your",
};

fn isStopword(token: []const u8) bool {
    for (stopwords) |s| {
        if (std.mem.eql(u8, token, s)) return true;
    }
    return false;
}

fn dedup(terms: *std.ArrayList([]const u8)) void {
    var n: usize = 0;
    outer: for (terms.items) |t| {
        for (terms.items[0..n]) |kept| {
            if (std.mem.eql(u8, t, kept)) continue :outer;
        }
        terms.items[n] = t;
        n += 1;
    }
    terms.shrinkRetainingCapacity(n);
}

// ============================================================================
// Tests
// ============================================================================

const testing = std.testing;

test "rank puts exact identifier matches first" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const docs = [_]Doc{
        .{ .id = 1, .text = "the daemon owns the store" },
        .{ .id = 2, .text = "the Apple Silicon npm package resolves to darwin-arm64" },
        .{ .id = 3, .text = "wire the hosted backend auth check" },
    };

    const hits = try rank(arena.allocator(), &docs, "darwin-arm64 package");
    try testing.expect(hits.len >= 1);
    try testing.expectEqual(@as(u64, 2), hits[0].id);
}

test "rank keeps underscored identifiers whole and drops non-matches" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const docs = [_]Doc{
        .{ .id = 1, .text = "the AGENT_WAYMARK_SOCKET env var sets the socket path" },
        .{ .id = 2, .text = "sockets are a unix thing" },
    };

    const hits = try rank(arena.allocator(), &docs, "AGENT_WAYMARK_SOCKET");
    try testing.expectEqual(@as(usize, 1), hits.len);
    try testing.expectEqual(@as(u64, 1), hits[0].id);
}

test "rank weights rare terms above common ones" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    // "store" appears everywhere; "corrupt" only in doc 2.
    const docs = [_]Doc{
        .{ .id = 1, .text = "the store holds entries" },
        .{ .id = 2, .text = "per-process stores corrupt the store" },
        .{ .id = 3, .text = "the store is a json snapshot" },
    };

    const hits = try rank(arena.allocator(), &docs, "corrupt store");
    try testing.expectEqual(@as(u64, 2), hits[0].id);
}

test "rank handles empty query and empty docs" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    try testing.expectEqual(@as(usize, 0), (try rank(arena.allocator(), &.{}, "anything")).len);
    const docs = [_]Doc{.{ .id = 1, .text = "something" }};
    try testing.expectEqual(@as(usize, 0), (try rank(arena.allocator(), &docs, "")).len);
    try testing.expectEqual(@as(usize, 0), (try rank(arena.allocator(), &docs, "!!! ???")).len);
}

test "rrf rewards agreement between rankings" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    // id 7 is second in both lists; id 1 and id 9 each top one list only.
    const dense = [_]u64{ 1, 7, 3 };
    const lex = [_]u64{ 9, 7 };
    const fused = try rrf(arena.allocator(), &.{ &dense, &lex });

    try testing.expectEqual(@as(u64, 7), fused[0]);
    try testing.expectEqual(@as(usize, 4), fused.len);
}

//! The daemon owns the one Store and serves the internal protocol over a unix
//! socket. Clients (the MCP bridge, the hook CLI) are thin and stateless; all
//! durable state lives here. This single-owner design is what keeps a user's
//! main session and its sub-agents (separate processes) from corrupting a
//! shared store, and the socket protocol is the seam the team HTTP backend
//! reuses.
//!
//! Concurrency: a pool of workers each accept and serve connections, so a
//! long-lived client (the MCP bridge holds its connection for the whole
//! session) never blocks a transient one (a hook or CLI call). An RwLock guards
//! the store — shared for reads, exclusive for writes — and the slow embedding
//! call happens outside the lock. The allocator is the thread-safe smp
//! allocator, since workers allocate concurrently.

const std = @import("std");
const embedder = @import("embedder.zig");
const extractor = @import("extractor.zig");
const entry_mod = @import("entry.zig");
const store_mod = @import("store.zig");
const protocol = @import("protocol.zig");

const Allocator = std.mem.Allocator;
const Store = store_mod.Store;
const EntryKind = entry_mod.EntryKind;
const Request = protocol.Request;
const Response = protocol.Response;

const buffer_size = 512 * 1024; // embeddings ~10KB; the sweep sends a transcript tail
const worker_count = 8;

/// Default cosine above which a swept candidate is treated as already known and
/// skipped. Catches obvious repeats and near-paraphrases; genuinely distinct
/// entries rarely exceed it. Tunable per embedding model via CAIRN_SWEEP_DEDUP.
pub const default_sweep_dedup: f32 = 0.85;

pub const Config = struct {
    socket_path: []const u8,
    store_path: []const u8,
    embed: embedder.Config = .{},
    extract: extractor.Config = .{},
    sweep_dedup: f32 = default_sweep_dedup,
};

/// Shared, long-lived state handed to every worker. Lives in `run`'s frame,
/// which stays alive (blocked in `group.await`) for the daemon's lifetime.
const Server = struct {
    store: *Store,
    lock: *std.Io.RwLock,
    listener: *std.Io.net.Server,
    cfg: Config,
};

/// Open the store and serve until the process is killed. The socket file is
/// removed on startup (clearing a stale socket from a prior crash) and on exit.
pub fn run(io: std.Io, cfg: Config) !void {
    const allocator = std.heap.smp_allocator;

    var store = try Store.init(allocator, io, cfg.store_path);
    defer store.deinit();
    var lock: std.Io.RwLock = .init;

    const cwd = std.Io.Dir.cwd();
    cwd.deleteFile(io, cfg.socket_path) catch {}; // clear a stale socket

    const addr = try std.Io.net.UnixAddress.init(cfg.socket_path);
    var listener = try addr.listen(io, .{});
    defer {
        listener.deinit(io);
        cwd.deleteFile(io, cfg.socket_path) catch {};
    }

    var server: Server = .{ .store = &store, .lock = &lock, .listener = &listener, .cfg = cfg };

    var group: std.Io.Group = .init;
    defer group.cancel(io);
    var spawned: usize = 0;
    while (spawned < worker_count) : (spawned += 1) {
        group.concurrent(io, worker, .{ allocator, io, &server }) catch break;
    }
    if (spawned == 0) return worker(allocator, io, &server); // no concurrency: serve inline
    group.await(io) catch {};
}

fn worker(allocator: Allocator, io: std.Io, server: *Server) void {
    while (true) {
        const stream = server.listener.accept(io) catch |err| switch (err) {
            error.Canceled => return,
            else => continue,
        };
        handleConn(allocator, io, server, stream);
    }
}

/// Handle one connection: read request lines until the client disconnects,
/// answering each. A malformed or failing request gets an error response but
/// does not drop the connection.
fn handleConn(allocator: Allocator, io: std.Io, server: *Server, stream: std.Io.net.Stream) void {
    defer stream.close(io);
    const rbuf = allocator.alloc(u8, buffer_size) catch return;
    defer allocator.free(rbuf);
    const wbuf = allocator.alloc(u8, buffer_size) catch return;
    defer allocator.free(wbuf);

    var reader = stream.reader(io, rbuf);
    var writer = stream.writer(io, wbuf);

    while (true) {
        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();
        const a = arena.allocator();

        const parsed = protocol.readLine(Request, a, &reader.interface) catch |err| switch (err) {
            error.EndOfStream => return, // client closed
            else => {
                protocol.writeLine(a, &writer.interface, Response.err("malformed request")) catch return;
                continue;
            },
        };

        const resp = dispatch(a, io, server, parsed.value) catch |err|
            Response.err(@errorName(err));
        protocol.writeLine(a, &writer.interface, resp) catch return;
    }
}

fn dispatch(a: Allocator, io: std.Io, server: *Server, req: Request) !Response {
    const op = req.op;
    const store = server.store;
    const lock = server.lock;
    if (std.mem.eql(u8, op, "ping")) return .{ .ok = true, .text = "pong" };

    if (std.mem.eql(u8, op, "record")) {
        const kind_str = req.kind orelse return Response.err("record requires kind");
        const kind = EntryKind.fromString(kind_str) orelse return Response.err("unknown kind");
        const body = req.body orelse return Response.err("record requires body");
        // Embed outside the lock; the model call is the slow part.
        const vec = resolveVector(a, io, server.cfg, req, body) catch |e| return embedErr(e);
        lock.lockUncancelable(io);
        defer lock.unlock(io);
        const id = store.record(.{
            .kind = kind,
            .scope = req.scope orelse "",
            .body = body,
            .refs = req.refs orelse &.{},
            .author = req.author orelse "",
            .supersedes = req.supersedes,
            .embedding = vec,
        }) catch |e| return Response.err(@errorName(e));
        return .{ .ok = true, .id = id, .count = store.count() };
    }

    if (std.mem.eql(u8, op, "recall")) {
        const query = req.text orelse return Response.err("recall requires query text");
        const vec = resolveVector(a, io, server.cfg, req, query) catch |e| return embedErr(e);
        lock.lockSharedUncancelable(io);
        defer lock.unlockShared(io);
        const hits = try store.recall(a, vec, req.scope orelse "", optKind(req.kind), req.limit orelse 5);
        return hitsResponse(a, hits);
    }

    if (std.mem.eql(u8, op, "timeline")) {
        lock.lockSharedUncancelable(io);
        defer lock.unlockShared(io);
        const hits = try store.timeline(a, req.scope orelse "", optKind(req.kind), req.limit orelse 20);
        return hitsResponse(a, hits);
    }

    if (std.mem.eql(u8, op, "header")) {
        lock.lockSharedUncancelable(io);
        defer lock.unlockShared(io);
        const text = try store.header(a, req.scope orelse "", req.limit orelse 5, req.limit orelse 5);
        return .{ .ok = true, .text = text };
    }

    if (std.mem.eql(u8, op, "done")) {
        const id = req.id orelse return Response.err("done requires id");
        lock.lockUncancelable(io);
        defer lock.unlock(io);
        if (!try store.resolve(id)) return Response.err("unknown id");
        return .{ .ok = true, .count = store.count() };
    }

    if (std.mem.eql(u8, op, "sweep")) {
        const transcript = req.text orelse return Response.err("sweep requires text");
        const scope = req.scope orelse "";
        // Extraction (a model generation) and embedding are slow and run outside
        // the lock; only the per-candidate dedup-and-record touches the store.
        const cands = extractor.extract(io, a, server.cfg.extract, transcript);
        var recorded: usize = 0;
        for (cands) |c| {
            if (c.body.len < 8) continue; // drop empties and leftover placeholders
            const kind = fuzzyKind(c.kind);
            const vec = embedder.embed(io, a, server.cfg.embed, c.body) catch continue;
            if (recordIfNew(a, io, store, lock, scope, kind, c.body, vec, server.cfg.sweep_dedup)) recorded += 1;
        }
        return .{ .ok = true, .count = recorded };
    }

    if (std.mem.eql(u8, op, "pin") or std.mem.eql(u8, op, "unpin")) {
        const id = req.id orelse return Response.err("pin requires id");
        lock.lockUncancelable(io);
        defer lock.unlock(io);
        if (!try store.setPinned(id, std.mem.eql(u8, op, "pin"))) return Response.err("unknown id");
        return .{ .ok = true, .count = store.count() };
    }

    if (std.mem.eql(u8, op, "forget")) {
        const id = req.id orelse return Response.err("forget requires id");
        lock.lockUncancelable(io);
        defer lock.unlock(io);
        if (!try store.forget(id)) return Response.err("unknown id");
        return .{ .ok = true, .count = store.count() };
    }

    return Response.err("unknown op");
}

/// Record a swept candidate unless a near-identical entry already exists in
/// scope. Holds the write lock for the dedup check plus the insert so the two
/// are atomic. Returns whether it recorded.
fn recordIfNew(
    a: std.mem.Allocator,
    io: std.Io,
    store: *Store,
    lock: *std.Io.RwLock,
    scope: []const u8,
    kind: EntryKind,
    body: []const u8,
    vec: []const f32,
    dedup_threshold: f32,
) bool {
    lock.lockUncancelable(io);
    defer lock.unlock(io);

    const hits = store.recall(a, vec, scope, null, 1) catch return false;
    if (hits.len > 0 and hits[0].score >= dedup_threshold) return false;

    _ = store.record(.{
        .kind = kind,
        .scope = scope,
        .body = body,
        .author = "cairn-sweep",
        .embedding = vec,
    }) catch return false;
    return true;
}

/// Resolve the vector for a request: a precomputed `embedding` (validated) or
/// embed `text` via the model.
fn resolveVector(a: Allocator, io: std.Io, cfg: Config, req: Request, text: []const u8) ![]const f32 {
    if (req.embedding) |v| {
        if (v.len != embedder.dim) return error.EmbeddingDimMismatch;
        return v;
    }
    return embedder.embed(io, a, cfg.embed, text);
}

fn optKind(s: ?[]const u8) ?EntryKind {
    return if (s) |str| EntryKind.fromString(str) else null;
}

/// Lenient kind for swept candidates: an extraction model may return a wrong
/// case or echo the enum list, so map to the closest real kind rather than drop
/// the entry. Falls back to `note`.
fn fuzzyKind(s: []const u8) EntryKind {
    var buf: [40]u8 = undefined;
    const n = @min(s.len, buf.len);
    const low = std.ascii.lowerString(buf[0..n], s[0..n]);
    if (EntryKind.fromString(low)) |k| return k;
    if (std.mem.indexOf(u8, low, "reject") != null or std.mem.indexOf(u8, low, "dead") != null) return .rejected;
    if (std.mem.indexOf(u8, low, "todo") != null) return .todo;
    if (std.mem.indexOf(u8, low, "deci") != null) return .decision;
    if (std.mem.indexOf(u8, low, "find") != null or std.mem.indexOf(u8, low, "found") != null) return .finding;
    return .note;
}

fn hitsResponse(a: Allocator, hits: []entry_mod.Hit) !Response {
    const rows = try a.alloc(protocol.HitJson, hits.len);
    for (hits, rows) |h, *r| r.* = protocol.HitJson.from(h);
    return .{ .ok = true, .count = hits.len, .hits = rows };
}

fn embedErr(err: anyerror) Response {
    return switch (err) {
        error.EmbeddingDimMismatch => Response.err("embedding dimension does not match the configured model"),
        error.EmbeddingHttpError => Response.err("could not reach the embedding service (is Ollama running?)"),
        else => Response.err("failed to generate embedding"),
    };
}

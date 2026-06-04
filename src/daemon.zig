//! The daemon owns the one Store and serves the internal protocol over a unix
//! socket, one request at a time. Clients (the MCP bridge, the hook CLI) are
//! thin and stateless; all durable state lives here. This single-owner design
//! is what keeps a user's main session and its sub-agents (separate processes)
//! from corrupting a shared store, and the socket protocol is the seam the
//! team HTTP backend reuses.

const std = @import("std");
const embedder = @import("embedder.zig");
const entry_mod = @import("entry.zig");
const store_mod = @import("store.zig");
const protocol = @import("protocol.zig");

const Allocator = std.mem.Allocator;
const Store = store_mod.Store;
const EntryKind = entry_mod.EntryKind;
const Request = protocol.Request;
const Response = protocol.Response;

const buffer_size = 256 * 1024; // embeddings are ~10KB of JSON; leave headroom

pub const Config = struct {
    socket_path: []const u8,
    store_path: []const u8,
    embed: embedder.Config = .{},
};

/// Open the store and serve until the process is killed. The socket file is
/// removed on a clean exit and on startup (clearing a stale socket from a prior
/// crash).
pub fn run(allocator: Allocator, io: std.Io, cfg: Config) !void {
    var store = try Store.init(allocator, io, cfg.store_path);
    defer store.deinit();

    const cwd = std.Io.Dir.cwd();
    cwd.deleteFile(io, cfg.socket_path) catch {}; // clear a stale socket

    const addr = try std.Io.net.UnixAddress.init(cfg.socket_path);
    var server = try addr.listen(io, .{});
    defer {
        server.deinit(io);
        cwd.deleteFile(io, cfg.socket_path) catch {};
    }

    while (true) {
        const stream = server.accept(io) catch continue;
        handleConn(allocator, io, &store, cfg, stream);
    }
}

/// Handle one connection: read request lines until the client disconnects,
/// answering each. A malformed or failing request gets an error response but
/// does not drop the connection.
fn handleConn(allocator: Allocator, io: std.Io, store: *Store, cfg: Config, stream: std.Io.net.Stream) void {
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

        const resp = dispatch(a, io, store, cfg, parsed.value) catch |err|
            Response.err(@errorName(err));
        protocol.writeLine(a, &writer.interface, resp) catch return;
    }
}

fn dispatch(a: Allocator, io: std.Io, store: *Store, cfg: Config, req: Request) !Response {
    const op = req.op;
    if (std.mem.eql(u8, op, "ping")) return .{ .ok = true, .text = "pong" };

    if (std.mem.eql(u8, op, "record")) {
        const kind_str = req.kind orelse return Response.err("record requires kind");
        const kind = EntryKind.fromString(kind_str) orelse return Response.err("unknown kind");
        const body = req.body orelse return Response.err("record requires body");
        const vec = resolveVector(a, io, cfg, req, body) catch |e| return embedErr(e);
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
        const vec = resolveVector(a, io, cfg, req, query) catch |e| return embedErr(e);
        const hits = try store.recall(a, vec, req.scope orelse "", optKind(req.kind), req.limit orelse 5);
        return hitsResponse(a, hits);
    }

    if (std.mem.eql(u8, op, "timeline")) {
        const hits = try store.timeline(a, req.scope orelse "", optKind(req.kind), req.limit orelse 20);
        return hitsResponse(a, hits);
    }

    if (std.mem.eql(u8, op, "header")) {
        const text = try store.header(a, req.scope orelse "", req.limit orelse 5, req.limit orelse 5);
        return .{ .ok = true, .text = text };
    }

    if (std.mem.eql(u8, op, "done")) {
        const id = req.id orelse return Response.err("done requires id");
        if (!try store.resolve(id)) return Response.err("unknown id");
        return .{ .ok = true, .count = store.count() };
    }

    if (std.mem.eql(u8, op, "forget")) {
        const id = req.id orelse return Response.err("forget requires id");
        const removed = try store.forget(id);
        if (!removed) return Response.err("unknown id");
        return .{ .ok = true, .count = store.count() };
    }

    return Response.err("unknown op");
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

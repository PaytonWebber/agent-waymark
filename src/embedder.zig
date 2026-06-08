//! Text → embedding via a local Ollama server.
//!
//! quantal stores raw f32 vectors only, so text must be embedded before it
//! reaches the index. We call Ollama's `/api/embeddings` endpoint (no API key,
//! runs offline). The vector dimension is fixed at build time (`build_options.dim`)
//! because the quantal index type bakes it in at comptime. It MUST match the
//! model (`nomic-embed-text` = 768).

const std = @import("std");
const build_options = @import("build_options");

/// The embedding dimension, shared with the quantal index instantiation.
pub const dim: usize = build_options.dim;

pub const Config = struct {
    pub const default_url = "http://localhost:11434/api/embeddings";
    pub const default_model = "nomic-embed-text";
    // Keep the embedding model resident between calls. The per-prompt hook
    // embeds on every turn, so a warm model means ~20-30ms instead of a cold
    // load; this just widens the window so an idle gap doesn't force a reload.
    pub const default_keep_alive = "30m";

    url: []const u8 = default_url,
    model: []const u8 = default_model,
    keep_alive: []const u8 = default_keep_alive,
};

pub const Error = error{
    EmbeddingHttpError,
    EmbeddingDimMismatch,
} || std.mem.Allocator.Error;

/// Embed `text` into a freshly allocated `[]f32` of length `dim`, owned by
/// `allocator`. Network and parse failures surface as `error.EmbeddingHttpError`;
/// a model whose dimension disagrees with the build is `error.EmbeddingDimMismatch`.
pub fn embed(io: std.Io, allocator: std.mem.Allocator, cfg: Config, text: []const u8) ![]f32 {
    var client: std.http.Client = .{ .allocator = allocator, .io = io };
    defer client.deinit();

    const body = try std.json.Stringify.valueAlloc(
        allocator,
        .{ .model = cfg.model, .prompt = text, .keep_alive = cfg.keep_alive },
        .{},
    );
    defer allocator.free(body);

    var response: std.Io.Writer.Allocating = .init(allocator);
    defer response.deinit();

    const result = client.fetch(.{
        .location = .{ .url = cfg.url },
        .method = .POST,
        .payload = body,
        .extra_headers = &.{.{ .name = "content-type", .value = "application/json" }},
        .response_writer = &response.writer,
    }) catch return error.EmbeddingHttpError;

    if (result.status != .ok) return error.EmbeddingHttpError;

    const Parsed = struct { embedding: []f32 };
    const parsed = std.json.parseFromSlice(
        Parsed,
        allocator,
        response.written(),
        .{ .ignore_unknown_fields = true },
    ) catch return error.EmbeddingHttpError;
    defer parsed.deinit();

    if (parsed.value.embedding.len != dim) return error.EmbeddingDimMismatch;

    const out = try allocator.alloc(f32, dim);
    @memcpy(out, parsed.value.embedding);
    normalize(out);
    return out;
}

/// L2-normalize in place so the index's inner-product score is cosine
/// similarity (comparable across queries, which lets recall apply a relevance
/// floor). Scale-invariant, so it does not affect SimHash routing.
pub fn normalize(v: []f32) void {
    var sum: f64 = 0;
    for (v) |x| sum += @as(f64, x) * x;
    if (sum <= 0) return;
    const inv: f32 = @floatCast(1.0 / @sqrt(sum));
    for (v) |*x| x.* *= inv;
}

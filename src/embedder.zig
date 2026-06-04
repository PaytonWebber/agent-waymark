//! Text → embedding via a local Ollama server.
//!
//! quantal stores raw f32 vectors only, so text must be embedded before it
//! reaches the index. We call Ollama's `/api/embeddings` endpoint (no API key,
//! runs offline). The vector dimension is fixed at build time (`build_options.dim`)
//! because the quantal index type bakes it in at comptime — it MUST match the
//! model (`nomic-embed-text` = 768).

const std = @import("std");
const build_options = @import("build_options");

/// The embedding dimension, shared with the quantal index instantiation.
pub const dim: usize = build_options.dim;

pub const Config = struct {
    pub const default_url = "http://localhost:11434/api/embeddings";
    pub const default_model = "nomic-embed-text";

    url: []const u8 = default_url,
    model: []const u8 = default_model,
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
        .{ .model = cfg.model, .prompt = text },
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
    return out;
}

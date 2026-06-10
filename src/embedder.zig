//! Text → embedding via a model2vec model compiled into the binary.
//!
//! The bundled model defaults to potion-retrieval-32M quantized to i8
//! (512d, ~32 MB): static embeddings, so embedding a text is a vocabulary
//! lookup and a mean. Microseconds per call, works offline, no service to
//! install, and the retrieval-tuned model matches the old transformer
//! stack's paraphrase quality on our eval suite. Hybrid recall (lexical +
//! dense fusion) covers exact identifiers on top.
//! `zig build -Dmodel=potion-base-8M` bundles the smaller 256d model
//! instead (~30 MB f32, or ~8 MB after `zig build quantize-model`).
//!
//! quantal bakes the vector dimension in at comptime (`build_options.dim`),
//! so it must match the model; the build derives it from `-Dmodel`.
//! AGENT_WAYMARK_MODEL_DIR loads a different model2vec model from disk; a
//! dimension mismatch is rejected at startup rather than corrupting the
//! index.
//!
//! Output vectors are L2-normalized (the model config asks for it), so the
//! index's inner-product score is cosine similarity and recall can apply a
//! relevance floor that is comparable across queries.

const std = @import("std");
const build_options = @import("build_options");
const m2v = @import("model2vec");

pub const dim: usize = build_options.dim;

pub const model_name = build_options.model_name;

const bundled_tokenizer = @embedFile("model/" ++ model_name ++ "/tokenizer.json");
const bundled_safetensors = @embedFile("model/" ++ model_name ++ "/model.safetensors");

pub const Error = error{
    ModelLoadFailed,
    EmbeddingDimMismatch,
} || std.mem.Allocator.Error;

pub const Embedder = struct {
    model: m2v.Model,

    /// `model_dir` overrides the bundled model (AGENT_WAYMARK_MODEL_DIR).
    pub fn init(gpa: std.mem.Allocator, io: std.Io, model_dir: ?[]const u8) Error!Embedder {
        var model = if (model_dir) |dir|
            m2v.Model.load(gpa, io, dir) catch return error.ModelLoadFailed
        else
            m2v.Model.loadFromBytes(gpa, bundled_tokenizer, bundled_safetensors, .{}) catch
                return error.ModelLoadFailed;
        errdefer model.deinit();

        if (model.dim != dim) return error.EmbeddingDimMismatch;
        return .{ .model = model };
    }

    pub fn deinit(self: *Embedder) void {
        self.model.deinit();
    }

    /// Identifies the exact embedding matrix; vectors persist keyed to this.
    pub fn fingerprint(self: *const Embedder) u64 {
        return self.model.fingerprint();
    }

    /// Embed `text` into a freshly allocated `[]f32` of length `dim`. The
    /// model is read-only, so concurrent calls are fine as long as each one
    /// brings its own allocator.
    pub fn embed(self: *const Embedder, allocator: std.mem.Allocator, text: []const u8) ![]f32 {
        return self.model.embed(allocator, text);
    }
};

const testing = std.testing;

test "bundled model loads at the built dimension and embeds" {
    var emb = try Embedder.init(testing.allocator, testing.io, null);
    defer emb.deinit();

    const v = try emb.embed(testing.allocator, "the daemon owns the store");
    defer testing.allocator.free(v);
    try testing.expectEqual(dim, v.len);

    // Normalized output: unit length.
    var sum: f64 = 0;
    for (v) |x| sum += @as(f64, x) * x;
    try testing.expectApproxEqAbs(@as(f64, 1.0), sum, 1e-5);
}

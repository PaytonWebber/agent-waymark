//! Extracts durable entries from a session transcript via a local Ollama
//! generation model. Used by the PreCompact sweep so the store gets populated
//! even when the agent did not record as it went. Best-effort: any failure
//! (model not installed, bad output) yields no candidates and the sweep is a
//! no-op.

const std = @import("std");

pub const Config = struct {
    pub const default_url = "http://localhost:11434/api/generate";
    pub const default_model = "llama3.2";

    url: []const u8 = default_url,
    model: []const u8 = default_model,
};

pub const Candidate = struct {
    kind: []const u8,
    body: []const u8,
};

pub const max_candidates = 8;

const preamble =
    \\You are extracting durable project memory from the tail of a coding-agent
    \\session transcript (JSONL). From the transcript ONLY, extract concrete
    \\architectural decisions made, dead ends or rejected approaches (with the
    \\reason), explicit todos that remain, and important non-obvious findings.
    \\Ignore chit-chat, tool noise, file dumps, and transient details. One
    \\concise sentence per entry, in your own words. At most 8 entries. Do not
    \\invent entries; if nothing durable stands out, return an empty list.
    \\
    \\Transcript tail:
    \\
;

// A JSON Schema passed to Ollama's `format` so the output is constrained: a
// single `entries` array, `kind` restricted to the enum (no echoed list), and
// no room to copy an example. This is what fixes both the duplicate-key
// structure and the placeholder-leak that a prose example caused.
const output_schema = .{
    .type = "object",
    .properties = .{
        .entries = .{
            .type = "array",
            .items = .{
                .type = "object",
                .properties = .{
                    .kind = .{ .type = "string", .@"enum" = [_][]const u8{ "decision", "rejected", "todo", "finding" } },
                    .body = .{ .type = "string" },
                },
                .required = [_][]const u8{ "kind", "body" },
            },
        },
    },
    .required = [_][]const u8{"entries"},
};

/// Extract candidates from `transcript`, allocated in `arena`. Returns an empty
/// slice on any failure.
pub fn extract(io: std.Io, arena: std.mem.Allocator, cfg: Config, transcript: []const u8) []const Candidate {
    return tryExtract(io, arena, cfg, transcript) catch &.{};
}

fn tryExtract(io: std.Io, arena: std.mem.Allocator, cfg: Config, transcript: []const u8) ![]const Candidate {
    var client: std.http.Client = .{ .allocator = arena, .io = io };
    defer client.deinit();

    const prompt = try std.fmt.allocPrint(arena, "{s}{s}", .{ preamble, transcript });
    const body = try std.json.Stringify.valueAlloc(arena, .{
        .model = cfg.model,
        .prompt = prompt,
        .stream = false,
        .format = output_schema,
        .keep_alive = "5m",
        .options = .{ .temperature = 0 },
    }, .{});

    var response: std.Io.Writer.Allocating = .init(arena);
    const result = client.fetch(.{
        .location = .{ .url = cfg.url },
        .method = .POST,
        .payload = body,
        .extra_headers = &.{.{ .name = "content-type", .value = "application/json" }},
        .response_writer = &response.writer,
    }) catch return error.ExtractHttpError;
    if (result.status != .ok) return error.ExtractHttpError;

    // Ollama /api/generate (stream:false) returns {"response":"<json string>",…}.
    const Gen = struct { response: []const u8 };
    const gen = try std.json.parseFromSliceLeaky(Gen, arena, response.written(), .{ .ignore_unknown_fields = true });

    const Parsed = struct { entries: []const Candidate = &.{} };
    const parsed = std.json.parseFromSliceLeaky(Parsed, arena, gen.response, .{ .ignore_unknown_fields = true }) catch
        return &.{};

    var entries = parsed.entries;
    if (entries.len > max_candidates) entries = entries[0..max_candidates];
    return entries;
}

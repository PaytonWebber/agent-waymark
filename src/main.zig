//! agent-waymark: durable shared working-state for agent orchestration.
//!
//! One binary, two roles. `agent-waymark daemon` runs the long-lived store owner;
//! every other subcommand is a thin client that connects to it over a unix
//! socket. The MCP bridge (phase 2) and hook kit (phase 3) are additional
//! clients of the same daemon.
//!
//!   agent-waymark daemon
//!   agent-waymark ping
//!   agent-waymark record <kind> <body> [--scope S] [--author A] [--supersedes N] [--ref PATH]
//!   agent-waymark recall <query>        [--scope S] [--kind K] [--limit N]
//!   agent-waymark timeline              [--scope S] [--kind K] [--limit N]
//!   agent-waymark header                [--scope S] [--limit N]
//!   agent-waymark touch <id>
//!   agent-waymark forget <id>

const std = @import("std");
const sdk = @import("zig_mcp_sdk");
const embedder = @import("embedder.zig");
const extractor = @import("extractor.zig");
const daemon = @import("daemon.zig");
const client_mod = @import("client.zig");
const protocol = @import("protocol.zig");
const mcp = @import("mcp.zig");
const hooks = @import("hooks.zig");
const scope_mod = @import("scope.zig");
const install_mod = @import("install.zig");
const doctor = @import("doctor.zig");

const Client = client_mod.Client;
const Request = protocol.Request;

const default_socket = "/tmp/agent-waymark.sock";
const default_store = "agent-waymark-state.json";
const version = "0.1.3";

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    const io = init.io;
    const env = init.environ_map;

    var arg_it = try init.minimal.args.iterateAllocator(allocator);
    defer arg_it.deinit();
    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(allocator);
    while (arg_it.next()) |a| try argv.append(allocator, a);

    if (argv.items.len < 2) return usage();
    const cmd = argv.items[1];
    const args = argv.items[2..];
    if (std.mem.eql(u8, cmd, "--help") or std.mem.eql(u8, cmd, "-h")) return usage();
    if (std.mem.eql(u8, cmd, "--version") or std.mem.eql(u8, cmd, "-V") or std.mem.eql(u8, cmd, "version")) return printVersion(io);

    const cfg: daemon.Config = .{
        .socket_path = env.get("AGENT_WAYMARK_SOCKET") orelse default_socket,
        .store_path = env.get("AGENT_WAYMARK_STORE") orelse default_store,
        .embed = .{
            .url = env.get("AGENT_WAYMARK_EMBED_URL") orelse embedder.Config.default_url,
            .model = env.get("AGENT_WAYMARK_EMBED_MODEL") orelse embedder.Config.default_model,
            .keep_alive = env.get("AGENT_WAYMARK_EMBED_KEEP_ALIVE") orelse embedder.Config.default_keep_alive,
        },
        .extract = .{
            .url = env.get("AGENT_WAYMARK_EXTRACT_URL") orelse extractor.Config.default_url,
            .model = env.get("AGENT_WAYMARK_EXTRACT_MODEL") orelse extractor.Config.default_model,
        },
        .sweep_dedup = if (env.get("AGENT_WAYMARK_SWEEP_DEDUP")) |s|
            std.fmt.parseFloat(f32, s) catch daemon.default_sweep_dedup
        else
            daemon.default_sweep_dedup,
    };

    if (std.mem.eql(u8, cmd, "daemon")) {
        return daemon.run(io, cfg);
    }
    if (std.mem.eql(u8, cmd, "mcp")) {
        return runMcp(allocator, io, env, cfg);
    }
    if (std.mem.eql(u8, cmd, "hook")) {
        return hooks.run(allocator, io, env, cfg, if (args.len > 0) args[0] else "");
    }
    if (std.mem.eql(u8, cmd, "sweep-file")) {
        return hooks.runSweepFile(allocator, io, cfg, args);
    }
    if (std.mem.eql(u8, cmd, "install")) {
        return install_mod.run(allocator, io, env, args);
    }
    if (std.mem.eql(u8, cmd, "mcp-config")) {
        return install_mod.runMcpConfig(allocator, io, env, args);
    }
    if (std.mem.eql(u8, cmd, "doctor") or std.mem.eql(u8, cmd, "--doctor")) {
        return doctor.run(allocator, io, env, cfg, args);
    }

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var req = buildRequest(a, cmd, args) catch |err| {
        fatal("{s}", .{@errorName(err)});
    };

    // Default the scope the same way the bridge and hooks do. `record` writes
    // repo-wide by default (durable knowledge), or branch-local with
    // `--branch-local`; everything else queries at the branch scope (reads see
    // repo-wide + current branch). Pass an explicit `--scope ""` to span all.
    if (req.scope == null or std.mem.eql(u8, req.op, "record")) {
        const info = scope_mod.detect(a, io, env, null);
        if (req.scope == null) {
            const repo_wide_write = std.mem.eql(u8, cmd, "record") and !flagPresent(args, "--branch-local");
            req.scope = if (repo_wide_write) info.repo_scope else info.branch_scope;
        }
        req.worktree_root = info.worktree_root;
    }

    var client: Client = undefined;
    client.connectOrStart(allocator, io, cfg.socket_path) catch {
        fatal("could not reach or start the agent-waymark daemon at {s}", .{cfg.socket_path});
    };
    defer client.deinit();

    const parsed = try client.call(a, req);
    try printResponse(io, parsed.value);
    if (!parsed.value.ok) std.process.exit(1);
}

/// Run the MCP bridge over stdio as a thin client of the daemon (auto-started
/// if needed). Claude Code launches this with `command: agent-waymark mcp`.
fn runMcp(allocator: std.mem.Allocator, io: std.Io, env: *std.process.Environ.Map, cfg: daemon.Config) !void {
    var client: Client = undefined;
    try client.connectOrStart(allocator, io, cfg.socket_path);
    defer client.deinit();

    var scope_arena = std.heap.ArenaAllocator.init(allocator);
    defer scope_arena.deinit();
    const info = scope_mod.detect(scope_arena.allocator(), io, env, null);
    var handler: mcp.Handler = .{
        .client = &client,
        .repo_scope = info.repo_scope,
        .branch_scope = info.branch_scope,
        .worktree_root = info.worktree_root,
        .author = env.get("AGENT_WAYMARK_AUTHOR") orelse "claude-code",
    };
    var server = sdk.Server(mcp.Handler).init(allocator, &handler, .{
        .server_info = .{ .name = "agent-waymark", .version = version },
        .capabilities = .{ .tools = .{} },
        .instructions =
        \\Shared working-state for this project, so work carries across
        \\sessions and sub-agents. Be proactive about writing to it:
        \\  - When you make an architectural decision, hit a dead end, learn
        \\    a non-obvious fact, or take on a task, record it (record /
        \\    supersede / touch / done). Capture decisions and dead ends, not
        \\    every thought.
        \\  - If an old entry is still true, touch it instead of rewriting it.
        \\  - Before investigating something non-trivial, recall first to see
        \\    if it was already decided or tried.
        \\Relevant prior entries are injected automatically at session start
        \\and on each prompt; build on them instead of starting cold.
        ,
    });
    try server.start(io);
}

fn buildRequest(a: std.mem.Allocator, cmd: []const u8, args: []const []const u8) !Request {
    if (std.mem.eql(u8, cmd, "ping")) return .{ .op = "ping" };

    if (std.mem.eql(u8, cmd, "record")) {
        if (args.len < 2) return error.RecordNeedsKindAndBody;
        return .{
            .op = "record",
            .kind = args[0],
            .body = args[1],
            .text = args[1], // daemon embeds the body
            .scope = flag(args, "--scope"),
            .author = flag(args, "--author"),
            .supersedes = try optU64(flag(args, "--supersedes")),
            .refs = try refs(a, args),
        };
    }

    if (std.mem.eql(u8, cmd, "recall")) {
        if (args.len < 1) return error.RecallNeedsQuery;
        return .{
            .op = "recall",
            .text = args[0],
            .scope = flag(args, "--scope"),
            .kind = flag(args, "--kind"),
            .limit = try optUsize(flag(args, "--limit")),
        };
    }

    if (std.mem.eql(u8, cmd, "timeline")) {
        return .{
            .op = "timeline",
            .scope = flag(args, "--scope"),
            .kind = flag(args, "--kind"),
            .limit = try optUsize(flag(args, "--limit")),
        };
    }

    if (std.mem.eql(u8, cmd, "header")) {
        return .{
            .op = "header",
            .scope = flag(args, "--scope"),
            .limit = try optUsize(flag(args, "--limit")),
        };
    }

    if (std.mem.eql(u8, cmd, "done")) {
        if (args.len < 1) return error.DoneNeedsId;
        return .{ .op = "done", .id = try std.fmt.parseInt(u64, args[0], 10) };
    }

    if (std.mem.eql(u8, cmd, "touch") or std.mem.eql(u8, cmd, "confirm")) {
        if (args.len < 1) return error.TouchNeedsId;
        return .{ .op = "touch", .id = try std.fmt.parseInt(u64, args[0], 10) };
    }

    if (std.mem.eql(u8, cmd, "pin") or std.mem.eql(u8, cmd, "unpin")) {
        if (args.len < 1) return error.PinNeedsId;
        return .{ .op = cmd, .id = try std.fmt.parseInt(u64, args[0], 10) };
    }

    if (std.mem.eql(u8, cmd, "forget")) {
        if (args.len < 1) return error.ForgetNeedsId;
        return .{ .op = "forget", .id = try std.fmt.parseInt(u64, args[0], 10) };
    }

    return error.UnknownCommand;
}

/// Value following `--name` in `args`, or null. A positional like the body is
/// never mistaken for a flag value because flags are looked up by name.
fn flag(args: []const []const u8, name: []const u8) ?[]const u8 {
    var i: usize = 0;
    while (i + 1 < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], name)) return args[i + 1];
    }
    return null;
}

fn flagPresent(args: []const []const u8, name: []const u8) bool {
    for (args) |arg| if (std.mem.eql(u8, arg, name)) return true;
    return false;
}

fn refs(a: std.mem.Allocator, args: []const []const u8) !?[]const []const u8 {
    var n: usize = 0;
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--ref")) {
            if (i + 1 >= args.len) return error.RefNeedsPath;
            n += 1;
            i += 1;
        }
    }
    if (n == 0) return null;
    const out = try a.alloc([]const u8, n);
    var j: usize = 0;
    i = 0;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--ref")) {
            out[j] = args[i + 1];
            j += 1;
            i += 1;
        }
    }
    return out;
}

fn optU64(s: ?[]const u8) !?u64 {
    return if (s) |v| try std.fmt.parseInt(u64, v, 10) else null;
}

fn optUsize(s: ?[]const u8) !?usize {
    return if (s) |v| try std.fmt.parseInt(usize, v, 10) else null;
}

fn printResponse(io: std.Io, resp: protocol.Response) !void {
    var buf: [64 * 1024]u8 = undefined;
    var fw: std.Io.File.Writer = .init(.stdout(), io, &buf);
    const w = &fw.interface;
    defer fw.interface.flush() catch {};

    if (!resp.ok) {
        try w.print("error: {s}\n", .{resp.@"error" orelse "unknown"});
        return;
    }
    if (resp.id) |id| try w.print("recorded #{d} ({d} total)\n", .{ id, resp.count orelse 0 });
    if (resp.text) |t| {
        if (t.len > 0) try w.print("{s}\n", .{t}) else try w.writeAll("(empty)\n");
    }
    if (resp.warning) |warning| try w.print("warning: {s}\n", .{warning});
    if (resp.hits) |hits| {
        if (hits.len == 0) try w.writeAll("(no matches)\n");
        for (hits) |h| {
            try w.print("#{d} [{s}] ({s})", .{ h.id, h.kind, h.freshness });
            if (h.score != 0) try w.print(" {d:.3}", .{h.score});
            if (h.scope.len > 0) try w.print(" {s}", .{h.scope});
            if (h.supersedes) |s| try w.print(" (supersedes #{d})", .{s});
            if (h.ref_statuses.len > 0) {
                try w.writeAll(" refs:");
                for (h.ref_statuses) |status| try w.print(" {s} {s}", .{ status.status, status.ref });
            }
            try w.print("\n  {s}\n", .{h.body});
        }
    }
    if (resp.hits == null and resp.text == null and resp.id == null) {
        try w.print("ok ({d} total)\n", .{resp.count orelse 0});
    }
}

fn usage() void {
    std.debug.print(
        \\agent-waymark: shared working-state for agent orchestration
        \\
        \\  agent-waymark install [--user] [--global-mcp] [--store PATH]
        \\                                     register the MCP server + hooks with Claude Code
        \\  agent-waymark install --codex      register the MCP server + hooks with Codex
        \\  agent-waymark mcp-config <claude|codex> [--store PATH]
        \\                                     print MCP config for an external config manager
        \\  agent-waymark doctor [--json]       check daemon reachability and project config
        \\  agent-waymark --version             print the CLI version
        \\  agent-waymark daemon                run the store owner (auto-started otherwise)
        \\  agent-waymark mcp                   run the MCP bridge over stdio
        \\  agent-waymark hook <Event>          run a hook (reads the event JSON on stdin)
        \\
        \\  agent-waymark ping
        \\  agent-waymark record <kind> <body> [--scope S] [--author A] [--supersedes N] [--ref PATH]
        \\  agent-waymark recall <query>        [--scope S] [--kind K] [--limit N]
        \\  agent-waymark timeline              [--scope S] [--kind K] [--limit N]
        \\  agent-waymark header                [--scope S] [--limit N]
        \\  agent-waymark done <id>             mark a todo done (kept for history)
        \\  agent-waymark touch <id>            confirm an entry is still valid
        \\  agent-waymark pin <id> | unpin <id> always show an entry in the header
        \\  agent-waymark forget <id>
        \\
        \\kinds: decision finding rejected todo artifact note
        \\
    , .{});
}

fn printVersion(io: std.Io) !void {
    var buf: [256]u8 = undefined;
    var fw: std.Io.File.Writer = .init(.stdout(), io, &buf);
    const w = &fw.interface;
    defer fw.interface.flush() catch {};

    try w.print("agent-waymark {s}\n", .{version});
}

fn fatal(comptime fmt: []const u8, args: anytype) noreturn {
    std.debug.print("error: " ++ fmt ++ "\n", args);
    std.process.exit(1);
}

test {
    _ = @import("store.zig");
    _ = @import("protocol.zig");
    _ = @import("install.zig");
    _ = @import("doctor.zig");
    _ = @import("store_test.zig");
}

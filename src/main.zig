//! cairn — durable shared working-state for agent orchestration.
//!
//! One binary, two roles. `cairn daemon` runs the long-lived store owner;
//! every other subcommand is a thin client that connects to it over a unix
//! socket. The MCP bridge (phase 2) and hook kit (phase 3) are additional
//! clients of the same daemon.
//!
//!   cairn daemon
//!   cairn ping
//!   cairn record <kind> <body> [--scope S] [--author A] [--supersedes N]
//!   cairn recall <query>        [--scope S] [--kind K] [--limit N]
//!   cairn timeline              [--scope S] [--kind K] [--limit N]
//!   cairn header                [--scope S] [--limit N]
//!   cairn forget <id>

const std = @import("std");
const sdk = @import("zig_mcp_sdk");
const embedder = @import("embedder.zig");
const daemon = @import("daemon.zig");
const client_mod = @import("client.zig");
const protocol = @import("protocol.zig");
const mcp = @import("mcp.zig");
const hooks = @import("hooks.zig");
const scope_mod = @import("scope.zig");
const install_mod = @import("install.zig");

const Client = client_mod.Client;
const Request = protocol.Request;

const default_socket = "/tmp/cairn.sock";
const default_store = "cairn-state.json";

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

    const cfg: daemon.Config = .{
        .socket_path = env.get("CAIRN_SOCKET") orelse default_socket,
        .store_path = env.get("CAIRN_STORE") orelse default_store,
        .embed = .{
            .url = env.get("CAIRN_EMBED_URL") orelse embedder.Config.default_url,
            .model = env.get("CAIRN_EMBED_MODEL") orelse embedder.Config.default_model,
        },
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
    if (std.mem.eql(u8, cmd, "install")) {
        return install_mod.run(allocator, io, env, args);
    }

    var req = buildRequest(cmd, args) catch |err| {
        fatal("{s}", .{@errorName(err)});
    };

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // Default the scope the same way the bridge and hooks do, so the CLI reads
    // and writes the same project state. Pass an explicit `--scope ""` to span
    // all scopes.
    if (req.scope == null) req.scope = try scope_mod.forCwd(a, io, env, null);

    var client: Client = undefined;
    client.connectOrStart(allocator, io, cfg.socket_path) catch {
        fatal("could not reach or start the cairn daemon at {s}", .{cfg.socket_path});
    };
    defer client.deinit();

    const parsed = try client.call(a, req);
    try printResponse(io, parsed.value);
    if (!parsed.value.ok) std.process.exit(1);
}

/// Run the MCP bridge over stdio as a thin client of the daemon (auto-started
/// if needed). Claude Code launches this with `command: cairn mcp`.
fn runMcp(allocator: std.mem.Allocator, io: std.Io, env: *std.process.Environ.Map, cfg: daemon.Config) !void {
    var client: Client = undefined;
    try client.connectOrStart(allocator, io, cfg.socket_path);
    defer client.deinit();

    var handler: mcp.Handler = .{
        .client = &client,
        .default_scope = try scope_mod.forCwd(allocator, io, env, null),
        .author = env.get("CAIRN_AUTHOR") orelse "claude-code",
    };
    var server = sdk.Server(mcp.Handler).init(allocator, &handler, .{
        .server_info = .{ .name = "cairn", .version = "0.0.0" },
        .capabilities = .{ .tools = .{} },
        .instructions =
            \\Shared working-state for this project. Record decisions, findings,
            \\rejected paths, and todos so later sessions and sub-agents don't
            \\re-derive them; recall them before re-investigating something.
        ,
    });
    try server.start(io);
}

fn buildRequest(cmd: []const u8, args: []const []const u8) !Request {
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
    if (resp.hits) |hits| {
        if (hits.len == 0) try w.writeAll("(no matches)\n");
        for (hits) |h| {
            try w.print("#{d} [{s}]", .{ h.id, h.kind });
            if (h.score != 0) try w.print(" {d:.3}", .{h.score});
            if (h.scope.len > 0) try w.print(" {s}", .{h.scope});
            if (h.supersedes) |s| try w.print(" (supersedes #{d})", .{s});
            try w.print("\n  {s}\n", .{h.body});
        }
    }
    if (resp.hits == null and resp.text == null and resp.id == null) {
        try w.print("ok ({d} total)\n", .{resp.count orelse 0});
    }
}

fn usage() void {
    std.debug.print(
        \\cairn — shared working-state for agent orchestration
        \\
        \\  cairn install [--user]      register the MCP server + hooks with Claude Code
        \\  cairn daemon                run the store owner (auto-started otherwise)
        \\  cairn mcp                   run the MCP bridge over stdio
        \\  cairn hook <Event>          run a hook (reads the event JSON on stdin)
        \\
        \\  cairn ping
        \\  cairn record <kind> <body> [--scope S] [--author A] [--supersedes N]
        \\  cairn recall <query>        [--scope S] [--kind K] [--limit N]
        \\  cairn timeline              [--scope S] [--kind K] [--limit N]
        \\  cairn header                [--scope S] [--limit N]
        \\  cairn done <id>             mark a todo done (kept for history)
        \\  cairn pin <id> | unpin <id> always show an entry in the header
        \\  cairn forget <id>
        \\
        \\kinds: decision finding rejected todo artifact note
        \\
    , .{});
}

fn fatal(comptime fmt: []const u8, args: anytype) noreturn {
    std.debug.print("error: " ++ fmt ++ "\n", args);
    std.process.exit(1);
}

test {
    _ = @import("store.zig");
    _ = @import("protocol.zig");
    _ = @import("store_test.zig");
}

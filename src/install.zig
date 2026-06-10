//! `agent-waymark install`: register the MCP server and the hooks with agent clients.
//!
//! Project scope (default): writes Claude Code config. `--codex` writes
//! `.codex/config.toml` (MCP server) and `.codex/hooks.json` (hooks). `--user`
//! writes user-level hooks and a global MCP server. `--global-mcp` writes only
//! the MCP server at user scope. `--store PATH` pins the daemon snapshot path.
//!
//! The settings merge is careful: existing JSON is parsed, only agent-waymark's own
//! hook entries are replaced (idempotent re-install), every other key is
//! preserved, and the prior file is backed up to `<name>.bak`.

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const Value = std.json.Value;
const ObjectMap = std.json.ObjectMap;
const Array = std.json.Array;
const scope_mod = @import("scope.zig");

const events = [_][]const u8{ "SessionStart", "UserPromptSubmit", "SubagentStart", "PreCompact" };
const server_name = "agent-waymark";
const project_state_dir = ".agent-waymark";
const codex_mcp_table = "mcp_servers.agent-waymark";

pub fn run(allocator: Allocator, io: std.Io, env: *std.process.Environ.Map, args: []const []const u8) !void {
    const opts = try parseOptions(args);
    const exe = try std.process.executablePathAlloc(io, allocator);
    defer allocator.free(exe);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();

    if (opts.codex) return installCodex(io, env, a, exe, opts);
    return installClaude(io, env, a, exe, opts);
}

pub fn runMcpConfig(allocator: Allocator, io: std.Io, env: *std.process.Environ.Map, args: []const []const u8) !void {
    if (args.len < 1) return error.McpConfigNeedsHarness;

    const exe = try std.process.executablePathAlloc(io, allocator);
    defer allocator.free(exe);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const opts = try parseOptions(args[1..]);
    const bytes = try mcpConfigBytes(a, env, exe, args[0], opts);

    var buf: [16 * 1024]u8 = undefined;
    var fw: std.Io.File.Writer = .init(.stdout(), io, &buf);
    const w = &fw.interface;
    defer fw.interface.flush() catch {};

    try w.writeAll(bytes);
    if (bytes.len == 0 or bytes[bytes.len - 1] != '\n') try w.writeByte('\n');
}

const InstallOptions = struct {
    user: bool = false,
    codex: bool = false,
    global_mcp: bool = false,
    store_path: ?[]const u8 = null,
};

const StatePaths = struct {
    store_path: []const u8,
    socket_path: []const u8,
    mkdir_path: []const u8,
};

fn installClaude(io: std.Io, env: *std.process.Environ.Map, a: Allocator, exe: []const u8, opts: InstallOptions) !void {
    const cwd = std.Io.Dir.cwd();
    const mcp_global = opts.user or opts.global_mcp;
    const state = try claudeState(a, io, env, opts, mcp_global);
    const settings_path = if (opts.user) blk: {
        const home = env.get("HOME") orelse return error.NoHomeDir;
        const dir = try std.fmt.allocPrint(a, "{s}/.claude", .{home});
        cwd.createDirPath(io, dir) catch {};
        break :blk try std.fmt.allocPrint(a, "{s}/settings.json", .{dir});
    } else blk: {
        cwd.createDirPath(io, ".claude") catch {};
        break :blk ".claude/settings.json";
    };

    try mergeHooks(io, a, settings_path, exe, .claude, state);

    if (mcp_global) {
        const home = env.get("HOME") orelse return error.NoHomeDir;
        const mcp_path = try std.fmt.allocPrint(a, "{s}/.claude.json", .{home});
        try mergeClaudeMcp(io, a, mcp_path, exe, state);
        report("Wrote {s} (MCP server) and {s} (hooks).", .{ mcp_path, settings_path });
    } else {
        try mergeClaudeMcp(io, a, ".mcp.json", exe, state);
        report("Wrote .claude/settings.json (hooks) and .mcp.json (MCP server).", .{});
        report("Restart Claude Code in this directory to pick them up.", .{});
    }
}

fn installCodex(io: std.Io, env: *std.process.Environ.Map, a: Allocator, exe: []const u8, opts: InstallOptions) !void {
    const cwd = std.Io.Dir.cwd();
    const mcp_global = opts.user or opts.global_mcp;
    const hooks_dir = if (opts.user) blk: {
        const home = env.get("HOME") orelse return error.NoHomeDir;
        const path = try std.fmt.allocPrint(a, "{s}/.codex", .{home});
        cwd.createDirPath(io, path) catch {};
        break :blk path;
    } else blk: {
        cwd.createDirPath(io, ".codex") catch {};
        break :blk ".codex";
    };
    const config_dir = if (mcp_global) blk: {
        const home = env.get("HOME") orelse return error.NoHomeDir;
        const path = try std.fmt.allocPrint(a, "{s}/.codex", .{home});
        cwd.createDirPath(io, path) catch {};
        break :blk path;
    } else hooks_dir;

    const state = try codexState(a, io, env, opts, mcp_global);
    const hooks_path = try std.fmt.allocPrint(a, "{s}/hooks.json", .{hooks_dir});
    const config_path = try std.fmt.allocPrint(a, "{s}/config.toml", .{config_dir});
    try mergeHooks(io, a, hooks_path, exe, .codex, state);
    try mergeCodexMcp(io, a, config_path, exe, state.?);

    report("Wrote {s} (MCP server) and {s} (hooks).", .{ config_path, hooks_path });
    report("Restart Codex in this directory and review/trust hooks with /hooks.", .{});
}

/// Remove agent-waymark's hooks and MCP entries from the files `install`
/// writes, preserving everything else. Never creates files that don't exist.
pub fn runUninstall(allocator: Allocator, io: std.Io, env: *std.process.Environ.Map, args: []const []const u8) !void {
    const opts = try parseOptions(args);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();

    if (opts.codex) {
        try uninstallCodex(io, env, a, opts);
    } else {
        try uninstallClaude(io, env, a, opts);
    }

    report("The daemon, if running, is not stopped: pkill -f 'agent-waymark daemon'.", .{});
    report("Recorded entries are kept; delete the .agent-waymark state directory to remove them.", .{});
}

fn uninstallClaude(io: std.Io, env: *std.process.Environ.Map, a: Allocator, opts: InstallOptions) !void {
    const mcp_global = opts.user or opts.global_mcp;
    const settings_path = if (opts.user) blk: {
        const home = env.get("HOME") orelse return error.NoHomeDir;
        break :blk try std.fmt.allocPrint(a, "{s}/.claude/settings.json", .{home});
    } else ".claude/settings.json";
    const mcp_path = if (mcp_global) blk: {
        const home = env.get("HOME") orelse return error.NoHomeDir;
        break :blk try std.fmt.allocPrint(a, "{s}/.claude.json", .{home});
    } else ".mcp.json";

    reportRemoval(settings_path, try removeHooks(io, a, settings_path));
    reportRemoval(mcp_path, try removeClaudeMcp(io, a, mcp_path));
}

fn uninstallCodex(io: std.Io, env: *std.process.Environ.Map, a: Allocator, opts: InstallOptions) !void {
    const mcp_global = opts.user or opts.global_mcp;
    const hooks_path = if (opts.user) blk: {
        const home = env.get("HOME") orelse return error.NoHomeDir;
        break :blk try std.fmt.allocPrint(a, "{s}/.codex/hooks.json", .{home});
    } else ".codex/hooks.json";
    const config_path = if (mcp_global) blk: {
        const home = env.get("HOME") orelse return error.NoHomeDir;
        break :blk try std.fmt.allocPrint(a, "{s}/.codex/config.toml", .{home});
    } else ".codex/config.toml";

    reportRemoval(hooks_path, try removeHooks(io, a, hooks_path));
    reportRemoval(config_path, try removeCodexMcp(io, a, config_path));
}

fn reportRemoval(path: []const u8, removed: bool) void {
    if (removed) {
        report("Removed agent-waymark entries from {s}.", .{path});
    } else {
        report("No agent-waymark entries in {s}.", .{path});
    }
}

/// Returns false when the file is absent or carries no agent-waymark entries.
fn removeHooks(io: std.Io, a: Allocator, path: []const u8) !bool {
    const bytes = std.Io.Dir.cwd().readFileAlloc(io, path, a, .unlimited) catch |err| switch (err) {
        error.FileNotFound => return false,
        else => return err,
    };
    if (bytes.len == 0) return false;
    var root = std.json.parseFromSliceLeaky(Value, a, bytes, .{}) catch return false;
    if (root != .object) return false;
    const hooks_val = root.object.getPtr("hooks") orelse return false;
    if (hooks_val.* != .object) return false;

    var removed = false;
    for (events) |event| {
        const arr_ptr = hooks_val.object.getPtr(event) orelse continue;
        if (arr_ptr.* != .array) continue;
        var kept = Array.init(a);
        for (arr_ptr.array.items) |item| {
            if (isAgentWaymarkEntry(item)) {
                removed = true;
            } else {
                try kept.append(item);
            }
        }
        arr_ptr.* = .{ .array = kept };
    }
    if (!removed) return false;

    try writeObject(io, a, path, root);
    return true;
}

fn removeClaudeMcp(io: std.Io, a: Allocator, path: []const u8) !bool {
    const bytes = std.Io.Dir.cwd().readFileAlloc(io, path, a, .unlimited) catch |err| switch (err) {
        error.FileNotFound => return false,
        else => return err,
    };
    if (bytes.len == 0) return false;
    var root = std.json.parseFromSliceLeaky(Value, a, bytes, .{}) catch return false;
    if (root != .object) return false;
    const servers = root.object.getPtr("mcpServers") orelse return false;
    if (servers.* != .object) return false;
    if (!servers.object.orderedRemove(server_name)) return false;

    try writeObject(io, a, path, root);
    return true;
}

fn removeCodexMcp(io: std.Io, a: Allocator, path: []const u8) !bool {
    const old = std.Io.Dir.cwd().readFileAlloc(io, path, a, .unlimited) catch |err| switch (err) {
        error.FileNotFound => return false,
        else => return err,
    };
    const kept = try removeTomlTable(a, old, codex_mcp_table);
    if (std.mem.eql(u8, kept, old)) return false;

    try writeBytes(io, a, path, kept);
    return true;
}

const HookClient = enum { claude, codex };

fn mergeHooks(io: std.Io, a: Allocator, path: []const u8, exe: []const u8, client: HookClient, state: ?StatePaths) !void {
    var root = try readObject(io, a, path);
    const hooks_obj = try ensureObject(a, &root, "hooks");

    for (events) |event| {
        const arr_ptr = try ensureArray(a, hooks_obj, event);
        var kept = Array.init(a);
        for (arr_ptr.array.items) |item| {
            if (!isAgentWaymarkEntry(item)) try kept.append(item);
        }
        try kept.append(try hookEntry(a, exe, event, client, state));
        arr_ptr.* = .{ .array = kept };
    }

    try writeObject(io, a, path, root);
}

fn mergeClaudeMcp(io: std.Io, a: Allocator, path: []const u8, exe: []const u8, state: ?StatePaths) !void {
    var root = try readObject(io, a, path);
    const servers = try ensureObject(a, &root, "mcpServers");
    try putClaudeMcpServer(a, servers, exe, state);

    try writeObject(io, a, path, root);
}

fn putClaudeMcpServer(a: Allocator, servers: *Value, exe: []const u8, state: ?StatePaths) !void {
    var args_arr = Array.init(a);
    var entry: ObjectMap = .empty;
    if (state) |paths| {
        const command = try stateShellCommand(a, exe, "mcp", paths);
        try args_arr.append(.{ .string = "-lc" });
        try args_arr.append(.{ .string = command });
        try entry.put(a, "command", .{ .string = "sh" });
    } else {
        try args_arr.append(.{ .string = "mcp" });
        try entry.put(a, "command", .{ .string = exe });
    }
    try entry.put(a, "args", .{ .array = args_arr });
    try servers.object.put(a, server_name, .{ .object = entry });
}

fn mergeCodexMcp(io: std.Io, a: Allocator, path: []const u8, exe: []const u8, state: StatePaths) !void {
    const old = std.Io.Dir.cwd().readFileAlloc(io, path, a, .unlimited) catch |err| switch (err) {
        error.FileNotFound => "",
        else => return err,
    };
    const bytes = try codexMcpConfig(a, old, exe, state);
    try writeBytes(io, a, path, bytes);
}

fn mcpConfigBytes(a: Allocator, env: *std.process.Environ.Map, exe: []const u8, harness: []const u8, opts: InstallOptions) ![]const u8 {
    const state = if (opts.store_path) |store|
        try customState(a, store)
    else
        try userState(a, env);

    if (std.mem.eql(u8, harness, "claude")) return claudeMcpConfig(a, exe, state);
    if (std.mem.eql(u8, harness, "codex")) return codexMcpConfig(a, "", exe, state);
    return error.UnknownMcpConfigHarness;
}

fn claudeMcpConfig(a: Allocator, exe: []const u8, state: StatePaths) ![]const u8 {
    var root: Value = .{ .object = .empty };
    const servers = try ensureObject(a, &root, "mcpServers");
    try putClaudeMcpServer(a, servers, exe, state);
    return std.json.Stringify.valueAlloc(a, root, .{ .whitespace = .indent_2 });
}

fn codexMcpConfig(a: Allocator, old: []const u8, exe: []const u8, state: StatePaths) ![]const u8 {
    const kept = try removeTomlTable(a, old, codex_mcp_table);
    defer a.free(kept);

    const command = try stateShellCommand(a, exe, "mcp", state);
    defer a.free(command);

    const escaped = try tomlEscape(a, command);
    defer a.free(escaped);

    const block = try std.fmt.allocPrint(a,
        \\[mcp_servers.agent-waymark]
        \\command = "sh"
        \\args = ["-lc", "{s}"]
        \\startup_timeout_sec = 10
        \\tool_timeout_sec = 60
        \\
    , .{escaped});
    defer a.free(block);

    const sep: []const u8 = if (kept.len == 0 or std.mem.endsWith(u8, kept, "\n")) "" else "\n";
    return std.fmt.allocPrint(a, "{s}{s}{s}", .{ kept, sep, block });
}

// ---- json helpers ---------------------------------------------------------

fn readObject(io: std.Io, a: Allocator, path: []const u8) !Value {
    const bytes = std.Io.Dir.cwd().readFileAlloc(io, path, a, .unlimited) catch |err| switch (err) {
        error.FileNotFound => return .{ .object = .empty },
        else => return err,
    };
    if (bytes.len == 0) return .{ .object = .empty };
    const v = try std.json.parseFromSliceLeaky(Value, a, bytes, .{});
    return if (v == .object) v else .{ .object = .empty };
}

/// Write `root` pretty-printed, backing up an existing file to `<path>.bak`.
fn writeObject(io: std.Io, a: Allocator, path: []const u8, root: Value) !void {
    const bytes = try std.json.Stringify.valueAlloc(a, root, .{ .whitespace = .indent_2 });
    try writeBytes(io, a, path, bytes);
}

fn writeBytes(io: std.Io, a: Allocator, path: []const u8, bytes: []const u8) !void {
    const cwd = std.Io.Dir.cwd();
    if (cwd.readFileAlloc(io, path, a, .unlimited)) |old| {
        const bak = try std.fmt.allocPrint(a, "{s}.bak", .{path});
        try cwd.writeFile(io, .{ .sub_path = bak, .data = old });
    } else |_| {}
    try cwd.writeFile(io, .{ .sub_path = path, .data = bytes });
}

fn removeTomlTable(a: Allocator, bytes: []const u8, table: []const u8) ![]const u8 {
    var out: std.Io.Writer.Allocating = .init(a);
    const w = &out.writer;
    const prefix = try std.fmt.allocPrint(a, "[{s}", .{table});
    defer a.free(prefix);
    const exact = try std.fmt.allocPrint(a, "[{s}]", .{table});
    defer a.free(exact);
    var skip = false;
    var it = std.mem.splitScalar(u8, bytes, '\n');
    while (it.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r\n");
        if (std.mem.startsWith(u8, trimmed, "[")) {
            skip = std.mem.eql(u8, trimmed, exact) or
                (std.mem.startsWith(u8, trimmed, prefix) and trimmed.len > prefix.len and trimmed[prefix.len] == '.');
        }
        if (!skip) try w.print("{s}\n", .{line});
    }
    const written = try out.toOwnedSlice();
    errdefer a.free(written);
    const trimmed = std.mem.trim(u8, written, " \t\r\n");
    if (trimmed.ptr == written.ptr and trimmed.len == written.len) return written;

    const result = try a.dupe(u8, trimmed);
    a.free(written);
    return result;
}

fn tomlEscape(a: Allocator, s: []const u8) ![]const u8 {
    var out: std.Io.Writer.Allocating = .init(a);
    const w = &out.writer;
    for (s) |c| switch (c) {
        '\\' => try w.writeAll("\\\\"),
        '"' => try w.writeAll("\\\""),
        '\n' => try w.writeAll("\\n"),
        '\r' => try w.writeAll("\\r"),
        '\t' => try w.writeAll("\\t"),
        else => try w.writeByte(c),
    };
    return out.toOwnedSlice();
}

/// Get `parent[key]` as an object, creating it (or replacing a non-object) as
/// needed. `parent` must itself be an object.
fn ensureObject(a: Allocator, parent: *Value, key: []const u8) !*Value {
    if (parent.object.getPtr(key)) |v| {
        if (v.* == .object) return v;
    }
    try parent.object.put(a, key, .{ .object = .empty });
    return parent.object.getPtr(key).?;
}

fn ensureArray(a: Allocator, parent: *Value, key: []const u8) !*Value {
    if (parent.object.getPtr(key)) |v| {
        if (v.* == .array) return v;
    }
    try parent.object.put(a, key, .{ .array = Array.init(a) });
    return parent.object.getPtr(key).?;
}

fn hookEntry(a: Allocator, exe: []const u8, event: []const u8, client: HookClient, state: ?StatePaths) !Value {
    var inner: ObjectMap = .empty;
    try inner.put(a, "type", .{ .string = "command" });
    const command = switch (client) {
        .claude => if (state) |paths|
            try stateShellCommand(a, exe, try std.fmt.allocPrint(a, "hook {s}", .{event}), paths)
        else
            try std.fmt.allocPrint(a, "{s} hook {s}", .{ exe, event }),
        .codex => try stateShellCommand(a, exe, try std.fmt.allocPrint(a, "hook {s}", .{event}), state.?),
    };
    try inner.put(a, "command", .{ .string = command });

    var hooks_arr = Array.init(a);
    try hooks_arr.append(.{ .object = inner });

    var entry: ObjectMap = .empty;
    try entry.put(a, "hooks", .{ .array = hooks_arr });
    return .{ .object = entry };
}

fn stateShellCommand(a: Allocator, exe: []const u8, args: []const u8, paths: StatePaths) ![]const u8 {
    const quoted_dir = try shellQuote(a, paths.mkdir_path);
    defer a.free(quoted_dir);
    const quoted_socket = try shellQuote(a, paths.socket_path);
    defer a.free(quoted_socket);
    const quoted_store = try shellQuote(a, paths.store_path);
    defer a.free(quoted_store);
    const quoted_exe = try shellQuote(a, exe);
    defer a.free(quoted_exe);

    return std.fmt.allocPrint(
        a,
        "mkdir -p {s} && AGENT_WAYMARK_SOCKET={s} AGENT_WAYMARK_STORE={s} exec {s} {s}",
        .{ quoted_dir, quoted_socket, quoted_store, quoted_exe, args },
    );
}

fn parseOptions(args: []const []const u8) !InstallOptions {
    var opts: InstallOptions = .{};
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--user")) {
            opts.user = true;
        } else if (std.mem.eql(u8, arg, "--codex")) {
            opts.codex = true;
        } else if (std.mem.eql(u8, arg, "--global-mcp")) {
            opts.global_mcp = true;
        } else if (std.mem.eql(u8, arg, "--store") or std.mem.eql(u8, arg, "--store-path")) {
            i += 1;
            if (i >= args.len) return error.MissingStorePath;
            opts.store_path = args[i];
        } else if (std.mem.startsWith(u8, arg, "--store=")) {
            opts.store_path = arg["--store=".len..];
        } else if (std.mem.startsWith(u8, arg, "--store-path=")) {
            opts.store_path = arg["--store-path=".len..];
        } else if (std.mem.startsWith(u8, arg, "--")) {
            return error.UnknownInstallOption;
        }
    }
    return opts;
}

fn claudeState(a: Allocator, io: std.Io, env: *std.process.Environ.Map, opts: InstallOptions, mcp_global: bool) !?StatePaths {
    if (opts.store_path) |store| {
        const state = try customState(a, store);
        return state;
    }
    if (mcp_global) {
        const state = try userState(a, env);
        return state;
    }
    const state = try projectState(a, io);
    return state;
}

fn codexState(a: Allocator, io: std.Io, env: *std.process.Environ.Map, opts: InstallOptions, mcp_global: bool) !?StatePaths {
    if (opts.store_path) |store| {
        const state = try customState(a, store);
        return state;
    }
    if (mcp_global) {
        const state = try userState(a, env);
        return state;
    }
    const state = try projectState(a, io);
    return state;
}

fn projectState(a: Allocator, io: std.Io) !StatePaths {
    const root = scope_mod.projectRoot(a, io, null);
    const dir = try std.fs.path.join(a, &.{ root, project_state_dir });
    return .{
        .store_path = try std.fs.path.join(a, &.{ dir, "agent-waymark-state.json" }),
        .socket_path = try std.fs.path.join(a, &.{ dir, "agent-waymark.sock" }),
        .mkdir_path = dir,
    };
}

fn userState(a: Allocator, env: *std.process.Environ.Map) !StatePaths {
    const home = env.get("HOME") orelse return error.NoHomeDir;
    const dir = try std.fmt.allocPrint(a, "{s}/.agent-waymark", .{home});
    return .{
        .store_path = try std.fmt.allocPrint(a, "{s}/agent-waymark-state.json", .{dir}),
        .socket_path = try std.fmt.allocPrint(a, "{s}/agent-waymark.sock", .{dir}),
        .mkdir_path = dir,
    };
}

fn customState(a: Allocator, store_path: []const u8) !StatePaths {
    const socket_path = try std.fmt.allocPrint(a, "{s}.sock", .{store_path});
    return .{
        .store_path = store_path,
        .socket_path = socket_path,
        .mkdir_path = std.fs.path.dirname(store_path) orelse ".",
    };
}

fn shellQuote(a: Allocator, s: []const u8) ![]const u8 {
    var out: std.Io.Writer.Allocating = .init(a);
    const w = &out.writer;
    try w.writeByte('\'');
    for (s) |c| {
        if (c == '\'') {
            try w.writeAll("'\\''");
        } else {
            try w.writeByte(c);
        }
    }
    try w.writeByte('\'');
    return out.toOwnedSlice();
}

/// Recognize a hook group agent-waymark added (so re-install replaces rather than
/// duplicates) without touching the user's own hooks.
fn isAgentWaymarkEntry(item: Value) bool {
    if (item != .object) return false;
    const hv = item.object.get("hooks") orelse return false;
    if (hv != .array) return false;
    for (hv.array.items) |h| {
        if (h != .object) continue;
        const c = h.object.get("command") orelse continue;
        if (c == .string and
            std.mem.indexOf(u8, c.string, server_name) != null and
            std.mem.indexOf(u8, c.string, "hook") != null) return true;
    }
    return false;
}

fn report(comptime fmt: []const u8, args: anytype) void {
    if (builtin.is_test) return;
    std.debug.print(fmt ++ "\n", args);
}

test "removeTomlTable removes target table and subtables only" {
    const a = std.testing.allocator;
    const input =
        \\title = "keep"
        \\[mcp_servers.other]
        \\command = "other"
        \\[mcp_servers.agent-waymark]
        \\command = "old"
        \\[mcp_servers.agent-waymark.env]
        \\AGENT_WAYMARK_STORE = "old"
        \\[tools]
        \\enabled = true
        \\
    ;

    const out = try removeTomlTable(a, input, codex_mcp_table);
    defer a.free(out);

    try std.testing.expect(std.mem.indexOf(u8, out, "[mcp_servers.agent-waymark]") == null);
    try std.testing.expect(std.mem.indexOf(u8, out, "[mcp_servers.agent-waymark.env]") == null);
    try std.testing.expect(std.mem.indexOf(u8, out, "[mcp_servers.other]") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "[tools]") != null);
}

test "tomlEscape escapes basic string control characters" {
    const a = std.testing.allocator;
    const out = try tomlEscape(a, "a\"b\\c\n\t");
    defer a.free(out);

    try std.testing.expectEqualStrings("a\\\"b\\\\c\\n\\t", out);
}

test "shellQuote handles embedded single quotes" {
    const a = std.testing.allocator;
    const out = try shellQuote(a, "/tmp/it's/agent-waymark");
    defer a.free(out);

    try std.testing.expectEqualStrings("'/tmp/it'\\''s/agent-waymark'", out);
}

test "parseOptions accepts global MCP and store path" {
    const opts = try parseOptions(&.{ "--codex", "--global-mcp", "--store", "/tmp/waymark/state.json" });

    try std.testing.expect(opts.codex);
    try std.testing.expect(opts.global_mcp);
    try std.testing.expectEqualStrings("/tmp/waymark/state.json", opts.store_path.?);
}

test "stateShellCommand uses shared project daemon state" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var cwd = try TempCwd.enter(std.testing.io, tmp.dir);
    defer cwd.restore();

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // projectState resolves the enclosing git repo root (the tmp cwd sits
    // inside this repo's .zig-cache), so assert against the paths it actually
    // returned: the contract under test is that stateShellCommand embeds them.
    const state = try projectState(a, std.testing.io);
    const out = try stateShellCommand(a, "/tmp/it's/agent-waymark", "mcp", state);

    const mkdir = try std.fmt.allocPrint(a, "mkdir -p '{s}'", .{state.mkdir_path});
    const socket = try std.fmt.allocPrint(a, "AGENT_WAYMARK_SOCKET='{s}'", .{state.socket_path});
    const store = try std.fmt.allocPrint(a, "AGENT_WAYMARK_STORE='{s}'", .{state.store_path});

    try std.testing.expect(std.mem.indexOf(u8, out, mkdir) != null);
    try std.testing.expect(std.mem.indexOf(u8, out, socket) != null);
    try std.testing.expect(std.mem.indexOf(u8, out, store) != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "'/tmp/it'\\''s/agent-waymark' mcp") != null);
}

test "mcpConfigBytes emits Claude JSON with user state by default" {
    var env = std.process.Environ.Map.init(std.testing.allocator);
    defer env.deinit();
    try env.put("HOME", "/tmp/home");

    // mcpConfigBytes allocates intermediates it never frees: arena contract.
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const out = try mcpConfigBytes(a, &env, "/tmp/agent-waymark", "claude", .{});

    const parsed = try std.json.parseFromSlice(std.json.Value, a, out, .{});
    defer parsed.deinit();

    try std.testing.expect(std.mem.indexOf(u8, out, "\"mcpServers\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\"agent-waymark\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "AGENT_WAYMARK_STORE='/tmp/home/.agent-waymark/agent-waymark-state.json'") != null);
}

test "mcpConfigBytes emits Codex TOML with explicit store path" {
    var env = std.process.Environ.Map.init(std.testing.allocator);
    defer env.deinit();

    // mcpConfigBytes allocates intermediates it never frees: arena contract.
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const out = try mcpConfigBytes(a, &env, "/tmp/agent-waymark", "codex", .{ .store_path = "/tmp/waymark/state.json" });

    try std.testing.expect(std.mem.indexOf(u8, out, "[mcp_servers.agent-waymark]") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "command = \"sh\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "AGENT_WAYMARK_SOCKET='/tmp/waymark/state.json.sock'") != null);
}

test "codexMcpConfig is idempotent and preserves unrelated tables" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var cwd = try TempCwd.enter(std.testing.io, tmp.dir);
    defer cwd.restore();

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const old =
        \\profile = "default"
        \\[mcp_servers.other]
        \\command = "other"
        \\[mcp_servers.agent-waymark]
        \\command = "old"
        \\args = ["old"]
        \\[mcp_servers.agent-waymark.env]
        \\AGENT_WAYMARK_STORE = "old"
        \\
    ;

    const state = try projectState(a, std.testing.io);
    const once = try codexMcpConfig(a, old, "/tmp/agent-waymark", state);
    const twice = try codexMcpConfig(a, once, "/tmp/agent-waymark", state);

    try std.testing.expectEqualStrings(once, twice);
    try std.testing.expect(std.mem.indexOf(u8, once, "profile = \"default\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, once, "[mcp_servers.other]") != null);
    try std.testing.expect(std.mem.indexOf(u8, once, "[mcp_servers.agent-waymark]") != null);
    try std.testing.expect(std.mem.indexOf(u8, once, "command = \"old\"") == null);
    try std.testing.expect(std.mem.indexOf(u8, once, "[mcp_servers.agent-waymark.env]") == null);
}

test "project Claude install is idempotent and preserves existing config" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var cwd = try TempCwd.enter(std.testing.io, tmp.dir);
    defer cwd.restore();

    try std.Io.Dir.cwd().createDirPath(std.testing.io, ".claude");
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{
        .sub_path = ".claude/settings.json",
        .data =
        \\{
        \\  "theme": "dark",
        \\  "hooks": {
        \\    "SessionStart": [
        \\      {
        \\        "hooks": [
        \\          {
        \\            "type": "command",
        \\            "command": "echo user-hook"
        \\          }
        \\        ]
        \\      }
        \\    ]
        \\  }
        \\}
        ,
    });
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{
        .sub_path = ".mcp.json",
        .data =
        \\{
        \\  "mcpServers": {
        \\    "other": {
        \\      "command": "other"
        \\    }
        \\  }
        \\}
        ,
    });

    var env = std.process.Environ.Map.init(std.testing.allocator);
    defer env.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    try installClaude(std.testing.io, &env, arena.allocator(), "/tmp/agent-waymark", .{});
    try installClaude(std.testing.io, &env, arena.allocator(), "/tmp/agent-waymark", .{});

    const settings = try readCwdFile(std.testing.allocator, std.testing.io, ".claude/settings.json");
    defer std.testing.allocator.free(settings);
    const mcp_json = try readCwdFile(std.testing.allocator, std.testing.io, ".mcp.json");
    defer std.testing.allocator.free(mcp_json);

    try std.testing.expectEqual(@as(usize, 1), count(settings, "echo user-hook"));
    try std.testing.expectEqual(@as(usize, 1), count(settings, "hook SessionStart"));
    try std.testing.expectEqual(@as(usize, 1), count(settings, "hook UserPromptSubmit"));
    try std.testing.expectEqual(@as(usize, 1), count(settings, "hook SubagentStart"));
    try std.testing.expectEqual(@as(usize, 1), count(settings, "hook PreCompact"));
    try std.testing.expect(std.mem.indexOf(u8, settings, "AGENT_WAYMARK_STORE=") != null);
    try std.testing.expect(std.mem.indexOf(u8, mcp_json, "AGENT_WAYMARK_STORE=") != null);
    try std.testing.expect(std.mem.indexOf(u8, settings, "\"theme\": \"dark\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, mcp_json, "\"other\"") != null);
    try std.testing.expectEqual(@as(usize, 1), count(mcp_json, "\"agent-waymark\""));
}

test "Claude install can write global MCP with shared user state" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var cwd = try TempCwd.enter(std.testing.io, tmp.dir);
    defer cwd.restore();

    var env = std.process.Environ.Map.init(std.testing.allocator);
    defer env.deinit();
    try env.put("HOME", ".");
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    try installClaude(std.testing.io, &env, arena.allocator(), "/tmp/agent-waymark", .{ .global_mcp = true });
    try installClaude(std.testing.io, &env, arena.allocator(), "/tmp/agent-waymark", .{ .global_mcp = true });

    const settings = try readCwdFile(std.testing.allocator, std.testing.io, ".claude/settings.json");
    defer std.testing.allocator.free(settings);
    const mcp_json = try readCwdFile(std.testing.allocator, std.testing.io, ".claude.json");
    defer std.testing.allocator.free(mcp_json);

    try std.testing.expectEqual(@as(usize, 1), count(mcp_json, "\"agent-waymark\""));
    try std.testing.expect(std.mem.indexOf(u8, mcp_json, "\"command\": \"sh\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, mcp_json, "AGENT_WAYMARK_STORE='./.agent-waymark/agent-waymark-state.json'") != null);
    try std.testing.expect(std.mem.indexOf(u8, settings, "AGENT_WAYMARK_SOCKET='./.agent-waymark/agent-waymark.sock'") != null);
}

test "Claude user install writes user hooks and global MCP" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var cwd = try TempCwd.enter(std.testing.io, tmp.dir);
    defer cwd.restore();

    var env = std.process.Environ.Map.init(std.testing.allocator);
    defer env.deinit();
    try env.put("HOME", ".");
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    try installClaude(std.testing.io, &env, arena.allocator(), "/tmp/agent-waymark", .{ .user = true });

    const settings = try readCwdFile(std.testing.allocator, std.testing.io, ".claude/settings.json");
    defer std.testing.allocator.free(settings);
    const mcp_json = try readCwdFile(std.testing.allocator, std.testing.io, ".claude.json");
    defer std.testing.allocator.free(mcp_json);

    try std.testing.expect(std.mem.indexOf(u8, settings, "hook SessionStart") != null);
    try std.testing.expect(std.mem.indexOf(u8, settings, "AGENT_WAYMARK_STORE='./.agent-waymark/agent-waymark-state.json'") != null);
    try std.testing.expectEqual(@as(usize, 1), count(mcp_json, "\"agent-waymark\""));
}

test "Claude project install can use an explicit store path" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var cwd = try TempCwd.enter(std.testing.io, tmp.dir);
    defer cwd.restore();

    var env = std.process.Environ.Map.init(std.testing.allocator);
    defer env.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    try installClaude(std.testing.io, &env, arena.allocator(), "/tmp/agent-waymark", .{ .store_path = "/tmp/waymark/state.json" });

    const settings = try readCwdFile(std.testing.allocator, std.testing.io, ".claude/settings.json");
    defer std.testing.allocator.free(settings);
    const mcp_json = try readCwdFile(std.testing.allocator, std.testing.io, ".mcp.json");
    defer std.testing.allocator.free(mcp_json);

    try std.testing.expect(std.mem.indexOf(u8, settings, "mkdir -p '/tmp/waymark'") != null);
    try std.testing.expect(std.mem.indexOf(u8, settings, "AGENT_WAYMARK_STORE='/tmp/waymark/state.json'") != null);
    try std.testing.expect(std.mem.indexOf(u8, mcp_json, "AGENT_WAYMARK_SOCKET='/tmp/waymark/state.json.sock'") != null);
}

test "project Codex install is idempotent and preserves existing config" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var cwd = try TempCwd.enter(std.testing.io, tmp.dir);
    defer cwd.restore();

    try std.Io.Dir.cwd().createDirPath(std.testing.io, ".codex");
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{
        .sub_path = ".codex/config.toml",
        .data =
        \\profile = "default"
        \\[mcp_servers.other]
        \\command = "other"
        \\
        ,
    });
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{
        .sub_path = ".codex/hooks.json",
        .data =
        \\{
        \\  "hooks": {
        \\    "SessionStart": [
        \\      {
        \\        "hooks": [
        \\          {
        \\            "type": "command",
        \\            "command": "echo user-hook"
        \\          }
        \\        ]
        \\      }
        \\    ]
        \\  }
        \\}
        ,
    });

    var env = std.process.Environ.Map.init(std.testing.allocator);
    defer env.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    // projectState resolves the enclosing git repo root (the tmp cwd sits
    // inside this repo's .zig-cache); assert against what it returns.
    const state = try projectState(arena.allocator(), std.testing.io);
    const socket = try std.fmt.allocPrint(arena.allocator(), "AGENT_WAYMARK_SOCKET='{s}'", .{state.socket_path});

    try installCodex(std.testing.io, &env, arena.allocator(), "/tmp/agent-waymark", .{});
    try installCodex(std.testing.io, &env, arena.allocator(), "/tmp/agent-waymark", .{});

    const config = try readCwdFile(std.testing.allocator, std.testing.io, ".codex/config.toml");
    defer std.testing.allocator.free(config);
    const hooks_json = try readCwdFile(std.testing.allocator, std.testing.io, ".codex/hooks.json");
    defer std.testing.allocator.free(hooks_json);

    try std.testing.expect(std.mem.indexOf(u8, config, "profile = \"default\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, config, "[mcp_servers.other]") != null);
    try std.testing.expectEqual(@as(usize, 1), count(config, "[mcp_servers.agent-waymark]"));
    try std.testing.expectEqual(@as(usize, 1), count(config, socket));
    try std.testing.expectEqual(@as(usize, 1), count(hooks_json, "echo user-hook"));
    try std.testing.expectEqual(@as(usize, 1), count(hooks_json, "hook SessionStart"));
    try std.testing.expectEqual(@as(usize, 1), count(hooks_json, "hook UserPromptSubmit"));
    try std.testing.expectEqual(@as(usize, 1), count(hooks_json, "hook SubagentStart"));
    try std.testing.expectEqual(@as(usize, 1), count(hooks_json, "hook PreCompact"));
}

test "uninstall removes claude entries and preserves the rest" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var cwd = try TempCwd.enter(std.testing.io, tmp.dir);
    defer cwd.restore();

    try std.Io.Dir.cwd().createDirPath(std.testing.io, ".claude");
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{
        .sub_path = ".claude/settings.json",
        .data =
        \\{"hooks":{"SessionStart":[{"hooks":[{"type":"command","command":"echo user-hook"}]}]},"model":"opus"}
        ,
    });
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{
        .sub_path = ".mcp.json",
        .data =
        \\{"mcpServers":{"other":{"command":"other"}}}
        ,
    });

    var env = std.process.Environ.Map.init(std.testing.allocator);
    defer env.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    try installClaude(std.testing.io, &env, a, "/tmp/agent-waymark", .{});
    try uninstallClaude(std.testing.io, &env, a, .{});

    const settings = try readCwdFile(a, std.testing.io, ".claude/settings.json");
    const mcp_json = try readCwdFile(a, std.testing.io, ".mcp.json");

    try std.testing.expect(std.mem.indexOf(u8, settings, "agent-waymark") == null);
    try std.testing.expect(std.mem.indexOf(u8, settings, "echo user-hook") != null);
    try std.testing.expect(std.mem.indexOf(u8, settings, "\"model\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, mcp_json, "agent-waymark") == null);
    try std.testing.expect(std.mem.indexOf(u8, mcp_json, "\"other\"") != null);
}

test "uninstall removes codex entries and preserves the rest" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var cwd = try TempCwd.enter(std.testing.io, tmp.dir);
    defer cwd.restore();

    try std.Io.Dir.cwd().createDirPath(std.testing.io, ".codex");
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{
        .sub_path = ".codex/config.toml",
        .data =
        \\profile = "default"
        \\[mcp_servers.other]
        \\command = "other"
        \\
        ,
    });

    var env = std.process.Environ.Map.init(std.testing.allocator);
    defer env.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    try installCodex(std.testing.io, &env, a, "/tmp/agent-waymark", .{ .codex = true });
    try uninstallCodex(std.testing.io, &env, a, .{ .codex = true });

    const config = try readCwdFile(a, std.testing.io, ".codex/config.toml");
    const hooks_json = try readCwdFile(a, std.testing.io, ".codex/hooks.json");

    try std.testing.expect(std.mem.indexOf(u8, config, "agent-waymark") == null);
    try std.testing.expect(std.mem.indexOf(u8, config, "[mcp_servers.other]") != null);
    try std.testing.expect(std.mem.indexOf(u8, config, "profile = \"default\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, hooks_json, "agent-waymark") == null);
}

test "uninstall creates no files when nothing is installed" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var cwd = try TempCwd.enter(std.testing.io, tmp.dir);
    defer cwd.restore();

    var env = std.process.Environ.Map.init(std.testing.allocator);
    defer env.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    try uninstallClaude(std.testing.io, &env, a, .{});
    try uninstallCodex(std.testing.io, &env, a, .{ .codex = true });

    try std.testing.expectError(error.FileNotFound, readCwdFile(a, std.testing.io, ".claude/settings.json"));
    try std.testing.expectError(error.FileNotFound, readCwdFile(a, std.testing.io, ".mcp.json"));
    try std.testing.expectError(error.FileNotFound, readCwdFile(a, std.testing.io, ".codex/config.toml"));
}

test "project Codex install in linked worktree uses shared repo state" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var cwd = try TempCwd.enter(std.testing.io, tmp.dir);
    defer cwd.restore();

    const io = std.testing.io;
    const dir = std.Io.Dir.cwd();
    try dir.createDirPath(io, "main/.git/worktrees/feature");
    try dir.createDirPath(io, "linked");
    try dir.writeFile(io, .{ .sub_path = "main/.git/HEAD", .data = "ref: refs/heads/main\n" });
    try dir.writeFile(io, .{ .sub_path = "linked/.git", .data = "gitdir: ../main/.git/worktrees/feature\n" });
    try dir.writeFile(io, .{ .sub_path = "main/.git/worktrees/feature/HEAD", .data = "ref: refs/heads/feature\n" });
    try dir.writeFile(io, .{ .sub_path = "main/.git/worktrees/feature/commondir", .data = "../..\n" });

    try std.process.setCurrentPath(io, "linked");
    var env = std.process.Environ.Map.init(std.testing.allocator);
    defer env.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const expected_main = scope_mod.projectRoot(a, io, null);
    const expected_store = try std.fmt.allocPrint(a, "AGENT_WAYMARK_STORE='{s}/.agent-waymark/agent-waymark-state.json'", .{expected_main});

    try installCodex(io, &env, a, "/tmp/agent-waymark", .{});

    const config = try readCwdFile(std.testing.allocator, io, ".codex/config.toml");
    defer std.testing.allocator.free(config);

    try std.testing.expect(std.mem.indexOf(u8, config, expected_store) != null);
}

const TempCwd = struct {
    io: std.Io,
    old_path: [:0]u8,

    fn enter(io: std.Io, dir: std.Io.Dir) !TempCwd {
        const old_path = try std.process.currentPathAlloc(io, std.testing.allocator);
        errdefer std.testing.allocator.free(old_path);
        try std.process.setCurrentDir(io, dir);
        return .{ .io = io, .old_path = old_path };
    }

    fn restore(self: *TempCwd) void {
        std.process.setCurrentPath(self.io, self.old_path) catch {};
        std.testing.allocator.free(self.old_path);
        self.* = undefined;
    }
};

fn readCwdFile(a: Allocator, io: std.Io, path: []const u8) ![]u8 {
    return std.Io.Dir.cwd().readFileAlloc(io, path, a, .limited(1024 * 1024));
}

fn count(haystack: []const u8, needle: []const u8) usize {
    var n: usize = 0;
    var rest = haystack;
    while (std.mem.indexOf(u8, rest, needle)) |idx| {
        n += 1;
        rest = rest[idx + needle.len ..];
    }
    return n;
}

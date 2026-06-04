//! `cairn install` — register the MCP server and the hooks with Claude Code.
//!
//! Project scope (default): writes `.claude/settings.json` (hooks) and
//! `.mcp.json` (the MCP server) in the current directory. `--user` writes the
//! hooks to `~/.claude/settings.json` and prints the one MCP command, so a
//! single global install covers every repo (scope is derived per project at
//! runtime).
//!
//! The settings merge is careful: existing JSON is parsed, only cairn's own
//! hook entries are replaced (idempotent re-install), every other key is
//! preserved, and the prior file is backed up to `<name>.bak`.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Value = std.json.Value;
const ObjectMap = std.json.ObjectMap;
const Array = std.json.Array;

const events = [_][]const u8{ "SessionStart", "UserPromptSubmit", "SubagentStart" };

pub fn run(allocator: Allocator, io: std.Io, env: *std.process.Environ.Map, args: []const []const u8) !void {
    const user = hasFlag(args, "--user");
    const exe = try std.process.executablePathAlloc(io, allocator);
    defer allocator.free(exe);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const cwd = std.Io.Dir.cwd();
    const settings_path = if (user) blk: {
        const home = env.get("HOME") orelse return error.NoHomeDir;
        break :blk try std.fmt.allocPrint(a, "{s}/.claude/settings.json", .{home});
    } else blk: {
        cwd.createDirPath(io, ".claude") catch {};
        break :blk ".claude/settings.json";
    };

    try mergeHooks(io, a, settings_path, exe);

    if (user) {
        report("Hooks written to {s}", .{settings_path});
        report("Register the MCP server with:\n  claude mcp add --transport stdio cairn -- {s} mcp", .{exe});
    } else {
        try mergeMcp(io, a, ".mcp.json", exe);
        report("Wrote .claude/settings.json (hooks) and .mcp.json (MCP server).", .{});
        report("Restart Claude Code in this directory to pick them up.", .{});
    }
}

fn mergeHooks(io: std.Io, a: Allocator, path: []const u8, exe: []const u8) !void {
    var root = try readObject(io, a, path);
    const hooks_obj = try ensureObject(a, &root, "hooks");

    for (events) |event| {
        const arr_ptr = try ensureArray(a, hooks_obj, event);
        var kept = Array.init(a);
        for (arr_ptr.array.items) |item| {
            if (!isCairnEntry(item)) try kept.append(item);
        }
        try kept.append(try hookEntry(a, exe, event));
        arr_ptr.* = .{ .array = kept };
    }

    try writeObject(io, a, path, root);
}

fn mergeMcp(io: std.Io, a: Allocator, path: []const u8, exe: []const u8) !void {
    var root = try readObject(io, a, path);
    const servers = try ensureObject(a, &root, "mcpServers");

    var args_arr = Array.init(a);
    try args_arr.append(.{ .string = "mcp" });
    var entry: ObjectMap = .empty;
    try entry.put(a, "command", .{ .string = exe });
    try entry.put(a, "args", .{ .array = args_arr });
    try servers.object.put(a, "cairn", .{ .object = entry });

    try writeObject(io, a, path, root);
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
    const cwd = std.Io.Dir.cwd();
    if (cwd.readFileAlloc(io, path, a, .unlimited)) |old| {
        const bak = try std.fmt.allocPrint(a, "{s}.bak", .{path});
        try cwd.writeFile(io, .{ .sub_path = bak, .data = old });
    } else |_| {}

    const bytes = try std.json.Stringify.valueAlloc(a, root, .{ .whitespace = .indent_2 });
    try cwd.writeFile(io, .{ .sub_path = path, .data = bytes });
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

fn hookEntry(a: Allocator, exe: []const u8, event: []const u8) !Value {
    var inner: ObjectMap = .empty;
    try inner.put(a, "type", .{ .string = "command" });
    try inner.put(a, "command", .{ .string = try std.fmt.allocPrint(a, "{s} hook {s}", .{ exe, event }) });

    var hooks_arr = Array.init(a);
    try hooks_arr.append(.{ .object = inner });

    var entry: ObjectMap = .empty;
    try entry.put(a, "hooks", .{ .array = hooks_arr });
    return .{ .object = entry };
}

/// Recognize a hook group cairn added (so re-install replaces rather than
/// duplicates) without touching the user's own hooks.
fn isCairnEntry(item: Value) bool {
    if (item != .object) return false;
    const hv = item.object.get("hooks") orelse return false;
    if (hv != .array) return false;
    for (hv.array.items) |h| {
        if (h != .object) continue;
        const c = h.object.get("command") orelse continue;
        if (c == .string and
            std.mem.indexOf(u8, c.string, "cairn") != null and
            std.mem.indexOf(u8, c.string, "hook") != null) return true;
    }
    return false;
}

fn hasFlag(args: []const []const u8, name: []const u8) bool {
    for (args) |arg| if (std.mem.eql(u8, arg, name)) return true;
    return false;
}

fn report(comptime fmt: []const u8, args: anytype) void {
    std.debug.print(fmt ++ "\n", args);
}

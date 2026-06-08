//! Setup diagnostics for agent-waymark.

const std = @import("std");
const Allocator = std.mem.Allocator;

const daemon = @import("daemon.zig");
const client_mod = @import("client.zig");
const scope_mod = @import("scope.zig");

const Client = client_mod.Client;

const Status = enum { ok, warn, fail };

const Check = struct {
    status: Status,
    name: []const u8,
    detail: []const u8,
};

const JsonCheck = struct {
    status: []const u8,
    name: []const u8,
    detail: []const u8,
};

const JsonReport = struct {
    status: []const u8,
    ok: bool,
    checks: []const JsonCheck,
};

pub fn run(allocator: Allocator, io: std.Io, env: *std.process.Environ.Map, cfg: daemon.Config, args: []const []const u8) !void {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var buf: [16 * 1024]u8 = undefined;
    var fw: std.Io.File.Writer = .init(.stdout(), io, &buf);
    const w = &fw.interface;
    defer fw.interface.flush() catch {};

    const exe = try std.process.executablePathAlloc(io, a);
    const scope = scope_mod.detect(a, io, env, null);

    const checks = try collectChecks(a, allocator, io, cfg, exe, scope.branch_scope);
    if (hasFlag(args, "--json")) {
        try writeJson(w, a, checks);
        return;
    }

    try w.writeAll("agent-waymark doctor\n");
    for (checks) |check| try printCheck(w, check);
}

fn collectChecks(a: Allocator, allocator: Allocator, io: std.Io, cfg: daemon.Config, exe: []const u8, scope: []const u8) ![]Check {
    var checks = try a.alloc(Check, 9);
    checks[0] = .{ .status = .ok, .name = "binary", .detail = exe };
    checks[1] = .{ .status = .ok, .name = "socket", .detail = cfg.socket_path };
    checks[2] = .{ .status = .ok, .name = "store", .detail = cfg.store_path };
    checks[3] = .{ .status = .ok, .name = "scope", .detail = scope };
    checks[4] = try daemonCheck(a, allocator, io, cfg);
    checks[5] = try fileCheck(a, io, ".mcp.json", "Claude MCP", "\"agent-waymark\"");
    checks[6] = try fileCheck(a, io, ".claude/settings.json", "Claude hooks", "agent-waymark");
    checks[7] = try fileCheck(a, io, ".codex/config.toml", "Codex MCP", "[mcp_servers.agent-waymark]");
    checks[8] = try fileCheck(a, io, ".codex/hooks.json", "Codex hooks", "agent-waymark");
    return checks;
}

fn daemonCheck(a: Allocator, allocator: Allocator, io: std.Io, cfg: daemon.Config) !Check {
    var client: Client = undefined;
    client.init(allocator, io, cfg.socket_path) catch |err| {
        return .{
            .status = .warn,
            .name = "daemon",
            .detail = try std.fmt.allocPrint(a, "not reachable ({s}); normal clients will auto-start it", .{@errorName(err)}),
        };
    };
    defer client.deinit();

    var call_arena = std.heap.ArenaAllocator.init(allocator);
    defer call_arena.deinit();
    const parsed = client.call(call_arena.allocator(), .{ .op = "ping" }) catch |err| {
        return .{
            .status = .fail,
            .name = "daemon",
            .detail = try std.fmt.allocPrint(a, "connected but ping failed ({s})", .{@errorName(err)}),
        };
    };
    if (parsed.value.ok and std.mem.eql(u8, parsed.value.text orelse "", "pong")) {
        return .{ .status = .ok, .name = "daemon", .detail = "reachable" };
    }
    return .{ .status = .fail, .name = "daemon", .detail = parsed.value.@"error" orelse "unexpected ping response" };
}

fn fileCheck(a: Allocator, io: std.Io, path: []const u8, name: []const u8, needle: []const u8) !Check {
    return fileCheckInDir(a, io, std.Io.Dir.cwd(), path, name, needle);
}

fn fileCheckInDir(a: Allocator, io: std.Io, dir: std.Io.Dir, path: []const u8, name: []const u8, needle: []const u8) !Check {
    const bytes = dir.readFileAlloc(io, path, a, .limited(1024 * 1024)) catch |err| switch (err) {
        error.FileNotFound => return .{ .status = .warn, .name = name, .detail = try std.fmt.allocPrint(a, "{s} not found; run agent-waymark install", .{path}) },
        else => return .{ .status = .fail, .name = name, .detail = try std.fmt.allocPrint(a, "could not read {s} ({s})", .{ path, @errorName(err) }) },
    };
    defer a.free(bytes);
    if (std.mem.indexOf(u8, bytes, needle) != null) {
        return .{ .status = .ok, .name = name, .detail = path };
    }
    return .{ .status = .warn, .name = name, .detail = try std.fmt.allocPrint(a, "{s} has no agent-waymark entry; run agent-waymark install", .{path}) };
}

fn printCheck(w: *std.Io.Writer, check: Check) !void {
    try w.print("{s: >4}  {s}: {s}\n", .{ statusLabel(check.status), check.name, check.detail });
}

fn writeJson(w: *std.Io.Writer, a: Allocator, checks: []const Check) !void {
    const status = aggregateStatus(checks);
    const json_checks = try a.alloc(JsonCheck, checks.len);
    defer a.free(json_checks);
    for (checks, json_checks) |check, *json_check| {
        json_check.* = .{
            .status = statusLabel(check.status),
            .name = check.name,
            .detail = check.detail,
        };
    }

    const report: JsonReport = .{
        .status = statusLabel(status),
        .ok = status != .fail,
        .checks = json_checks,
    };
    const bytes = try std.json.Stringify.valueAlloc(a, report, .{});
    defer a.free(bytes);
    try w.writeAll(bytes);
    try w.writeByte('\n');
}

fn aggregateStatus(checks: []const Check) Status {
    var status: Status = .ok;
    for (checks) |check| switch (check.status) {
        .fail => return .fail,
        .warn => status = .warn,
        .ok => {},
    };
    return status;
}

fn statusLabel(status: Status) []const u8 {
    return switch (status) {
        .ok => "ok",
        .warn => "warn",
        .fail => "fail",
    };
}

fn hasFlag(args: []const []const u8, name: []const u8) bool {
    for (args) |arg| if (std.mem.eql(u8, arg, name)) return true;
    return false;
}

test "fileCheck reports missing config as warning" {
    var env = std.testing.tmpDir(.{});
    defer env.cleanup();

    const check = try fileCheckInDir(std.testing.allocator, std.testing.io, env.dir, ".codex/config.toml", "Codex MCP", "[mcp_servers.agent-waymark]");
    defer std.testing.allocator.free(check.detail);

    try std.testing.expectEqual(Status.warn, check.status);
    try std.testing.expectEqualStrings("Codex MCP", check.name);
}

test "fileCheck finds configured entry" {
    var env = std.testing.tmpDir(.{});
    defer env.cleanup();

    try env.dir.createDirPath(std.testing.io, ".codex");
    try env.dir.writeFile(std.testing.io, .{ .sub_path = ".codex/config.toml", .data = "[mcp_servers.agent-waymark]\ncommand = \"sh\"\n" });

    const check = try fileCheckInDir(std.testing.allocator, std.testing.io, env.dir, ".codex/config.toml", "Codex MCP", "[mcp_servers.agent-waymark]");
    try std.testing.expectEqual(Status.ok, check.status);
    try std.testing.expectEqualStrings(".codex/config.toml", check.detail);
}

test "writeJson emits aggregate status and checks" {
    const checks = [_]Check{
        .{ .status = .ok, .name = "binary", .detail = "/tmp/agent-waymark" },
        .{ .status = .warn, .name = "Codex hooks", .detail = "missing" },
    };
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();

    try writeJson(&out.writer, std.testing.allocator, &checks);
    const bytes = out.written();
    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, bytes, .{});
    defer parsed.deinit();

    try std.testing.expectEqualStrings("warn", parsed.value.object.get("status").?.string);
    try std.testing.expect(parsed.value.object.get("ok").?.bool);
    try std.testing.expectEqual(@as(usize, 2), parsed.value.object.get("checks").?.array.items.len);
}

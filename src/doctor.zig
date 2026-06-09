//! Setup diagnostics for agent-waymark.

const std = @import("std");
const Allocator = std.mem.Allocator;

const daemon = @import("daemon.zig");
const client_mod = @import("client.zig");
const scope_mod = @import("scope.zig");

const Client = client_mod.Client;

const Status = enum { ok, warn, fail };
const config_read_limit = 16 * 1024 * 1024;

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

const DaemonChecks = struct {
    daemon: Check,
    store: ?Check = null,
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

    const checks = try collectChecks(a, allocator, io, env, cfg, exe, scope.branch_scope);
    if (hasFlag(args, "--json")) {
        try writeJson(w, a, checks);
        return;
    }

    try w.writeAll("agent-waymark doctor\n");
    for (checks) |check| try printCheck(w, check);
}

fn collectChecks(a: Allocator, allocator: Allocator, io: std.Io, env: *std.process.Environ.Map, cfg: daemon.Config, exe: []const u8, scope: []const u8) ![]Check {
    var checks: std.ArrayList(Check) = .empty;
    try checks.append(a, .{ .status = .ok, .name = "binary", .detail = exe });
    try checks.append(a, .{ .status = .ok, .name = "socket", .detail = cfg.socket_path });
    try checks.append(a, .{ .status = .ok, .name = "store", .detail = cfg.store_path });
    try checks.append(a, .{ .status = .ok, .name = "scope", .detail = scope });
    const daemon_checks = try daemonCheck(a, allocator, io, cfg);
    try checks.append(a, daemon_checks.daemon);
    if (daemon_checks.store) |store| try checks.append(a, store);

    const home = env.get("HOME");
    try checks.append(a, try configCheck(
        a,
        io,
        "Claude MCP",
        ".mcp.json",
        try homePath(a, home, ".claude.json"),
        "\"agent-waymark\"",
        "agent-waymark install",
    ));
    try checks.append(a, try configCheck(
        a,
        io,
        "Claude hooks",
        ".claude/settings.json",
        try homePath(a, home, ".claude/settings.json"),
        "agent-waymark",
        "agent-waymark install",
    ));
    try checks.append(a, try configCheck(
        a,
        io,
        "Codex MCP",
        ".codex/config.toml",
        try homePath(a, home, ".codex/config.toml"),
        "[mcp_servers.agent-waymark]",
        "agent-waymark install --codex",
    ));
    try checks.append(a, try configCheck(
        a,
        io,
        "Codex hooks",
        ".codex/hooks.json",
        try homePath(a, home, ".codex/hooks.json"),
        "agent-waymark",
        "agent-waymark install --codex",
    ));
    return try checks.toOwnedSlice(a);
}

fn daemonCheck(a: Allocator, allocator: Allocator, io: std.Io, cfg: daemon.Config) !DaemonChecks {
    var client: Client = undefined;
    client.init(allocator, io, cfg.socket_path) catch |err| {
        return .{
            .daemon = .{
                .status = .warn,
                .name = "daemon",
                .detail = try std.fmt.allocPrint(a, "not reachable ({s}); normal clients will auto-start it", .{@errorName(err)}),
            },
        };
    };
    defer client.deinit();

    var call_arena = std.heap.ArenaAllocator.init(allocator);
    defer call_arena.deinit();
    const parsed = client.call(call_arena.allocator(), .{ .op = "info" }) catch |err| {
        return .{
            .daemon = .{
                .status = .fail,
                .name = "daemon",
                .detail = try std.fmt.allocPrint(a, "connected but info failed ({s})", .{@errorName(err)}),
            },
        };
    };
    if (!parsed.value.ok) return daemonPingFallback(a, &client, call_arena.allocator(), parsed.value.@"error" orelse "info unavailable");
    if (std.mem.eql(u8, parsed.value.text orelse "", "reachable")) {
        return .{
            .daemon = .{ .status = .ok, .name = "daemon", .detail = "reachable" },
            .store = .{
                .status = .ok,
                .name = "daemon store",
                .detail = try std.fmt.allocPrint(
                    a,
                    "{s} ({d} entries)",
                    .{ parsed.value.store_path orelse "unknown", parsed.value.count orelse 0 },
                ),
            },
        };
    }
    return .{
        .daemon = .{
            .status = .fail,
            .name = "daemon",
            .detail = parsed.value.@"error" orelse "unexpected info response",
        },
    };
}

fn daemonPingFallback(a: Allocator, client: *Client, call_a: Allocator, reason: []const u8) !DaemonChecks {
    const parsed = client.call(call_a, .{ .op = "ping" }) catch |err| {
        return .{
            .daemon = .{
                .status = .fail,
                .name = "daemon",
                .detail = try std.fmt.allocPrint(a, "connected but ping failed ({s})", .{@errorName(err)}),
            },
        };
    };
    if (parsed.value.ok and std.mem.eql(u8, parsed.value.text orelse "", "pong")) {
        return .{
            .daemon = .{ .status = .ok, .name = "daemon", .detail = "reachable" },
            .store = .{
                .status = .warn,
                .name = "daemon store",
                .detail = try std.fmt.allocPrint(a, "unknown ({s}); restart the daemon after upgrading", .{reason}),
            },
        };
    }
    return .{
        .daemon = .{
            .status = .fail,
            .name = "daemon",
            .detail = parsed.value.@"error" orelse "unexpected ping response",
        },
    };
}

fn fileCheck(a: Allocator, io: std.Io, path: []const u8, name: []const u8, needle: []const u8) !Check {
    return fileCheckInDir(a, io, std.Io.Dir.cwd(), path, name, needle);
}

const ConfigSource = struct {
    label: []const u8,
    path: []const u8,
    status: Status,
    configured: bool,
    problem: ?[]const u8 = null,
};

fn configCheck(
    a: Allocator,
    io: std.Io,
    name: []const u8,
    project_path: []const u8,
    user_path: ?[]const u8,
    needle: []const u8,
    install_cmd: []const u8,
) !Check {
    const project = try configSource(a, io, "project", project_path, needle);
    const user = if (user_path) |path| try configSource(a, io, "user", path, needle) else null;

    var configured: std.ArrayList([]const u8) = .empty;
    if (project.configured) try configured.append(a, try sourceDetail(a, project));
    if (user) |src| if (src.configured) try configured.append(a, try sourceDetail(a, src));
    if (configured.items.len > 0) {
        return .{ .status = .ok, .name = name, .detail = try joinDetails(a, configured.items) };
    }

    var failures: std.ArrayList([]const u8) = .empty;
    if (project.status == .fail) try failures.append(a, project.problem.?);
    if (user) |src| {
        if (src.status == .fail) try failures.append(a, src.problem.?);
    }
    if (failures.items.len > 0) {
        return .{ .status = .fail, .name = name, .detail = try joinDetails(a, failures.items) };
    }

    const user_hint = if (user_path) |path|
        try std.fmt.allocPrint(a, " or user {s}", .{path})
    else
        "";
    return .{
        .status = .warn,
        .name = name,
        .detail = try std.fmt.allocPrint(a, "not configured in project {s}{s}; run {s}", .{ project_path, user_hint, install_cmd }),
    };
}

fn configSource(a: Allocator, io: std.Io, label: []const u8, path: []const u8, needle: []const u8) !ConfigSource {
    const bytes = std.Io.Dir.cwd().readFileAlloc(io, path, a, .limited(config_read_limit)) catch |err| switch (err) {
        error.FileNotFound => return .{ .label = label, .path = path, .status = .warn, .configured = false },
        else => return .{
            .label = label,
            .path = path,
            .status = .fail,
            .configured = false,
            .problem = try std.fmt.allocPrint(a, "could not read {s} {s} ({s})", .{ label, path, @errorName(err) }),
        },
    };
    defer a.free(bytes);

    return .{
        .label = label,
        .path = path,
        .status = if (std.mem.indexOf(u8, bytes, needle) != null) .ok else .warn,
        .configured = std.mem.indexOf(u8, bytes, needle) != null,
    };
}

fn sourceDetail(a: Allocator, source: ConfigSource) ![]const u8 {
    return std.fmt.allocPrint(a, "{s} {s}", .{ source.label, source.path });
}

fn joinDetails(a: Allocator, items: []const []const u8) ![]const u8 {
    if (items.len == 0) return "";
    var total: usize = 0;
    for (items) |item| total += item.len;
    total += 2 * (items.len - 1);

    const out = try a.alloc(u8, total);
    var offset: usize = 0;
    for (items, 0..) |item, i| {
        if (i > 0) {
            @memcpy(out[offset..][0..2], "; ");
            offset += 2;
        }
        @memcpy(out[offset..][0..item.len], item);
        offset += item.len;
    }
    return out;
}

fn homePath(a: Allocator, home: ?[]const u8, sub_path: []const u8) !?[]const u8 {
    const root = home orelse return null;
    const path = try std.fmt.allocPrint(a, "{s}/{s}", .{ root, sub_path });
    return path;
}

fn fileCheckInDir(a: Allocator, io: std.Io, dir: std.Io.Dir, path: []const u8, name: []const u8, needle: []const u8) !Check {
    const bytes = dir.readFileAlloc(io, path, a, .limited(config_read_limit)) catch |err| switch (err) {
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

test "configCheck finds user config when project config is missing" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var cwd = try TempCwd.enter(std.testing.io, tmp.dir);
    defer cwd.restore();

    try std.Io.Dir.cwd().createDirPath(std.testing.io, ".home/.codex");
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{
        .sub_path = ".home/.codex/config.toml",
        .data = "[mcp_servers.agent-waymark]\ncommand = \"sh\"\n",
    });

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const check = try configCheck(
        arena.allocator(),
        std.testing.io,
        "Codex MCP",
        ".codex/config.toml",
        ".home/.codex/config.toml",
        "[mcp_servers.agent-waymark]",
        "agent-waymark install --codex",
    );

    try std.testing.expectEqual(Status.ok, check.status);
    try std.testing.expect(std.mem.indexOf(u8, check.detail, "user .home/.codex/config.toml") != null);
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

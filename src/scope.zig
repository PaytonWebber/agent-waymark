//! Scope derivation, shared by the MCP bridge and the hooks so both agree on
//! which project an entry belongs to. An explicit CAIRN_SCOPE always wins;
//! otherwise the scope is derived from the working directory (the hook event's
//! `cwd` when available, else the process cwd). Phase 4 will refine this to the
//! git repo root plus branch.

const std = @import("std");

pub fn forCwd(a: std.mem.Allocator, io: std.Io, env: *std.process.Environ.Map, cwd_override: ?[]const u8) ![]const u8 {
    if (env.get("CAIRN_SCOPE")) |s| return s;
    const cwd = cwd_override orelse (std.process.currentPathAlloc(io, a) catch return "");
    return std.fmt.allocPrint(a, "repo:{s}", .{cwd});
}

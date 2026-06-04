//! Scope derivation, shared by the CLI, the MCP bridge, and the hooks so they
//! agree on which project (and branch) an entry belongs to.
//!
//! Scope is hierarchical: a repo-wide entry lives at `repo:<root>` and a
//! branch-local entry at `repo:<root>/branch/<name>`. Reads run at the most
//! specific (branch) scope and the store returns any entry at or above it, so
//! repo-wide knowledge surfaces on every branch while branch-local work shows
//! only on its branch. Writes default to repo-wide; branch-local is opt-in.
//!
//! The root is the git toplevel (so subdirectories and worktrees of one repo
//! share state). The default branch (main/master) and non-git directories
//! collapse to repo-wide. An explicit CAIRN_SCOPE overrides everything.
//!
//! Detection reads `.git` directly rather than spawning git, to keep the
//! per-prompt hook fast.

const std = @import("std");

pub const Info = struct {
    /// Repo-wide scope: the default write level, and the read/write level on the
    /// trunk or outside a git repo.
    repo_scope: []const u8,
    /// Most-specific scope: used for reads, and for branch-local writes.
    branch_scope: []const u8,
};

pub fn detect(a: std.mem.Allocator, io: std.Io, env: *std.process.Environ.Map, cwd_override: ?[]const u8) Info {
    if (env.get("CAIRN_SCOPE")) |s| return .{ .repo_scope = s, .branch_scope = s };

    const cwd = cwd_override orelse (std.process.currentPathAlloc(io, a) catch return flat(""));
    const root = findGitRoot(a, io, cwd) orelse cwd;
    const repo_scope = std.fmt.allocPrint(a, "repo:{s}", .{root}) catch return flat("");

    if (readBranch(a, io, root)) |branch| {
        if (!isTrunk(branch)) {
            const bs = std.fmt.allocPrint(a, "{s}/branch/{s}", .{ repo_scope, branch }) catch repo_scope;
            return .{ .repo_scope = repo_scope, .branch_scope = bs };
        }
    }
    return .{ .repo_scope = repo_scope, .branch_scope = repo_scope };
}

fn flat(s: []const u8) Info {
    return .{ .repo_scope = s, .branch_scope = s };
}

fn isTrunk(branch: []const u8) bool {
    return std.mem.eql(u8, branch, "main") or std.mem.eql(u8, branch, "master");
}

/// Walk up from `start` to the directory containing `.git` (a dir for a normal
/// repo, a file for a worktree). Null if none is found.
fn findGitRoot(a: std.mem.Allocator, io: std.Io, start: []const u8) ?[]const u8 {
    var dir = start;
    while (true) {
        const dotgit = std.fs.path.join(a, &.{ dir, ".git" }) catch return null;
        if (std.Io.Dir.cwd().access(io, dotgit, .{})) |_| return dir else |_| {}
        const parent = std.fs.path.dirname(dir) orelse return null;
        if (std.mem.eql(u8, parent, dir)) return null;
        dir = parent;
    }
}

/// Current branch name from HEAD, or null if detached or unreadable. Handles a
/// worktree, whose `.git` is a file pointing at the real gitdir.
fn readBranch(a: std.mem.Allocator, io: std.Io, root: []const u8) ?[]const u8 {
    const cwd = std.Io.Dir.cwd();

    const head_path = std.fs.path.join(a, &.{ root, ".git", "HEAD" }) catch return null;
    if (cwd.readFileAlloc(io, head_path, a, .limited(4096))) |content| {
        return parseHead(content);
    } else |_| {}

    // Worktree: `.git` is a file "gitdir: <path>".
    const dotgit = std.fs.path.join(a, &.{ root, ".git" }) catch return null;
    const gf = cwd.readFileAlloc(io, dotgit, a, .limited(4096)) catch return null;
    const line = std.mem.trim(u8, gf, " \t\r\n");
    if (!std.mem.startsWith(u8, line, "gitdir:")) return null;
    const gitdir = std.mem.trim(u8, line["gitdir:".len..], " \t\r\n");
    const wt_head = if (std.fs.path.isAbsolute(gitdir))
        std.fs.path.join(a, &.{ gitdir, "HEAD" }) catch return null
    else
        std.fs.path.join(a, &.{ root, gitdir, "HEAD" }) catch return null;
    const content = cwd.readFileAlloc(io, wt_head, a, .limited(4096)) catch return null;
    return parseHead(content);
}

fn parseHead(content: []const u8) ?[]const u8 {
    const line = std.mem.trim(u8, content, " \t\r\n");
    const prefix = "ref: refs/heads/";
    return if (std.mem.startsWith(u8, line, prefix)) line[prefix.len..] else null;
}

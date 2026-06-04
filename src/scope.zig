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
//! share state). The repo's default branch and non-git directories collapse to
//! repo-wide. An explicit CAIRN_SCOPE overrides everything.
//!
//! Detection reads `.git` directly rather than spawning git, to keep the
//! per-prompt hook fast.

const std = @import("std");

pub const Info = struct {
    /// Repo-wide scope: the default write level, and the read/write level on the
    /// default branch or outside a git repo.
    repo_scope: []const u8,
    /// Most-specific scope: used for reads, and for branch-local writes.
    branch_scope: []const u8,
};

pub fn detect(a: std.mem.Allocator, io: std.Io, env: *std.process.Environ.Map, cwd_override: ?[]const u8) Info {
    if (env.get("CAIRN_SCOPE")) |s| return .{ .repo_scope = s, .branch_scope = s };

    const cwd = cwd_override orelse (std.process.currentPathAlloc(io, a) catch return flat(""));
    const root = findGitRoot(a, io, cwd) orelse
        return flat(std.fmt.allocPrint(a, "repo:{s}", .{cwd}) catch "");

    const repo_scope = std.fmt.allocPrint(a, "repo:{s}", .{root}) catch return flat("");
    const paths = gitPaths(a, io, root);

    if (readBranch(a, io, paths.head_path)) |branch| {
        if (!isDefaultBranch(a, io, paths.common_dir, branch)) {
            const bs = std.fmt.allocPrint(a, "{s}/branch/{s}", .{ repo_scope, branch }) catch repo_scope;
            return .{ .repo_scope = repo_scope, .branch_scope = bs };
        }
    }
    return .{ .repo_scope = repo_scope, .branch_scope = repo_scope };
}

fn flat(s: []const u8) Info {
    return .{ .repo_scope = s, .branch_scope = s };
}

/// True if `branch` is the repo's default branch. Prefers the actual default
/// (the symbolic ref `refs/remotes/origin/HEAD`, set when a remote exists);
/// falls back to the main/master convention for local-only repos.
fn isDefaultBranch(a: std.mem.Allocator, io: std.Io, common_dir: []const u8, branch: []const u8) bool {
    if (originDefault(a, io, common_dir)) |def| return std.mem.eql(u8, branch, def);
    return std.mem.eql(u8, branch, "main") or std.mem.eql(u8, branch, "master");
}

fn originDefault(a: std.mem.Allocator, io: std.Io, common_dir: []const u8) ?[]const u8 {
    const path = std.fs.path.join(a, &.{ common_dir, "refs", "remotes", "origin", "HEAD" }) catch return null;
    const content = std.Io.Dir.cwd().readFileAlloc(io, path, a, .limited(4096)) catch return null;
    return symref(content, "ref: refs/remotes/origin/");
}

const GitPaths = struct {
    head_path: []const u8, // file holding the current ref
    common_dir: []const u8, // the shared git dir (where refs/remotes lives)
};

/// Resolve the HEAD file and the common git dir, handling a worktree whose
/// `.git` is a file pointing at its per-worktree gitdir.
fn gitPaths(a: std.mem.Allocator, io: std.Io, root: []const u8) GitPaths {
    const cwd = std.Io.Dir.cwd();
    const dir_dotgit = std.fs.path.join(a, &.{ root, ".git" }) catch "";
    const dir_head = std.fs.path.join(a, &.{ root, ".git", "HEAD" }) catch "";
    const fallback: GitPaths = .{ .head_path = dir_head, .common_dir = dir_dotgit };

    // Normal repo: .git is a directory with HEAD in it.
    if (cwd.access(io, dir_head, .{})) |_| return fallback else |_| {}

    // Worktree: .git is a file "gitdir: <path>".
    const gf = cwd.readFileAlloc(io, dir_dotgit, a, .limited(4096)) catch return fallback;
    const line = std.mem.trim(u8, gf, " \t\r\n");
    if (!std.mem.startsWith(u8, line, "gitdir:")) return fallback;
    const gd_raw = std.mem.trim(u8, line["gitdir:".len..], " \t\r\n");
    const gitdir = if (std.fs.path.isAbsolute(gd_raw)) gd_raw else std.fs.path.join(a, &.{ root, gd_raw }) catch return fallback;

    var common_dir = gitdir;
    if (cwd.readFileAlloc(io, std.fs.path.join(a, &.{ gitdir, "commondir" }) catch "", a, .limited(4096))) |cd| {
        const cdt = std.mem.trim(u8, cd, " \t\r\n");
        common_dir = if (std.fs.path.isAbsolute(cdt)) cdt else std.fs.path.join(a, &.{ gitdir, cdt }) catch gitdir;
    } else |_| {}

    return .{ .head_path = std.fs.path.join(a, &.{ gitdir, "HEAD" }) catch dir_head, .common_dir = common_dir };
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

/// Current branch name from the HEAD file, or null if detached or unreadable.
fn readBranch(a: std.mem.Allocator, io: std.Io, head_path: []const u8) ?[]const u8 {
    const content = std.Io.Dir.cwd().readFileAlloc(io, head_path, a, .limited(4096)) catch return null;
    return symref(content, "ref: refs/heads/");
}

/// The target of a symbolic ref file (`ref: <prefix><name>`), returning `name`,
/// or null if the content is not that symref.
fn symref(content: []const u8, comptime prefix: []const u8) ?[]const u8 {
    const line = std.mem.trim(u8, content, " \t\r\n");
    return if (std.mem.startsWith(u8, line, prefix)) line[prefix.len..] else null;
}

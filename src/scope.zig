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
//! share state through the repo's common git dir). File refs still use the
//! active worktree root. The repo's default branch and non-git directories
//! collapse to repo-wide. An explicit AGENT_WAYMARK_SCOPE overrides everything.
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
    /// Actual working tree root used to resolve file refs. In a linked worktree,
    /// this is the linked worktree path, not the main repo path used for scope.
    worktree_root: []const u8,
};

pub fn detect(a: std.mem.Allocator, io: std.Io, env: *std.process.Environ.Map, cwd_override: ?[]const u8) Info {
    const cwd = cwd_override orelse (std.process.currentPathAlloc(io, a) catch return flat(""));
    if (env.get("AGENT_WAYMARK_SCOPE")) |s| return .{ .repo_scope = s, .branch_scope = s, .worktree_root = cwd };

    const worktree_root = findGitRoot(a, io, cwd) orelse
        return flat(std.fmt.allocPrint(a, "repo:{s}", .{cwd}) catch "");

    const paths = gitPaths(a, io, worktree_root);
    const repo_root = sharedRepoRoot(paths.common_dir) orelse worktree_root;
    const repo_scope = std.fmt.allocPrint(a, "repo:{s}", .{repo_root}) catch return flat("");

    if (readBranch(a, io, paths.head_path)) |branch| {
        if (!isDefaultBranch(a, io, paths.common_dir, branch)) {
            const bs = std.fmt.allocPrint(a, "{s}/branch/{s}", .{ repo_scope, branch }) catch repo_scope;
            return .{ .repo_scope = repo_scope, .branch_scope = bs, .worktree_root = worktree_root };
        }
    }
    return .{ .repo_scope = repo_scope, .branch_scope = repo_scope, .worktree_root = worktree_root };
}

fn flat(s: []const u8) Info {
    return .{ .repo_scope = s, .branch_scope = s, .worktree_root = if (std.mem.startsWith(u8, s, "repo:")) s["repo:".len..] else s };
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
    const gitdir = if (std.fs.path.isAbsolute(gd_raw)) gd_raw else std.fs.path.resolve(a, &.{ root, gd_raw }) catch return fallback;

    var common_dir = gitdir;
    if (cwd.readFileAlloc(io, std.fs.path.join(a, &.{ gitdir, "commondir" }) catch "", a, .limited(4096))) |cd| {
        const cdt = std.mem.trim(u8, cd, " \t\r\n");
        common_dir = if (std.fs.path.isAbsolute(cdt)) cdt else std.fs.path.resolve(a, &.{ gitdir, cdt }) catch gitdir;
    } else |_| {}

    return .{ .head_path = std.fs.path.join(a, &.{ gitdir, "HEAD" }) catch dir_head, .common_dir = common_dir };
}

fn sharedRepoRoot(common_dir: []const u8) ?[]const u8 {
    if (std.mem.eql(u8, std.fs.path.basename(common_dir), ".git")) {
        return std.fs.path.dirname(common_dir);
    }
    return null;
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

test "linked worktrees share repo scope but keep their own worktree root" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var cwd = try TempCwd.enter(std.testing.io, tmp.dir);
    defer cwd.restore();

    const io = std.testing.io;
    const dir = std.Io.Dir.cwd();
    try dir.createDirPath(io, "main/.git/refs/remotes/origin");
    try dir.createDirPath(io, "main/.git/worktrees/linked");
    try dir.createDirPath(io, "linked");
    try dir.writeFile(io, .{ .sub_path = "main/.git/HEAD", .data = "ref: refs/heads/main\n" });
    try dir.writeFile(io, .{ .sub_path = "main/.git/refs/remotes/origin/HEAD", .data = "ref: refs/remotes/origin/main\n" });
    try dir.writeFile(io, .{ .sub_path = "linked/.git", .data = "gitdir: ../main/.git/worktrees/linked\n" });
    try dir.writeFile(io, .{ .sub_path = "main/.git/worktrees/linked/HEAD", .data = "ref: refs/heads/feature\n" });
    try dir.writeFile(io, .{ .sub_path = "main/.git/worktrees/linked/commondir", .data = "../..\n" });

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var env = std.process.Environ.Map.init(std.testing.allocator);
    defer env.deinit();

    const root = try std.process.currentPathAlloc(io, a);
    const main = try std.fs.path.join(a, &.{ root, "main" });
    const linked = try std.fs.path.join(a, &.{ root, "linked" });

    const info = detect(a, io, &env, linked);
    try std.testing.expectEqualStrings(try std.fmt.allocPrint(a, "repo:{s}", .{main}), info.repo_scope);
    try std.testing.expectEqualStrings(try std.fmt.allocPrint(a, "repo:{s}/branch/feature", .{main}), info.branch_scope);
    try std.testing.expectEqualStrings(linked, info.worktree_root);
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

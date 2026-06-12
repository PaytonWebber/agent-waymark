//! Thin client to the daemon. Stateless: connect, send requests, read
//! responses. Pinned via `init(self, ...)` so the stream reader/writer keep a
//! stable address for the lifetime of the connection.

const std = @import("std");
const builtin = @import("builtin");
const net = std.Io.net;
const posix = std.posix;
const protocol = @import("protocol.zig");
const version = @import("version.zig").version;

const Allocator = std.mem.Allocator;
const Request = protocol.Request;
const Response = protocol.Response;

const buffer_size = 256 * 1024;
const connect_retry_count = 100;
const connect_retry_delay_ms = 50;

const DaemonConnectError = error{
    DaemonUnreachable,
    NameTooLong,
    ProcessFdQuotaExceeded,
    SystemFdQuotaExceeded,
    SystemResources,
    AddressFamilyUnsupported,
    ProtocolUnsupportedBySystem,
    SocketModeUnsupported,
    AccessDenied,
    PermissionDenied,
    SymLinkLoop,
    FileNotFound,
    NotDir,
    ReadOnlyFileSystem,
};

pub const Client = struct {
    io: std.Io,
    allocator: Allocator,
    stream: net.Stream,
    rbuf: []u8,
    wbuf: []u8,
    reader: net.Stream.Reader,
    writer: net.Stream.Writer,
    socket_path: []u8,
    /// Whether this client may spawn or replace daemons. Set by
    /// connectOrStart; plain init connections (probes, doctor) only observe.
    can_spawn: bool,

    pub fn init(self: *Client, allocator: Allocator, io: std.Io, socket_path: []const u8) !void {
        const stream = try quietConnect(socket_path);
        try self.finish(allocator, io, stream, socket_path, false);
    }

    /// Connect, or spawn the daemon (`<self> daemon`, inheriting our environment
    /// so it picks up the same AGENT_WAYMARK_* config) and connect once it is up. This
    /// is what makes the MCP bridge and the hooks "just work" without the user
    /// starting a daemon by hand.
    pub fn connectOrStart(self: *Client, allocator: Allocator, io: std.Io, socket_path: []const u8) !void {
        if (quietConnect(socket_path)) |stream| {
            return self.finish(allocator, io, stream, socket_path, true);
        } else |_| {}

        try spawnDaemon(allocator, io);
        const stream = try connectWithRetry(io, socket_path);
        return self.finish(allocator, io, stream, socket_path, true);
    }

    fn finish(self: *Client, allocator: Allocator, io: std.Io, stream: net.Stream, socket_path: []const u8, can_spawn: bool) !void {
        const rbuf = try allocator.alloc(u8, buffer_size);
        errdefer allocator.free(rbuf);
        const wbuf = try allocator.alloc(u8, buffer_size);
        errdefer allocator.free(wbuf);
        const path = try allocator.dupe(u8, socket_path);
        errdefer allocator.free(path);

        self.* = .{
            .io = io,
            .allocator = allocator,
            .stream = stream,
            .rbuf = rbuf,
            .wbuf = wbuf,
            .reader = stream.reader(io, rbuf),
            .writer = stream.writer(io, wbuf),
            .socket_path = path,
            .can_spawn = can_spawn,
        };
    }

    pub fn deinit(self: *Client) void {
        self.stream.close(self.io);
        self.allocator.free(self.rbuf);
        self.allocator.free(self.wbuf);
        self.allocator.free(self.socket_path);
        self.* = undefined;
    }

    /// Send one request and read one response. The result is parsed into
    /// `arena`; pass an arena allocator and ignore the returned `deinit`.
    ///
    /// Spawn-capable clients self-heal. A dead connection (most commonly the
    /// daemon being replaced under a long-lived MCP bridge after an upgrade)
    /// is reconnected and the request retried once. A response from a daemon
    /// of a different version (or one old enough not to report a version)
    /// triggers a replacement of that daemon before the retry, so upgrades
    /// take effect without anyone manually restarting anything.
    pub fn call(self: *Client, arena: Allocator, req: Request) !std.json.Parsed(Response) {
        const resp = self.send(arena, req) catch |err| {
            if (!self.can_spawn) return err;
            try self.reconnect();
            return self.send(arena, req);
        };
        if (!self.can_spawn or sameVersion(resp.value.version)) return resp;

        self.replaceDaemon(arena) catch return resp;
        return self.send(arena, req) catch resp;
    }

    fn send(self: *Client, arena: Allocator, req: Request) !std.json.Parsed(Response) {
        try protocol.writeLine(arena, &self.writer.interface, req);
        return protocol.readLine(Response, arena, &self.reader.interface);
    }

    fn attach(self: *Client, stream: net.Stream) void {
        self.stream = stream;
        self.reader = stream.reader(self.io, self.rbuf);
        self.writer = stream.writer(self.io, self.wbuf);
    }

    /// Reconnect after the daemon went away mid-connection: connect straight
    /// to its successor if one is already serving, otherwise spawn one.
    fn reconnect(self: *Client) !void {
        self.stream.close(self.io);
        if (quietConnect(self.socket_path)) |stream| return self.attach(stream) else |_| {}
        try spawnDaemon(self.allocator, self.io);
        self.attach(try connectWithRetry(self.io, self.socket_path));
    }

    /// Replace a stale daemon. Serialized across processes by a lock file,
    /// because hooks and the MCP bridge fire together at session start and
    /// must not race to unlink each other's freshly bound sockets. Under the
    /// lock: if a current-version daemon already answers, adopt it; otherwise
    /// ask the stale one to exit (pre-shutdown-op daemons ignore this and
    /// merely lose the socket path), unlink the socket, and start a fresh
    /// daemon from this binary. The snapshot is durable on every write, so
    /// the handover loses nothing.
    fn replaceDaemon(self: *Client, arena: Allocator) !void {
        {
            // The lock must be released before spawning: the new daemon
            // takes the same lock around its own probe-and-bind.
            const lock = acquireSocketLock(self.allocator, self.io, self.socket_path);
            defer if (lock) |f| f.close(self.io);

            self.stream.close(self.io);
            if (quietConnect(self.socket_path)) |stream| {
                self.attach(stream);
                if (self.send(arena, .{ .op = "ping" }) catch null) |pong| {
                    if (sameVersion(pong.value.version)) return; // already replaced
                    _ = self.send(arena, .{ .op = "shutdown" }) catch {};
                }
                self.stream.close(self.io);
            } else |_| {}

            terminateDaemonByPidFile(self.allocator, self.io, self.socket_path);
            std.Io.Dir.cwd().deleteFile(self.io, self.socket_path) catch {};
        }
        try spawnDaemon(self.allocator, self.io);
        self.attach(try connectWithRetry(self.io, self.socket_path));
    }
};

/// Best-effort cross-process mutex (`<socket>.lock`) serializing daemon
/// startup and replacement. flock is released by the OS if the holder dies,
/// so a crash cannot wedge it.
pub fn acquireSocketLock(allocator: Allocator, io: std.Io, socket_path: []const u8) ?std.Io.File {
    const path = std.fmt.allocPrint(allocator, "{s}.lock", .{socket_path}) catch return null;
    defer allocator.free(path);
    const file = std.Io.Dir.cwd().createFile(io, path, .{ .truncate = false }) catch return null;
    flockExclusive(file.handle);
    return file;
}

/// Terminate the daemon recorded in `<socket>.pid`, if it is still alive.
/// The daemon holds an exclusive flock on its pidfile for its lifetime, so a
/// grabbable lock means the owner is gone (nothing to kill) and a held lock
/// means the pid inside is trustworthy enough to SIGTERM. This is what keeps
/// replaced daemons from accumulating as orphaned processes.
pub fn terminateDaemonByPidFile(allocator: Allocator, io: std.Io, socket_path: []const u8) void {
    const path = std.fmt.allocPrint(allocator, "{s}.pid", .{socket_path}) catch return;
    defer allocator.free(path);
    const file = std.Io.Dir.cwd().openFile(io, path, .{}) catch return;
    defer file.close(io);
    if (tryFlockNb(file.handle)) {
        std.Io.Dir.cwd().deleteFile(io, path) catch {};
        return;
    }
    const bytes = std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(64)) catch return;
    defer allocator.free(bytes);
    const pid = std.fmt.parseInt(posix.pid_t, std.mem.trim(u8, bytes, " \r\n\t"), 10) catch return;
    posix.kill(pid, .TERM) catch return;
    std.Io.sleep(io, std.Io.Duration.fromMilliseconds(150), .awake) catch {};
}

pub fn flockExclusive(fd: posix.fd_t) void {
    switch (builtin.os.tag) {
        .linux => _ = std.os.linux.flock(fd, posix.LOCK.EX),
        else => _ = std.c.flock(fd, posix.LOCK.EX),
    }
}

/// Try to take an exclusive lock without blocking; true on success.
pub fn tryFlockNb(fd: posix.fd_t) bool {
    switch (builtin.os.tag) {
        .linux => return posix.errno(std.os.linux.flock(fd, posix.LOCK.EX | posix.LOCK.NB)) == .SUCCESS,
        else => return std.c.flock(fd, posix.LOCK.EX | posix.LOCK.NB) == 0,
    }
}

fn sameVersion(daemon_version: ?[]const u8) bool {
    const v = daemon_version orelse return false;
    return std.mem.eql(u8, v, version);
}

fn connectWithRetry(io: std.Io, socket_path: []const u8) !net.Stream {
    for (0..connect_retry_count) |_| {
        std.Io.sleep(io, std.Io.Duration.fromMilliseconds(connect_retry_delay_ms), .awake) catch {};
        if (quietConnect(socket_path)) |stream| return stream else |_| {}
    }
    return error.DaemonUnreachable;
}

// Zig 0.16 logs ECONNREFUSED from Unix connect as Unexpected. Use the syscall
// layer here so stale daemon sockets stay a normal retryable condition.
fn quietConnect(socket_path: []const u8) DaemonConnectError!net.Stream {
    const ua = try net.UnixAddress.init(socket_path);
    const fd = try openSocket();
    errdefer _ = posix.system.close(fd);

    var storage: extern union {
        any: posix.sockaddr,
        un: posix.sockaddr.un,
    } = undefined;
    const addr_len = unixAddressToPosix(&ua, &storage);
    try connectFd(fd, &storage.any, addr_len);

    return .{ .socket = .{
        .handle = fd,
        .address = .{ .ip4 = .loopback(0) },
    } };
}

fn openSocket() DaemonConnectError!posix.socket_t {
    while (true) {
        // Keep the socket type portable. Linux accepts SOCK_CLOEXEC here, but
        // macOS rejects it for Unix sockets on some releases.
        const rc = posix.system.socket(posix.AF.UNIX, posix.SOCK.STREAM, 0);
        switch (posix.errno(rc)) {
            .SUCCESS => return @intCast(rc),
            .INTR => continue,
            .AFNOSUPPORT => return error.AddressFamilyUnsupported,
            .INVAL => return error.ProtocolUnsupportedBySystem,
            .MFILE => return error.ProcessFdQuotaExceeded,
            .NFILE => return error.SystemFdQuotaExceeded,
            .NOBUFS, .NOMEM => return error.SystemResources,
            .PROTONOSUPPORT => return error.AddressFamilyUnsupported,
            .PROTOTYPE => return error.SocketModeUnsupported,
            else => return error.DaemonUnreachable,
        }
    }
}

fn connectFd(fd: posix.socket_t, addr: *const posix.sockaddr, addr_len: posix.socklen_t) DaemonConnectError!void {
    while (true) {
        switch (posix.errno(posix.system.connect(fd, addr, addr_len))) {
            .SUCCESS => return,
            .INTR => continue,
            .CONNREFUSED => return error.DaemonUnreachable,
            .AFNOSUPPORT => return error.AddressFamilyUnsupported,
            .AGAIN, .INPROGRESS => return error.DaemonUnreachable,
            .ACCES => return error.AccessDenied,
            .LOOP => return error.SymLinkLoop,
            .NOENT => return error.FileNotFound,
            .NOTDIR => return error.NotDir,
            .ROFS => return error.ReadOnlyFileSystem,
            .PERM => return error.PermissionDenied,
            else => return error.DaemonUnreachable,
        }
    }
}

fn unixAddressToPosix(a: *const net.UnixAddress, storage: anytype) posix.socklen_t {
    storage.un.family = posix.AF.UNIX;
    var path_len: usize = a.path.len;
    @memcpy(storage.un.path[0..path_len], a.path);
    if (storage.un.path.len - path_len > 0) {
        storage.un.path[path_len] = 0;
        path_len += 1;
    }
    return @intCast(@offsetOf(posix.sockaddr.un, "path") + path_len);
}

/// Spawn `<self-exe> daemon` detached, inheriting the current environment. The
/// child outlives this process and is shared by every other client.
fn spawnDaemon(allocator: Allocator, io: std.Io) !void {
    const exe = try std.process.executablePathAlloc(io, allocator);
    defer allocator.free(exe);
    var child = try std.process.spawn(io, .{
        .argv = &.{ exe, "daemon" },
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .ignore,
    });
    _ = &child; // detached: do not wait
}

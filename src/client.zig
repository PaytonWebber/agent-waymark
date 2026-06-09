//! Thin client to the daemon. Stateless: connect, send requests, read
//! responses. Pinned via `init(self, ...)` so the stream reader/writer keep a
//! stable address for the lifetime of the connection.

const std = @import("std");
const net = std.Io.net;
const posix = std.posix;
const protocol = @import("protocol.zig");

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

    pub fn init(self: *Client, allocator: Allocator, io: std.Io, socket_path: []const u8) !void {
        const stream = try quietConnect(socket_path);
        try self.finish(allocator, io, stream);
    }

    /// Connect, or spawn the daemon (`<self> daemon`, inheriting our environment
    /// so it picks up the same AGENT_WAYMARK_* config) and connect once it is up. This
    /// is what makes the MCP bridge and the hooks "just work" without the user
    /// starting a daemon by hand.
    pub fn connectOrStart(self: *Client, allocator: Allocator, io: std.Io, socket_path: []const u8) !void {
        if (quietConnect(socket_path)) |stream| {
            return self.finish(allocator, io, stream);
        } else |_| {}

        try spawnDaemon(allocator, io);

        for (0..connect_retry_count) |_| {
            std.Io.sleep(io, std.Io.Duration.fromMilliseconds(connect_retry_delay_ms), .awake) catch {};
            if (quietConnect(socket_path)) |stream| {
                return self.finish(allocator, io, stream);
            } else |_| {}
        }
        return error.DaemonUnreachable;
    }

    fn finish(self: *Client, allocator: Allocator, io: std.Io, stream: net.Stream) !void {
        const rbuf = try allocator.alloc(u8, buffer_size);
        errdefer allocator.free(rbuf);
        const wbuf = try allocator.alloc(u8, buffer_size);
        errdefer allocator.free(wbuf);

        self.* = .{
            .io = io,
            .allocator = allocator,
            .stream = stream,
            .rbuf = rbuf,
            .wbuf = wbuf,
            .reader = stream.reader(io, rbuf),
            .writer = stream.writer(io, wbuf),
        };
    }

    pub fn deinit(self: *Client) void {
        self.stream.close(self.io);
        self.allocator.free(self.rbuf);
        self.allocator.free(self.wbuf);
        self.* = undefined;
    }

    /// Send one request and read one response. The result is parsed into
    /// `arena`; pass an arena allocator and ignore the returned `deinit`.
    pub fn call(self: *Client, arena: Allocator, req: Request) !std.json.Parsed(Response) {
        try protocol.writeLine(arena, &self.writer.interface, req);
        return protocol.readLine(Response, arena, &self.reader.interface);
    }
};

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

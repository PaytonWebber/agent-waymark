//! Thin client to the daemon. Stateless: connect, send requests, read
//! responses. Pinned via `init(self, ...)` so the stream reader/writer keep a
//! stable address for the lifetime of the connection.

const std = @import("std");
const net = std.Io.net;
const protocol = @import("protocol.zig");

const Allocator = std.mem.Allocator;
const Request = protocol.Request;
const Response = protocol.Response;

const buffer_size = 256 * 1024;

pub const Client = struct {
    io: std.Io,
    allocator: Allocator,
    stream: net.Stream,
    rbuf: []u8,
    wbuf: []u8,
    reader: net.Stream.Reader,
    writer: net.Stream.Writer,

    pub fn init(self: *Client, allocator: Allocator, io: std.Io, socket_path: []const u8) !void {
        const addr = try net.UnixAddress.init(socket_path);
        const stream = try addr.connect(io);
        try self.finish(allocator, io, stream);
    }

    /// Connect, or spawn the daemon (`<self> daemon`, inheriting our environment
    /// so it picks up the same CAIRN_* config) and connect once it is up. This
    /// is what makes the MCP bridge and the hooks "just work" without the user
    /// starting a daemon by hand.
    pub fn connectOrStart(self: *Client, allocator: Allocator, io: std.Io, socket_path: []const u8) !void {
        const addr = try net.UnixAddress.init(socket_path);
        if (addr.connect(io)) |stream| {
            return self.finish(allocator, io, stream);
        } else |_| {}

        try spawnDaemon(allocator, io);

        var tries: usize = 0;
        while (tries < 100) : (tries += 1) {
            std.Io.sleep(io, std.Io.Duration.fromMilliseconds(50), .awake) catch {};
            if (addr.connect(io)) |stream| {
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

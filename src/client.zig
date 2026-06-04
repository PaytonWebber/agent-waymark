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

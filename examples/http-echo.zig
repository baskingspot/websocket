//! WebSocket echo over baskingspot/http.
//!
//! The HTTP half is `http.h1.ServerConn`, the same sans-I/O machine a plain
//! HTTP server drives: it parses the request, queues the response, and when
//! the response is a 101 it hands back the bytes the peer sent past the head.
//! Those bytes belong to the next protocol, and that is where this example
//! picks up.
//!
//!     just example-http
//!     curl -v http://127.0.0.1:8080/
//!
//! A request without upgrade headers gets a one-line page. A request with
//! `Upgrade: websocket` and `Sec-WebSocket-Key` gets the 101 and the frame
//! echo, whatever the path; a server with routes would check
//! `head.target` first.
//!
//! One connection at a time, deliberately: the point is the seam between the
//! two libraries, not a server design.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const print = std.debug.print;

const http = @import("http");
const ws = @import("websocket").server;

const page =
    "websocket echo server\n" ++
    "connect to /ws with an upgrade request\n";

pub fn main(init: std.process.Init.Minimal) !void {
    var debug_allocator: std.heap.DebugAllocator(.{}) = .init;
    defer _ = debug_allocator.deinit();
    const gpa = debug_allocator.allocator();

    var threaded: Io.Threaded = .init(gpa, .{ .environ = init.environ });
    defer threaded.deinit();
    const io = threaded.io();

    const port = parsePort(init.args);
    const address: Io.net.IpAddress = try .parseIp4("127.0.0.1", port);
    var listener = try address.listen(io, .{ .reuse_address = true });
    defer listener.deinit(io);

    print("http-echo: listening on 127.0.0.1:{d}\n", .{port});

    while (true) {
        const stream = listener.accept(io) catch |err| {
            print("accept error: {s}\n", .{@errorName(err)});
            continue;
        };
        handleConnection(gpa, io, stream) catch |err| {
            print("connection: {s}\n", .{@errorName(err)});
        };
    }
}

/// Everything one connection owns. The HTTP machine and the frame parser both
/// borrow these, so they live in the caller.
const Buffers = struct {
    request: [16 * 1024]u8 = undefined,
    headers: [64]http.Header = undefined,
    response_head: [1024]u8 = undefined,
    read: [4096]u8 = undefined,
    write: [4096]u8 = undefined,
};

fn handleConnection(gpa: Allocator, io: Io, stream: Io.net.Stream) !void {
    defer stream.close(io);

    var buffers: Buffers = .{};
    var conn: http.h1.ServerConn = .init(.{
        .request_buffer = &buffers.request,
        .headers = &buffers.headers,
        .response_buffer = &buffers.response_head,
    });

    var stream_reader = stream.reader(io, &buffers.read);
    var stream_writer = stream.writer(io, &buffers.write);
    const reader = &stream_reader.interface;
    const writer = &stream_writer.interface;

    var now = Io.Clock.awake.now(io);
    conn.start(now);

    while (true) {
        // One read, not a fill: the machine parses whatever arrived.
        const dst = conn.recvBuffer();
        var vec: [1][]u8 = .{dst};
        const n = reader.readVec(&vec) catch |err| switch (err) {
            error.EndOfStream => return,
            else => return err,
        };
        if (n == 0) return;
        now = Io.Clock.awake.now(io);

        const event = conn.received(n, now);
        switch (event) {
            .need_more => continue,
            .closed => return,
            .reject => {
                // The machine queued a policy response. Send it and stop.
                _ = try flushResponse(&conn, writer, io);
                return;
            },
            .request_head, .request => {},
        }

        // Both events carry the parsed head. A GET upgrade has no body, so
        // either one can be answered from the head alone.
        const head = switch (event) {
            .request => |request| request.head,
            .request_head => |head_event| head_event.head,
            else => unreachable,
        };

        if (head.headers.containsToken("upgrade", "websocket")) {
            try upgrade(&conn, writer, io, &head);
            // The 101 is on the wire and HTTP is finished. The bytes read
            // past the head are the first WebSocket frames.
            const leftover = conn.remainingInput();
            try echo(gpa, reader, writer, @constCast(leftover));
            return;
        }

        try conn.respond(.{
            .status = .ok,
            .content_type = "text/plain; charset=utf-8",
        }, page);
        switch (try flushResponse(&conn, writer, io)) {
            .keep_alive => continue,
            .more, .read => unreachable,
            .close, .close_after_drain, .switched => return,
        }
    }
}

/// Answer the upgrade from the head. `Sec-WebSocket-Accept` comes from the
/// client's key, which this library computes; everything else is HTTP.
fn upgrade(
    conn: *http.h1.ServerConn,
    writer: *Io.Writer,
    io: Io,
    head: *const http.h1.RequestHead,
) !void {
    const key = head.headers.get("sec-websocket-key") orelse
        return conn.respond(.{ .status = .bad_request }, "missing Sec-WebSocket-Key\n");

    var accept_buffer: ws.AcceptKey = undefined;
    const accept = ws.computeAcceptKey(key, &accept_buffer);

    try conn.switchProtocols(.{ .headers = &.{
        .{ .name = "Upgrade", .value = "websocket" },
        .{ .name = "Connection", .value = "Upgrade" },
        .{ .name = "Sec-WebSocket-Accept", .value = accept },
    } });

    const slices = conn.sendSlices();
    try writer.writeAll(slices.head);
    try writer.writeAll(slices.body);
    try writer.flush();
    const sent = conn.sent(slices.head.len + slices.body.len, Io.Clock.awake.now(io));
    std.debug.assert(sent == .switched);
}

/// Write whatever the machine queued, and report how the response ended.
fn flushResponse(conn: *http.h1.ServerConn, writer: *Io.Writer, io: Io) !http.h1.ServerConn.Done {
    while (true) {
        const slices = conn.sendSlices();
        if (slices.head.len == 0 and slices.body.len == 0) return .more;
        try writer.writeAll(slices.head);
        try writer.writeAll(slices.body);
        try writer.flush();
        switch (conn.sent(slices.head.len + slices.body.len, Io.Clock.awake.now(io))) {
            .more => continue,
            else => |done| return done,
        }
    }
}

/// The frame layer. `initial` is the input the HTTP machine read past the
/// request head; it is mutable because the parser unmasks server-side payloads
/// where they lie.
fn echo(gpa: Allocator, reader: *Io.Reader, writer: *Io.Writer, initial: []u8) !void {
    var handler: ws.FrameHandler = .init(.{});
    var message: std.ArrayList(u8) = .empty;
    defer message.deinit(gpa);

    var input = initial;
    while (true) {
        if (input.len != 0) {
            if (!try pump(gpa, &handler, &message, writer, input)) return;
            input = &.{};
        }

        reader.fill(1) catch return;
        const buffered = reader.buffered();
        if (buffered.len == 0) return;
        if (!try pump(gpa, &handler, &message, writer, buffered)) return;
        try writer.flush();
        reader.toss(buffered.len);
    }
}

/// Feed one buffer through the handler. Returns false when the peer closed.
fn pump(
    gpa: Allocator,
    handler: *ws.FrameHandler,
    message: *std.ArrayList(u8),
    writer: *Io.Writer,
    input: []u8,
) !bool {
    var data = input;
    while (true) {
        const result = handler.feed(data) catch {
            try ws.writeClose(writer, .protocol_error);
            return false;
        };
        data = data[result.consumed..];

        switch (result.message) {
            .data => |chunk| try message.appendSlice(gpa, chunk),
            .data_end => |end| {
                // Autobahn's 6.* cases send text that is not UTF-8. The
                // library moves bytes; a server that answers text has to
                // decide what valid means.
                if (end.opcode == .text and !std.unicode.utf8ValidateSlice(message.items)) {
                    try ws.writeClose(writer, .invalid_payload);
                    return false;
                }
                try ws.writeFrame(writer, message.items, .{ .opcode = end.opcode });
                message.clearRetainingCapacity();
            },
            .ping => |payload| try ws.writePong(writer, payload),
            .pong => {},
            .close => |payload| {
                const parsed = ws.parseClosePayload(payload) catch {
                    try ws.writeClose(writer, .protocol_error);
                    return false;
                };
                if (parsed) |closed| {
                    if (!std.unicode.utf8ValidateSlice(closed.reason)) {
                        try ws.writeClose(writer, .invalid_payload);
                        return false;
                    }
                }
                try ws.writeFrame(writer, payload, .{ .opcode = .close });
                return false;
            },
            .need_more => return true,
        }
    }
}

fn parsePort(args: std.process.Args) u16 {
    var it = args.iterate();
    _ = it.next();
    const port_str = it.next() orelse return 8080;
    return std.fmt.parseInt(u16, port_str, 10) catch 8080;
}

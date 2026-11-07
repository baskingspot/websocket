+++
title = "websocket"
+++

WebSocket frames and the upgrade handshake in Zig, with no IO and no allocator.

Zig's `std.http.Server` can answer a request and hand the connection to another
protocol, and nothing in `std` reads a WebSocket frame. A WebSocket library
usually arrives with a socket, a thread, and an allocator attached. This is the
frame layer only: you read the bytes, hand them over, and get frames back.

`Parser.feed` takes the bytes you already read and returns one event with the
count it consumed. `FrameHandler` sits above it and reassembles fragments into
messages. The parser holds a 14-byte header and the handler 125 bytes for a
control payload. Nothing else.

- [Frames](#frames): `Parser.feed` returns `.frame_header`, `.payload`, `.frame_end`, or `.need_more`, unmasks server-side payloads in the buffer you gave it, and keeps 14 bytes of header state.
- [Messages](#messages): `FrameHandler.feed` reassembles fragments and returns `.data`, `.data_end`, `.ping`, `.pong`, or `.close`.
- [Writing](#writing): `writeFrame` writes one frame, `MessageWriter` streams one message across several, and `FrameHeader.Buffer` serializes the header alone for a scatter-gather write.
- [Close](#close): `parseClosePayload` returns the `CloseCode` and the reason bytes, and rejects the codes RFC 6455 forbids on the wire.
- [Extensions](#extensions): `Extension` negotiates `permessage-deflate`, claims the RSV1 bit, and marks a written frame `.compressed`.
- [The upgrade](#the-upgrade): `computeAcceptKey`, `validateUpgradeRequest`, and `UpgradeResponse` cover the WebSocket half of the 101, and the HTTP half is the server's.
- [Conformance](#conformance): the Autobahn TestSuite runs against the echo server and the echo client, and the fast profile is a CI gate.

The [API reference](api/) documents every symbol.

# Getting started

## Install

```sh
zig fetch --save https://baskingspot.dev/websocket/v0.1.0.tar.gz
```

Add the module to `build.zig`:

```zig
const websocket = b.dependency("websocket", .{ .target = target, .optimize = optimize });
exe.root_module.addImport("websocket", websocket.module("websocket"));
```

`websocket` builds with Zig 0.16, which is `minimum_zig_version` in
`build.zig.zon`.

## Import it

```zig
const websocket = @import("websocket");
```

The package exports two namespaces, and you pick one by your role in the
connection. `websocket.server` parses masked frames and writes unmasked ones.
`websocket.client` parses unmasked frames and masks what it writes, in place,
in your buffer. Both namespaces use the same type names, so a program on both
sides of two connections aliases them:

```zig
const server_ws = @import("websocket").server;
const client_ws = @import("websocket").client;
```

## Read the examples

Each example is a complete program:

| Example           | What it shows                                                                                                              |
| ----------------- | -------------------------------------------------------------------------------------------------------------------------- |
| `blocking-echo`   | One connection at a time over `std.net`, the shortest correct loop.                                                        |
| `blocking-client` | The client role against `blocking-echo`.                                                                                   |
| `http-upgrade`    | A thread per connection with `std.http.Server`, a page on `/`, and an upgrade on `/ws`.                                    |
| `http-echo`       | The same upgrade through `baskingspot/http`: its HTTP/1 machine parses the request and hands over the bytes past the head. |
| `xev-echo`        | A completion-based server on libxev with connection pooling.                                                               |

`just examples` builds all five. The libxev and http dependencies are lazy, so
a project that does not build those examples never fetches them.

# Frames

`Parser` is the frame layer. It reads a frame header, hands you the payload
bytes where they already are, and tells you how much of the input it used.

```zig
const ws = @import("websocket").server;

var parser: ws.Parser = .init(.{});
while (true) {
    const result = try parser.feed(buf);
    buf = buf[result.consumed..];
    switch (result.event) {
        .frame_header => |header| try expectFin(header.fin),
        .payload => |bytes| try sink.writeAll(bytes),
        .frame_end => {},
        .need_more => break,
    }
}
```

Loop until `.need_more` or an empty buffer. `.consumed` counts the bytes the
parser took, which is the header bytes for `.frame_header` and the payload
bytes for `.payload`. Then read more from the socket and call `feed` again.

## The event union

`.frame_header` carries the decoded `FrameHeader`: `fin`, `opcode`, `payload_len`,
and `mask_key`. `.payload` is a slice of your own input buffer. On the server
side the bytes are already unmasked, which is why the buffer is mutable. A
frame longer than what you have read so far arrives as several `.payload`
events, so treat the payload as a stream and not as a message.

The parser rejects what RFC 6455 says to reject, as `ParseError`: a reserved
opcode, an RSV bit the negotiated extension did not claim, a control frame over
125 bytes or split across frames, a payload length written in a longer form than
it needs, and a mask on the wrong side. It does not reject a text payload that is
not UTF-8. That is the next section's problem or yours.

# Messages

`FrameHandler` wraps `Parser` and gives you messages. It runs the parser in a
loop and returns only the events a caller acts on.

```zig
const ws = @import("websocket").server;

var handler: ws.FrameHandler = .init(.{});
var message: std.ArrayList(u8) = .empty;
while (true) {
    const result = try handler.feed(buf);
    buf = buf[result.consumed..];
    switch (result.message) {
        .data => |chunk| try message.appendSlice(allocator, chunk),
        .data_end => |end| {
            defer message.clearRetainingCapacity();
            try handleMessage(allocator, end.opcode, message.items);
        },
        .ping => |payload| try ws.writePong(writer, payload),
        .close => |payload| {
            try ws.writeFrame(writer, payload, .{ .opcode = .close });
            return;
        },
        .need_more => break,
        .pong => {},
    }
}
```

## The event union

`.data` is one payload chunk and arrives once per frame fragment. `.data_end`
marks the last one and carries the message's `opcode` and a `compressed` flag,
and no bytes. `.ping`, `.pong`, and `.close` are complete control frames,
copied into the handler so the payload survives the next `feed`. A ping must be
answered with a pong that carries the same payload, and a close must be echoed
before the connection drops.

## Validate fragments yourself

`FrameHandler` runs `MessageValidator` on every header. A caller driving
`Parser` directly can run the same check and get the same errors,
`error.UnexpectedContinuation` and `error.ExpectedContinuation`. Control frames
may interleave inside a fragmented message, and the validator allows them.

# Writing

Every write goes to a `*std.Io.Writer` you own. The library never flushes, so
your loop can batch frames and flush once.

## Write one frame

```zig
try ws.writeFrame(writer, payload, .{ .opcode = .text });
try ws.writeClose(writer, .normal);
try ws.writePing(writer, payload);
try ws.writePong(writer, payload);
```

`WriteFrameOptions` has `opcode` and `compressed`. The helpers assert what RFC
6455 requires of the caller: no reserved opcode, no control frame over 125
bytes, and no compressed control frame. In the client namespace the payload is
`[]u8` because the mask is XOR'd into the buffer before it is written, so the
caller's bytes come back changed. Keep a copy, or mask a scratch buffer.

## Stream a message

`MessageWriter` splits one message into fragments without a payload buffer:

```zig
var msg: ws.MessageWriter = .init(writer, .{ .opcode = .text });
try msg.writeChunk(part1);
try msg.writeChunk(part2);
try msg.finish(part3);
```

Each `writeChunk` emits one non-final frame. `finish` emits the final one, and
`msg.finish(null)` sends it with no payload.

## Serialize the header alone

When the payload comes from somewhere else, such as a file descriptor or a
`writev` of several buffers, write the header and let the OS move the body:

```zig
const header: ws.FrameHeader.Buffer = .init(.{
    .opcode = .binary,
    .payload_len = payload_len,
});
try header.write(writer);
```

# Close

A close frame carries a two-byte code and, optionally, a reason. `CloseCode`
has the codes RFC 6455 defines, and `parseClosePayload` reads the pair back out:

```zig
if (try ws.parseClosePayload(payload)) |closed| {
    if (closed.code == .too_big) std.log.warn("peer refused: {s}", .{closed.reason});
}
```

An empty payload returns `null`, which RFC 6455 permits and means no code was
sent. A one-byte payload returns `error.InvalidClosePayloadLength`, and a code
that must not appear on the wire (1004, 1005, 1006, 1015) returns
`error.InvalidCloseCode`. `CloseCode.isValid` is the predicate behind that.

# Extensions

`permessage-deflate` (RFC 7692) is the one extension the library negotiates. It
does not link a deflate implementation. It sets and checks the RSV1 bit, writes
the `Sec-WebSocket-Extensions` header, and reports whether a message arrived
compressed:

```zig
var handler: ws.FrameHandler = .init(.{
    .extension = .{ .permessage_deflate = .init },
});
```

`Extension.DeflateConfig` holds the four negotiation parameters, and
`writeHeader` emits them. Inflating a payload whose `.data_end` reported
`compressed = true` is the caller's step, and so is deflating before setting
`.compressed = true` on a written frame. The test scaffolding in
`test/echo_server.zig` is a working example over zlib.

# The upgrade

RFC 6455 upgrades an HTTP/1.1 connection, so the handshake is split. The server
parses the request and produces the 101. This library does the WebSocket half of
both.

```zig
try ws.validateUpgradeRequest(.{
    .key = key,
    .version = version,
});

const response: ws.UpgradeResponse = .init(.{
    .key = key,
    .extension = negotiated,
});
try response.write(writer);
```

`computeAcceptKey` is the SHA-1 and base64 from RFC 6455 Section 4.2.2, written
into an `AcceptKey` buffer the caller owns. `UpgradeResponse` builds the whole
response in a fixed buffer: the status line, `Upgrade`, `Connection`, the accept
value, and the extension header when there is one.

## Where the HTTP half lives

`validateUpgradeRequest` wants two values, `Sec-WebSocket-Key` and
`Sec-WebSocket-Version`, and a caller already has them in the request it
parsed. With [baskingspot/http](https://baskingspot.dev/http/) that is
`h1.ServerConn`: after a request head, `switchProtocols` queues the 101, `sent`
returns `.switched`, and `remainingInput()` holds the bytes the peer sent past
the request. Those bytes are the first thing to feed `Parser`, and any HTTP
server that can end its own parsing there works the same way.
`examples/http-echo.zig` is the whole loop, and it passes the Autobahn profile:

```sh
just example-http          # serve on 127.0.0.1:8080
just conformance-http      # run the fast Autobahn profile against it
```

# Conformance

The [Autobahn TestSuite](https://github.com/crossbario/autobahn-testsuite) is
the protocol's test suite. It runs as a Python 2 program on PyPy, and the
devshell builds it from a pinned source checkout with a hashed sdist lock.

```sh
just conformance         # the fast profile: every case except 9.*, 12.*, and 13.*
just conformance-full    # every case
just report              # serve the last report at http://127.0.0.1:8080
```

The client role has its own profile, `just conformance-client`, which runs the
echo client against Autobahn's fuzzing server. `just conformance-xev` runs the
fast profile against the libxev example instead of the blocking echo server.

The fast profile is in `just ci`. The full profile takes over ten minutes and
needs about 2 GB of memory, so it runs by hand and not in CI. A pass means the frame layer follows RFC 6455 as Autobahn reads
it, including the fragmentation and control-frame cases a unit test tends to
miss.

# Limits

- No UTF-8 validation of text payloads. Autobahn's 6.* cases pass because the echo server validates before it echoes, and a library's job here is to move the bytes it was given.
- No HTTP parsing. `UpgradeRequest` holds two fields, and everything else about the request is the server's.
- No deflate. `permessage-deflate` is negotiation and the RSV1 bit, and the codec is yours.
- No allocator, no socket, no thread, no timer. State lives in the values you declare.
- No subprotocol negotiation. Callers read and write `Sec-WebSocket-Protocol` themselves.
- No server or client object. `Parser`, `FrameHandler`, and `MessageWriter` are values in your own connection loop.

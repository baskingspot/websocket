<h1>
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="docs/static/logo-dark.svg">
    <img src="docs/static/logo.svg" alt="websocket" height="48">
  </picture>
</h1>

WebSocket frames and the upgrade handshake in Zig, with no IO and no allocator.

Zig's `std.http.Server` has a WebSocket type that reads one message at a time
into its buffer. A message larger than that buffer is `error.MessageOversize`,
and so is a frame that is not the last of its message; `std.http` has no
client-side WebSocket at all. A real connection does all three. This is the
frame layer instead: you hand it the bytes you read, it returns frames, and
`FrameHandler` assembles a message as the bytes arrive.

`Parser.feed` takes the bytes you already read and returns one event with the
count it consumed. `FrameHandler` sits above it. The parser holds a 14-byte
header and the handler 125 bytes for a control payload. Nothing else.

## What is in it

- [Frames](https://baskingspot.dev/websocket/#frames): `Parser.feed` returns `.frame_header`, `.payload`, `.frame_end`, or `.need_more`, unmasks server-side payloads in the buffer you gave it, and keeps 14 bytes of header state.
- [Messages](https://baskingspot.dev/websocket/#messages): `FrameHandler.feed` reassembles fragments and returns `.data`, `.data_end`, `.ping`, `.pong`, or `.close`.
- [Writing](https://baskingspot.dev/websocket/#writing): `writeFrame` writes one frame, `MessageWriter` streams one message across several, and `FrameHeader.Buffer` serializes the header alone for a scatter-gather write.
- [Close](https://baskingspot.dev/websocket/#close): `parseClosePayload` returns the `CloseCode` and the reason bytes, and rejects the codes RFC 6455 forbids on the wire.
- [Extensions](https://baskingspot.dev/websocket/#extensions): `Extension` negotiates `permessage-deflate`, claims the RSV1 bit, and marks a written frame `.compressed`.
- [The upgrade](https://baskingspot.dev/websocket/#the-upgrade): `computeAcceptKey`, `validateUpgradeRequest`, and `UpgradeResponse` cover the WebSocket half of the 101, and the HTTP half is the server's.
- [Conformance](https://baskingspot.dev/websocket/#conformance): the Autobahn TestSuite runs against the echo server and the echo client, and the fast profile is a CI gate.

Not implemented:

- UTF-8 validation. A `text` message reaches your handler as the bytes arrived, and Autobahn's 6.* cases pass because the echo server validates before it echoes.
- HTTP parsing. `UpgradeRequest` carries `key` and `version` and nothing else; the rest of the request stays with your server.
- Deflate. `permessage-deflate` is negotiation and the RSV1 bit, and inflating a `.compressed` payload is the caller's library.
- Subprotocol negotiation. `Sec-WebSocket-Protocol` is yours to read and write.
- Any socket, thread, timer, or allocator.

## Install

```sh
zig fetch --save https://baskingspot.dev/websocket/v0.2.0.tar.gz
```

Add the module in `build.zig`:

```zig
const websocket = b.dependency("websocket", .{ .target = target, .optimize = optimize });
exe.root_module.addImport("websocket", websocket.module("websocket"));
```

The package exports `server` and `client` namespaces, so a program imports the
one for its side of the connection. `websocket` builds with Zig 0.16 and 0.17.

## Documentation

- The [guide](https://baskingspot.dev/websocket/) says which piece to use at each step of a connection, with the symbols a caller needs.
- The [API reference](https://baskingspot.dev/websocket/api/) documents every symbol.
- [`examples/`](examples/) holds four complete programs: a blocking echo server, its client, and two HTTP upgrades.

## Work on it

```sh
nix develop
just ci
```

`nix develop` provides the toolchain. `just ci` runs the tests, the lint, the
examples, the fast Autobahn profile, and the site build. `just conformance-full`
runs every Autobahn case, takes over ten minutes, and needs about 2 GB of
memory.

## License

MIT. See [`LICENSE`](LICENSE). The logo files in `docs/static/` are baskingspot
marks and are not covered by it. See
[`docs/static/LICENSE`](docs/static/LICENSE).

## How it's made

Built with LLM assistance. [How, in detail](https://github.com/baskingspot/.github/blob/main/docs/AI.md).

<a href="https://github.com/baskingspot"><img src="https://raw.githubusercontent.com/baskingspot/.github/main/brand/assets/badge.svg" alt="baskingspot" height="24"></a>

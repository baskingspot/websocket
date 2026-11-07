# Changelog

All notable changes to websocket are recorded here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [Unreleased]

## [0.1.0] - 2026-11-07

### Added

- `server` and `client` namespaces. Each re-exports the parser, the writer, and
  the close types for its role, so a program imports one and gets the frame
  rules that belong to it: a server unmasks what it reads and writes unmasked,
  a client does the reverse.
- `Parser`, the streaming frame parser. `feed` takes the bytes read from the
  socket and returns `.frame_header`, `.payload`, `.frame_end`, or
  `.need_more`, with the count it consumed. It reads payload bytes in place,
  unmasks them in the buffer it was given, and holds no allocation.
- `FrameHandler`, the message layer over `Parser`. It reassembles fragments
  and returns `.data`, `.data_end`, `.ping`, `.pong`, `.close`, or
  `.need_more`, with the 125-byte control payload kept in the handler itself.
- `MessageValidator`, the RFC 6455 Section 5.4 fragmentation check as a
  separate value, for a caller that drives `Parser` and wants
  `error.UnexpectedContinuation` and `error.ExpectedContinuation` instead of
  tracking the state by hand.
- `writeFrame`, `writeClose`, `writePing`, and `writePong`. `client.writeFrame`
  takes a mutable payload because RFC 6455 Section 5.3 makes it XOR the mask
  into the buffer before writing.
- `MessageWriter`, which streams one message across frames with `writeChunk`
  and `finish`, as `server.MessageWriter` and `client.MessageWriter`.
- `FrameHeader.Buffer`, the serialized header on its own for scatter-gather
  writes.
- `Mask`, `MaskKey`, and `client.generateMaskKey`: the four-byte key,
  `Mask.apply` for masking or unmasking a chunk, and a key from
  `std.crypto.random`.
- `CloseCode`, `ClosePayload`, and `parseClosePayload`: the RFC 6455 Section
  7.4 codes, plus a parser that rejects a one-byte payload and a code the
  wire forbids.
- `Extension` and `Extension.DeflateConfig`: the `permessage-deflate`
  negotiation (RFC 7692), the RSV1 bit, and the `compressed` flag on a written
  frame. Deflate itself is the caller's library.
- `computeAcceptKey`, `UpgradeRequest`, `validateUpgradeRequest`, and
  `UpgradeResponse`: the `Sec-WebSocket-Accept` value, the two WebSocket
  fields an upgrade request carries, their validation, and a complete 101
  response in a fixed buffer.
- The Autobahn TestSuite passes 247 of 247 cases in its fast profile against
  the echo server, and that profile is a CI gate.
- `examples/http-echo.zig`: the interop with `baskingspot/http`. Its
  `h1.ServerConn` parses the request, queues the 101, and `remainingInput()`
  hands the frame layer the bytes it read past the head. `just conformance-http`
  runs the fast Autobahn profile against it, and `just ci` runs that too.

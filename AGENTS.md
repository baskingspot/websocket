# websocket: agent notes

RFC 6455 frames and the upgrade handshake in Zig, with no IO and no allocator.
`README.md` is the user overview and `docs/content/_index.md` is the guide.
`docs/specs/rfc6455-websocket.txt` is the spec, vendored.

## Architecture

- `src/root.zig` is the module entry point. It exports the `client` and
  `server` namespaces, and nothing else. A caller picks a role, not a layer.
- `src/server.zig` re-exports the server-side types (`Parser`, `FrameHandler`,
  `MessageWriter`, `UpgradeRequest`, `UpgradeResponse`, the close types) and
  writes unmasked frames.
- `src/client.zig` re-exports the client-side types and writes masked frames.
  `client.writeFrame` takes `[]u8` because the mask is XOR'd into the buffer it
  was given.
- `src/frame.zig` holds the shared types (`Opcode`, `RsvBits`, `FrameHeader`,
  `Mask`, `MaskKey`, `Event`, `ParseError`, `WriteFrameOptions`),
  `BoundedBuffer`, `generateMaskKey`, and the integer helpers.
- `src/parse.zig` holds the streaming `Parser` (one generic over the role), the
  `MessageValidator`, and `FrameHandler`.
- `src/close.zig` holds `CloseCode`, `ClosePayload`, and `parseClosePayload`.
- `src/handshake.zig` holds `computeAcceptKey`, `UpgradeRequest`,
  `validateUpgradeRequest`, and `UpgradeResponse`.
- `src/message_writer.zig` holds the `MessageWriter` generic, instantiated as
  `ServerMessageWriter` and `ClientMessageWriter`.
- `src/extension.zig` holds `Extension` and its `permessage-deflate`
  configuration and header writer.
- `test/echo_server.zig` and `test/echo_client.zig` are scaffolding for the
  Autobahn suite. They are not part of the library, and they link zlib for
  permessage-deflate.
- `examples/` holds four complete programs. `xev-echo.zig` is the only one that
  needs the lazy libxev dependency.
- `.pi/skills/rfc6455/` is a quick reference to the vendored spec: section
  offsets into `docs/specs/rfc6455-websocket.txt`, the frame layout, and the
  close codes.

## Design decisions

- No UTF-8 validation. Text payloads are opaque bytes; the echo server
  validates so that Autobahn's 6.* cases pass. Adding validation to the parser
  would make a frame library decide what a message means.
- `permessage-deflate` is negotiation, not compression. The library sets RSV1,
  writes the extension header, and reports `compressed` on `.data_end` and
  `WriteFrameOptions`. It never calls a codec.
- No HTTP parsing. `UpgradeRequest` is two fields, and the caller's server owns
  the request. `baskingspot/http` is the pairing: `h1.ServerConn.switchProtocols`
  ends its own parsing at the 101 and `remainingInput()` hands over the bytes.
  The two packages do not depend on each other, and should not: the seam is the
  bytes.
- Role is a namespace, not a runtime flag. A server unmasks inbound frames and
  writes unmasked ones, a client does the reverse, and the compiler enforces
  which is which through two sets of functions with two signatures.

## Environment

- Zig 0.16 from the flake, through `baskingspot/nix`'s `zig."0.16"` module.
  Read the `zig-016` skill before writing Zig here.
- The flake is the environment. A missing tool goes in `flake.nix`; do not
  install it globally.
- The Autobahn runtime is Python 2 on PyPy, built from a pinned source checkout
  and the hashed sdist lock in `test/autobahn/requirements.txt`. Its
  `cryptography` sdist refuses OpenSSL 3, and nixpkgs removed `openssl_1_1` on
  2026-09-17, so the flake builds 1.1.1w itself for that one build. Do not
  widen its use.
- `just autobahn-setup` installs into `.autobahn/` and stamps it. It is
  idempotent, and every conformance recipe depends on it.

## Tasks

```
just test                    # unit tests
just fmt                     # zig fmt, nix fmt, oxfmt, just --fmt
just lint                    # the checks in `just fmt` plus ziglint and the house rules
just examples                # build every example
just conformance             # the fast Autobahn profile against the echo server
just conformance-full        # every Autobahn case, several minutes
just conformance-client      # the fast profile against the echo client
just conformance-xev         # the fast profile against the libxev example
just report                  # serve the last report on 127.0.0.1:8080
just doc                     # build the site into zig-out/site/websocket
just ci                      # what CI runs
```

`just ci` runs the fast profile, not `conformance-full`. The full profile takes
over ten minutes and grows to about two gigabytes under pypy, so it runs by hand
before a release.

The echo server binds 127.0.0.1:9002 and does not set `SO_REUSEADDR`, so a
conformance run started within a minute of the previous one fails with
`AddressInUse`. Wait, or change the port in `build.zig`.

## Docs

- The guide is `docs/content/_index.md` and the API page is `docs/data/api.json`,
  written by `docgen` in the `api` recipe. The theme comes from
  `baskingspot/nix`; do not copy templates or CSS into this repo.
- Human documents are the README, the guide, `CHANGELOG.md`, and anything in
  `docs/`. Agent material goes in `docs/slop/`, which no human document links.
  There is none yet.
- The tagline lives in five places and they move together: the README, the
  guide's first sentence, the first lines of `src/root.zig`, `description` in
  `docs/config.toml`, and the GitHub About text.

## Rules

- Commit messages are one line, `area: summary`, and every commit is signed.
  Do not rewrite pushed history.
- Never `git add -A` or `git add .`. Stage by path.
- Gate commands on their exit codes, and claim only what you ran.
- A new frame-level behavior gets a hostile-input test, and one that pins the
  RFC section it enforces.

## RFC reference

The full RFC 6455 text is `docs/specs/rfc6455-websocket.txt`. The quick
reference is `.pi/skills/rfc6455/`.

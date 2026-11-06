//! WebSocket frames and the upgrade handshake in Zig, with no IO and no allocator.
//!
//! Callers provide all buffers. The parser handles header parsing, payload
//! length decoding, and masking. Fragmentation sequencing and UTF-8 validation
//! are the caller's responsibility.
//!
//! ## Quick start
//!
//! Import the `server` or `client` namespace depending on your role:
//!
//! ```
//! const ws = @import("websocket").server;
//!
//! var parser: ws.Parser = .init(.{});
//! while (true) {
//!     const result = try parser.feed(buf);
//!     buf = buf[result.consumed..];
//!     switch (result.event) {
//!         .frame_header => |hdr| { ... },
//!         .payload => |data| { ... },
//!         .frame_end => {},
//!         .need_more => break,
//!     }
//! }
//! ```

const std = @import("std");
const testing = std.testing;

/// Client-role API for parsing unmasked inbound frames
/// and writing masked outbound frames.
pub const client = @import("client.zig");
/// Server-role API for parsing masked inbound frames,
/// writing unmasked outbound frames, and handling upgrades.
pub const server = @import("server.zig");

test {
    testing.refAllDecls(@This());
}

// The translation unit behind `@import("c")` in `echo_server.zig` and
// `echo_client.zig`. Zig 0.17 has no `@cImport`, so `build.zig` translates this
// header and the test scaffolding imports the result.
#include <zlib.h>

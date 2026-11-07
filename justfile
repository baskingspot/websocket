# websocket: RFC 6455 frames, masking, and the upgrade handshake in Zig, with no IO and no
# allocations. `just --list` shows the recipes. AGENTS.md holds the working conventions.

[private]
default:
    @just --list

[doc("Unit tests")]
[group("test")]
test:
    zig build test --summary all

[doc("Build every example under examples/")]
[group("example")]
examples:
    zig build examples

[doc("Install the native Autobahn TestSuite into the local PyPy environment. Every conformance recipe depends on this, and it does nothing when the install is current")]
[group("conformance")]
autobahn-setup:
    ./scripts/setup-autobahn-native.nu

[doc("Regenerate the hashed requirements lock in test/autobahn from PyPI")]
[group("conformance")]
autobahn-lock:
    ./scripts/generate-autobahn-lock.nu

[doc("Run wstest from the local PyPy environment, with the arguments given")]
[group("conformance")]
autobahn-wstest *ARGS: autobahn-setup
    ./scripts/wstest-native.nu {{ ARGS }}

[doc("Run the fast Autobahn profile against the echo server: every case except 9.*, 12.*, and 13.*")]
[group("conformance")]
conformance *ARGS: autobahn-setup
    zig build conformance {{ ARGS }}

[doc("Run the full Autobahn profile against the echo server")]
[group("conformance")]
conformance-full *ARGS: autobahn-setup
    zig build conformance-full {{ ARGS }}

[doc("Run the fast Autobahn profile against the echo client")]
[group("conformance")]
conformance-client: autobahn-setup
    zig build conformance-client

[doc("Run the full Autobahn profile against the echo client")]
[group("conformance")]
conformance-client-full: autobahn-setup
    zig build conformance-client-full

[doc("Run the fast Autobahn profile against the libxev example")]
[group("conformance")]
conformance-xev: autobahn-setup
    zig build conformance-xev

[doc("Serve the last Autobahn report at http://127.0.0.1:PORT")]
[group("conformance")]
report PORT="8080": autobahn-setup
    @echo "http://localhost:{{ PORT }}/index.html"
    python3 -m http.server -d test/autobahn/reports -b 127.0.0.1 {{ PORT }}

[doc("Lint Zig, Nushell, Nix, Markdown, the workflows, and this justfile: ziglint-0-16, the ast-grep house rules, zig fmt, nufmt, nix fmt, oxfmt, actionlint, zizmor, and just --fmt")]
[group("lint")]
lint:
    ziglint-0-16
    baskingspot-lint src
    zig fmt --check src test examples build.zig build.zig.zon
    nufmt --dry-run --all-recurse
    nix fmt -- --ci
    oxfmt --check .oxfmtrc.jsonc README.md AGENTS.md CHANGELOG.md docs/content docs/config.toml .github
    actionlint
    zizmor .
    just --fmt --check

[doc("Format everything lint checks")]
[group("lint")]
fmt:
    zig fmt src test examples build.zig build.zig.zon
    nufmt --all-recurse
    nix fmt
    oxfmt .oxfmtrc.jsonc README.md AGENTS.md CHANGELOG.md docs/content docs/config.toml .github
    just --fmt

# The API reference data. docgen comes from the baskingspot flake's docs shell,
# so this is not a Zig build dependency.
[private]
api:
    docgen --root src/root.zig --out docs/data --format json --title websocket --repo-url https://github.com/baskingspot/websocket --rev main

[doc("Build the site into zig-out/site/websocket/: the guide (Zola, from docs/) and the API reference (docgen JSON, rendered by the theme's api.html) under api/. The router in baskingspot/site serves /websocket/... from it")]
[group("docs")]
doc: api
    baskingspot-docs build websocket

[doc("Edit the guide with live reload (http://127.0.0.1:1111), API reference included")]
[group("docs")]
guide: api
    baskingspot-docs serve websocket

[doc("Deploy the rendered docs to Cloudflare as an assets-only Worker (config in wrangler.jsonc). Needs CLOUDFLARE_API_TOKEN in the environment, plus CLOUDFLARE_ACCOUNT_ID if the token can see more than one account")]
[group("docs")]
doc-deploy: doc
    wrangler deploy

[doc("Everything CI runs")]
[group("ci")]
ci: test lint examples conformance doc

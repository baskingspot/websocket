const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const mod = b.addModule("websocket", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
    });

    // The only exported module. Everything below is developer-only: returning
    // early for a consumer keeps testingx, libxev, and the test binaries out
    // of its fetch path.
    if (b.pkg_hash.len != 0) return;

    // testingx provides the test runner and the bench engine. It is lazy
    // because only the root build uses it; a consumer never fetches it. On the
    // first configure pass it is not fetched yet, `lazyDependency` returns
    // null, and the build runner fetches it and reruns this script.
    const testingx_dep = b.lazyDependency("testingx", .{ .target = target });
    const test_runner: ?std.Build.Step.Compile.TestRunner = if (testingx_dep) |dep|
        .{ .path = dep.path("src/runner.zig"), .mode = .simple }
    else
        null;

    const mod_tests = b.addTest(.{
        .root_module = mod,
        .test_runner = test_runner,
    });
    const run_mod_tests = b.addRunArtifact(mod_tests);
    passthruArgs(b, run_mod_tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_mod_tests.step);

    const echo_server = b.addExecutable(.{
        .name = "echo-server",
        .root_module = b.createModule(.{
            .root_source_file = b.path("test/echo_server.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
            .imports = &.{
                .{ .name = "websocket", .module = mod },
            },
        }),
    });
    echo_server.root_module.linkSystemLibrary("zlib", .{ .use_pkg_config = .force });

    b.installArtifact(echo_server);

    const echo_run = b.addRunArtifact(echo_server);
    passthruArgs(b, echo_run);

    const echo_step = b.step("echo-server", "Run the Autobahn echo server");
    echo_step.dependOn(&echo_run.step);

    const echo_client = b.addExecutable(.{
        .name = "echo-client",
        .root_module = b.createModule(.{
            .root_source_file = b.path("test/echo_client.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
            .imports = &.{
                .{ .name = "websocket", .module = mod },
            },
        }),
    });
    echo_client.root_module.linkSystemLibrary("zlib", .{ .use_pkg_config = .force });
    b.installArtifact(echo_client);

    const examples_step = b.step("examples", "Build all examples");

    const blocking_echo = b.addExecutable(.{
        .name = "blocking-echo",
        .root_module = b.createModule(.{
            .root_source_file = b.path("examples/blocking-echo.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "websocket", .module = mod },
            },
        }),
    });
    b.installArtifact(blocking_echo);
    examples_step.dependOn(&blocking_echo.step);

    const http_upgrade = b.addExecutable(.{
        .name = "http-upgrade",
        .root_module = b.createModule(.{
            .root_source_file = b.path("examples/http-upgrade.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "websocket", .module = mod },
            },
        }),
    });
    b.installArtifact(http_upgrade);
    examples_step.dependOn(&http_upgrade.step);

    const blocking_client = b.addExecutable(.{
        .name = "blocking-client",
        .root_module = b.createModule(.{
            .root_source_file = b.path("examples/blocking-client.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "websocket", .module = mod },
            },
        }),
    });
    b.installArtifact(blocking_client);
    examples_step.dependOn(&blocking_client.step);

    const run_autobahn = b.path("scripts/run-autobahn.nu");

    // The suite leaves the port in TIME_WAIT for a minute after a run, so a
    // second run against the same port fails to bind. Pick another one with
    // `-Dport=9003`, or because another checkout already holds 9002.
    const conformance_port = b.option(
        u16,
        "port",
        "Port for the conformance echo server (default 9002)",
    ) orelse 9002;
    const conformance_port_arg = b.fmt("{d}", .{conformance_port});

    const conformance_script = b.addSystemCommand(&.{"nu"});
    conformance_script.addFileArg(run_autobahn);
    conformance_script.addArtifactArg(echo_server);
    conformance_script.addArgs(&.{ conformance_port_arg, "echo-server", "fast" });
    conformance_script.step.dependOn(&echo_server.step);
    conformance_script.step.dependOn(&b.addInstallArtifact(echo_server, .{}).step);

    const conformance_step = b.step("conformance", "Run the fast Autobahn conformance suite");
    conformance_step.dependOn(&conformance_script.step);

    const conformance_full_script = b.addSystemCommand(&.{"nu"});
    conformance_full_script.addFileArg(run_autobahn);
    conformance_full_script.addArtifactArg(echo_server);
    conformance_full_script.addArgs(&.{ conformance_port_arg, "echo-server", "full" });
    conformance_full_script.step.dependOn(&b.addInstallArtifact(echo_server, .{}).step);

    const conformance_full_step = b.step(
        "conformance-full",
        "Run the full Autobahn conformance test suite",
    );
    conformance_full_step.dependOn(&conformance_full_script.step);

    const run_autobahn_client = b.path("scripts/run-autobahn-client.nu");

    const conformance_client_script = b.addSystemCommand(&.{"nu"});
    conformance_client_script.addFileArg(run_autobahn_client);
    conformance_client_script.addArtifactArg(echo_client);
    conformance_client_script.addArgs(&.{ "9001", "echo-client", "fast" });
    conformance_client_script.step.dependOn(&b.addInstallArtifact(echo_client, .{}).step);

    const conformance_client_step = b.step(
        "conformance-client",
        "Run the fast Autobahn client conformance suite",
    );
    conformance_client_step.dependOn(&conformance_client_script.step);

    const conformance_client_full_script = b.addSystemCommand(&.{"nu"});
    conformance_client_full_script.addFileArg(run_autobahn_client);
    conformance_client_full_script.addArtifactArg(echo_client);
    conformance_client_full_script.addArgs(&.{ "9001", "echo-client", "full" });
    conformance_client_full_script.step.dependOn(&b.addInstallArtifact(echo_client, .{}).step);

    const conformance_client_full_step = b.step(
        "conformance-client-full",
        "Run the full Autobahn client conformance test suite",
    );
    conformance_client_full_step.dependOn(&conformance_client_full_script.step);

    // The interop example: the WebSocket frame layer over the HTTP/1 machine
    // from baskingspot/http. Lazy, like libxev, so a consumer fetches neither.
    if (b.lazyDependency("http", .{})) |http_dep| {
        const http_echo = b.addExecutable(.{
            .name = "http-echo",
            .root_module = b.createModule(.{
                .root_source_file = b.path("examples/http-echo.zig"),
                .target = target,
                .optimize = optimize,
                .imports = &.{
                    .{ .name = "websocket", .module = mod },
                    .{ .name = "http", .module = http_dep.module("http") },
                },
            }),
        });
        const http_echo_install = b.addInstallArtifact(http_echo, .{});
        examples_step.dependOn(&http_echo_install.step);

        const http_echo_run = b.addRunArtifact(http_echo);
        passthruArgs(b, http_echo_run);
        const http_echo_step = b.step(
            "example-http",
            "Run the baskingspot/http echo server",
        );
        http_echo_step.dependOn(&http_echo_run.step);

        const http_conformance = b.addSystemCommand(&.{"nu"});
        http_conformance.addFileArg(run_autobahn);
        http_conformance.addArtifactArg(http_echo);
        http_conformance.addArgs(&.{ "9004", "http-echo", "fast" });
        http_conformance.step.dependOn(&http_echo_install.step);

        const http_conf_step = b.step(
            "conformance-http",
            "Run Autobahn against the baskingspot/http echo server",
        );
        http_conf_step.dependOn(&http_conformance.step);
    }

    if (b.lazyDependency("libxev", .{})) |xev_dep| {
        const xev_echo = b.addExecutable(.{
            .name = "xev-echo",
            .root_module = b.createModule(.{
                .root_source_file = b.path("examples/xev-echo.zig"),
                .target = target,
                .optimize = optimize,
                .imports = &.{
                    .{ .name = "websocket", .module = mod },
                    .{ .name = "xev", .module = xev_dep.module("xev") },
                },
            }),
        });
        const xev_install = b.addInstallArtifact(xev_echo, .{});
        examples_step.dependOn(&xev_install.step);

        const xev_conformance = b.addSystemCommand(&.{"nu"});
        xev_conformance.addFileArg(run_autobahn);
        xev_conformance.addArtifactArg(xev_echo);
        xev_conformance.addArgs(&.{ "9003", "xev-echo", "fast" });
        xev_conformance.step.dependOn(&xev_install.step);

        const xev_conf_step = b.step(
            "conformance-xev",
            "Run Autobahn against xev echo server",
        );
        xev_conf_step.dependOn(&xev_conformance.step);
    }
}

/// Pass the build runner's own arguments through to a run step. Zig 0.17
/// replaced `Build.args` with `Run.addPassthruArgs`; one tree serves both.
fn passthruArgs(b: *std.Build, run: *std.Build.Step.Run) void {
    if (comptime @hasDecl(std.Build.Step.Run, "addPassthruArgs")) {
        run.addPassthruArgs();
    } else if (b.args) |args| {
        run.addArgs(args);
    }
}

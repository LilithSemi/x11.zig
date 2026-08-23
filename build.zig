const std = @import("std");

pub fn generateProtocol(
    owner: *std.Build,
    x11_dep: *std.Build.Dependency,
    xml: std.Build.LazyPath,
    imports: []const std.Build.LazyPath,
    module_name: []const u8,
) *std.Build.Module {
    const run = owner.addRunArtifact(x11_dep.artifact("x11-gen-host"));
    run.addFileArg(xml);
    const out = run.addOutputFileArg(owner.fmt("{s}.zig", .{module_name}));
    for (imports) |imp| run.addFileArg(imp);
    const mod = owner.createModule(.{ .root_source_file = out });
    mod.addImport("x11", x11_dep.module("x11"));
    return mod;
}

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const root_module = b.addModule("x11", .{
        .root_source_file = b.path("lib/x11.zig"),
        .target = target,
        .optimize = optimize,
    });

    const test_step = b.step("test", "Run tests");
    const x11_tests = b.addTest(.{ .root_module = root_module });
    test_step.dependOn(&b.addRunArtifact(x11_tests).step);

    const xml_dep = b.dependency("xml", .{ .target = target, .optimize = optimize });
    const xml_mod = xml_dep.module("xml");

    const gen_mod = b.createModule(.{
        .root_source_file = b.path("generator/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    gen_mod.addImport("xml", xml_mod);
    const gen_exe = b.addExecutable(.{ .name = "x11-gen", .root_module = gen_mod });
    b.installArtifact(gen_exe);

    const host_gen_mod = b.createModule(.{
        .root_source_file = b.path("generator/main.zig"),
        .target = b.graph.host,
        .optimize = optimize,
    });
    host_gen_mod.addImport("xml", xml_mod);
    const host_gen_exe = b.addExecutable(.{ .name = "x11-gen-host", .root_module = host_gen_mod });
    b.installArtifact(host_gen_exe);

    const gen_test_mod = b.createModule(.{
        .root_source_file = b.path("generator/xcbproto.zig"),
        .target = target,
        .optimize = optimize,
    });
    gen_test_mod.addImport("xml", xml_mod);
    test_step.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = gen_test_mod })).step);

    const registry_test_mod = b.createModule(.{
        .root_source_file = b.path("generator/registry.zig"),
        .target = target,
        .optimize = optimize,
    });
    registry_test_mod.addImport("xml", xml_mod);
    test_step.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = registry_test_mod })).step);

    const codegen_test_mod = b.createModule(.{
        .root_source_file = b.path("generator/codegen.zig"),
        .target = target,
        .optimize = optimize,
    });
    codegen_test_mod.addImport("xml", xml_mod);
    test_step.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = codegen_test_mod })).step);

    // --- Generated bindings roundtrip (the integration gate) ---
    const xcbproto_dep = b.dependency("xcbproto", .{});

    // xproto (no imports): argv = xproto.xml <out>
    const gen_xproto = b.addRunArtifact(host_gen_exe);
    gen_xproto.addFileArg(xcbproto_dep.path("src/xproto.xml"));
    const xproto_out = gen_xproto.addOutputFileArg("xproto.zig");
    const xproto_mod = b.createModule(.{ .root_source_file = xproto_out, .target = target, .optimize = optimize });
    xproto_mod.addImport("x11", root_module);

    // xkb: argv = xkb.xml <out> xproto.xml  (xproto.xml is the import seed = argv[3])
    const gen_xkb = b.addRunArtifact(host_gen_exe);
    gen_xkb.addFileArg(xcbproto_dep.path("src/xkb.xml"));
    const xkb_out = gen_xkb.addOutputFileArg("xkb.zig");
    gen_xkb.addFileArg(xcbproto_dep.path("src/xproto.xml"));
    const xkb_mod = b.createModule(.{ .root_source_file = xkb_out, .target = target, .optimize = optimize });
    xkb_mod.addImport("x11", root_module);
    xkb_mod.addImport("xproto", xproto_mod);

    const rt_mod = b.createModule(.{
        .root_source_file = b.path("test/generated_roundtrip.zig"),
        .target = target,
        .optimize = optimize,
    });
    rt_mod.addImport("xproto", xproto_mod);
    rt_mod.addImport("xkb", xkb_mod);
    test_step.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = rt_mod })).step);

    const probe_mod = b.createModule(.{
        .root_source_file = b.path("tools/probe.zig"),
        .target = target,
        .optimize = optimize,
    });
    probe_mod.addImport("x11", root_module);
    probe_mod.addImport("xproto", xproto_mod);
    probe_mod.addImport("xkb", xkb_mod);
    const probe_exe = b.addExecutable(.{ .name = "x11-probe", .root_module = probe_mod });
    const run_probe = b.addRunArtifact(probe_exe);
    if (b.args) |pa| run_probe.addArgs(pa);
    b.step("run-probe", "Run live X server probe (needs Xvfb on :99)").dependOn(&run_probe.step);

    const server_mod = b.createModule(.{
        .root_source_file = b.path("tools/server.zig"),
        .target = target,
        .optimize = optimize,
    });
    server_mod.addImport("x11", root_module);
    server_mod.addImport("xproto", xproto_mod);
    const server_exe = b.addExecutable(.{ .name = "x11-server", .root_module = server_mod });
    const run_server = b.addRunArtifact(server_exe);
    if (b.args) |pa| run_server.addArgs(pa);
    b.step("run-server", "Run the x11.zig server (default :77)").dependOn(&run_server.step);

    const check_mod = b.createModule(.{
        .root_source_file = b.path("tools/check-server.zig"),
        .target = target,
        .optimize = optimize,
    });
    check_mod.addImport("x11", root_module);
    check_mod.addImport("xproto", xproto_mod);
    const check_exe = b.addExecutable(.{ .name = "x11-server-check", .root_module = check_mod });
    const run_check = b.addRunArtifact(check_exe);
    if (b.args) |pa| run_check.addArgs(pa);
    b.step("run-server-check", "Run the client check against our server").dependOn(&run_check.step);

    // The executables (probe, server, server-check) carry no unit tests, but
    // compiling them under `zig build test` closes a real gate blind spot: a
    // compile break in the executable layer would otherwise only surface when
    // someone remembers to run its `run-*` step. Building them as test binaries
    // (main is ignored in test mode) type-checks them on every `zig build test`.
    test_step.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = probe_mod })).step);
    test_step.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = server_mod })).step);
    test_step.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = check_mod })).step);
}

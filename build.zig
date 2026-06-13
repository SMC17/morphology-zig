const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const stemmer_dep = b.dependency("stemmer", .{
        .target = target,
        .optimize = optimize,
    });
    const stemmer_mod = stemmer_dep.module("stemmer");

    const morphology_mod = b.addModule("morphology", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    morphology_mod.addImport("stemmer", stemmer_mod);

    const unit_tests = b.addTest(.{
        .root_module = morphology_mod,
    });
    const run_tests = b.addRunArtifact(unit_tests);
    const test_step = b.step("test", "Run unit tests (rule engine + hybrid analyzer + reference set)");
    test_step.dependOn(&run_tests.step);
}

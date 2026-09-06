const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{
        .default_target = .{ .cpu_arch = .x86_64, .os_tag = .linux },
    });
    const optimize = b.option(std.builtin.OptimizeMode, "optimize", "Optimization mode") orelse .ReleaseSmall;

    const exe = b.addExecutable(.{
        .name = "run",
        .use_llvm = true,
        .use_lld = true,
        .root_module = b.createModule(.{
            .root_source_file = b.path("run.zig"),
            .target = target,
            .optimize = optimize,
            .strip = optimize != .Debug,
            .unwind_tables = if (optimize == .Debug) .sync else .none,
        }),
    });
    b.installArtifact(exe);
    const budget = b.allocator.create(Budget) catch @panic("out of memory");
    budget.* = .{ .step = .init(.{ .id = .custom, .name = "Size report", .owner = b, .makeFn = Budget.make }), .binary = exe.getEmittedBin() };
    budget.binary.addStepDependencies(&budget.step);
    if (optimize == .ReleaseSmall) b.getInstallStep().dependOn(&budget.step);
    b.step("size", "Report executable and core source size").dependOn(&budget.step);

    const run = b.addRunArtifact(exe);
    run.step.dependOn(b.getInstallStep());
    if (b.args) |args| run.addArgs(args);
    b.step("run", "Run run").dependOn(&run.step);

    const tests = b.addTest(.{
        .use_llvm = true,
        .use_lld = true,
        .root_module = b.createModule(.{
            .root_source_file = b.path("run.zig"),
            .target = target,
            .optimize = .Debug,
        }),
    });
    b.step("test", "Unit tests (host may not execute a Linux binary)").dependOn(&b.addRunArtifact(tests).step);
    const install_tests = b.addInstallArtifact(tests, .{ .dest_sub_path = "run-test" });
    b.step("test-build", "Build checked Linux tests for a separate runner").dependOn(&install_tests.step);
}

const Budget = struct {
    step: std.Build.Step,
    binary: std.Build.LazyPath,
    fn make(step: *std.Build.Step, _: std.Build.Step.MakeOptions) !void {
        const self: *Budget = @fieldParentPtr("step", step);
        const b = step.owner;
        const binary = try std.Io.Dir.cwd().statFile(b.graph.io, self.binary.getPath2(b, step), .{});
        var total = binary.size;
        for ([_][]const u8{ "run.zig", "build.zig", "build.zig.zon", "README.md", "SYSTEM.md", ".gitignore" }) |path| {
            total += (try std.Io.Dir.cwd().statFile(b.graph.io, b.pathFromRoot(path), .{})).size;
        }
        std.debug.print("run: {d} byte executable; {d} bytes with core source and docs\n", .{ binary.size, total });
    }
};

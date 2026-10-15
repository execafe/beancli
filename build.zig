const std = @import("std");

pub fn build(b: *std.Build) void {
    const optimize = b.standardOptimizeOption(.{});
    const target = b.standardTargetOptions(.{});

    _ = b.addModule("beancli", .{
        .root_source_file = b.path("beancli.zig"),
        .optimize = optimize,
        .target = target,
    });
}

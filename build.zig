const std = @import("std");

pub fn build(b: *std.Build) void {
    _ = b.addModule("beancli", .{
        .root_source_file = b.path("beancli.zig"),
    });
}

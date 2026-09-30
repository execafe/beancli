const std = @import("std");
const cli = @import("beancli.zig");

const print = std.debug.print;

const test_enum = enum {
    hello,
    world,
};

const Args = struct {
    port: ?u16 = 80,
    mode: enum {fast, safe} = .safe,
    verbose: ?bool = null,
    input: []const u8 = "in.txt",
    output: ?[]const u8 = null,
    // rest: []const []const u8,
    test_subcommand: ?struct {} = null,

    pub const name = "scratch";
    pub const doc = "hello world!";
    pub const meta = .{.port = .{.short = 'p'}, .mode = .{ .short = 'm'}};
};

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const argv = try init.minimal.args.toSlice(arena);

    try cli.parse(Args, argv);
}

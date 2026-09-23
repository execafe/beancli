const std = @import("std");
const cli = @import("beancli.zig");

const print = std.debug.print;

const Args = struct {
    port: u16 = 80,
    mode: enum {fast, safe} = .safe,
    verbose: ?bool = null,
    input: []const u8 = "in.txt",
    output: ?[]const u8 = null,
    test_subcommand: ?struct {} = null,
};

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const argv = try arena.dupe([]const u8, raw);

    const args = try cli.parse(Args, argv);
    print("{d}\n", .{args.port});
    print("{}\n", .{args.mode});
    print("{?}\n", .{args.verbose});
    print("{s}\n", .{args.input});
    print("{?s}\n", .{args.output});
}

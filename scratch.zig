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
    // mode: enum {fast, safe, release_fast, @"release-fast"} = .safe,
    verbose: ?bool = null,
    // input: []const u8 = "in.txt",
    // input2: []const u8 = "in.txt",
    // input3: []const u8 = "in.txt",
    // output: []const u8,
    // rest: []const []const u8,
    test_subcommand: ?struct {} = null,
    // test_subcommand2: ?struct {} = null,
    // @"test-subcommand": ?struct {},

    pub const name = "scratch";
    pub const doc = "hello world!";
    pub const meta = .{
        .port = .{
            .short = 'p',
        },
        .mode = .{
            .short = 'm',
        },
        // .input = .{.mode = .positional,},
        // .input2 = .{.mode = .positional,},
        // .input3 = .{.mode = .positional,},
        // .output = .{.mode = .positional,},
    };
};

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    var buffer: [4096]u8 = undefined;
    var stdout_writer: std.Io.File.Writer = .initStreaming(.stdout(), init.io, &buffer);
    const writer = &stdout_writer.interface;
    defer stdout_writer.flush() catch {};

    var diagnostic: cli.Diagnostic = .{};
    const args = cli.parse(Args, arena, init.minimal.args, &diagnostic) catch |err| {
        try diagnostic.print(writer);
        return err;
    };
    const fields = @typeInfo(@TypeOf(args)).@"struct".fields;
    inline for (fields) |f| {
        if (@typeInfo(f.type) != .pointer) {
            print("{s}: {any}\n", .{f.name, @field(args, f.name)});
        } else {
            for (@field(args, f.name), 0..) |v, i| {
                if (@TypeOf(v) == []const u8) print("{s}.{d}: {s}\n", .{f.name, i, v})
                else print("{s}.{d}: {any}\n", .{f.name, i, v});
            }
        }
    }
}

const std = @import("std");
const cli = @import("beancli.zig");

const print = std.debug.print;

const test_enum = enum {
    hello,
    world,
};

const Test = struct {
    files: []const []const u8,
};

const Run = struct {
    verbose: bool,
    input: []const u8,
    output: []const u8 = "out",

    pub const meta = .{
        .verbose = .{ .short = 'v' },
        .input   = .{ .mode  = .positional },
        .output   = .{ .mode  = .positional },
    };
};

const Args = struct {
    // rgb: ?u8,
    port: ?u16 = 80,
    mode: enum {fast, safe} = .safe,
    // mode: enum {fast, safe, release_fast, @"release-fast"} = .safe,
    verbose: ?bool,
    // input: []const u8 = "in.txt",
    // input2: []const u8 = "in.txt",
    // input3: []const u8 = "in.txt",
    // output: []const u8,
    // input: []const u8,
    // rest: []const []const u8,
    // print_help: bool,
    run: ?Run,
    @"test": ?Test,
    // test_subcommand2: ?struct {} = null,
    // @"test-subcommand": ?struct {},

    pub const name = "scratch";
    pub const doc = "Scratch app for beancli!";
    pub const meta = .{
        .port = .{
            .doc = "Port number to use.",
            .short = 'p',
        },
        .mode = .{
            .short = 'm',
        },
        .verbose = .{
            .short = 'v',
        },
        // .print_help = .{
        //     .short = 'h',
        //     .mode = .help,
        // },
        // .input = .{.mode = .positional},
        // .input2 = .{.mode = .positional,},
        // .input3 = .{.mode = .positional,},
        // .output = .{.mode = .positional,},
    };
};

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    var buffer: [4096]u8 = undefined;
    var err_buffer: [4096]u8 = undefined;
    var stdout_writer: std.Io.File.Writer = .initStreaming(.stdout(), init.io, &buffer);
    const writer = &stdout_writer.interface;
    defer stdout_writer.flush() catch {};
    var stderr_writer: std.Io.File.Writer = .initStreaming(.stderr(), init.io, &err_buffer);
    const err_writer = &stderr_writer.interface;
    defer stderr_writer.flush() catch {};

    var info: cli.Info = undefined;
    const args = cli.parse(Args, arena, init.minimal.args, &info) catch |err| {
        if (err == cli.ParseError.HelpRequested) {
            try info.print_help(writer);
            return;
        }
        try info.print_error(err_writer);
        return;
    };
    const fields = @typeInfo(@TypeOf(args)).@"struct".fields;
    inline for (fields) |f| {
        const value = @field(args, f.name);
        if (f.type == []const u8) {
            print("{s}: {s}\n", .{f.name, value});
        } else if (@typeInfo(f.type) != .pointer) {
            print("{s}: {any}\n", .{f.name, value});
        } else {
            for (value, 0..) |v, i| {
                if (@TypeOf(v) == []const u8) print("{s}.{d}: {s}\n", .{f.name, i, v})
                else print("{s}.{d}: {any}\n", .{f.name, i, v});
            }
        }
    }
}

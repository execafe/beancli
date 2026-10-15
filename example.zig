const std = @import("std");
const cli = @import("beancli.zig");

const Run = struct {
    verbose: bool,
    input: []const u8,
    output: []const u8 = "out",

    pub const meta = .{
        .verbose = .{ .short = 'v' },
        .input   = .{ .mode = .positional },
        .output  = .{ .mode = .positional },
    };
};

const Args = struct {
    port: u16 = 80,
    mode: enum { fast, safe } = .safe,
    run: ?Run = null,

    help: u8 = 88,
    real_help: bool,

    pub const name = "app";
    pub const doc = "does app things";
    pub const meta = .{
        .port = .{ .short = 'p', .doc = "port to listen on" },
        .help = .{ .short = 'h', .doc = "bwahaha im fake help"},
        .real_help = .{ .mode = .help, .short = 'H' },
    };
};

pub fn main(init: std.process.Init) !void {
    var out_buffer: [4096]u8 = undefined;
    var err_buffer: [4096]u8 = undefined;
    var stdout_writer: std.Io.File.Writer = .initStreaming(.stdout(), init.io, &out_buffer);
    const stdout = &stdout_writer.interface;
    defer stdout_writer.flush() catch {};

    var stderr_writer: std.Io.File.Writer = .initStreaming(.stderr(), init.io, &err_buffer);
    const stderr = &stderr_writer.interface;
    defer stderr_writer.flush() catch {};

    var info: cli.Info = undefined;
    const args = cli.parse(Args, init.arena.allocator(), init.minimal.args, &info) catch |err| {
        if (err == error.HelpRequested) return info.print_help(stdout);
        return info.print_error(stderr);
    };
    if (args.run) |run| {
        _ = run;
        std.debug.print("Running app...\n", .{});
    } else {
        try info.print_help(stdout);
    }
}

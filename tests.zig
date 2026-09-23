const std = @import("std");
const print = std.debug.print;
const t = std.testing;

const cli = @import("beancli.zig");
const cli_internal = cli.testing;

const slice_child = cli_internal.slice_child;
const is_scalar = cli_internal.is_scalar;
const Meta = cli.Meta;
const meta_for = cli_internal.meta_for;
const classify = cli_internal.classify;
const Field = std.builtin.Type.StructField;

test "slice_child" {
    const not_a_slice = u8;
    const with_sentinel = [:0]const u8;
    const fixed_len = [5]u8;
    const not_const = []u8;
    const const_slice = []const u8;

    comptime var child = slice_child(not_a_slice);
    try t.expectEqual(null, child);
    child = slice_child(with_sentinel);
    try t.expectEqual(null, child);
    child = slice_child(fixed_len);
    try t.expectEqual(null, child);
    child = slice_child(not_const);
    if (child) |c| {
        const child_type = @typeInfo(c);
        try t.expect(child_type == .int);
    } else try t.expect(false);
    child = slice_child(const_slice);
    if (child) |c| {
        const child_type = @typeInfo(c);
        try t.expect(child_type == .int);
    } else try t.expect(false);
}

test "is_scalar" {
    const boolean = bool;
    const string = []const u8;
    const integer = u8;
    const float = f32;
    const mune = enum {};
    const optional_scalar = ?u8;
    const optional_non_scalar = ?struct {};
    const noinu = union(enum) {};
    const slice_of_string = []const []const u8;
    const immutable_slice_of_T = []const u16;
    const mutable_slice_of_T = []u16;

    try t.expect(is_scalar(boolean));
    try t.expect(is_scalar(string));
    try t.expect(is_scalar(integer));
    try t.expect(is_scalar(float));
    try t.expect(is_scalar(mune));
    try t.expect(is_scalar(optional_scalar));
    try t.expect(!is_scalar(optional_non_scalar));
    try t.expect(!is_scalar(noinu));
    try t.expect(!is_scalar(slice_of_string));
    try t.expect(!is_scalar(immutable_slice_of_T));
    try t.expect(!is_scalar(mutable_slice_of_T));
}

test "meta_for" {
    const meta = .{
        .complete_meta = Meta{
            .short = 'v',
            .doc = "Field complete meta",
            .mode = .count,
        },
        .short_only = Meta{
            .short = 'S',
        },
        .doc_only = Meta{
            .doc = "Doc only",
        },
        .mode_only = Meta{
            .mode = .positional,
        },
        .empty = .{},
    };

    try t.expectEqualDeep(Meta{
        .short = 'v',
        .doc = "Field complete meta",
        .mode = .count,
        }, meta_for(meta, "complete_meta"));
    try t.expectEqualDeep(Meta{
        .short = 'S',
        }, meta_for(meta, "short_only"));
    try t.expectEqualDeep(Meta{
        .doc = "Doc only",
        }, meta_for(meta, "doc_only"));
    try t.expectEqualDeep(Meta{
        .mode = .positional,
        }, meta_for(meta, "mode_only"));
    try t.expectEqualDeep(Meta{}, meta_for(meta, "empty"));
    try t.expectEqualDeep(Meta{}, meta_for(null, "null_meta"));
    try t.expectEqualDeep(Meta{}, meta_for(meta, "invalid_field"));
    try t.expectError(error.MetaNotStruct, meta_for(enum{}, "invalid meta"));
}

test "classify" {
    const Args = struct {
        string: []const u8,
        flag: bool,
        toggle: ?bool,
        signed: i8,
        unsigned: u8,
        float: f32,
        mune: enum { member1, member2, member3, },
        noinu: union { member1: u8, member2: u16, member3: u32 },
        noinu_tagged: union(enum) { member1: u8, member2: u16, member3: u32 },
        mune_repeated: []enum { member1, member2, member3, },
        repeated_int: []u8,
        repeated_invalid: []const []const []const u8,
        repeated_string: []const []const u8,
        rest: []const []const u8,
        command: ?struct {},
        invalid_command: struct {},
    };

    // string
    const string = @typeInfo(Args).@"struct".fields[0];

    try t.expect(try classify(.{}, string) == .value);
    try t.expect(try classify(.{ .string = Meta{.mode = .positional}}, string) == .slot);
    try t.expectError(error.CounterFieldNotInt, classify(.{
        .string = Meta{.mode = .count}}, string));

    // this means []const u8 can be two things:
    //     1. it's a field that accepts string as value
    //     2. it's a repeated field that accepts u8 as value
    try t.expect(try classify(.{ .string = Meta{.mode = .repeat}}, string) == .repeated);

    // bool and ?bool
    const flag = @typeInfo(Args).@"struct".fields[1];
    const toggle = @typeInfo(Args).@"struct".fields[2];

    try t.expect(try classify(.{}, flag) == .flag);
    try t.expect(try classify(.{}, toggle) == .toggle);
    // flag and toggle cannot be positional
    // i.e. app true
    try t.expectError(error.BoolCannotBePositional, classify(.{
        .toggle = Meta{
            .mode=.positional
        }}, toggle));

    // int and float
    const signed = @typeInfo(Args).@"struct".fields[3];
    const unsigned = @typeInfo(Args).@"struct".fields[4];
    const float = @typeInfo(Args).@"struct".fields[5];

    try t.expect(try classify(.{}, signed) == .value);
    try t.expect(try classify(.{}, unsigned) == .value);
    try t.expect(try classify(.{}, float) == .value);

    // counter can only be of type integer
    // float will not work
    try t.expect(try classify(.{
        .signed = Meta{
            .mode = .count,
        }}, signed) == .counter);
    try t.expectError(error.CounterFieldNotInt, classify(.{
        .float = Meta{
            .mode = .count,
        }}, float));

    // enum and union
    const mune = @typeInfo(Args).@"struct".fields[6];
    const noinu = @typeInfo(Args).@"struct".fields[7];
    const noinu_tagged = @typeInfo(Args).@"struct".fields[8];
    const mune_repeated = @typeInfo(Args).@"struct".fields[9];

    try t.expect(try classify(.{}, mune) == .value);
    // union and tagged union is not supported
    try t.expectError(error.UnsupportedFieldType ,classify(.{}, noinu));
    try t.expectError(error.UnsupportedFieldType ,classify(.{}, noinu_tagged));
    // just like any scalar type
    // enum can also be a slot
    // or a repeated field
    try t.expect(try classify(.{
        .mune = Meta{
            .mode = .positional,
        }}, mune) == .slot);
    try t.expect(try classify(.{
        .mune_repeated = Meta{
            .mode = .repeat,
        }}, mune_repeated) == .repeated);

    // slice types []T can only either be
    // repeated field or rest field
    const repeated_int = @typeInfo(Args).@"struct".fields[10];
    const repeated_invalid = @typeInfo(Args).@"struct".fields[11];
    const repeated_string = @typeInfo(Args).@"struct".fields[12];
    const rest = @typeInfo(Args).@"struct".fields[13];

    try t.expect(try classify(.{
        .repeated_int = Meta {
            .mode = .repeat,
        }}, repeated_int) == .repeated);
    try t.expectError(error.RepeatedFieldSliceChildNotNonOptionalScalar, classify(.{
        .repeated_invalid = Meta{
            .mode = .repeat,
        }}, repeated_invalid));
    // repeated string and rest
    // have the same []const []const u8 type
    // the only difference is the Meta.mode
    // being set to .repeat turns it from .rest to .repeated
    try t.expect(try classify(.{
        .repeated_string = .{
            .mode = .repeat,
        }}, repeated_string) == .repeated);
    try t.expect(try classify(.{}, rest) == .rest);

    // command
    // a command is just an optional struct (?struct) type
    // inside that struct you can have another set of options
    // specific only to that command (more on that later)
    const command = @typeInfo(Args).@"struct".fields[14];
    const invalid_command = @typeInfo(Args).@"struct".fields[15];

    try t.expect(try classify(.{}, command) == .command);
    try t.expectError(error.UnsupportedFieldType, classify(.{}, invalid_command));
}

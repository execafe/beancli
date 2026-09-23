// MIT License
//
// Copyright (c) 2026 execafe
//
// Permission is hereby granted, free of charge, to any person obtaining a copy
// of this software and associated documentation files (the "Software"), to deal
// in the Software without restriction, including without limitation the rights
// to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
// copies of the Software, and to permit persons to whom the Software is
// furnished to do so, subject to the following conditions:
//
// The above copyright notice and this permission notice shall be included in all
// copies or substantial portions of the Software.
//
// THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
// IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
// FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
// AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
// LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
// OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
// SOFTWARE.

//! beancli
//! CLI argument parser for Zig where the struct declaration is the whole CLI.

const std = @import("std");
const builtin = @import("builtin");

const Field = std.builtin.Type.StructField;
const Kind = enum {
    flag, // bool type, does not accept value
    toggle, // ?bool type, accepts value
    counter, // e.g. -vvv or --verbose=3, must be integer type
    repeated, // e.g. -I src -I lib, []const T type
    value, // e.g. --port80, could be one of the following types: any integer, float, any enum, or []const u8
    slot, // named positional argument, e.g. --out a.txt or app a.txt
    command, // ?struct type, null if not used. only one command can be used at a time
    rest, // the rest of positional args or everything after --
};
fn slice_child(comptime T: type) ?type {
    const info = switch (@typeInfo(T)) {
        .pointer => |p| p,
        else => return null,
    };

    if (info.size != .slice
            // or !info.is_const
            or info.sentinel_ptr != null) return null;
    return info.child;
}
fn is_scalar(comptime T: type) bool {
    if (T == []const u8) return true;
    return switch(@typeInfo(T)) {
        .bool,
        .int, .float,
        .@"enum" => true,
        .optional => |info| @typeInfo(info.child) != .optional
            and is_scalar(info.child),
        else => false,
    };
}
const FieldMode = enum {
    default, count, repeat, positional
};
pub const Meta = struct {
    short: ?u8 = null,
    doc: []const u8 = "",
    mode: FieldMode = .default,
};
fn meta_for(comptime meta: anytype, comptime field_name: []const u8) !Meta {
    const metatype = @TypeOf(meta);
    const info = @typeInfo(metatype);

    if (info == .null) return .{};
    if (info != .@"struct") return error.MetaNotStruct;
    if (!@hasField(metatype, field_name)) return .{};

    const entry = @field(meta, field_name);
    const Entry = @TypeOf(entry);
    return .{
        .short = if (@hasField(Entry, "short")) entry.short else null,
        .doc = if (@hasField(Entry, "doc")) entry.doc else "",
        .mode = if (@hasField(Entry, "mode")) entry.mode else .default,
    };
}
fn classify(comptime meta: anytype, comptime field: Field) !Kind {
    const M = comptime try meta_for(meta, field.name);
    const T = field.type;

    // classify slice except []const u8
    if (slice_child(T)) |t| {
        if (M.mode == .repeat) {
            if (!is_scalar(t) or @typeInfo(t) == .optional)
                return error.RepeatedFieldSliceChildNotNonOptionalScalar;
            return .repeated;
        }
        if (T != []const u8) {
            if (M.mode == .positional) return error.PositionalFieldNotScalar;
            if (M.mode == .count) return error.CounterFieldNotInt;
            if (t != []const u8) return error.RestFieldNotSliceOfStrings;
            return .rest;
        }
    }

    if (M.mode == .repeat) return error.RepeatedFieldNotSlice;
    if (M.mode == .count and @typeInfo(T) != .int) return error.CounterFieldNotInt;
    if (@typeInfo(T) == .optional and @typeInfo(@typeInfo(T).optional.child) == .@"struct") {
        if (M.mode == .positional) return error.CommandCannotBePositional;
        return .command;
    }
    if (!is_scalar(T)) return error.UnsupportedFieldType;
    if (M.mode == .count) {
        return .counter;
    }

    if (T == bool or T == ?bool) {
        if (M.mode == .positional) return error.BoolCannotBePositional;
        if (T == bool) return .flag else return .toggle;
    }

    return if (M.mode == .positional) .slot else .value;
}
fn Schema(comptime Args: type) type {
    const fields = @typeInfo(Args).@"struct".fields;
    const N = fields.len;
    return struct {
        const Self = @This();

        names: [N][]const u8,
        field_types: [N]type,
        kinds: [N]Kind,
        meta: [N]?Meta,

        pub fn build(comptime meta: anytype) Self {
            var self: Self = undefined;
            inline for (fields, 0..) |field, i| {
                self.names[i] = field.name;
                self.field_types[i] = field.type;
                self.kinds[i] = comptime try classify(Args, field);
                self.meta[i] = comptime try meta_for(meta, field.name);
            }
            return self;
        }

        // dashed name support
        pub fn find_index(self: Self, name: []const u8) ?usize {
            for (self.names, 0..) |candidate, i| {
                if (candidate.len != name.len) continue;
                if (candidate.len == 0 or candidate.ptr == name.ptr) return i;
                var matched = true;
                for (candidate, name) |a,b| {
                    if (!matched) break;
                    matched = a == b or (a == '_' and b == '-');
                }
                if (matched) return i;
            }
            return null;
        }

        // fn bind(value: anytype) bool {

        // }

        // pub fn bind_default_value(comptime field: Field) bool {
        //     const default = field.defaultValue();
        //     if (default) |df| {

        //     } else return false;
        // }

        // pub fn bind_value(self: Self, comptime out: *Args, index: usize, value: []const u8) ValueError!void {
        //     const kind = self.kinds[index];
        //     const field_type = self.field_types[index];
        // }
    };
}

pub const ValueError = error {
    InvalidValue,
    // from std.fmt
    Overflow,
    InvalidCharacter,
};
fn parse_enum(comptime T: type, value: []const u8) ValueError!T {
    if (@typeInfo(T) != .@"enum") @compileError("parse_enum can only be used with enum type");
    const maybe_match = std.meta.stringToEnum(T, value);
    if (maybe_match) |m| return m;

    // dashed value support
    // match against @"dashed-value"
    // or against dashed_value
    const fields = @typeInfo(T).@"enum".fields;
    inline for (fields) |tag| {
        if (tag.name.len == value.len) {
            var matched = true;
            for (tag.name, value) |a,b| {
                if (!matched) break;
                matched = a == b or (a == '_' and b == '-');
            }
            if (matched) return @enumFromInt(tag.value);
        }
    }

    return error.InvalidValue;
}
fn parse_scalar(comptime T: type, value: []const u8) ValueError!T {
    if (T == []const u8) return value;
    return switch(@typeInfo(T)) {
        .bool => if (std.mem.eql(u8, value, "true"))
            true
        else if (std.mem.eql(u8, value, "false"))
            false
        else
            error.InvalidValue,
        .int => try std.fmt.parseInt(T, value, 10),
        .float => try std.fmt.parseFloat(T, value),
        .@"enum" => try parse_enum(T, value),
        .optional => |info| if (info.child == bool and std.mem.eql(u8, value, "null"))
            null
        else
            try is_scalar(info.child, value),
        else => unreachable,
    };
}
const TokenKind = enum {
    init,
    barrier,
    positional,
    value,
    flag,
    long,
    short,
};
const Token = struct {
    kind: TokenKind,
    raw: []const u8,
    arg_index: usize,
};
const ParseError = error {
    MissingValue,
    SyntaxError,
} & ValueError;
const Diagnostic = struct {
    error_type: ParseError,
    arg_index: usize,
    subindex: usize,
    error_message: []const u8,
};

// fn Tokenizer(comptime Args: type) type {
//     return struct {
//         const Self = @This();

//         kind: TokenKind = .init,
//         raw: []const u8 = "",
//         arg_index: usize = 0,
//         subindex: usize = 0,

//         pub fn consume_arg(self: *Self) void {

//         }

//         pub fn next(self: *Self, argv: [][]const u8, comptime schema: Schema(Args)) union(enum){
//             diagnostic: Diagnostic,
//             token: Token,
//         } {
//             var token: Token = undefined;
//             var diagnostic: Diagnostic = undefined;

//             if (self.kind == .init) {
//                 self.raw = argv[0];
//             } else if (self.subindex != 0) {
//                 self.raw = argv[self.arg_index][self.subindex];
//             } else if (self.kind == .long or self.kind == .short) {

//             } else {
//                 self.index += 1;
//                 self.raw = argv[self.arg_index];
//             }


//             if (std.mem.startsWith(u8, self.raw, '-')) {

//             }
//         }
//     };
// }

pub fn parse(comptime Args: type, argv: [][]const u8, comptime meta: anytype) !Args {
    const schema = comptime Schema(Args).build(meta);
    var out: Args = undefined;

    for (argv, 0..) |arg, i| {
        if (!std.mem.startsWith(u8, arg, "--")) continue;
        const name = arg[2..];
        const field_index = schema.find_index(name) orelse continue;
        const kind = schema.kinds[field_index];

        if (kind == .subcommand or kind == .rest) continue;

        const skip_value = schema.skip_value[field_index];
        if (skip_value) {
            try schema.assign_fns[field_index](&out, "");
        } else {
            const value_index = i + 1;
            if (value_index >= argv.len) return error.MissingValue;
            try schema.assign_fns[field_index](&out, argv[value_index]);
        }
    }

    return out;
}

const cli = @This();
pub const testing = if (builtin.is_test) struct {
    pub const Kind = cli.Kind;
    pub const slice_child = cli.slice_child;
    pub const is_scalar = cli.is_scalar;
    pub const meta_for = cli.meta_for;
    pub const classify = cli.classify;
} else struct {};

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
fn compileError(comptime fmt: []const u8, comptime args: anytype) noreturn {
    @compileError(std.fmt.comptimePrint(fmt, args));
}

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
fn enum_child(comptime T: type) ?type {
    return switch(@typeInfo(T)) {
        .@"enum"  => T,
        .optional => |info| enum_child(info.child),
        .pointer  => if (slice_child(T)) |c| enum_child(c) else null,
        else      => null,
    };
}
fn is_scalar(comptime T: type) bool {
    if (T == []const u8) return true;
    return switch(@typeInfo(T)) {
        .bool,
        .int, .float,
        .@"enum"      => true,
        .optional     => |info| @typeInfo(info.child) != .optional and is_scalar(info.child),
        else          => false,
    };
}
const FieldMode = enum {
    default, count, repeat, positional
};
pub const Meta = struct {
    short: ?u8      = null,
    doc: []const u8 = "",
    mode: FieldMode = .default,
};
fn meta_for(comptime meta: anytype, comptime field_name: []const u8) Meta {
    const metatype = @TypeOf(meta);
    const info = @typeInfo(metatype);

    if (info == .null) return .{};
    if (!@hasField(metatype, field_name)) return .{};

    const entry = @field(meta, field_name);
    const Entry = @TypeOf(entry);
    return .{
        .short = if (@hasField(Entry, "short")) entry.short else null,
        .doc = if (@hasField(Entry, "doc")) entry.doc else "",
        .mode = if (@hasField(Entry, "mode")) entry.mode else .default,
    };
}
const ClassifyError = error {
    BoolCannotBePositional,
    PositionalFieldNotScalar,
    CounterFieldNotInt,
    RepeatedFieldNotSlice,
    RepeatedFieldSliceChildNotNonOptionalScalar,
    RestFieldNotSliceOfStrings,
    UnsupportedFieldType,
};
fn classify(comptime meta: anytype, comptime field: Field) ClassifyError!Kind {
    const M = comptime meta_for(meta, field.name);
    const T = field.type;

    if (slice_child(T)) |t| {
        if (M.mode == .repeat) {
            if (!is_scalar(t) or @typeInfo(t) == .optional)
                return ClassifyError.RepeatedFieldSliceChildNotNonOptionalScalar;
            return .repeated;
        }
        if (T != []const u8) {
            if (M.mode == .positional) return ClassifyError.PositionalFieldNotScalar;
            if (M.mode == .count) return ClassifyError.CounterFieldNotInt;
            if (t != []const u8) return ClassifyError.RestFieldNotSliceOfStrings;
            return .rest;
        }
    }

    if (M.mode == .repeat) return ClassifyError.RepeatedFieldNotSlice;
    if (M.mode == .count and @typeInfo(T) != .int) return ClassifyError.CounterFieldNotInt;
    if (@typeInfo(T) == .optional and @typeInfo(@typeInfo(T).optional.child) == .@"struct") {
        if (M.mode == .positional) return ClassifyError.PositionalFieldNotScalar;
        return .command;
    }
    if (!is_scalar(T)) return ClassifyError.UnsupportedFieldType;
    if (M.mode == .count) {
        return .counter;
    }

    if (T == bool or T == ?bool) {
        if (M.mode == .positional) return ClassifyError.BoolCannotBePositional;
        if (T == bool) return .flag else return .toggle;
    }

    return if (M.mode == .positional) .slot else .value;
}
fn Schema(comptime Args: type) type {
    const argsinfo = @typeInfo(Args);
    if (argsinfo != .@"struct") compileError("Args must be a struct.\n", .{});
    const fields = argsinfo.@"struct".fields;
    const N = fields.len;
    if (N <= 0) compileError("Args must not be an empty struct.\n", .{});

    const meta = if (@hasDecl(Args, "meta")) @field(Args, "meta") else null;
    const metatype = @TypeOf(meta);
    const metainfo = @typeInfo(metatype);
    if (metainfo != .null) {
        if (metainfo != .@"struct") compileError("Meta declaration must be a struct.\n", .{});
        const metafields = metainfo.@"struct".fields;
        inline for (metafields) |metafield| {
            if (!@hasField(Args, metafield.name)) compileError("Unknown meta field: `{s}` is not a field of type Args.\n", .{metafield.name});
            const metafieldinfo = @typeInfo(metafield.type);
            if (metafieldinfo != .@"struct") compileError("Meta for `{s}` must be of type struct beancli.Meta.\n", .{metafield.name});
            const metakeys = metafieldinfo.@"struct".fields;
            inline for (metakeys) |metakey| {
                if (!@hasField(Meta, metakey.name)) compileError("Meta for `{s}` contains invalid field `{s}`. Must be of type struct beancli.Meta.\n", .{metafield.name, metakey.name});
            }
        }
    }

    const program_name = if (@hasDecl(Args, "name")) @field(Args, "name") else "";
    const program_doc = if (@hasDecl(Args, "doc")) @field(Args, "doc") else "";

    // for root and each command and subcommands
    const SchemaType = struct {
        const Self = @This();

        pub const Entry = struct {
            name: []const u8,
            name_snake: []const u8,
            name_kebab: []const u8,
            doc: []const u8,
            kind: Kind,

            takes_value: bool,
            value_optional: bool,
            required: bool,

            // for help and diagnostics
            short: ?u8,
            long: []const u8,
            long_snake: []const u8,
            long_kebab: []const u8,
            default_label: ?[]const u8,
            value_label: []const u8,
            type_label: []const u8,
            choices: []const []const u8,

            set_default: ?*const fn(*Self) void,
            assign: *const fn(*Self, ?[]const u8) ValueError!void,
            command: ?*Self,
        };

        name: []const u8, // program / command name
        doc: []const u8,

        root_schema: ?*Self,

        slots: [N]?usize,
        shorts: [N]u8,
        has_command: bool,
        commands: [N]?usize,
        rest_index: ?usize,

        entries: [N]Entry,

        pub fn init(root_schema: ?*Self) Self {
            var schema: Self = undefined;
            schema.name = program_name;
            schema.doc = program_doc;

            if (root_schema) |S| schema.root_schema = S
            else schema.root_schema = null;

            schema.slots = [_]?usize{null} ** N;
            schema.shorts = [_]u8{' '} ** N;
            schema.has_command = false;
            schema.commands = [_]?usize{null} ** N;
            schema.rest_index = null;

            inline for (fields, 0..) |field, field_index| {
                var entry: Entry = undefined;
                const field_meta = meta_for(meta, field.name);
                const fieldinfo = @typeInfo(field.type);
                _ = fieldinfo;

                entry.name = field.name;
                entry.name_kebab = comptime blk: {
                    var buf: [field.name.len]u8 = field.name[0..field.name.len].*;
                    std.mem.replaceScalar(u8, &buf, '_', '-');
                    const out = buf;
                    break :blk &out;
                };
                entry.name_snake = comptime blk: {
                    var buf: [field.name.len]u8 = field.name[0..field.name.len].*;
                    std.mem.replaceScalar(u8, &buf, '-', '_');
                    const out = buf;
                    break :blk &out;
                };
                entry.doc = field_meta.doc;
                entry.kind = classify(meta, field) catch |err| switch(err) {
                    error.BoolCannotBePositional => compileError(
                        \\Field `{s}` invalid: Boolean fields cannot be positional.
                        ,.{
                            field.name,
                        }
                    ),
                    error.PositionalFieldNotScalar => compileError(
                        \\Field `{s}` unsupported meta `.mode = .positional`: Positional fields must be a scalar type.
                        ,.{
                            field.name,
                        }
                    ),
                    error.CounterFieldNotInt => compileError(
                        \\Field `{s}` unsupported type `{s}`: Counter fields must be an integer type.
                        ,.{
                            field.name,
                            @typeName(field.type),
                        }
                    ),
                    error.RepeatedFieldNotSlice => compileError(
                        \\Field `{s}` unsupported type `{s}`: Repeated fields must be a slice `[]T` or `[]const T` type.
                        ,.{
                            field.name,
                            @typeName(field.type),
                        }
                    ),
                    error.RepeatedFieldSliceChildNotNonOptionalScalar => compileError(
                        \\Field `{s}` unsupported type `{s}`: Repeated fields' slice child's type must be non-optional.
                        ,.{
                            field.name,
                            @typeName(field.type),
                        }
                    ),
                    error.RestFieldNotSliceOfStrings => compileError(
                        \\Field `{s}` unsupported type `{s}`: Rest field can only be of type []const []const u8.
                        ,.{
                            field.name,
                            @typeName(field.type),
                        }
                    ),
                    error.UnsupportedFieldType => compileError(
                        \\Field `{s}` unsupported type `{s}`: Unknown field type.
                        ,.{
                            field.name,
                            @typeName(field.type),
                        }
                    ),
                };

                // Verify field kinds
                // i.e. There can only be one rest field
                switch(entry.kind) {
                    .rest => {
                        if (schema.rest_index != null) compileError(
                            \\Invalid field `{s}`: Only one rest field can exist per level.
                                ,.{
                                    entry.name,
                        }) else if (schema.has_command) compileError(
                            \\Invalid field `{s}`: A rest field cannot exist when there are subcommands.
                                ,.{
                                    entry.name,
                        }) else schema.rest_index = field_index;
                    },
                    .command => {
                        if (schema.rest_index != null) compileError(
                            \\Invalid field `{s}`: Commands cannot exist when there's a rest field.
                                ,.{
                                    entry.name,
                        }) else {
                            schema.has_command = true;
                            schema.commands[field_index] = field_index;
                            // const S = if (root_schema != null) root_schema else &schema;
                            // entry.command = comptime Self.init(S);
                        }
                    },
                    else => {},
                }

                entry.takes_value = switch(entry.kind) {
                    .flag, .command => false,
                    .value, .slot,
                    .repeated, .rest,
                    .toggle,
                    .counter        => true,
                    // else            => unreachable,
                };

                entry.value_optional = switch(entry.kind) {
                    .flag, .command   => false,
                    .counter, .toggle => true,
                    .slot, .value,
                    .repeated, .rest  => false,
                    // else            => unreachable,
                };

                if (field.defaultValue()) |default_value| {
                    entry.required = false;
                    const default_label = comptime std.fmt.comptimePrint("{any}", .{default_value});
                    entry.default_label = default_label;
                } else {
                    entry.required = true;
                    entry.default_label = null;
                }

                if (field_meta.short) |s| {
                    if (std.mem.findScalar(u8, &schema.shorts, s) != null) compileError(
                        \\Invalid meta for field `{s}`: Short `{u}` duplicated.
                        ,.{
                            field.name,
                            s,
                        }
                    );
                    entry.short = s;
                    schema.shorts[field_index] = s;
                } else entry.short = null;

                entry.long = comptime blk: {
                    var buf: [entry.name.len + 2]u8 = undefined;
                    buf[0] = '-'; buf[1] = '-';
                    @memcpy(buf[2..], entry.name);
                    const out = buf;
                    break :blk &out;
                };

                entry.long_snake = comptime blk: {
                    var buf: [entry.name_snake.len + 2]u8 = undefined;
                    buf[0] = '-'; buf[1] = '-';
                    @memcpy(buf[2..], entry.name_snake);
                    const out = buf;
                    break :blk &out;
                };

                entry.long_kebab = comptime blk: {
                    var buf: [entry.name_kebab.len + 2]u8 = undefined;
                    buf[0] = '-'; buf[1] = '-';
                    @memcpy(buf[2..], entry.name_kebab);
                    const out = buf;
                    break :blk &out;
                };

                entry.value_label = comptime blk: {
                    var buf: [entry.name_snake.len]u8 = undefined;
                    _ = std.ascii.upperString(&buf, entry.name_snake);
                    const out = buf;
                    break :blk &out;
                };

                entry.type_label = comptime blk: {
                    const type_name = @typeName(field.type);
                    var buf: [type_name.len]u8 = undefined;
                    _ = std.ascii.upperString(&buf, type_name);
                    const out = buf;
                    break :blk &out;
                };

                entry.choices = comptime blk: {
                    const E = enum_child(field.type) orelse break :blk &[_][]const u8{};
                    const enumfields = @typeInfo(E).@"enum".fields;
                    var buf: [enumfields.len][]const u8 = undefined;
                    for (enumfields, 0..) |f, i| buf[i] = f.name;
                    const out = buf;
                    break :blk &out;
                };

                // set_default: ?*const fn(*Self) void,
                // assign: *const fn(*Self, ?[]const u8) ValueError!void,
                // command: ?*Self,

                schema.entries[field_index] = entry;
            }

            return schema;
        }

        pub fn find_entry(self: Self, name: []const u8) ?Entry {
            for (self.entries) |candidate| {
                if (candidate.name.len != name.len) continue;
                if (candidate.name.len == 0 or candidate.name.ptr == name.ptr) return candidate;
                var matched = true;
                for (candidate.name, name) |a,b| {
                    if (!matched) break;
                    matched = a == b or (a == '_' and b == '-');
                }
                if (matched) return candidate;
            }
            return null;
        }
    };

    return SchemaType;
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
            try parse_scalar(info.child, value),
        else => unreachable,
    };
}
const TokenKind = enum {
    init,
    flag,
    long,
    short,
    barrier,
    value,
    positional,
    command,
};
const Token = struct {
    kind: TokenKind,
    raw: []const u8,
    arg_index: usize,
};
const ParseError = error {
    MissingValue,
    SyntaxError,
} || ValueError;
const Diagnostic = struct {
    error_type: ParseError,
    arg_index: usize,
    subindex: usize,
    error_message: []const u8,
};

pub fn parse(comptime Args: type, argv: []const []const u8) !void {
    const schema = comptime Schema(Args).init(null);
    const print = std.debug.print;

    print("schema\n", .{});
    print("name: {s}\n", .{schema.name});
    print("doc: {s}\n", .{schema.doc});
    print("shorts: {s}\n", .{schema.shorts});
    if (schema.rest_index) |i| print("rest_index: {d}\n", .{i});

    inline for (schema.entries) |entry| {
        print("entry: {s}\n", .{entry.name});
        print("    entry kind: {any}\n", .{entry.kind});

        print("    entry kebab: {s}\n", .{entry.name_kebab});
        print("    entry snake: {s}\n", .{entry.name_snake});
        if (entry.short) |s| print("    entry short: {u}\n", .{s});
        print("    entry long: {s}\n", .{entry.long});
        print("    entry long_snake: {s}\n", .{entry.long_snake});
        print("    entry long_kebab: {s}\n", .{entry.long_kebab});
        if (entry.default_label) |s| print("    entry default value: {s}\n", .{s});
        print("    entry value_label: {s}\n", .{entry.value_label});
        print("    entry type_label: {s}\n", .{entry.type_label});
        if (entry.choices.len > 0) {
            print("    entry choices:\n", .{});
            for (entry.choices) |choice| print("        choice: {s}\n", .{choice});
        }
    }
    _ = argv;
}

const cli = @This();
pub const testing = if (builtin.is_test) struct {
    pub const Kind = cli.Kind;
    pub const slice_child = cli.slice_child;
    pub const is_scalar = cli.is_scalar;
    pub const meta_for = cli.meta_for;
    pub const classify = cli.classify;
} else struct {};

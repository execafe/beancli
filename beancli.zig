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
const Schema = struct {
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
        long: ?[]const u8,
        long_snake: ?[]const u8,
        long_kebab: ?[]const u8,
        default_label: ?[]const u8,
        value_label: []const u8,
        type_label: []const u8,
        choices: []const []const u8,

        set_default: ?*const fn(*anyopaque) void,
        command: ?*const Schema,
    };

    name: []const u8, // program / command name
    doc: []const u8,

    root_schema: ?*const Schema,

    required_slots: []const usize,
    optional_slots: []const usize,
    shorts: []const u8,
    has_command: bool,
    has_slot: bool,
    commands: []const usize,
    rest_index: ?usize,

    entries: []const Entry,
};
fn is_string(comptime T: type) bool {
    if (T == []const u8) return true;
    const info = @typeInfo(T);
    if (info != .pointer or info.pointer.size != .one) return false;
    const child = @typeInfo(info.pointer.child);
    return child == .array and child.array.child == u8;
}
fn to_kebab(comptime string: []const u8) *const [string.len] u8{
    var buf: [string.len]u8 = string[0..string.len].*;
    std.mem.replaceScalar(u8, &buf, '_', '-');
    const out = buf;
    return &out;
}
fn to_snake(comptime string: []const u8) *const [string.len] u8{
    var buf: [string.len]u8 = string[0..string.len].*;
    std.mem.replaceScalar(u8, &buf, '-', '_');
    const out = buf;
    return &out;
}
fn to_long_flag(comptime string: []const u8) *const [string.len + 2] u8{
    var buf: [string.len + 2]u8 = undefined;
    buf[0] = '-'; buf[1] = '-';
    @memcpy(buf[2..], string);
    const out = buf;
    return &out;
}
fn str_eql_kebab(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |cha, chb| {
        const chacha = if (cha == '_') '-' else cha;
        const chbchb = if (chb == '_') '-' else chb;
        if (chacha != chbchb) return false;
    }
    return true;
}
fn create_set_default_function(comptime Args: type, comptime field: Field) ?*const fn(*anyopaque) void {
    const default = field.defaultValue() orelse return null;
    return struct {
        fn set(args_ptr: *anyopaque) void {
            const args: *Args = @ptrCast(@alignCast(args_ptr));
            @field(args, field.name) = default;
        }
    }.set;
}
fn build_schema(comptime Args: type, comptime root_schema: *const Schema, comptime is_root: bool, comptime fallback_name: ?[]const u8) Schema {
    const argsinfo = @typeInfo(Args);
    if (argsinfo != .@"struct") compileError("Args must be a struct.\n", .{});
    const fields = argsinfo.@"struct".fields;
    const N = fields.len;
    if (is_root and N <= 0) compileError("Args must not be an empty struct.\n", .{});

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
    inline for (.{"name", "doc"}) |decl| {
        if (@hasDecl(Args, decl) and !is_string(@TypeOf(@field(Args, decl)))) compileError(
            \\`{s}.{s}` must be of type []const u8, got `{s}`.
            ,.{ @typeName(Args), decl, @typeName(@TypeOf(@field(Args, decl))) }
        );
    }

    var schema: Schema = undefined;

    schema.name = if (@hasDecl(Args, "name")) @field(Args, "name")
    else if (fallback_name) |f| f
    else "";
    schema.doc = if (@hasDecl(Args, "doc")) @field(Args, "doc") else "";

    if (!is_root) schema.root_schema = root_schema
    else schema.root_schema = null;

    schema.has_slot = false;
    schema.has_command = false;
    schema.rest_index = null;

    var temp_req_slots: [N]usize = undefined;
    var temp_req_slots_len: usize = 0;
    var temp_opt_slots: [N]usize = undefined;
    var temp_opt_slots_len: usize = 0;
    var temp_shorts: [N]u8 = [_]u8{' '} ** N;
    var temp_commands: [N]usize = undefined;
    var temp_commands_len: usize = 0;

    var temp_entries: [N]Schema.Entry = undefined;

    inline for (fields, 0..) |field, field_index| {
        if (field.is_comptime) compileError(
            \\Field `{s}` invalid: comptime fields not supported.
            ,.{field.name}
        );
        var entry: Schema.Entry = undefined;
        const field_meta = meta_for(meta, field.name);
        const fieldinfo = @typeInfo(field.type);
        _ = fieldinfo;

        for (field.name, 0..) |c, i| {
            if (i == 0 and c == '-') compileError(
                \\Field `{s}` invalid: field name cannot start with '-'.
                ,.{field.name}
            );
            if (c == '=' or !std.ascii.isPrint(c) or std.ascii.isWhitespace(c)) compileError(
                \\Field `{s}` invalid: field name cannot contain `=`, whitespaces, or control characters.
                ,.{
                    field.name,
                }
            );
        }

        entry.name = field.name;
        entry.name_snake = comptime to_snake(field.name);
        entry.name_kebab = comptime to_kebab(field.name);

        // because we can do dashes in field names of struct by using @"" syntax
        // flag_name: bool and @"flag-name": bool should be considered duplicates
        for (temp_entries[0..field_index]) |prev| {
            if (str_eql_kebab(prev.name, entry.name)) compileError(
                \\Field `{s}` collides with field `{s}`: Both are `--{s}`.
                ,.{
                    entry.name, prev.name, prev.name_kebab
                }
            );
        }

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

        entry.command = null;
        switch(entry.kind) {
            .rest => {
                if (schema.rest_index != null) compileError(
                    \\Invalid field `{s}`: Only one rest field can exist per level.
                    ,.{entry.name}
                ) else if (schema.has_command) compileError(
                    \\Invalid field `{s}`: A rest field cannot exist when there are subcommands.
                    ,.{entry.name}
                ) else schema.rest_index = field_index;
            },
            .command => {
                if (schema.rest_index != null) compileError(
                    \\Invalid field `{s}`: Commands cannot exist when there's a rest field.
                    ,.{entry.name}
                ) else if (schema.has_slot) compileError(
                    \\Invalid field `{s}`: Commands cannot exist when there are positional slots.
                    ,.{entry.name}
                ) else {
                    temp_commands[temp_commands_len] = field_index;
                    temp_commands_len += 1;

                    const CommandArgs = @typeInfo(field.type).optional.child;
                    entry.command = get_schema(CommandArgs, root_schema, entry.name_kebab);

                    schema.has_command = true;
                }
            },
            .slot => {
                if (schema.has_command) compileError(
                    \\Invalid field `{s}`: Positional fields cannot exist when there are commands.
                    ,.{entry.name}
                );
                if (field.defaultValue() == null) {
                    if (temp_opt_slots_len > 0) compileError(
                        \\Invalid field `{s}`: Required positional slot `{s}` comes after optional positional slot `{s}`.
                        ,.{entry.name, entry.name, temp_entries[temp_opt_slots[0].?].name}
                    );
                    temp_req_slots[temp_req_slots_len] = field_index;
                    temp_req_slots_len += 1;
                } else {
                    temp_opt_slots[temp_opt_slots_len] = field_index;
                    temp_opt_slots_len += 1;
                }
                schema.has_slot = true;
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
            if (entry.kind == .command and default_value != null) compileError(
                \\Command `{s}` invalid: commands must default to `null`.
                ,.{entry.name},
            );
            entry.required = false;
            const default_label = comptime std.fmt.comptimePrint("{any}", .{default_value});
            entry.default_label = default_label;
        } else {
            if (entry.kind == .command) compileError(
                \\Command `{s}` invalid: commands must default to `null`.
                ,.{entry.name},
            );
            entry.required = true;
            entry.default_label = null;
        }

        if (field_meta.short) |c| {
            if (!std.ascii.isAlphanumeric(c)) compileError(
                \\Invalid meta for field `{s}`: Short must be alphanumeric, got `{u}`.
                ,.{field.name, c}
            );
            switch (entry.kind) {
                .command, .rest => compileError(
                    \\Invalid meta for field `{s}`: `{s}` fields cannot have a short.
                    ,.{field.name, @tagName(entry.kind)}
                ),
                .flag, .toggle, .counter, .repeated, .value, .slot => {},
            }
            if (std.mem.findScalar(u8, &temp_shorts, c) != null) compileError(
                \\Invalid meta for field `{s}`: Short `{u}` duplicated.
                ,.{field.name, c}
            );
            entry.short = c;
            temp_shorts[field_index] = c;
        } else entry.short = null;

        if (entry.kind == .command or entry.kind == .rest) {
            entry.long       = null;
            entry.long_snake = null;
            entry.long_kebab = null;
        } else {
            entry.long       = comptime to_long_flag(entry.name);
            entry.long_snake = comptime to_long_flag(entry.name_snake);
            entry.long_kebab = comptime to_long_flag(entry.name_kebab);
        }

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
            const enuminfo = @typeInfo(E).@"enum";
            if (!enuminfo.is_exhaustive) compileError(
                \\Field `{s}` unsupported type `{s}`: Enum fields must be exhaustive.
                ,.{field.name,@typeName(E)},
            );
            const enumfields = enuminfo.fields;
            for (enumfields, 0..) |a, i| {
                for(enumfields[0..i]) |b| {
                    const kebab_enum_name = to_kebab(b.name);
                    if (str_eql_kebab(a.name, b.name)) compileError(
                        \\Enum field `{s}.{s}` collides with `{s}.{s}`: Both can be set as `--{s}={s}`.
                        ,.{field.name, a.name, field.name, b.name, entry.name_kebab, kebab_enum_name}
                    );
                }
            }
            var buf: [enumfields.len][]const u8 = undefined;
            for (enumfields, 0..) |f, i| buf[i] = f.name;
            const out = buf;
            break :blk &out;
        };

        entry.set_default = create_set_default_function(Args, field);
        // assign: *const fn(*Self, ?[]const u8) ValueError!void,

        temp_entries[field_index] = entry;
    }

    const final_req_slots = temp_req_slots;
    const final_opt_slots = temp_opt_slots;
    const final_shorts = temp_shorts;
    const final_commands = temp_commands;
    const final_entries = temp_entries;

    schema.required_slots = &final_req_slots;
    schema.optional_slots = &final_opt_slots;
    schema.shorts = &final_shorts;
    schema.commands = &final_commands;
    schema.entries = &final_entries;

    return schema;
}

fn get_schema(comptime Args: type, comptime root_schema: ?*const Schema, comptime fallback_name: ?[]const u8) *const Schema {
    return &struct {
        const schema: Schema = build_schema(Args, root_schema orelse &schema, root_schema == null, fallback_name);
    }.schema;
}

pub const ValueError = error {
    InvalidValue,
    // from std.fmt
    Overflow,
    InvalidCharacter,
};
fn parse_enum(comptime T: type, value: []const u8) ValueError!T {
    const maybe_match = std.meta.stringToEnum(T, value);
    if (maybe_match) |m| return m;

    const choices = @typeInfo(T).@"enum".fields;
    inline for (choices) |choice| {
        const matched = str_eql_kebab(choice.name, value);
        if (matched) return @enumFromInt(choice.value);
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
    ident,
    value,
    equal,
    dash,
    double_dash,
};
const Token = struct {
    kind: TokenKind,
    raw: []const u8,
    arg_index: usize,
    subindex: usize,
};
const ParseError = error {
    Unimplemented,
    EmptyArgs,
    MissingValue,
    SyntaxError,
} || ValueError;
pub const Diagnostic = struct {
    error_type: ?ParseError = null,
    offending_token: ?Token = null,
    // suggestion: ?[]const u8,

    pub fn fill(diagnostic: ?*Diagnostic, error_type: ParseError, offending_token: ?Token) void {
        if (diagnostic) |d| {
            d.error_type = error_type;
            d.offending_token = offending_token;
        } else {}
    }
};
const Tokens = struct {
    argv: []const []const u8,
    curr_index: usize = 0,
    curr_subindex: usize = 0,

    curr_token: ?Token = null,
    parse_error: ?ParseError = null,

    pub fn init(argv: []const []const u8, diagnostic: ?*Diagnostic) ?Tokens {
        if (argv.len <= 0) {
            Diagnostic.fill(diagnostic, ParseError.EmptyArgs, null);
            return null;
        }
        return .{ .argv = argv };
    }

    fn advance_token(self: *Tokens) !Token {
        _ = self;
        return error.Unimplemented;
    }

    pub fn next(self: *Tokens, diagnostic: ?*Diagnostic) ?Token {
        _ = diagnostic;
        const len = self.argv.len;
        const last_arg = self.argv[len - 1];
        if (self.curr_index >= len - 1 and self.curr_subindex >= last_arg.len - 1) return null;

        const curr = self.curr_token;
        if (curr == null) {}

        return null;
    }
};
pub fn parse(comptime Args: type, argv: []const []const u8, diagnostic: ?*Diagnostic) Args {
    const schema = comptime get_schema(Args, null, null);
    _ = schema;
    const args: Args = undefined;
    // const print = std.debug.print;

    const prog_name = if (argv.len > 0) std.fs.path.basename(argv[0]) else "";
    _ = prog_name;

    const tokens = Tokens.init(argv[1..], diagnostic);
    _ = tokens;

    return args;
}

const cli = @This();
pub const testing = if (builtin.is_test) struct {
    pub const Kind = cli.Kind;
    pub const slice_child = cli.slice_child;
    pub const is_scalar = cli.is_scalar;
    pub const meta_for = cli.meta_for;
    pub const classify = cli.classify;
} else struct {};

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
    default, count, repeat, positional, help
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
    HelpFieldNotBool,
};
fn classify(comptime meta: anytype, comptime field: Field) ClassifyError!Kind {
    const M = comptime meta_for(meta, field.name);
    const T = field.type;

    if (M.mode == .help) {
        if (T != bool) return ClassifyError.HelpFieldNotBool;
        return .flag;
    }

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
        return .flag;
    }

    return if (M.mode == .positional) .slot else .value;
}
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
fn create_default_label(comptime T: type, comptime value: T) ?[]const u8 {
    if (T == []const u8) return std.fmt.comptimePrint("\"{s}\"", .{value});
    const typeinfo = @typeInfo(T);
    return switch(typeinfo) {
        .optional    => |o| if (value) |v| create_default_label(o.child, v) else null,
        .@"enum"     => @tagName(value),
        .bool        => if (value) "true" else "false",
        .int, .float => std.fmt.comptimePrint("{d}", .{value}),
        else         => null,
    };
}

const SetDefaultFn = *const fn (args: *anyopaque) void;
const AssignFn     = *const fn (args: *anyopaque, value: ?[]const u8) ParseError!void;
const AppendFn     = *const fn (args: *anyopaque, allocator: std.mem.Allocator, cap: usize, count: usize, value: []const u8) ParseError!void;
const CommandFn    = *const fn (args: *anyopaque, allocator: std.mem.Allocator, argv: []const []const u8, info: ?*Info, root: *const Level) ParseError!void;
const Level = struct {
    schema: *const Schema,
    args: *anyopaque,
    seen_count: []usize,
};
const Schema = struct {
    pub const Entry = struct {
        field_index    : usize,

        name           : []const u8,
        name_snake     : []const u8,
        name_kebab     : []const u8,
        doc            : []const u8,
        kind           : Kind,

        takes_value    : bool,
        value_optional : bool,
        required       : bool,

        // for help and diagnostics
        is_help        : bool,
        short          : ?u8,
        long           : ?[]const u8,
        long_snake     : ?[]const u8,
        long_kebab     : ?[]const u8,
        default_label  : ?[]const u8,
        value_label    : []const u8,
        type_label     : []const u8,
        min_label      : ?[]const u8,
        max_label      : ?[]const u8,
        choices        : []const []const u8,

        command        : ?*const Schema,

        set_default: ?SetDefaultFn,   // null = no default = required
        assign: ?AssignFn,            // flag, counter, value, slot
        append: ?AppendFn,            // repeated, rest
        parse_command: ?CommandFn,    // command
    };

    name           : []const u8, // program / command name
    doc            : []const u8,
    path           : []const u8,

    root_schema    : ?*const Schema,

    shorts         : []const u8,
    shorts_index   : []const usize,

    has_slot       : bool,
    required_slots : []const usize,
    optional_slots : []const usize,

    has_command    : bool,
    commands       : []const usize,

    rest_index     : ?usize,
    help_index     : ?usize,

    entries        : []const Entry,

    pub fn find_by_name(self: *const Schema, name: []const u8) ?*const Entry {
        for (self.entries) |*entry| {
            if (entry.long == null) continue; // commands and rest have no --flag
            if (str_eql_kebab(entry.name, name)) return entry;
        }
        return null;
    }
    pub fn find_negated(self: *const Schema, name: []const u8) ?*const Entry {
        if (name.len <= 3
                or name[0]  != 'n'
                or name[1]  != 'o'
                or name[2]  != '-'
                and name[2] != '_'
            ) return null;
        const e = self.find_by_name(name[3..]) orelse return null;
        return if (e.kind == .flag and !e.is_help) e else null;
    }
    pub fn find_by_short(self: *const Schema, short: u8) ?*const Entry {
        const i = std.mem.findScalar(u8, self.shorts, short) orelse return null;
        return &self.entries[self.shorts_index[i]];
    }
    pub fn find_command(self: *const Schema, name: []const u8) ?*const Entry {
        for (self.commands) |idx| {
            if (str_eql_kebab(self.entries[idx].name, name)) return &self.entries[idx];
        }
        return null;
    }
    pub fn slot_at(self: *const Schema, n: usize) ?*const Entry {
        const req_len = self.required_slots.len;
        if (n < req_len) return &self.entries[self.required_slots[n]];
        if (n - req_len < self.optional_slots.len) return &self.entries[self.optional_slots[n - req_len]];
        return null;
    }
    pub fn builtin_help(self: *const Schema) bool {
        if (self.help_index != null) return false;
        if (self.root_schema) |r| if (r.help_index != null) return false;
        return true;
    }
};
fn create_set_default_fn(comptime Args: type, comptime field: Field, comptime kind: Kind) ?SetDefaultFn {
    // Implicit defaults
    const value: field.type = field.defaultValue() orelse switch (kind) {
        .flag    => if (field.type == bool) false else null,
        .counter => 0,
        .rest    => &.{},
        .command => null,
        else     => return null,
    };
    return struct {
        fn f(args_ptr: *anyopaque) void {
            const args: *Args = @ptrCast(@alignCast(args_ptr));
            @field(args, field.name) = value;
        }
    }.f;
}
fn create_assign_fn(comptime Args: type, comptime field: Field, comptime kind: Kind) ?AssignFn {
    switch (kind) {
        .repeated, .rest, .command => return null,
        .flag, .counter, .value, .slot => {},
    }
    return struct {
        fn f(args_ptr: *anyopaque, value: ?[]const u8) ParseError!void {
            const args: *Args = @ptrCast(@alignCast(args_ptr));
            const T = field.type;
            const field_ptr = &@field(args, field.name);
            switch(kind) {
                .flag => {
                    field_ptr.* = if (value) |v| try parse_scalar(bool, v) else true;
                },
                .counter => {
                    field_ptr.* = if (value) |v| try parse_scalar(T, v) else try std.math.add(T, field_ptr.*, 1);
                },
                .value, .slot => {
                    if (value) |v| field_ptr.* = try parse_scalar(T, v) else return ParseError.MissingValue;
                },
                .repeated,
                .rest,
                .command => unreachable,
            }
        }
    }.f;
}
fn create_append_fn(comptime Args: type, comptime field: Field, comptime kind: Kind) ?AppendFn {
    if (kind != .repeated and kind != .rest) return null;
    const Child = slice_child(field.type).?;
    return struct {
        fn f(args_ptr: *anyopaque, allocator: std.mem.Allocator, size: usize, count: usize, value: []const u8) ParseError!void {
            const args: *Args = @ptrCast(@alignCast(args_ptr));
            if (count == 0) @field(args, field.name) = (try allocator.alloc(Child, size))[0..0];
            const field_ptr: [*]Child = @constCast(@field(args, field.name).ptr);
            field_ptr[count] = try parse_scalar(Child, value);
            @field(args, field.name) = field_ptr[0 .. count + 1];
        }
    }.f;
}
fn create_parse_command_fn(comptime Args: type, comptime field: Field, comptime kind: Kind, comptime sub_schema: ?*const Schema) ?CommandFn {
    if (kind != .command) return null;
    const Sub = @typeInfo(field.type).optional.child;
    return struct {
        fn f(args_ptr: *anyopaque, allocator: std.mem.Allocator, argv: []const []const u8, info: ?*Info, root: *const Level) ParseError!void {
            const args: *Args = @ptrCast(@alignCast(args_ptr));
            var sub: Sub = undefined;
            try parse_level(sub_schema.?, allocator, &sub, argv, info, root);
            @field(args, field.name) = sub;
        }
    }.f;
}
fn build_schema(comptime Args: type, comptime root_schema: *const Schema, comptime is_root: bool, comptime fallback_name: ?[]const u8, comptime path: []const u8) Schema {
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
    schema.path = path;

    if (!is_root) schema.root_schema = root_schema
    else schema.root_schema = null;

    schema.has_slot = false;
    schema.has_command = false;
    schema.rest_index = null;
    schema.help_index = null;

    var temp_req_slots: [N]usize = undefined;
    var temp_req_slots_count: usize = 0;
    var temp_opt_slots: [N]usize = undefined;
    var temp_opt_slots_count: usize = 0;
    var temp_shorts: [N]u8 = undefined;
    var temp_shorts_index: [N]usize = undefined;
    var temp_shorts_count: usize = 0;
    var temp_commands: [N]usize = undefined;
    var temp_commands_count: usize = 0;
    var temp_entries: [N]Schema.Entry = undefined;

    inline for (fields, 0..) |field, field_index| {
        if (field.is_comptime) compileError(
            \\Field `{s}` invalid: comptime fields not supported.
            ,.{field.name}
        );
        var entry: Schema.Entry = undefined;
        const field_meta = meta_for(meta, field.name);

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
                ,.{entry.name, prev.name, prev.name_kebab}
            );
        }

        entry.doc = field_meta.doc;
        entry.kind = classify(meta, field) catch |err| switch(err) {
            ClassifyError.BoolCannotBePositional => compileError(
                \\Field `{s}` invalid: Boolean fields cannot be positional.
                ,.{
                    field.name,
                }
            ),
            ClassifyError.PositionalFieldNotScalar => compileError(
                \\Field `{s}` unsupported meta `.mode = .positional`: Positional fields must be a scalar type.
                ,.{
                    field.name,
                }
            ),
            ClassifyError.CounterFieldNotInt => compileError(
                \\Field `{s}` unsupported type `{s}`: Counter fields must be an integer type.
                ,.{
                    field.name,
                    @typeName(field.type),
                }
            ),
            ClassifyError.RepeatedFieldNotSlice => compileError(
                \\Field `{s}` unsupported type `{s}`: Repeated fields must be a slice `[]T` or `[]const T` type.
                ,.{
                    field.name,
                    @typeName(field.type),
                }
            ),
            ClassifyError.RepeatedFieldSliceChildNotNonOptionalScalar => compileError(
                \\Field `{s}` unsupported type `{s}`: Repeated fields' slice child's type must be non-optional.
                ,.{
                    field.name,
                    @typeName(field.type),
                }
            ),
            ClassifyError.RestFieldNotSliceOfStrings => compileError(
                \\Field `{s}` unsupported type `{s}`: Rest field can only be of type []const []const u8.
                ,.{
                    field.name,
                    @typeName(field.type),
                }
            ),
            ClassifyError.UnsupportedFieldType => compileError(
                \\Field `{s}` unsupported type `{s}`: Unknown field type.
                ,.{
                    field.name,
                    @typeName(field.type),
                }
            ),
            ClassifyError.HelpFieldNotBool => compileError(
                \\Field `{s}` unsupported type `{s}`: `.mode = .help` fields must be of type `bool`.
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
                    temp_commands[temp_commands_count] = field_index;
                    temp_commands_count += 1;

                    const CommandArgs = @typeInfo(field.type).optional.child;
                    const sub_path = if (path.len == 0) entry.name_kebab else path ++ " " ++ entry.name_kebab;
                    entry.command = get_schema(CommandArgs, root_schema, entry.name_kebab, sub_path);

                    schema.has_command = true;
                }
            },
            .slot => {
                if (schema.has_command) compileError(
                    \\Invalid field `{s}`: Positional fields cannot exist when there are commands.
                    ,.{entry.name}
                );
                if (field.defaultValue() == null) {
                    if (temp_opt_slots_count > 0) compileError(
                        \\Invalid field `{s}`: Required positional slot `{s}` comes after optional positional slot `{s}`.
                        ,.{entry.name, entry.name, temp_entries[temp_opt_slots[0]].name}
                    );
                    temp_req_slots[temp_req_slots_count] = field_index;
                    temp_req_slots_count += 1;
                } else {
                    temp_opt_slots[temp_opt_slots_count] = field_index;
                    temp_opt_slots_count += 1;
                }
                schema.has_slot = true;
            },
            else => {},
        }

        entry.takes_value = switch(entry.kind) {
            .flag, .command   => false,
            .value, .slot,
            .repeated, .rest,
            .counter          => true,
        };

        entry.value_optional = switch(entry.kind) {
            .flag, .command  => false, // no value at all
            .counter         => true,
            .slot, .value,
            .repeated, .rest => false,
        };

        if (field.defaultValue()) |default_value| {
            if (entry.kind == .command and default_value != null) compileError(
                \\Command `{s}` invalid: commands must default to `null`.
                ,.{entry.name},
            );
            entry.default_label = comptime create_default_label(field.type, default_value);
        } else {
            // if (entry.kind == .command) compileError(
            //     \\Command `{s}` invalid: commands must default to `null`.
            //     ,.{entry.name},
            // );
            entry.default_label = null;
        }

        entry.set_default   = create_set_default_fn(Args, field, entry.kind);
        entry.required      = entry.set_default == null;

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
                .flag, .counter, .repeated, .value, .slot => {},
            }
            if (std.mem.findScalar(u8, temp_shorts[0..temp_shorts_count], c) != null) compileError(
                \\Invalid meta for field `{s}`: Short `{u}` duplicated.
                ,.{field.name, c}
            );
            entry.short = c;
            temp_shorts[temp_shorts_count] = c;
            temp_shorts_index[temp_shorts_count] = field_index;
            temp_shorts_count += 1;
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

        const typeinfo = @typeInfo(field.type);
        entry.type_label = @typeName(field.type);
        const valueinfo = if (entry.kind == .repeated) @typeInfo(typeinfo.pointer.child) else typeinfo;
        entry.value_label = comptime switch (entry.kind) {
            .flag, .command => "",
            .rest           => "STRING",
            .counter, .slot, .value, .repeated => val: switch (valueinfo) {
                .optional => |info| continue :val @typeInfo(info.child),
                .pointer  => |info| {
                    if (info.child == u8) break :val "STRING"
                    else continue :val @typeInfo(info.child);
                },
                .bool     => "true|false",
                .int      => |info| if (info.signedness == .signed) "INT" else "UINT",
                .float    => "FLOAT",
                .@"enum"  => |info| {
                    var choices: []const u8 = "";
                    for (info.fields, 0..) |f, i| {
                        if (i > 0) choices = choices ++ "|";
                        choices = choices ++ f.name;
                    }
                    break :val choices;
                },
                else => @compileError("no value label for " ++ @typeName(field.type)),
            },
        };
        blk: switch (typeinfo) {
            .optional => |info| {
                entry.type_label = @typeName(info.child);
                const childinfo = @typeInfo(info.child);
                continue :blk childinfo;
            },
            .pointer => |info| {
                entry.type_label = @typeName(info.child);
                if ((info.child == u8 and entry.kind != .repeated) // []const u8
                        or (info.child == []const u8 and entry.kind == .repeated)) { // []const []const u8
                    entry.min_label = null;
                    entry.max_label = null;
                    break :blk;
                }
                const childinfo = @typeInfo(info.child);
                continue :blk childinfo;
            },
            .int => |info| {
                entry.min_label = std.fmt.comptimePrint("{d}", .{std.math.minInt(@Int(info.signedness, info.bits))});
                entry.max_label = std.fmt.comptimePrint("{d}", .{std.math.maxInt(@Int(info.signedness, info.bits))});
            },
            .float => |info| {
                entry.min_label = std.fmt.comptimePrint("{d}", .{std.math.floatMin(std.meta.Float(info.bits))});
                entry.max_label = std.fmt.comptimePrint("{d}", .{std.math.floatMax(std.meta.Float(info.bits))});
            },
            else => {
                entry.min_label = null;
                entry.max_label = null;
            }
        }

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

        entry.assign        = create_assign_fn(Args, field, entry.kind);
        entry.append        = create_append_fn(Args, field, entry.kind);
        entry.parse_command = create_parse_command_fn(Args, field, entry.kind, entry.command);

        entry.field_index = field_index;

        entry.is_help = field_meta.mode == .help;
        if (entry.is_help) {
            if (schema.help_index) |i| compileError(
                \\Field `{s}` invalid: `{s}` is already the help field.
                ,.{
                    field.name,
                    fields[i].name,
                }
            );
            schema.help_index = field_index;
        }

        temp_entries[field_index] = entry;
    }

    // flag name check for negation
    for (temp_entries) |a| {
        if (a.kind != .flag) continue;
        for (temp_entries) |b| {
            if (b.name_kebab.len == a.name_kebab.len + 3 and std.mem.startsWith(u8, b.name_kebab, "no-") and std.mem.eql(u8, b.name_kebab[3..], a.name_kebab)) compileError(
                \\Field `{s}` collides with `--no-{s}` (negation of flag `{s}`)
                ,.{ b.name, a.name_kebab, a.name },
            );
        }
    }

    const final_req_slots = temp_req_slots[0..temp_req_slots_count].*;
    const final_opt_slots = temp_opt_slots[0..temp_opt_slots_count].*;
    const final_shorts = temp_shorts[0..temp_shorts_count].*;
    const final_shorts_index = temp_shorts_index[0..temp_shorts_count].*;
    const final_commands = temp_commands[0..temp_commands_count].*;
    const final_entries = temp_entries;

    schema.required_slots = &final_req_slots;
    schema.optional_slots = &final_opt_slots;
    schema.shorts = &final_shorts;
    schema.shorts_index = &final_shorts_index;
    schema.commands = &final_commands;
    schema.entries = &final_entries;

    return schema;
}
fn get_schema(comptime Args: type, comptime root_schema: ?*const Schema, comptime fallback_name: ?[]const u8, comptime path: []const u8) *const Schema {
    return &struct {
        const schema: Schema = build_schema(Args, root_schema orelse &schema, root_schema == null, fallback_name, path);
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

    return ValueError.InvalidValue;
}
fn parse_scalar(comptime T: type, value: []const u8) ValueError!T {
    if (T == []const u8) return value;
    return switch(@typeInfo(T)) {
        .bool => if (std.mem.eql(u8, value, "true"))
            true
        else if (std.mem.eql(u8, value, "false"))
            false
        else
            ValueError.InvalidValue,
        .int => try std.fmt.parseInt(T, value, 10),
        .float => try std.fmt.parseFloat(T, value),
        .@"enum" => try parse_enum(T, value),
        .optional => |info| try parse_scalar(info.child, value),
        else => unreachable,
    };
}
pub const ParseError = error {
    UnexpectedPositional,
    FlagTakesNoValue,

    UnknownOption,
    MissingValue,
    MissingRequired,

    HelpRequested,

    // allocator error
    OutOfMemory,
    Unexpected
} || ValueError;
pub const Diagnostic = struct {
    args: []const []const u8 = &.{},
    offset: usize = 0,

    error_type: ?ParseError = null,

    error_at: ?ErrorAt = null,
    missing_value: bool = false,
    value: ?[]const u8 = null,

    entry: ?*const Schema.Entry = null,
    ctx: ?*const Schema = null,
    suggestion: []const u8 = "",

    pub const ErrorAt = struct {
        usize, // arg_index -> arg = args[arg_index]
        usize, // start
        usize, // end       -> error_at = arg[start..end]
    };
};
pub const Info = struct {
    schema: *const Schema,
    diagnostic: Diagnostic,
    program_name: []const u8,

    const Message = struct {
        headline: []const u8,
        details: []const u8,
    };
    fn message(buf: []u8, err: ParseError, d: *const Diagnostic) Message {
        var msg: Message = .{ .headline = @errorName(err), .details = "" };
        const arg = if (d.error_at) |e| d.args[e[0]] else "";
        const ctx_name = if (d.ctx) |c| c.name else "";
        switch (err) {
            ParseError.UnknownOption        => {
                msg.headline = std.fmt.bufPrint(buf, "unknown option `{s}`", .{arg}) catch "";
                msg.details = std.fmt.bufPrint(buf[msg.headline.len..], "not an option of `{s}`", .{ctx_name}) catch "";
            },
            ParseError.UnexpectedPositional => {
                msg.headline = std.fmt.bufPrint(buf, "unexpected argument `{s}`", .{arg}) catch "";
                msg.details = "no more positional arguments";
            },
            ParseError.MissingValue         => {
                msg.headline = std.fmt.bufPrint(buf, "`{s}` needs a value", .{arg}) catch "";
                msg.details = std.fmt.bufPrint(buf[msg.headline.len..], "expected `<{s}>` here", .{d.entry.?.value_label}) catch "";
            },
            ParseError.FlagTakesNoValue     => {
                const eql_idx = std.mem.findScalar(u8, arg, '=');
                msg.headline = std.fmt.bufPrint(buf, "`{s}` doesn't take a value", .{arg[0..eql_idx orelse arg.len]}) catch "";
                msg.details = std.fmt.bufPrint(buf[msg.headline.len..], "remove `{s}`", .{if (eql_idx) |i| arg[i..] else d.value orelse ""}) catch "";
            },
            ParseError.InvalidValue         => {
                msg.headline = std.fmt.bufPrint(buf, "invalid value `{s}` for `{s}`", .{d.value.?, d.entry.?.long_kebab.?}) catch "";
                if (d.entry.?.choices.len > 0) {
                    var w: std.Io.Writer = .fixed(buf[msg.headline.len..]);
                    w.writeAll("expected one of: ") catch {};
                    for (d.entry.?.choices, 0..) |choice, i| {
                        if (i > 0) w.writeAll(", ") catch {};
                        if (i == d.entry.?.choices.len - 1) w.writeAll("or ") catch {};
                        w.print("`{s}`", .{choice}) catch {};
                    }
                    msg.details = w.buffered();
                }
            },
            ParseError.InvalidCharacter     => {
                msg.headline = std.fmt.bufPrint(buf, "invalid value `{s}` for `{s}`", .{d.value.?, d.entry.?.long_kebab.?}) catch "";
                msg.details = std.fmt.bufPrint(buf[msg.headline.len..], "expected a `{s}`", .{d.entry.?.type_label}) catch "";
            },
            ParseError.Overflow             => {
                msg.headline = std.fmt.bufPrint(buf, "invalid value `{s}` for `{s}`", .{d.value.?, d.entry.?.long_kebab.?}) catch "";
                msg.details = std.fmt.bufPrint(buf[msg.headline.len..],
                                               "out of range for `{s}`, expected value from {s} to {s}",
                                               .{d.entry.?.type_label, d.entry.?.min_label.?, d.entry.?.max_label.?}) catch "";
            },
            ParseError.MissingRequired      => {
                switch(d.entry.?.kind) {
                    .value,
                    .slot,
                    .counter  => {
                        msg.headline = std.fmt.bufPrint(buf, "missing required `{s} <{s}>`", .{d.entry.?.long_kebab.?, d.entry.?.value_label}) catch "";
                    },
                    .repeated => {
                        msg.headline = std.fmt.bufPrint(buf, "missing required `{s} <{s}> ...`", .{d.entry.?.long_kebab.?, d.entry.?.value_label}) catch "";
                    },
                    .flag,
                    .command,
                    .rest     => {
                        // cannot be required
                    }
                }
            },
            ParseError.OutOfMemory,
            ParseError.Unexpected           => {
                msg.headline = "out of memory / couldn't read the arguments";
            },
            ParseError.HelpRequested        => {
                msg.headline = "help requested";
            }
        }

        return msg;
    }
    pub fn print_error(info: *Info, w: *std.Io.Writer) std.Io.Writer.Error!void {
        const d = &info.diagnostic;
        const err = d.error_type orelse return;
        var buf : [256]u8 = undefined;
        const msg = message(&buf, err, d);

        try w.print("[beancli] error: {s}\n", .{msg.headline});

        // echo program name + args
        var arg_col: usize = 0;
        var col: usize = 4 + info.program_name.len;
        try w.print("    {s}", .{info.program_name});
        for (d.args, 0..) |arg, idx| {
            try w.writeByte(' ');
            col += 1;
            if (d.error_at) |at| {
                if (idx == at[0]) arg_col = col;
            }
            try w.writeAll(arg);
            col += arg.len;
        }
        try w.writeByte('\n');

        const at = d.error_at orelse {
            // MissingRequired, Unexpected, OutOfMemory ends here
            try w.writeByte('\n');
            return;
        };

        // underline offending arg
        const arg = d.args[at[0]];
        const pad = arg_col + arg[0..at[1]].len;
        const len = @max(1, arg[at[1]..at[2]].len);
        try w.splatByteAll(' ', pad);
        try w.splatByteAll('^', len);
        if (d.missing_value) {
            try w.splatByteAll(' ', col - (pad + len) + 1);
            try w.writeByte('^');
        }
        try w.print(" {s}\n", .{msg.details});
        try w.writeByte('\n');
    }
    fn help_entry(w: *std.Io.Writer, entry: *const Schema.Entry) std.Io.Writer.Error!void {
        var buf: [256]u8 = undefined;
        var left: std.Io.Writer = .fixed(&buf);
        switch(entry.kind) {
            .command  => try left.writeAll(entry.name_kebab),
            .slot     => {
                try left.print("<{s}>, ", .{entry.name_kebab});
                if (entry.short) |c| try left.print("-{c}, ", .{c});
                try left.print("--{s} <{s}>", .{ entry.name_kebab, entry.value_label });
            },
            .rest     => try left.print("[{s}...]", .{entry.name_kebab}),
            .flag,
            .counter,
            .value,
            .repeated => {
                if (entry.short) |c| try left.print("-{c}, ", .{c}) else try left.writeAll("    ");
                if (entry.kind == .flag and !entry.is_help) {
                    try left.print("--[no-]{s}", .{entry.name_kebab});
                } else {
                    try left.print("--{s}", .{entry.name_kebab});
                }
                if (entry.kind == .value) try left.print(" <{s}>", .{entry.value_label});
                if (entry.kind == .repeated) try left.print(" <{s}>...", .{entry.value_label});
                if (entry.kind == .counter) try left.writeAll("...");
            }
        }
        const doc = if (entry.kind == .command and entry.doc.len == 0) entry.command.?.doc
                    else if (entry.is_help and entry.doc.len == 0) "Print this help"
                    else entry.doc;

        try w.print("  {s:<28}  {s}", .{left.buffered(), doc});
        if (entry.kind != .flag) if (entry.default_label) |d| try w.print(" [default: {s}]", .{d});
        try w.writeByte('\n');
    }
    pub fn print_help(info: *const Info, w: *std.Io.Writer) std.Io.Writer.Error!void {
        const s = info.schema;
        if (s.doc.len > 0) try w.print("{s}\n\n", .{s.doc});

        // Usage line
        try w.print("Usage: {s}", .{info.program_name});
        if (s.path.len > 0) try w.print(" {s}", .{s.path});
        try w.writeAll(" [OPTIONS]");
        for (s.required_slots) |i| try w.print(" <{s}>", .{s.entries[i].name_kebab});
        for (s.optional_slots) |i| try w.print(" [{s}]", .{s.entries[i].name_kebab});
        if (s.rest_index) |i| try w.print(" [{s}...]", .{ s.entries[i].name_kebab });
        if (s.has_command) try w.writeAll(" [COMMAND]");
        try w.writeByte('\n');

        // commands
        if (s.has_command) {
            try w.writeAll("\nCommands:\n");
            for (s.commands) |i| try help_entry(w, &s.entries[i]);
        }

        // positional arguments
        if (s.has_slot or s.rest_index != null) {
            try w.writeAll("\nArguments:\n");
            for (s.entries) |*e| if (e.kind == .slot or e.kind == .rest) try help_entry(w, e);
        }

        // options
        try w.writeAll("\nOptions:\n");
        for (s.entries) |*e| if (e.long != null and e.kind != .slot) try help_entry(w, e);
        if (s.builtin_help() and s.find_by_name("help") == null) {
            try w.print("  {s:<28}  Print this help\n", .{
                if (s.find_by_short('h') == null) "-h, --help" else "    --help"
            });
        }

        // global options
        if (s.root_schema) |r| {
            try w.writeAll("\nGlobal options:\n");
            for (r.entries) |*e| if (e.long != null and e.kind != .slot) try help_entry(w, e);
        }
        try w.writeByte('\n');
    }
};
fn report(info: ?*Info, error_type: ParseError, d_info: struct {
    error_at: ?Diagnostic.ErrorAt = null,
    missing_value: bool = false,
    value: ?[]const u8 = null,

    entry: ?*const Schema.Entry = null,
    ctx: ?*const Schema = null,
    suggestion: []const u8 = "",
}) ParseError {
    if (info) |I| {
        I.diagnostic.error_type    = error_type;
        I.diagnostic.error_at      = if (d_info.error_at) |e| .{ e[0] + I.diagnostic.offset, e[1], e[2] } else null;
        I.diagnostic.missing_value = d_info.missing_value;
        I.diagnostic.value         = d_info.value;

        I.diagnostic.entry         = d_info.entry;
        I.diagnostic.ctx           = d_info.ctx;
        I.diagnostic.suggestion    = d_info.suggestion;
    }
    return error_type;
}

fn set_entry(
    entry: *const Schema.Entry,
    allocator: std.mem.Allocator,
    args: *anyopaque,
    argv: []const []const u8,
    arg_index: *usize,
    negated: bool,
    inline_value: ?[]const u8,
    value_at: ?struct {
        usize, //start
        usize //end
    },
    seen_count: []usize,
    info: ?*Info,
) ParseError!void {
    if (entry.is_help) return report(
        info,
        ParseError.HelpRequested,
        .{ .entry = entry },
    );

    var value = inline_value;
    // negated flag check
    if (entry.kind == .flag) {
        if (inline_value != null) return report(info, ParseError.FlagTakesNoValue, .{
            .error_at = .{ arg_index.*, if (value_at) |v| v[0] else 0, if (value_at) |v| v[1] else argv[arg_index.*].len },
            .entry = entry,
            .value = inline_value,
        });
        value = if (negated) "false" else null;
    }

    const needs_value = entry.takes_value and !entry.value_optional;
    if (value == null and needs_value) {
        if (arg_index.* + 1 >= argv.len) return report(
            info,
            ParseError.MissingValue,
            .{
                .error_at = .{ arg_index.*, 0, argv[arg_index.*].len },
                .entry = entry,
                .missing_value = true,
            }
        );
        arg_index.* += 1;
        value = argv[arg_index.*];
    }
    const count = seen_count[entry.field_index];
    if (entry.assign) |f| {
        f(
            args,
            value
        ) catch |err| return report(
            info,
            err,
            .{
                .error_at = .{
                    arg_index.*,
                    if (value_at) |v| v[0] else 0,
                    if (value_at) |v| v[1] else argv[arg_index.*].len
                },
                .entry = entry,
                .value = value,
            }
        );
    } else if (entry.append) |f| {
        f(
            args,
            allocator,
            argv.len,
            count,
            value.?
        ) catch |err| return report(
            info,
            err,
            .{
                .error_at = .{
                    arg_index.*,
                    if (value_at) |v| v[0] else 0,
                    if (value_at) |v| v[1] else argv[arg_index.*].len
                },
                .entry = entry,
                .value = value,
            }
        );
    } else unreachable;
    seen_count[entry.field_index] = count + 1;
}
fn parse_level(
    schema: *const Schema,
    allocator: std.mem.Allocator,
    args: *anyopaque,
    argv: []const []const u8,
    info: ?*Info,
    root: ?*const Level,
) ParseError!void {
    if (info) |I| I.schema = schema;

    for (schema.entries) |e| if (e.set_default) |set| set(args);

    const seen_count = try allocator.alloc(usize, schema.entries.len);
    defer allocator.free(seen_count);
    @memset(seen_count, 0);

    const here: Level = .{ .schema = schema, .args = args, .seen_count = seen_count };
    const levels = [_]?*const Level {&here, root};

    var next_slot: usize = 0;
    var after_barrier = false;

    var i: usize = 0;
    var start: usize = 0;
    var end: usize = 0;
    args_loop: while (i < argv.len) : (i += 1) {
        const arg = argv[i];
        end = arg.len;

        if (!after_barrier) {
            if (std.mem.eql(u8, arg, "--")) {
                after_barrier = true;
                continue;
            }

            // --name, --name=value, --name value
            if (std.mem.startsWith(u8, arg, "--")) {
                start = 2;
                const eql_sign = std.mem.findScalar(u8, arg, '=');
                end = eql_sign orelse arg.len;
                const name = arg[2..end];
                const level: *const Level, const entry: *const Schema.Entry, const negated: bool = for (levels) |l| {
                    const L = l orelse continue;
                    if (L.schema.find_by_name(name)) |e| break .{L, e, false};
                    if (L.schema.find_negated(name)) |e| break .{L, e, true};
                } else if (schema.builtin_help() and std.mem.eql(u8, arg, "--help")) {
                    return report(info, ParseError.HelpRequested, .{ .ctx = schema });
                } else return report(info, ParseError.UnknownOption, .{ .error_at = .{ i, start, end }, .ctx = schema });
                const inline_value: ?[]const u8 = if (eql_sign) |e| arg[e + 1 ..] else null;
                try set_entry(
                    entry,
                    allocator,
                    level.args,
                    argv, &i,
                    negated,
                    inline_value, if (eql_sign) |e| .{e, arg.len} else null,
                    level.seen_count, info
                );
                continue;
            }

            // -v, -vvv, -p8080, -p=8080, -p 8080, -vp8080
            if (arg.len > 1 and arg[0] == '-') {
                start = 1;
                var j: usize = start;
                while (j < arg.len) : (j += 1) {
                    const level: *const Level, const entry: *const Schema.Entry = for (levels) |l| {
                        const L = l orelse continue;
                        if (L.schema.find_by_short(arg[j])) |e| break .{ L, e };
                    } else if (schema.builtin_help() and arg[j] == 'h') {
                        return report(info, ParseError.HelpRequested, .{ .ctx = schema });
                    } else return report(info, ParseError.UnknownOption, .{ .error_at = .{ i, j, j + 1 }, .ctx = schema });
                    const tail = arg[j + 1..];
                    const needs_value = entry.takes_value and !entry.value_optional;
                    if (tail.len > 0 and tail[0] == '=') {
                        const inline_value = tail[1..];
                        try set_entry(
                            entry,
                            allocator,
                            level.args,
                            argv, &i,
                            false,
                            inline_value, .{ j + 1, arg.len },
                            level.seen_count, info
                        );
                        continue :args_loop;
                    }
                    if (needs_value and tail.len > 0) {
                        try set_entry(
                            entry,
                            allocator,
                            level.args,
                            argv, &i,
                            false,
                            tail, .{ j + 1, arg.len },
                            level.seen_count, info
                        );
                        continue :args_loop;
                    }
                    try set_entry(
                        entry,
                        allocator,
                        level.args,
                        argv, &i,
                        false,
                        null, null,
                        level.seen_count, info
                    );
                    if (needs_value) continue :args_loop; // took the next arg inside set_entry
                }
                continue;
            }

            // command: everything after it belongs to the command's schema
            if (schema.find_command(arg)) |entry| {
                if (info) |I| {
                    I.diagnostic.offset += i + 1;
                }
                try entry.parse_command.?(args, allocator, argv[i + 1 ..], info, root orelse &here);
                seen_count[entry.field_index] += 1;
                break;
            }
        }

        // positional: free slot, then rest regardless if after barrier or not
        if (schema.slot_at(next_slot)) |entry| {
            try set_entry(
                entry,
                allocator,
                args,
                argv, &i,
                false,
                arg, .{ 0, arg.len },
                seen_count, info
            );
            next_slot += 1;
        } else if (schema.rest_index) |rest_index| {
            try set_entry(
                &schema.entries[rest_index],
                allocator,
                args,
                argv, &i,
                false,
                arg, .{ 0, arg.len },
                seen_count, info
            );
        } else {
            return report(
                info,
                ParseError.UnexpectedPositional,
                .{
                    .error_at = .{ i, 0, arg.len },
                    .ctx = schema,
                    .value = arg,
                }
            );
        }
    }

    for (schema.entries) |*e| {
        if (e.required and seen_count[e.field_index] == 0) {
            return report(
                info,
                ParseError.MissingRequired,
                .{
                    .error_at = null,
                    .ctx = schema,
                    .entry = e,
                }
            );
        }
    }
}
pub fn parse(comptime Args: type,
             arena: std.mem.Allocator,
             process_args: std.process.Args,
             info: ?*Info,
) ParseError!Args {
    const schema = comptime get_schema(Args, null, null, "");
    const argv = try process_args.toSlice(arena);
    const program_name = if (argv.len > 0) std.fs.path.basename(argv[0]) else "";
    const user_args = if (argv.len > 1) argv[1..] else &.{};
    if (info) |I| {
        I.program_name = program_name;
        I.diagnostic = .{ .args = user_args, .offset = 0 };
        I.schema = schema;
    }
    var args: Args = undefined;
    try parse_level(schema, arena, &args, user_args, info, null);
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

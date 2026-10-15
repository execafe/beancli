# beancli

beancli is a CLI argument parser for Zig where the struct declaration is the whole CLI.

Single file, no dependencies, zig 0.16+. 

## Quick start
```
zig fetch --save git+https://github.com/execafe/beancli
```

```zig
// build.zig
const beancli = b.dependency("beancli", .{});
exe.root_module.addImport("beancli", beancli.module("beancli"));
```

Or just copy `beancli.zig` into your project.

## Example

Take a look at `example.zig` and run `zig run example.zig -- -H`

## Fields

The type of the field decides what kind of argument it is.

| field                          | meta                  | kind                              | usage                                   |
|--------------------------------|-----------------------|-----------------------------------|-----------------------------------------|
| `bool`                         |                       | .flag                             | `--flag`, `--no-flag`                   |
| int, float, enum, `[]const u8` |                       | .value                            | `--x 1`, `--x=1`, `-x1`, `-x=1`, `-x 1` |
| int                            | `.mode = .count`      | .counter                          | `-vvv`, `--verbose=3`                   |
| `[]const T`                    | `.mode = .repeat`     | .repeated                         | `-I src -I lib`                         |
| any scalar                     | `.mode = .positional` | .slot                             | `app a.txt` or `app --input a.txt`      |
| `[]const []const u8`           |                       | .rest                             | leftover args, everything after `--`    |
| `?struct`                      |                       | .command                          | subcommand                              |
| `bool`                         | `.mode = .help`       | technically a .flag (but special) | your own help flag                      |

No default = required, except bools which default to `false`, counters to `0`, rest to empty, commands to `null`.
Required slots have to come before optional ones.

## Meta

```zig
pub const meta = .{
    .field_name = .{
        .short = 'f',          // -f
        .doc   = "...",        // shows up in help
        .mode  = .positional,  // .default, .count, .repeat, .positional, .help
    },
};
```

`pub const name` and `pub const doc` on the struct set the program/command name and description.

## Syntax 

- `--flag=value` and `--flag value`
- short clusters: `-fvp8080`
- `--` stops option parsing
- `--dry-run` and `--dry_run` are the same thing, same for enum values
- root flags can go before or after a subcommand

## Errors

`print_error` points at the arg that broke:

For example: 
```
[beancli] error: invalid value `abc` for `--port`
    app --port abc
               ^^^ expected a `u16`
```

Most mistakes in the struct itself get caught at compile time: duplicate shorts, `--x` clashing with `--no-x`, rest + subcommands, positionals + subcommands, non-exhaustive enums, etc.

## Help

`print_help` prints usage, commands, arguments, options, and defaults.
`-h` / `--help` are built in and assigned a flag if available (i.e. `-h` or `--help` is unused). 

## Features
- [x] Struct-defined CLI
- [x] Boolean switches
- [x] Long flags (`--flag`)
- [x] Short flags (`-f`)
- [x] String values
- [x] Int and Float fields
- [x] Enum fields
- [x] Positional
- [x] Rest field
- [x] Commands
- [x] Subcommands
- [x] `--flag=value` syntax
- [x] `--` barrier
- [x] Counted flags `-fff`
- [x] Short flag clusters `-fvp8080`
- [x] Repeated options `--file 1` `--file 2`
- [x] Error diagnostics
- [x] Richer diagnostics / better error messages
- [x] `--no-flag` syntax
- [x] Root flags in subcommands `program subcommand --root-flag` == `program --root-flag subcommand`
- [x] Help text
- [ ] Did-you-mean suggestions
- [ ] Environment variables
- [ ] Shell completions

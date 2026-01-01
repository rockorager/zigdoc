# zigdoc

A command-line tool to view documentation for Zig standard library symbols.

## Installation

```bash
zig build install -Doptimize=ReleaseFast --prefix $HOME/.local
```

## Usage

```
Usage: zigdoc [options] <symbol>

Show documentation for Zig standard library symbols and imported modules.

zigdoc can access any module imported in your build.zig file, making it easy
to view documentation for third-party dependencies alongside the standard library.

Examples:
  zigdoc std.ArrayList
  zigdoc std.mem.Allocator
  zigdoc std.http.Server
  zigdoc vaxis.Window
  zigdoc zeit.timezone.Posix

Options:
  -h, --help        Show this help message
  --dump-imports    Dump module imports from build.zig as JSON

Commands:
  @init             Initialize a new Zig project with AGENTS.md
```

## Project Initialization

`zigdoc @init` scaffolds a minimal Zig project with an `AGENTS.md` file containing up-to-date API patterns and coding conventions for AI assistants.

```bash
mkdir my-project && cd my-project
zigdoc @init
```

## Examples

```bash
# Standard library symbols
zigdoc std.ArrayList
zigdoc std.mem.Allocator
zigdoc std.http.Server

# Imported modules from build.zig
zigdoc zeit.timezone.Posix
```

## Features

- View documentation for any public symbol in the Zig standard library
- Access documentation for imported modules from your build.zig
- Shows symbol location, category, and signature
- Displays doc comments and members
- Follows aliases to implementation

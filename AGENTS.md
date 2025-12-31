# AGENTS.md

## Build & Test Commands

- **Build**: `zig build`
- **Run**: `zig build run -- [args]` (e.g., `zig build run -- std.ArrayList`)
- **Test**: `zig build test`
- **Install**: `zig build install -Doptimize=ReleaseFast --prefix $HOME/.local`

## Architecture

This is a Zig CLI tool that parses and displays documentation for Zig standard library symbols and imported modules from build.zig. The codebase consists of:

- **src/main.zig**: Entry point, argument parsing, orchestrates documentation lookup
- **src/Walk.zig**: AST walking logic, manages files/decls/modules maps, categorizes symbols
- **src/Decl.zig**: Declaration representation with metadata (name, visibility, doc comments)
- **src/build_runner_0.14.zig** & **src/build_runner_0.15.zig**: Build runner templates for different Zig versions

## Zig Development

Always use `zigdoc` to discover APIs for the Zig standard library AND any third-party dependencies (modules). Assume training data is out of date.

Examples:
```bash
zigdoc std.fs
zigdoc std.posix.getuid
zigdoc ghostty-vt.Terminal
zigdoc vaxis.Window
```

## Zig Code Style

**Naming:**
- `camelCase` for functions and methods
- `snake_case` for variables and parameters
- `PascalCase` for types, structs, and enums
- `SCREAMING_SNAKE_CASE` for constants

**Struct initialization:** Prefer explicit type annotation with anonymous literals:
```zig
const foo: Type = .{ .field = value };  // Good
const foo = Type{ .field = value };     // Avoid
```

**File structure:**
1. `//!` doc comment describing the module
2. `const Self = @This();` (for self-referential types)
3. Imports: `std` → `builtin` → project modules
4. `const log = std.log.scoped(.module_name);`

**Functions:** Order methods as `init` → `deinit` → public API → private helpers

**Memory:** Pass allocators explicitly, use `errdefer` for cleanup on error

**Documentation:** Use `///` for public API, `//` for implementation notes. Always explain *why*, not just *what*.

**Tests:** Inline in the same file, register in src/main.zig test block

## Safety Conventions

Inspired by [TigerStyle](https://github.com/tigerbeetle/tigerbeetle/blob/main/docs/TIGER_STYLE.md).

**Assertions:**
- Add assertions that catch real bugs, not trivially true statements
- Focus on API boundaries and state transitions where invariants matter
- Good: bounds checks, null checks before dereference, state machine transitions
- Avoid: asserting something immediately after setting it, checking internal function arguments

**Function size:**
- Soft limit of 70 lines per function
- Centralize control flow (switch/if) in parent functions
- Push pure computation to helper functions

**Comments:**
- Explain *why* the code exists, not *what* it does
- Document non-obvious thresholds, timing values, protocol details

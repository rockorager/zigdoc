const std = @import("std");
const builtin = @import("builtin");
const Walk = @import("Walk.zig");
const log = std.log.scoped(.zigdoc);

const build_runner_0_14 = @embedFile("build_runner_0.14.zig");
const build_runner_0_15 = @embedFile("build_runner_0.15.zig");
const build_runner_0_16 = @embedFile("build_runner_0.16.zig");

pub fn main() !void {
    var debug_allocator: std.heap.DebugAllocator(.{}) = .init;
    const gpa, const is_debug = gpa: {
        break :gpa switch (builtin.mode) {
            .Debug, .ReleaseSafe => .{ debug_allocator.allocator(), true },
            .ReleaseFast, .ReleaseSmall => .{ std.heap.smp_allocator, false },
        };
    };
    defer if (is_debug) {
        _ = debug_allocator.deinit();
    };

    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();

    var args = try std.process.argsWithAllocator(arena.allocator());
    defer args.deinit();
    _ = args.skip(); // skip program name

    const symbol = args.next();

    if (symbol == null) {
        try printUsage();
        return;
    }

    if (std.mem.eql(u8, symbol.?, "--help") or std.mem.eql(u8, symbol.?, "-h")) {
        try printUsage();
        return;
    }

    if (std.mem.eql(u8, symbol.?, "--dump-imports")) {
        try dumpImports(&arena);
        return;
    }

    Walk.init(arena.allocator());
    Walk.Decl.init(arena.allocator());

    const std_dir_path = try getStdDir(&arena);

    // Only parse std library if the symbol starts with "std"
    if (std.mem.startsWith(u8, symbol.?, "std")) {
        try walkStdLib(&arena, std_dir_path);

        // Register std/std.zig as the "std" module for @import("std")
        const std_file_index = Walk.files.getIndex("std/std.zig") orelse return error.StdNotFound;
        try Walk.modules.put(arena.allocator(), "std", @enumFromInt(std_file_index));
    } else {
        // For non-std symbols, process build.zig to get imported modules
        try processBuildZig(&arena);
    }

    try printDocs(arena.allocator(), symbol.?, std_dir_path);
}

fn printUsage() !void {
    var stdout_buf: [1024]u8 = undefined;
    var stdout_writer = std.fs.File.stdout().writer(&stdout_buf);
    try stdout_writer.interface.writeAll(
        \\Usage: zigdoc [options] <symbol>
        \\
        \\Show documentation for Zig standard library symbols and imported modules.
        \\
        \\zigdoc can access any module imported in your build.zig file, making it easy
        \\to view documentation for third-party dependencies alongside the standard library.
        \\
        \\Examples:
        \\  zigdoc std.ArrayList
        \\  zigdoc std.mem.Allocator
        \\  zigdoc std.http.Server
        \\  zigdoc vaxis.Window
        \\  zigdoc zeit.timezone.Posix
        \\
        \\Options:
        \\  -h, --help        Show this help message
        \\  --dump-imports    Dump module imports from build.zig as JSON
        \\
    );
    try stdout_writer.interface.flush();
}

fn dumpImports(arena: *std.heap.ArenaAllocator) !void {
    // Check if build.zig exists
    std.fs.cwd().access("build.zig", .{}) catch {
        std.debug.print("No build.zig found in current directory\n", .{});
        return error.NoBuildZig;
    };

    // Setup the build runner
    try setupBuildRunner(arena);

    // Run zig build with our custom runner
    const result = try std.process.Child.run(.{
        .allocator = arena.allocator(),
        .argv = &[_][]const u8{
            "zig",
            "build",
            "--build-runner",
            ".zig-cache/zigdoc_build_runner.zig",
        },
    });

    if (result.term.Exited != 0) {
        std.debug.print("Error running build runner:\n{s}\n", .{result.stderr});
        return error.BuildRunnerFailed;
    }

    // Print the JSON output directly
    var stdout_buf: [4096]u8 = undefined;
    var stdout_writer = std.fs.File.stdout().writer(&stdout_buf);
    try stdout_writer.interface.writeAll(result.stdout);
    try stdout_writer.interface.flush();
}

const ZigEnv = struct {
    std_dir: []const u8,
};

fn getZigVersion(arena: *std.heap.ArenaAllocator) !std.SemanticVersion {
    const version_result = try std.process.Child.run(.{
        .allocator = arena.allocator(),
        .argv = &[_][]const u8{ "zig", "version" },
    });

    if (version_result.term.Exited != 0) {
        return error.ZigVersionFailed;
    }

    const version_str = std.mem.trim(u8, version_result.stdout, &std.ascii.whitespace);
    return try std.SemanticVersion.parse(version_str);
}

fn setupBuildRunner(arena: *std.heap.ArenaAllocator) !void {
    const version = try getZigVersion(arena);

    const runner_src = switch (version.minor) {
        14 => build_runner_0_14,
        15 => build_runner_0_15,
        16 => build_runner_0_16,
        else => return error.UnsupportedZigVersion,
    };

    std.fs.cwd().makeDir(".zig-cache") catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };

    const runner_path = ".zig-cache/zigdoc_build_runner.zig";
    try std.fs.cwd().writeFile(.{
        .sub_path = runner_path,
        .data = runner_src,
    });
}

fn processBuildZig(arena: *std.heap.ArenaAllocator) !void {
    // Check if build.zig exists
    std.fs.cwd().access("build.zig", .{}) catch {
        // No build.zig, nothing to do
        return;
    };

    // Setup the build runner
    try setupBuildRunner(arena);

    // Run zig build with our custom runner
    const result = try std.process.Child.run(.{
        .allocator = arena.allocator(),
        .argv = &[_][]const u8{
            "zig",
            "build",
            "--build-runner",
            ".zig-cache/zigdoc_build_runner.zig",
        },
    });

    if (result.term.Exited != 0) {
        log.err("Failed to analyze build.zig", .{});
        return;
    }

    // Parse the output to extract module information
    try parseBuildOutput(arena.allocator(), result.stdout);
}

fn parseBuildOutput(allocator: std.mem.Allocator, output: []const u8) !void {
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, output, .{});
    defer parsed.deinit();

    const root_obj = parsed.value.object;
    const modules_obj = root_obj.get("modules") orelse return;

    var modules_iter = modules_obj.object.iterator();
    while (modules_iter.next()) |entry| {
        const module_name = entry.key_ptr.*;
        const module_data = entry.value_ptr.*.object;

        const root_path = module_data.get("root").?.string;

        // Skip non-Zig files (fonts, images, etc.)
        if (!std.mem.endsWith(u8, root_path, ".zig")) continue;

        // Read and add the module file
        const file_content = std.fs.cwd().readFileAlloc(
            root_path,
            allocator,
            std.Io.Limit.limited(10 * 1024 * 1024),
        ) catch |err| {
            std.debug.print("Failed to read module {s}: {}\n", .{ module_name, err });
            continue;
        };

        const file_index = try Walk.add_file(root_path, file_content);
        try Walk.modules.put(allocator, module_name, file_index);

        // Handle imports if present
        if (module_data.get("imports")) |imports_obj| {
            var imports_iter = imports_obj.object.iterator();
            while (imports_iter.next()) |import_entry| {
                const import_name = import_entry.key_ptr.*;
                const import_path = import_entry.value_ptr.*.string;

                // Skip non-Zig files (fonts, images, etc.)
                if (!std.mem.endsWith(u8, import_path, ".zig")) continue;

                // Read and add the imported file
                const import_content = std.fs.cwd().readFileAlloc(
                    import_path,
                    allocator,
                    std.Io.Limit.limited(10 * 1024 * 1024),
                ) catch |err| {
                    std.debug.print("Failed to read import {s}: {}\n", .{ import_name, err });
                    continue;
                };

                const import_file_index = try Walk.add_file(import_path, import_content);
                try Walk.modules.put(allocator, import_name, import_file_index);
            }
        }
    }
}

fn getStdDir(arena: *std.heap.ArenaAllocator) ![]const u8 {
    const version = try getZigVersion(arena);

    const is_pre_0_15 = version.order(.{ .major = 0, .minor = 15, .patch = 0 }) == .lt;

    const result = try std.process.Child.run(.{
        .allocator = arena.allocator(),
        .argv = &[_][]const u8{ "zig", "env" },
    });

    if (result.term.Exited != 0) {
        return error.ZigEnvFailed;
    }

    const stdout = try arena.allocator().dupeZ(u8, result.stdout);

    if (is_pre_0_15) {
        const parsed = try std.json.parseFromSlice(
            ZigEnv,
            arena.allocator(),
            stdout,
            .{ .ignore_unknown_fields = true },
        );
        return parsed.value.std_dir;
    } else {
        const parsed = try std.zon.parse.fromSliceAlloc(
            ZigEnv,
            arena.allocator(),
            stdout,
            null,
            .{ .ignore_unknown_fields = true },
        );
        return parsed.std_dir;
    }
}

fn walkStdLib(arena: *std.heap.ArenaAllocator, std_dir_path: []const u8) !void {
    const allocator = arena.allocator();
    var dir = try std.fs.openDirAbsolute(std_dir_path, .{ .iterate = true });
    defer dir.close();

    var walker = try dir.walk(allocator);
    defer walker.deinit();

    while (try walker.next()) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.basename, ".zig")) continue;
        if (std.mem.endsWith(u8, entry.basename, "test.zig")) continue;

        const file_content = try entry.dir.readFileAllocOptions(
            entry.basename,
            allocator,
            std.Io.Limit.limited(10 * 1024 * 1024),
            @enumFromInt(0),
            0,
        );

        // Normalize path separators to forward slashes for consistent handling
        const normalized_path = try allocator.dupe(u8, entry.path);
        for (normalized_path) |*ch| {
            if (ch.* == '\\') ch.* = '/';
        }
        const file_name = try std.fmt.allocPrint(allocator, "std/{s}", .{normalized_path});
        allocator.free(normalized_path);

        _ = try Walk.add_file(file_name, file_content);
    }
}

fn resolveHierarchical(allocator: std.mem.Allocator, symbol: []const u8) !?*Walk.Decl {
    var parts = std.mem.splitScalar(u8, symbol, '.');
    const first_part = parts.next() orelse return null;

    // Find the root declaration
    var current_decl: ?*Walk.Decl = null;
    for (Walk.decls.items) |*decl| {
        const info = decl.extra_info();
        if (!info.is_pub) continue;

        var fqn_buf: std.ArrayListUnmanaged(u8) = .empty;
        defer fqn_buf.deinit(allocator);
        try decl.fqn(&fqn_buf);

        if (std.mem.eql(u8, fqn_buf.items, first_part)) {
            current_decl = decl;
            break;
        }
    }

    if (current_decl == null) return null;

    // Walk through the remaining parts
    while (parts.next()) |part| {
        // Follow aliases with circular reference protection
        var search_decl = current_decl.?;
        var category = search_decl.categorize();
        var hop_count: usize = 0;
        while (category == .alias) {
            hop_count += 1;
            if (hop_count >= 64) {
                log.err("Circular alias detected resolving '{s}'", .{symbol});
                return error.CircularAlias;
            }
            search_decl = category.alias.get();
            category = search_decl.categorize();
        }

        // Find child with matching name
        var found = false;
        for (Walk.decls.items) |*candidate| {
            if (candidate.parent != .none and candidate.parent.get() == search_decl) {
                const member_info = candidate.extra_info();
                if (!member_info.is_pub) continue;
                if (std.mem.eql(u8, member_info.name, part)) {
                    current_decl = candidate;
                    found = true;
                    break;
                }
            }
        }

        if (!found) return null;
    }

    return current_decl;
}

fn printDeclInfo(allocator: std.mem.Allocator, stdout: anytype, decl: *Walk.Decl, symbol: []const u8, std_dir_path: []const u8) !void {
    const file_path = decl.file.path();
    const ast = decl.file.get_ast();
    const info = decl.extra_info();

    // Print header
    try stdout.print("Symbol: {s}\n", .{symbol});
    const full_path = try getFullPath(allocator, std_dir_path, file_path);
    defer allocator.free(full_path);

    // Get line number
    const token_starts = ast.tokens.items(.start);
    const main_token = ast.nodeMainToken(decl.ast_node);
    const byte_offset = token_starts[main_token];
    const loc = std.zig.findLineColumn(ast.source, byte_offset);

    try stdout.print("Location: {s}:{d}\n", .{ full_path, loc.line + 1 });

    // Follow aliases to the actual implementation
    var target_decl = decl;
    var category = decl.categorize();
    while (category == .alias) {
        const aliasee_index = category.alias;
        target_decl = aliasee_index.get();
        category = target_decl.categorize();

        var aliasee_fqn: std.ArrayListUnmanaged(u8) = .empty;
        defer aliasee_fqn.deinit(allocator);
        try target_decl.fqn(&aliasee_fqn);

        const aliasee_path = target_decl.file.path();
        const aliasee_full_path = try getFullPath(allocator, std_dir_path, aliasee_path);
        defer allocator.free(aliasee_full_path);

        // Get line number for alias target
        const target_ast = target_decl.file.get_ast();
        const target_token_starts = target_ast.tokens.items(.start);
        const target_main_token = target_ast.nodeMainToken(target_decl.ast_node);
        const target_byte_offset = target_token_starts[target_main_token];
        const target_loc = std.zig.findLineColumn(target_ast.source, target_byte_offset);

        try stdout.print("Alias Target: {s}\n", .{aliasee_fqn.items});
        try stdout.print("Target Location: {s}:{d}\n", .{ aliasee_full_path, target_loc.line + 1 });
    }

    // Print category and signature
    try stdout.print("Category: {s}\n", .{@tagName(category)});
    const target_ast = target_decl.file.get_ast();
    const target_node = target_decl.ast_node;
    try printSignature(stdout, target_ast, target_decl, category);

    // Print documentation
    // For file roots, always try to show container doc comments from the target
    const target_info = target_decl.extra_info();
    const has_docs = if (target_ast.nodeTag(target_node) == .root)
        target_info.first_doc_comment.unwrap() != null
    else
        info.first_doc_comment.unwrap() != null or target_info.first_doc_comment.unwrap() != null;

    if (has_docs) {
        try stdout.writeAll("\nDocumentation:\n");
        if (target_ast.nodeTag(target_node) == .root) {
            if (target_info.first_doc_comment.unwrap()) |target_first_doc| {
                try printContainerDocComments(stdout, target_ast, target_first_doc);
            }
        } else {
            // For non-root nodes, prefer original docs, fallback to target
            if (info.first_doc_comment.unwrap()) |first_doc_comment| {
                try printDocComments(stdout, ast, first_doc_comment);
            } else if (target_info.first_doc_comment.unwrap()) |target_first_doc| {
                try printDocComments(stdout, target_ast, target_first_doc);
            }
        }
    }

    // Print members for namespaces, containers, and type functions
    const has_members = try printMembers(allocator, stdout, target_decl, category);

    // For type functions without members, show source code instead
    if (category == .type_function and !has_members) {
        try stdout.writeAll("\nSource:\n");
        try printSource(stdout, target_ast, target_node);
    }
}

fn printDocs(allocator: std.mem.Allocator, symbol: []const u8, std_dir_path: []const u8) !void {
    var stdout_buf: [4096]u8 = undefined;
    var stdout_writer = std.fs.File.stdout().writer(&stdout_buf);
    const stdout = &stdout_writer.interface;

    // Try hierarchical resolution first (e.g., "zeit.timezone.Posix")
    if (std.mem.indexOf(u8, symbol, ".")) |_| {
        if (try resolveHierarchical(allocator, symbol)) |decl| {
            try printDeclInfo(allocator, stdout, decl, symbol, std_dir_path);
            try stdout.flush();
            return;
        }
    }

    // Search for matching declarations by FQN
    var found = false;
    for (Walk.decls.items) |*decl| {
        const file_path = decl.file.path();
        if (file_path.len == 0) continue;

        const ast = decl.file.get_ast();
        if (ast.source.len == 0) continue;

        const info = decl.extra_info();
        if (!info.is_pub) continue;

        var fqn_buf: std.ArrayListUnmanaged(u8) = .empty;
        defer fqn_buf.deinit(allocator);
        try decl.fqn(&fqn_buf);

        if (std.mem.eql(u8, fqn_buf.items, symbol)) {
            found = true;
            try printDeclInfo(allocator, stdout, decl, symbol, std_dir_path);
            break;
        }
    }

    if (!found) {
        try stdout.writeAll("Symbol not found: ");
        try stdout.print("'{s}'\n\n", .{symbol});

        // Provide helpful suggestions
        var parts = std.mem.splitScalar(u8, symbol, '.');
        const first_part = parts.next() orelse {
            try stdout.writeAll("Tip: Specify a symbol like 'std.ArrayList' or 'moduleName.Symbol'\n");
            try stdout.flush();
            std.process.exit(1);
        };

        // Check if the module exists
        const module_exists = blk: {
            for (Walk.decls.items) |*decl| {
                var fqn_buf: std.ArrayListUnmanaged(u8) = .empty;
                defer fqn_buf.deinit(allocator);
                try decl.fqn(&fqn_buf);
                if (std.mem.eql(u8, fqn_buf.items, first_part)) break :blk true;
            }
            break :blk false;
        };

        if (!module_exists) {
            try stdout.print("Module '{s}' not found.\n", .{first_part});
            if (Walk.modules.count() > 0) {
                try stdout.writeAll("\nAvailable modules:\n");
                var iter = Walk.modules.iterator();
                while (iter.next()) |entry| {
                    try stdout.print("  {s}\n", .{entry.key_ptr.*});
                }
            }
        } else {
            try stdout.print("Module '{s}' found, but could not find symbol '{s}'.\n", .{ first_part, symbol });
            try stdout.writeAll("Possible reasons:\n");
            try stdout.writeAll("  - The symbol is private (not marked with 'pub')\n");
            try stdout.writeAll("  - The symbol name is misspelled\n");
            try stdout.writeAll("  - The symbol is nested deeper than specified\n");
        }

        try stdout.flush();
        std.process.exit(1);
    }

    try stdout.flush();
}

fn printMembers(allocator: std.mem.Allocator, writer: anytype, decl: *const Walk.Decl, category: Walk.Category) !bool {
    switch (category) {
        .type_function, .namespace, .container => {
            var functions: std.ArrayListUnmanaged([]const u8) = .empty;
            defer functions.deinit(allocator);
            var type_functions: std.ArrayListUnmanaged([]const u8) = .empty;
            defer type_functions.deinit(allocator);
            var constants: std.ArrayListUnmanaged([]const u8) = .empty;
            defer constants.deinit(allocator);
            var types: std.ArrayListUnmanaged([]const u8) = .empty;
            defer types.deinit(allocator);
            const FieldInfo = struct {
                name: []const u8,
                type_str: []const u8,
                doc_comment: ?std.zig.Ast.TokenIndex,
            };
            var fields: std.ArrayListUnmanaged(FieldInfo) = .empty;
            defer fields.deinit(allocator);

            const ast = decl.file.get_ast();

            if (category == .container) {
                const node = category.container;
                var buffer: [2]std.zig.Ast.Node.Index = undefined;
                if (ast.fullContainerDecl(&buffer, node)) |container_decl| {
                    for (container_decl.ast.members) |member| {
                        if (ast.fullContainerField(member)) |field| {
                            const name_token = field.ast.main_token;
                            if (ast.tokenTag(name_token) == .identifier) {
                                const field_name = ast.tokenSlice(name_token);

                                const type_str = if (field.ast.type_expr.unwrap()) |type_expr| blk: {
                                    const start_token = ast.firstToken(type_expr);
                                    const end_token = ast.lastToken(type_expr);
                                    const token_starts = ast.tokens.items(.start);
                                    const start_offset = token_starts[start_token];
                                    const end_offset = if (end_token + 1 < ast.tokens.len)
                                        token_starts[end_token + 1]
                                    else
                                        ast.source.len;
                                    break :blk std.mem.trim(u8, ast.source[start_offset..end_offset], &std.ascii.whitespace);
                                } else "";

                                const first_doc = Walk.Decl.findFirstDocComment(ast, field.firstToken());

                                try fields.append(allocator, .{
                                    .name = field_name,
                                    .type_str = type_str,
                                    .doc_comment = first_doc.unwrap(),
                                });
                            }
                        }
                    }
                }
            }

            // Collect public members
            // Note: We iterate by index because calling categorize() can trigger file loading
            // which appends to Walk.decls.items, invalidating slice references
            var i: usize = 0;
            // Find the index of the target decl to avoid pointer comparison issues
            // (pointers can become invalid when Walk.decls.items is reallocated)
            const target_decl_idx: usize = blk: {
                for (Walk.decls.items, 0..) |*d, idx| {
                    if (d == decl) break :blk idx;
                }
                @panic("decl not found in Walk.decls.items");
            };

            var checked: usize = 0;
            var matched_parent: usize = 0;
            while (i < Walk.decls.items.len) : (i += 1) {
                const candidate = &Walk.decls.items[i];
                checked += 1;
                // Validate parent index before using it
                if (candidate.parent != .none) {
                    const pidx = @intFromEnum(candidate.parent);
                    if (pidx >= Walk.decls.items.len) {
                        continue; // Skip invalid parent
                    }
                    // Compare parent index instead of pointer to avoid stale pointer issues
                    if (pidx != target_decl_idx) {
                        continue;
                    }
                    matched_parent += 1;
                } else {
                    continue; // No parent
                }

                const member_info = candidate.extra_info();
                if (!member_info.is_pub) continue;
                if (member_info.name.len == 0) continue;

                const member_cat = candidate.categorize();
                switch (member_cat) {
                    .function => try functions.append(allocator, member_info.name),
                    .type_function => try type_functions.append(allocator, member_info.name),
                    .namespace, .container => try types.append(allocator, member_info.name),
                    .alias => |alias_index| {
                        // Follow alias chain to get the final category
                        // Guard against invalid alias indices
                        const idx = @intFromEnum(alias_index);
                        if (alias_index == .none or idx >= Walk.decls.items.len) {
                            // Invalid alias, treat as constant
                            try constants.append(allocator, member_info.name);
                            continue;
                        }

                        var resolved_index = alias_index;
                        var hops: usize = 0;
                        var resolved_cat = resolved_index.get().categorize();
                        while (resolved_cat == .alias and hops < 64) : (hops += 1) {
                            const next_index = resolved_cat.alias;
                            const next_idx = @intFromEnum(next_index);
                            if (next_index == .none or next_idx >= Walk.decls.items.len) break;
                            resolved_index = next_index;
                            resolved_cat = resolved_index.get().categorize();
                        }
                        switch (resolved_cat) {
                            .namespace, .container => try types.append(allocator, member_info.name),
                            .function => try functions.append(allocator, member_info.name),
                            .type_function => try type_functions.append(allocator, member_info.name),
                            else => try constants.append(allocator, member_info.name),
                        }
                    },
                    .global_const => try constants.append(allocator, member_info.name),
                    else => {},
                }
            }

            var has_members = false;

            if (fields.items.len > 0) {
                try writer.writeAll("\nFields:\n");
                var prev_had_doc = false;
                for (fields.items) |field| {
                    if (prev_had_doc) try writer.writeAll("\n");
                    if (field.type_str.len > 0) {
                        try writer.print("  {s}: {s}\n", .{ field.name, field.type_str });
                    } else {
                        try writer.print("  {s}\n", .{field.name});
                    }
                    if (field.doc_comment) |first_doc| {
                        var token_idx = first_doc;
                        var has_any_docs = false;
                        while (ast.tokenTag(token_idx) == .doc_comment) : (token_idx += 1) {
                            const comment = ast.tokenSlice(token_idx);
                            try writer.print("      {s}\n", .{comment[3..]});
                            has_any_docs = true;
                        }
                        prev_had_doc = has_any_docs;
                    } else {
                        prev_had_doc = false;
                    }
                }
                has_members = true;
            }

            if (type_functions.items.len > 0) {
                try writer.writeAll("\nType Functions:\n");
                for (type_functions.items) |name| {
                    try writer.print("  {s}\n", .{name});
                }
                has_members = true;
            }

            if (types.items.len > 0) {
                try writer.writeAll("\nTypes:\n");
                for (types.items) |name| {
                    try writer.print("  {s}\n", .{name});
                }
                has_members = true;
            }

            if (functions.items.len > 0) {
                try writer.writeAll("\nFunctions:\n");
                for (functions.items) |name| {
                    try writer.print("  {s}\n", .{name});
                }
                has_members = true;
            }

            if (constants.items.len > 0) {
                try writer.writeAll("\nConstants:\n");
                for (constants.items) |name| {
                    try writer.print("  {s}\n", .{name});
                }
                has_members = true;
            }

            if (has_members) {
                try writer.writeAll("\n");
            }

            return has_members;
        },
        else => return false,
    }
}

fn getFullPath(allocator: std.mem.Allocator, std_dir_path: []const u8, file_path: []const u8) ![]const u8 {
    // If already an absolute path, return as-is
    if (std.fs.path.isAbsolute(file_path)) {
        return allocator.dupe(u8, file_path);
    }

    // For "std/..." paths, prepend std_dir_path
    if (std.mem.startsWith(u8, file_path, "std/")) {
        const relative_path = file_path[4..]; // Remove "std/" prefix
        return std.fmt.allocPrint(allocator, "{s}/{s}", .{ std_dir_path, relative_path });
    }

    // Fallback for any other path
    return std.fmt.allocPrint(allocator, "{s}/{s}", .{ std_dir_path, file_path });
}

fn printSignature(writer: anytype, ast: *const std.zig.Ast, _: *const Walk.Decl, category: Walk.Category) !void {
    switch (category) {
        .function, .type_function => |node| {
            var buf: [1]std.zig.Ast.Node.Index = undefined;
            const fn_proto = ast.fullFnProto(&buf, node) orelse return;

            const start_token = fn_proto.firstToken();
            // For function declarations, stop at the body (don't include '{' and beyond)
            // Find the end of the function prototype
            var end_token = start_token;
            var paren_depth: i32 = 0;
            var found_return_type = false;
            var token_idx = start_token;

            while (token_idx < ast.tokens.len) : (token_idx += 1) {
                const tag = ast.tokenTag(token_idx);

                if (tag == .l_paren) paren_depth += 1;
                if (tag == .r_paren) paren_depth -= 1;

                // Once we've closed all parens, we're past the parameter list
                if (paren_depth == 0 and found_return_type) {
                    end_token = token_idx;
                    break;
                }

                // Track when we've seen the return type (after closing parens)
                if (paren_depth == 0 and tag == .r_paren) {
                    found_return_type = true;
                }

                end_token = token_idx;

                // Stop before function body
                if (tag == .l_brace) {
                    end_token = token_idx - 1;
                    break;
                }
            }

            try writer.writeAll("Signature: ");
            token_idx = start_token;
            var prev_tag: std.zig.Token.Tag = .invalid;
            while (token_idx <= end_token) : (token_idx += 1) {
                const tag = ast.tokenTag(token_idx);
                if (tag == .doc_comment) continue;

                const token_slice = ast.tokenSlice(token_idx);

                // Skip trailing comma before closing paren
                if (tag == .comma) {
                    const next_token = token_idx + 1;
                    if (next_token <= end_token and ast.tokenTag(next_token) == .r_paren) {
                        continue;
                    }
                }

                // Add spacing rules for better readability
                if (token_idx > start_token) {
                    const needs_space = switch (prev_tag) {
                        .comma => true,
                        .colon => true, // Space after colon
                        .keyword_pub, .keyword_fn, .keyword_const, .keyword_var, .keyword_comptime => true,
                        .asterisk, .l_bracket, .question_mark, .period => false, // No space after *, [, ?, .
                        .r_bracket => tag != .identifier and tag != .keyword_const and tag != .keyword_var, // Space after ] except before type name
                        else => switch (tag) {
                            .l_paren, .r_paren, .r_bracket, .comma, .semicolon => false,
                            .colon, .period => false, // No space before : or .
                            .l_bracket, .asterisk => false, // No space before [ or *
                            else => prev_tag != .l_paren,
                        },
                    };
                    if (needs_space) try writer.writeAll(" ");
                }

                try writer.writeAll(token_slice);
                prev_tag = tag;
            }
            try writer.writeAll("\n");
        },
        .global_const, .global_variable => |node| {
            const var_decl = ast.fullVarDecl(node) orelse return;
            const start_token = var_decl.firstToken();
            const end_token = ast.lastToken(node);

            try writer.writeAll("Declaration: ");
            var token_idx = start_token;
            var prev_tag: std.zig.Token.Tag = .invalid;
            while (token_idx <= end_token) : (token_idx += 1) {
                const tag = ast.tokenTag(token_idx);
                if (tag == .doc_comment) continue;

                const token_slice = ast.tokenSlice(token_idx);

                // Add spacing rules
                if (token_idx > start_token) {
                    const needs_space = switch (prev_tag) {
                        .colon, .equal => true,
                        .keyword_pub, .keyword_const, .keyword_var, .keyword_comptime => true,
                        else => switch (tag) {
                            .colon, .equal, .semicolon => false,
                            else => true,
                        },
                    };
                    if (needs_space) try writer.writeAll(" ");
                }

                try writer.writeAll(token_slice);
                prev_tag = tag;
            }
            try writer.writeAll("\n");
        },
        .container => |node| {
            if (ast.nodeTag(node) == .root) {
                try writer.writeAll("Type: struct (file root)\n");
            } else {
                const main_token = ast.nodeMainToken(node);
                const container_kind = ast.tokenSlice(main_token);
                try writer.print("Type: {s}\n", .{container_kind});
            }
        },
        .namespace => |node| {
            if (ast.nodeTag(node) == .root) {
                try writer.writeAll("Type: namespace (file root)\n");
            } else {
                try writer.writeAll("Type: namespace (struct)\n");
            }
        },
        else => {},
    }
}

fn printDocComments(writer: anytype, ast: *const std.zig.Ast, first_token: std.zig.Ast.TokenIndex) !void {
    var token_index = first_token;
    while (ast.tokenTag(token_index) == .doc_comment) : (token_index += 1) {
        const comment = ast.tokenSlice(token_index);
        try writer.print(" {s}\n", .{comment[3..]});
    }
}

fn printContainerDocComments(writer: anytype, ast: *const std.zig.Ast, first_token: std.zig.Ast.TokenIndex) !void {
    var token_index = first_token;
    while (ast.tokenTag(token_index) == .container_doc_comment) : (token_index += 1) {
        const comment = ast.tokenSlice(token_index);
        try writer.print(" {s}\n", .{comment[3..]});
    }
}

fn printSource(writer: anytype, ast: *const std.zig.Ast, node: std.zig.Ast.Node.Index) !void {
    const token_starts = ast.tokens.items(.start);
    const start_token = ast.firstToken(node);
    const end_token = ast.lastToken(node);

    const start_offset = token_starts[start_token];
    const end_offset = if (end_token + 1 < ast.tokens.len)
        token_starts[end_token + 1]
    else
        ast.source.len;

    const source_text = ast.source[start_offset..end_offset];

    // Print each line with indentation
    var lines = std.mem.splitScalar(u8, source_text, '\n');
    while (lines.next()) |line| {
        try writer.print("  {s}\n", .{line});
    }
}

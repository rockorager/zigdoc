const std = @import("std");
const builtin = @import("builtin");

pub const root = @import("@build");
pub const dependencies = @import("@dependencies");

pub const std_options: std.Options = .{
    .side_channels_mitigations = .none,
};

pub fn main() !void {
    var gpa_instance = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa_instance.deinit();
    const gpa = gpa_instance.allocator();

    var single_threaded_arena = std.heap.ArenaAllocator.init(gpa);
    defer single_threaded_arena.deinit();

    var thread_safe_arena: std.heap.ThreadSafeAllocator = .{
        .child_allocator = single_threaded_arena.allocator(),
    };
    const arena = thread_safe_arena.allocator();

    const args = try std.process.argsAlloc(arena);

    // skip my own exe name
    var arg_idx: usize = 1;

    const zig_exe = args[arg_idx];
    arg_idx += 1;
    const zig_lib_dir = args[arg_idx];
    arg_idx += 1;
    const build_root = args[arg_idx];
    arg_idx += 1;
    const cache_root = args[arg_idx];
    arg_idx += 1;
    const global_cache_root = args[arg_idx];
    arg_idx += 1;

    const zig_lib_directory: std.Build.Cache.Directory = .{
        .path = zig_lib_dir,
        .handle = try std.fs.cwd().openDir(zig_lib_dir, .{}),
    };

    const build_root_directory: std.Build.Cache.Directory = .{
        .path = build_root,
        .handle = try std.fs.cwd().openDir(build_root, .{}),
    };

    const local_cache_directory: std.Build.Cache.Directory = .{
        .path = cache_root,
        .handle = try std.fs.cwd().makeOpenPath(cache_root, .{}),
    };

    const global_cache_directory: std.Build.Cache.Directory = .{
        .path = global_cache_root,
        .handle = try std.fs.cwd().makeOpenPath(global_cache_root, .{}),
    };

    // Version-specific Graph initialization
    const has_time_report = @hasField(std.Build.Graph, "time_report");

    var graph: std.Build.Graph = if (has_time_report) .{
        .arena = arena,
        .cache = .{
            .gpa = arena,
            .manifest_dir = try local_cache_directory.handle.makeOpenPath("h", .{}),
        },
        .zig_exe = zig_exe,
        .env_map = try std.process.getEnvMap(arena),
        .global_cache_root = global_cache_directory,
        .zig_lib_directory = zig_lib_directory,
        .host = .{
            .query = .{},
            .result = try std.zig.system.resolveTargetQuery(.{}),
        },
        .time_report = false,
    } else .{
        .arena = arena,
        .cache = .{
            .gpa = arena,
            .manifest_dir = try local_cache_directory.handle.makeOpenPath("h", .{}),
        },
        .zig_exe = zig_exe,
        .env_map = try std.process.getEnvMap(arena),
        .global_cache_root = global_cache_directory,
        .zig_lib_directory = zig_lib_directory,
        .host = .{
            .query = .{},
            .result = try std.zig.system.resolveTargetQuery(.{}),
        },
    };

    graph.cache.addPrefix(.{ .path = null, .handle = std.fs.cwd() });
    graph.cache.addPrefix(build_root_directory);
    graph.cache.addPrefix(local_cache_directory);
    graph.cache.addPrefix(global_cache_directory);
    graph.cache.hash.addBytes(builtin.zig_version_string);

    const builder = try std.Build.create(
        &graph,
        build_root_directory,
        local_cache_directory,
        dependencies.root_deps,
    );

    // Initialize install_path - required before calling build()
    builder.resolveInstallPrefix(null, .{});

    // Call the user's build() function
    try builder.runBuild(root);

    // NOW WE HAVE THE BUILD GRAPH!
    // Instead of executing it, let's dump information about it

    // Use a separate allocator for our module collection to avoid interfering with build graph
    var module_gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = module_gpa.deinit();
    const our_allocator = module_gpa.allocator();

    // Buffer output to avoid version-specific writer APIs
    var stdout_buf = std.array_list.Aligned(u8, null){};
    const stdout = stdout_buf.writer(arena);

    // Collect all modules - from builder.modules and compile steps
    var all_modules = std.StringHashMap(*std.Build.Module).init(our_allocator);

    // Add global modules
    var global_iter = builder.modules.iterator();
    while (global_iter.next()) |entry| {
        try all_modules.put(entry.key_ptr.*, entry.value_ptr.*);
    }

    // Walk compile steps to find their root modules and imports
    var visited_steps = std.AutoHashMap(*std.Build.Step, void).init(our_allocator);
    var step_iter = builder.top_level_steps.iterator();
    while (step_iter.next()) |entry| {
        const tls = entry.value_ptr.*;
        try collectStepModules(&all_modules, &tls.step, &visited_steps);
    }

    // Output in JSON format
    try stdout.writeAll("{\n");
    try stdout.writeAll("  \"modules\": {\n");

    var module_iter = all_modules.iterator();
    var first_module = true;
    while (module_iter.next()) |mod_entry| {
        const import_name = mod_entry.key_ptr.*;
        const module = mod_entry.value_ptr.*;
        const root_source = if (module.root_source_file) |rsf| blk: {
            // Skip generated files - they don't have a real path yet
            if (rsf == .generated) break :blk null;
            break :blk rsf.getPath2(builder, null);
        } else null;

        if (root_source) |root_path| {
            if (!first_module) try stdout.writeAll(",\n");
            first_module = false;

            try stdout.print("    \"{s}\": {{\n", .{import_name});
            try stdout.print("      \"root\": \"{s}\"", .{root_path});

            if (module.import_table.count() > 0) {
                try stdout.writeAll(",\n      \"imports\": {\n");
                var dep_iter = module.import_table.iterator();
                var first_dep = true;
                while (dep_iter.next()) |dep| {
                    const dep_name = dep.key_ptr.*;
                    const dep_module = dep.value_ptr.*;
                    const dep_root = if (dep_module.root_source_file) |rsf| blk: {
                        if (rsf == .generated) break :blk null;
                        break :blk rsf.getPath2(builder, null);
                    } else null;
                    if (dep_root) |droot| {
                        if (!first_dep) try stdout.writeAll(",\n");
                        first_dep = false;
                        try stdout.print("        \"{s}\": \"{s}\"", .{ dep_name, droot });
                    }
                }
                try stdout.writeAll("\n      }\n");
            } else {
                try stdout.writeAll("\n");
            }

            try stdout.writeAll("    }");
        }
    }

    try stdout.writeAll("\n  }\n");
    try stdout.writeAll("}\n");

    // Write buffered output to stdout (version-compatible)
    if (@hasDecl(std.io, "getStdOut")) {
        try std.io.getStdOut().writer().writeAll(stdout_buf.items);
    } else {
        var buf: [8192]u8 = undefined;
        var writer = std.fs.File.stdout().writer(&buf);
        try writer.interface.writeAll(stdout_buf.items);
        try writer.interface.flush();
    }
}

fn collectStepModules(
    modules: *std.StringHashMap(*std.Build.Module),
    step: *std.Build.Step,
    visited: *std.AutoHashMap(*std.Build.Step, void),
) !void {
    // Avoid infinite recursion on circular dependencies
    if (visited.contains(step)) return;
    try visited.put(step, {});

    // Check if this is a compile step
    if (step.cast(std.Build.Step.Compile)) |compile_step| {
        // Add imports from this compile step's root module
        var iter = compile_step.root_module.import_table.iterator();
        while (iter.next()) |entry| {
            const import_name = entry.key_ptr.*;
            const module = entry.value_ptr.*;
            try modules.put(import_name, module);
        }
    }

    // Recursively check dependencies
    for (step.dependencies.items) |dep_step| {
        try collectStepModules(modules, dep_step, visited);
    }
}

const std = @import("std");
const builtin = @import("builtin");

pub const root = @import("@build");
pub const dependencies = @import("@dependencies");

pub const std_options: std.Options = .{
    .side_channels_mitigations = .none,
};

pub fn main() !void {
    const allocator = std.heap.page_allocator;

    var single_threaded_arena = std.heap.ArenaAllocator.init(allocator);
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
    const our_allocator = std.heap.page_allocator;

    // Buffer output to avoid version-specific writer APIs
    var stdout_buf: std.ArrayList(u8) = .empty;
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

    // Materialize generated root source files by executing the steps that
    // produce them. A step that fails (or whose dependency fails) leaves
    // its root invisible rather than failing the dump.
    var make_results = std.AutoHashMap(*std.Build.Step, bool).init(our_allocator);
    var materialize_iter = all_modules.iterator();
    while (materialize_iter.next()) |mod_entry| {
        materializeGeneratedRoots(arena, mod_entry.value_ptr.*, &make_results);
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
            // Generated roots are invisible unless their generating step ran
            if (rsf == .generated and rsf.generated.file.path == null) break :blk null;
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
                        if (rsf == .generated and rsf.generated.file.path == null) break :blk null;
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

fn materializeGeneratedRoots(
    gpa: std.mem.Allocator,
    module: *std.Build.Module,
    results: *std.AutoHashMap(*std.Build.Step, bool),
) void {
    if (module.root_source_file) |rsf| {
        if (rsf == .generated) _ = makeStepGraph(gpa, rsf.generated.file.step, results);
    }
    var dep_iter = module.import_table.iterator();
    while (dep_iter.next()) |dep| {
        const dep_module = dep.value_ptr.*;
        if (dep_module.root_source_file) |rsf| {
            if (rsf == .generated) _ = makeStepGraph(gpa, rsf.generated.file.step, results);
        }
    }
}

/// Recursively makes `step` and its dependencies so generated files have
/// real paths when the dump queries them. Results are memoized in `results`;
/// a failed dependency prevents making the step. Returns whether the step is
/// safe to query after this call.
fn makeStepGraph(
    gpa: std.mem.Allocator,
    step: *std.Build.Step,
    results: *std.AutoHashMap(*std.Build.Step, bool),
) bool {
    if (results.get(step)) |made| return made;
    const made = for (step.dependencies.items) |dep| {
        if (!makeStepGraph(gpa, dep, results)) break false;
    } else blk: {
        // No step make() reads thread_pool in this Zig version; the field is
        // mandatory in MakeOptions but unused.
        step.make(.{
            .progress_node = .none,
            .thread_pool = undefined,
            .watch = false,
            .web_server = null,
            .gpa = gpa,
        }) catch break :blk false;
        break :blk true;
    };
    results.put(step, made) catch return false;
    return made;
}

/// If the given `step` is a `std.Build.Step.Compile`, adds any dependencies
/// for that step which are implied by the module graph rooted at
/// `step.cast(std.Build.Step.Compile).?.root_module`. Ported from the real
/// build runner.
fn createModuleDependenciesForStep(step: *std.Build.Step) std.mem.Allocator.Error!void {
    const root_module = if (step.cast(std.Build.Step.Compile)) |cs| root: {
        break :root cs.root_module;
    } else return; // not a compile step so no module dependencies

    // Starting from `root_module`, discover all modules in this graph.
    const modules = root_module.getGraph().modules;

    // For each of those modules, set up the implied step dependencies.
    for (modules) |mod| {
        if (mod.root_source_file) |lp| lp.addStepDependencies(step);
        for (mod.include_dirs.items) |include_dir| switch (include_dir) {
            .path,
            .path_system,
            .path_after,
            .framework_path,
            .framework_path_system,
            .embed_path,
            => |lp| lp.addStepDependencies(step),

            .other_step => |other| {
                other.getEmittedIncludeTree().addStepDependencies(step);
                step.dependOn(&other.step);
            },

            .config_header_step => |other| step.dependOn(&other.step),
        };
        for (mod.lib_paths.items) |lp| lp.addStepDependencies(step);
        for (mod.rpaths.items) |rpath| switch (rpath) {
            .lazy_path => |lp| lp.addStepDependencies(step),
            .special => {},
        };
        for (mod.link_objects.items) |link_object| switch (link_object) {
            .static_path,
            .assembly_file,
            => |lp| lp.addStepDependencies(step),
            .other_step => |other| step.dependOn(&other.step),
            .system_lib => {},
            .c_source_file => |source| source.file.addStepDependencies(step),
            .c_source_files => |source_files| source_files.root.addStepDependencies(step),
            .win32_resource_file => |rc_source| {
                rc_source.file.addStepDependencies(step);
                for (rc_source.include_paths) |lp| lp.addStepDependencies(step);
            },
        };
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

    // The build graph does not record module imports as step dependencies;
    // the real build runner adds these implied dependencies before running.
    // We must do the same so generated module roots build before the steps
    // that use them.
    try createModuleDependenciesForStep(step);

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

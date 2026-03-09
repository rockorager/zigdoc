const std = @import("std");
const Walk = @import("Walk.zig");
const Decl = @import("Decl.zig");
const testing = std.testing;

fn setupTest(allocator: std.mem.Allocator) !void {
    Walk.files = .empty;
    Walk.decls = .empty;
    Walk.modules = .empty;
    Walk.init(allocator);
    Decl.init(allocator);
}

fn addTestFile(allocator: std.mem.Allocator, name: []const u8, source: []const u8) !Walk.File.Index {
    const owned = try allocator.dupeZ(u8, source);
    return Walk.addFile(name, owned);
}

fn resolveHierarchical(allocator: std.mem.Allocator, symbol: []const u8) !?*Decl {
    var parts = std.mem.splitScalar(u8, symbol, '.');
    const first_part = parts.next() orelse return null;

    var current_decl: ?*Decl = null;
    for (Walk.decls.items) |*decl| {
        const info = decl.extraInfo();
        if (!info.is_pub) continue;

        var fqn_buf: std.ArrayList(u8) = .empty;
        defer fqn_buf.deinit(allocator);
        try decl.fqn(&fqn_buf);

        if (std.mem.eql(u8, fqn_buf.items, first_part)) {
            current_decl = decl;
            break;
        }
    }

    if (current_decl == null) return null;

    while (parts.next()) |part| {
        var search_decl = current_decl.?;
        var category = search_decl.categorize();
        var hop_count: usize = 0;
        while (category == .alias and hop_count < 64) : (hop_count += 1) {
            search_decl = category.alias.get();
            category = search_decl.categorize();
        }
        if (hop_count >= 64) return error.CircularAlias;

        var found = false;
        for (Walk.decls.items) |*candidate| {
            if (candidate.parent != .none and candidate.parent.get() == search_decl) {
                const member_info = candidate.extraInfo();
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

test "simple public member resolution" {
    const allocator = testing.allocator;
    try setupTest(allocator);
    defer {
        for (Walk.files.values()) |*file| file.ast.deinit(allocator);
        Walk.files.deinit(allocator);
        Walk.decls.deinit(allocator);
        Walk.modules.deinit(allocator);
    }

    const source = "pub const A = 1;\n";
    const file_idx = try addTestFile(allocator, "mod.zig", source);
    try Walk.modules.put(allocator, "mod", file_idx);

    const decl = try resolveHierarchical(allocator, "mod.A");
    try testing.expect(decl != null);
    try testing.expectEqualStrings("A", decl.?.extraInfo().name);
}

test "nested struct member resolution" {
    const allocator = testing.allocator;
    try setupTest(allocator);
    defer {
        for (Walk.files.values()) |*file| file.ast.deinit(allocator);
        Walk.files.deinit(allocator);
        Walk.decls.deinit(allocator);
        Walk.modules.deinit(allocator);
    }

    const source =
        \\pub const S = struct {
        \\    pub const Foo = 123;
        \\};
        \\
    ;
    const file_idx = try addTestFile(allocator, "mod.zig", source);
    try Walk.modules.put(allocator, "mod", file_idx);

    const decl = try resolveHierarchical(allocator, "mod.S.Foo");
    try testing.expect(decl != null);
    try testing.expectEqualStrings("Foo", decl.?.extraInfo().name);
}

test "alias chain resolution" {
    const allocator = testing.allocator;
    try setupTest(allocator);
    defer {
        for (Walk.files.values()) |*file| file.ast.deinit(allocator);
        Walk.files.deinit(allocator);
        Walk.decls.deinit(allocator);
        Walk.modules.deinit(allocator);
    }

    const source =
        \\pub const A = struct {
        \\    pub const B = 1;
        \\};
        \\pub const X = A;
        \\
    ;
    const file_idx = try addTestFile(allocator, "mod.zig", source);
    try Walk.modules.put(allocator, "mod", file_idx);

    const decl = try resolveHierarchical(allocator, "mod.X.B");
    try testing.expect(decl != null);
    try testing.expectEqualStrings("B", decl.?.extraInfo().name);
}

test "private member not resolved" {
    const allocator = testing.allocator;
    try setupTest(allocator);
    defer {
        for (Walk.files.values()) |*file| file.ast.deinit(allocator);
        Walk.files.deinit(allocator);
        Walk.decls.deinit(allocator);
        Walk.modules.deinit(allocator);
    }

    const source = "const hidden = 1;\n";
    const file_idx = try addTestFile(allocator, "mod.zig", source);
    try Walk.modules.put(allocator, "mod", file_idx);

    const decl = try resolveHierarchical(allocator, "mod.hidden");
    try testing.expect(decl == null);
}

test "non-existent symbol" {
    const allocator = testing.allocator;
    try setupTest(allocator);
    defer {
        for (Walk.files.values()) |*file| file.ast.deinit(allocator);
        Walk.files.deinit(allocator);
        Walk.decls.deinit(allocator);
        Walk.modules.deinit(allocator);
    }

    const source = "pub const A = 1;\n";
    const file_idx = try addTestFile(allocator, "mod.zig", source);
    try Walk.modules.put(allocator, "mod", file_idx);

    const decl = try resolveHierarchical(allocator, "mod.DoesNotExist");
    try testing.expect(decl == null);
}

test "categorize struct with fields as container" {
    const allocator = testing.allocator;
    try setupTest(allocator);
    defer {
        for (Walk.files.values()) |*file| file.ast.deinit(allocator);
        Walk.files.deinit(allocator);
        Walk.decls.deinit(allocator);
        Walk.modules.deinit(allocator);
    }

    const source =
        \\pub const S = struct {
        \\    x: i32,
        \\};
        \\
    ;
    const file_idx = try addTestFile(allocator, "mod.zig", source);
    try Walk.modules.put(allocator, "mod", file_idx);

    const decl = try resolveHierarchical(allocator, "mod.S");
    try testing.expect(decl != null);
    const category = decl.?.categorize();
    try testing.expect(category == .container);
}

test "categorize struct with only consts as namespace" {
    const allocator = testing.allocator;
    try setupTest(allocator);
    defer {
        for (Walk.files.values()) |*file| file.ast.deinit(allocator);
        Walk.files.deinit(allocator);
        Walk.decls.deinit(allocator);
        Walk.modules.deinit(allocator);
    }

    const source =
        \\pub const S = struct {
        \\    pub const A = 1;
        \\};
        \\
    ;
    const file_idx = try addTestFile(allocator, "mod.zig", source);
    try Walk.modules.put(allocator, "mod", file_idx);

    const decl = try resolveHierarchical(allocator, "mod.S");
    try testing.expect(decl != null);
    const category = decl.?.categorize();
    try testing.expect(category == .namespace);
}

test "type function categorization" {
    const allocator = testing.allocator;
    try setupTest(allocator);
    defer {
        for (Walk.files.values()) |*file| file.ast.deinit(allocator);
        Walk.files.deinit(allocator);
        Walk.decls.deinit(allocator);
        Walk.modules.deinit(allocator);
    }

    const source =
        \\pub fn MyType() type {
        \\    return struct {};
        \\}
        \\
    ;
    const file_idx = try addTestFile(allocator, "mod.zig", source);
    try Walk.modules.put(allocator, "mod", file_idx);

    const decl = try resolveHierarchical(allocator, "mod.MyType");
    try testing.expect(decl != null);
    const category = decl.?.categorize();
    try testing.expect(category == .type_function);
}

test "regular function categorization" {
    const allocator = testing.allocator;
    try setupTest(allocator);
    defer {
        for (Walk.files.values()) |*file| file.ast.deinit(allocator);
        Walk.files.deinit(allocator);
        Walk.decls.deinit(allocator);
        Walk.modules.deinit(allocator);
    }

    const source =
        \\pub fn myFunc() i32 {
        \\    return 1;
        \\}
        \\
    ;
    const file_idx = try addTestFile(allocator, "mod.zig", source);
    try Walk.modules.put(allocator, "mod", file_idx);

    const decl = try resolveHierarchical(allocator, "mod.myFunc");
    try testing.expect(decl != null);
    const category = decl.?.categorize();
    try testing.expect(category == .function);
}

test "deep alias chain within limit" {
    const allocator = testing.allocator;
    try setupTest(allocator);
    defer {
        for (Walk.files.values()) |*file| file.ast.deinit(allocator);
        Walk.files.deinit(allocator);
        Walk.decls.deinit(allocator);
        Walk.modules.deinit(allocator);
    }

    const source =
        \\pub const A = struct { pub const X = 1; };
        \\pub const B = A;
        \\pub const C = B;
        \\pub const D = C;
        \\pub const E = D;
        \\
    ;
    const file_idx = try addTestFile(allocator, "mod.zig", source);
    try Walk.modules.put(allocator, "mod", file_idx);

    const decl = try resolveHierarchical(allocator, "mod.E.X");
    try testing.expect(decl != null);
    try testing.expectEqualStrings("X", decl.?.extraInfo().name);
}

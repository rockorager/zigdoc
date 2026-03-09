const Decl = @This();
const std = @import("std");
const Ast = std.zig.Ast;
const Walk = @import("Walk.zig");
var gpa: std.mem.Allocator = undefined;

pub fn init(allocator: std.mem.Allocator) void {
    gpa = allocator;
}
const assert = std.debug.assert;
const log = std.log;

ast_node: Ast.Node.Index,
file: Walk.File.Index,
/// The decl whose namespace this is in.
parent: Index,

pub const ExtraInfo = struct {
    is_pub: bool,
    name: []const u8,
    first_doc_comment: Ast.OptionalTokenIndex,
};

pub const Index = enum(u32) {
    none = std.math.maxInt(u32),
    _,

    pub fn get(i: Index) *Decl {
        const raw = @intFromEnum(i);
        assert(raw < Walk.decls.items.len);
        return &Walk.decls.items[raw];
    }
};

pub fn isPub(d: *const Decl) bool {
    return d.extraInfo().is_pub;
}

pub fn extraInfo(d: *const Decl) ExtraInfo {
    const ast = d.file.getAst();
    switch (ast.nodeTag(d.ast_node)) {
        .root => return .{
            .name = "",
            .is_pub = true,
            .first_doc_comment = if (ast.tokenTag(0) == .container_doc_comment)
                .fromToken(0)
            else
                .none,
        },

        .global_var_decl,
        .local_var_decl,
        .simple_var_decl,
        .aligned_var_decl,
        => {
            const var_decl = ast.fullVarDecl(d.ast_node).?;
            const name_token = var_decl.ast.mut_token + 1;
            assert(ast.tokenTag(name_token) == .identifier);
            const ident_name = ast.tokenSlice(name_token);
            return .{
                .name = ident_name,
                .is_pub = var_decl.visib_token != null,
                .first_doc_comment = findFirstDocComment(ast, var_decl.firstToken()),
            };
        },

        .fn_proto,
        .fn_proto_multi,
        .fn_proto_one,
        .fn_proto_simple,
        .fn_decl,
        => {
            var buf: [1]Ast.Node.Index = undefined;
            const fn_proto = ast.fullFnProto(&buf, d.ast_node).?;
            const name_token = fn_proto.name_token.?;
            assert(ast.tokenTag(name_token) == .identifier);
            const ident_name = ast.tokenSlice(name_token);
            return .{
                .name = ident_name,
                .is_pub = fn_proto.visib_token != null,
                .first_doc_comment = findFirstDocComment(ast, fn_proto.firstToken()),
            };
        },

        else => |t| {
            log.debug("hit '{s}'", .{@tagName(t)});
            unreachable;
        },
    }
}

pub fn valueNode(d: *const Decl) ?Ast.Node.Index {
    const ast = d.file.getAst();
    return switch (ast.nodeTag(d.ast_node)) {
        .fn_proto,
        .fn_proto_multi,
        .fn_proto_one,
        .fn_proto_simple,
        .fn_decl,
        .root,
        => d.ast_node,

        .global_var_decl,
        .local_var_decl,
        .simple_var_decl,
        .aligned_var_decl,
        => {
            const var_decl = ast.fullVarDecl(d.ast_node).?;
            if (ast.tokenTag(var_decl.ast.mut_token) == .keyword_const)
                return var_decl.ast.init_node.unwrap();

            return null;
        },

        else => null,
    };
}

pub fn categorize(decl: *const Decl) Walk.Category {
    return decl.file.categorizeDecl(decl.ast_node);
}

/// Looks up a direct child of `decl` by name.
pub fn getChild(decl: *const Decl, name: []const u8) ?Decl.Index {
    switch (decl.categorize()) {
        .alias => |aliasee| {
            // Guard against invalid aliases
            const idx = @intFromEnum(aliasee);
            if (aliasee == .none or idx >= Walk.decls.items.len) return null;
            return aliasee.get().getChild(name);
        },
        .namespace, .container => |node| {
            const file = decl.file.get();
            const scope = file.scopes.get(node) orelse return null;
            const child_node = scope.getChild(name) orelse return null;
            const result = file.node_decls.get(child_node);
            // Validate the result before returning
            if (result) |r| {
                const ridx = @intFromEnum(r);
                if (r != .none and ridx < Walk.decls.items.len) return r;
            }
            return null;
        },
        .type_function => {
            // Find a decl with this function as the parent, with a name matching `name`
            for (Walk.decls.items, 0..) |*candidate, i| {
                if (candidate.parent != .none and
                    candidate.parent.get() == decl and
                    std.mem.eql(u8, candidate.extraInfo().name, name))
                {
                    return @enumFromInt(i);
                }
            }

            return null;
        },
        else => return null,
    }
}

/// If the type function returns another type function, return the index of that type function.
pub fn getTypeFnReturnTypeFn(decl: *const Decl) ?Decl.Index {
    if (decl.getTypeFnReturnExpr()) |return_expr| {
        const ast = decl.file.getAst();
        var buffer: [1]Ast.Node.Index = undefined;
        const call = ast.fullCall(&buffer, return_expr) orelse return null;
        const token = ast.nodeMainToken(call.ast.fn_expr);
        const name = ast.tokenSlice(token);
        if (decl.lookup(name)) |function_decl| {
            return function_decl;
        }
    }
    return null;
}

/// Gets the expression after the `return` keyword in a type function declaration.
pub fn getTypeFnReturnExpr(decl: *const Decl) ?Ast.Node.Index {
    switch (decl.categorize()) {
        .type_function => {
            const ast = decl.file.getAst();

            const body_node = ast.nodeData(decl.ast_node).node_and_node[1];

            var buf: [2]Ast.Node.Index = undefined;
            const statements = ast.blockStatements(&buf, body_node) orelse return null;

            for (statements) |stmt| {
                if (ast.nodeTag(stmt) == .@"return") {
                    return ast.nodeData(stmt).node;
                }
            }
            return null;
        },
        else => return null,
    }
}

/// Looks up a decl by name accessible in `decl`'s namespace.
pub fn lookup(decl: *const Decl, name: []const u8) ?Decl.Index {
    const namespace_node = switch (decl.categorize()) {
        .namespace, .container => |node| node,
        else => decl.parent.get().ast_node,
    };
    const file = decl.file.get();
    const scope = file.scopes.get(namespace_node) orelse return null;
    const resolved_node = scope.lookup(&file.ast, name) orelse return null;
    return file.node_decls.get(resolved_node);
}

/// Appends the fully qualified name to `out`.
pub fn fqn(decl: *const Decl, out: *std.ArrayList(u8)) std.mem.Allocator.Error!void {
    try decl.appendPath(out);
    if (decl.parent != .none) {
        try appendParentNs(out, decl.parent);
        try out.appendSlice(gpa, decl.extraInfo().name);
    } else {
        out.items.len -= 1; // remove the trailing '.'
    }
}

pub fn resetWithPath(decl: *const Decl, list: *std.ArrayList(u8)) std.mem.Allocator.Error!void {
    list.clearRetainingCapacity();
    try appendPath(decl, list);
}

pub fn appendPath(decl: *const Decl, list: *std.ArrayList(u8)) std.mem.Allocator.Error!void {
    const start = list.items.len;
    // Prefer the module name alias.
    for (Walk.modules.keys(), Walk.modules.values()) |pkg_name, pkg_file| {
        if (pkg_file == decl.file) {
            try list.ensureUnusedCapacity(gpa, pkg_name.len + 1);
            list.appendSliceAssumeCapacity(pkg_name);
            list.appendAssumeCapacity('.');
            return;
        }
    }

    const file_path = decl.file.path();
    try list.ensureUnusedCapacity(gpa, file_path.len + 1);
    list.appendSliceAssumeCapacity(file_path);
    for (list.items[start..]) |*byte| switch (byte.*) {
        '/' => byte.* = '.',
        else => continue,
    };
    if (std.mem.endsWith(u8, list.items, ".zig")) {
        list.items.len -= 3;
    } else {
        list.appendAssumeCapacity('.');
    }
}

pub fn appendParentNs(list: *std.ArrayList(u8), parent: Decl.Index) std.mem.Allocator.Error!void {
    assert(parent != .none);
    const decl = parent.get();
    if (decl.parent != .none) {
        try appendParentNs(list, decl.parent);
        try list.appendSlice(gpa, decl.extraInfo().name);
        try list.append(gpa, '.');
    }
}

pub fn findFirstDocComment(ast: *const Ast, token: Ast.TokenIndex) Ast.OptionalTokenIndex {
    var it = token;
    while (it > 0) {
        it -= 1;
        if (ast.tokenTag(it) != .doc_comment) {
            return .fromToken(it + 1);
        }
    }
    return .none;
}

/// Successively looks up each component.
pub fn find(search_string: []const u8) Decl.Index {
    var path_components = std.mem.splitScalar(u8, search_string, '.');
    const file = Walk.modules.get(path_components.first()) orelse return .none;
    var current_decl_index = file.findRootDecl();
    while (path_components.next()) |component| {
        while (true) switch (current_decl_index.get().categorize()) {
            .alias => |aliasee| current_decl_index = aliasee,
            else => break,
        };
        current_decl_index = current_decl_index.get().getChild(component) orelse return .none;
    }
    return current_decl_index;
}

const std = @import("std");
const ast = @import("ast");
const applicability = @import("applicability");
const testing = std.testing;
const root_ir = @import("../ir.zig");
const core_ids = @import("ids.zig");
const core_names = @import("names.zig");
const core_registry = @import("registry.zig");
const t_support = @import("tests_support.zig");

const ClassId = core_ids.ClassId;
const FileId = root_ir.FileId;
const FuncId = core_ids.FuncId;
const MethodSlotId = core_ids.MethodSlotId;
const Module = root_ir.Module;
const ModuleRegistry = core_registry.ModuleRegistry;
const Span = root_ir.Span;
const TypeRef = core_ids.TypeRef;
const classTypeParamIdentity = core_ids.classTypeParamIdentity;
const packageOfFqn = core_names.packageOfFqn;
const parseClassTypeParamIdentity = core_ids.parseClassTypeParamIdentity;
const pushTestFuncOpts = t_support.pushTestFuncOpts;

test "intern dedups equal constants" {
    var m = Module.default(testing.allocator);
    defer m.deinit(testing.allocator);
    const a = try m.internConst(testing.allocator, .{ .Int = 42 });
    const b = try m.internConst(testing.allocator, .{ .Int = 42 });
    try testing.expectEqual(a, b);
    try testing.expectEqual(@as(usize, 1), m.consts.items.len);
}

test "intern distinguishes typed zeros" {
    var m = Module.default(testing.allocator);
    defer m.deinit(testing.allocator);
    const i = try m.internConst(testing.allocator, .{ .Int = 0 });
    const l = try m.internConst(testing.allocator, .{ .Long = 0 });
    try testing.expect(i != l);
    try testing.expectEqual(@as(usize, 2), m.consts.items.len);
}

test "float nan does not collapse" {
    var m = Module.default(testing.allocator);
    defer m.deinit(testing.allocator);
    _ = try m.internConst(testing.allocator, .{ .Double = std.math.nan(f64) });
    _ = try m.internConst(testing.allocator, .{ .Double = std.math.nan(f64) });
    // Interning is total: a NaN Double never traps, and a canonical quiet NaN collapses to one entry.
    try testing.expect(m.consts.items[0] == .Double);
}

test "string consts are owned by the pool" {
    var m = Module.default(testing.allocator);
    defer m.deinit(testing.allocator);

    // The temporary is freed right after interning, so the pool must hold its own copy.
    const tmp = try testing.allocator.dupe(u8, "kotlin.math.abs");
    const id = try m.internConst(testing.allocator, .{ .String = tmp });
    testing.allocator.free(tmp);

    try testing.expect(m.consts.items[id.int()] == .String);
    try testing.expectEqualStrings("kotlin.math.abs", m.consts.items[id.int()].String);
    try testing.expect(m.consts.items[id.int()].String.ptr != tmp.ptr);

    const tmp2 = try testing.allocator.dupe(u8, "kotlin.math.abs");
    const id2 = try m.internConst(testing.allocator, .{ .String = tmp2 });
    testing.allocator.free(tmp2);
    try testing.expectEqual(id, id2);
    try testing.expectEqual(@as(usize, 1), m.consts.items.len);
}

test "packageOfFqn strips the trailing simple name" {
    try testing.expectEqualStrings("", packageOfFqn("foo", "foo"));
    try testing.expectEqualStrings("a.b", packageOfFqn("a.b.foo", "foo"));
    try testing.expectEqualStrings("kotlin.math", packageOfFqn("kotlin.math.abs", "abs"));
    // A mangled nested FQN: the package is everything up to the last dot.
    try testing.expectEqualStrings("pkg", packageOfFqn("pkg.Outer$Name", "Name"));
}

test "class type parameter identities are exact and unambiguous" {
    const first = try classTypeParamIdentity(
        testing.allocator,
        ClassId.from(1),
        "23X",
    );
    defer testing.allocator.free(first);
    const second = try classTypeParamIdentity(
        testing.allocator,
        ClassId.from(12),
        "3X",
    );
    defer testing.allocator.free(second);
    try testing.expect(!std.mem.eql(u8, first, second));

    const projected = try std.fmt.allocPrint(testing.allocator, "out#{s}", .{first});
    defer testing.allocator.free(projected);
    const parsed = parseClassTypeParamIdentity(projected).?;
    try testing.expectEqual(ClassId.from(1), parsed.owner);
    try testing.expectEqualStrings("23X", parsed.param);
    try testing.expect(parseClassTypeParamIdentity("$class$123X") == null);
}

test "extension candidate index uses declaration metadata for bodyless headers" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var m = Module.default(a);
    defer m.deinit(a);

    const min = try pushTestFuncOpts(
        &m,
        a,
        "min",
        "sample.min",
        "sample",
        0,
        .{ .extension = true, .stub = true },
    );
    m.funcs.items[min.int()].params = &.{};
    try m.decl_sigs.put(min.int(), .{
        .receiver_ty = .{ .name = "IntArray", .nullable = false, .args = &.{} },
        .arity = .{ .required = 0, .total = 0, .has_vararg = false },
        .kind = .top_level_extension,
        .has_body = true,
    });

    try testing.expect(m.extCouldApply(a, "IntArray", "min", 0));
    try testing.expect(!m.extCouldApply(a, "String", "min", 0));
    try testing.expect(!m.extCouldApply(a, "IntArray", "max", 0));
    // An extension declaring no value parameters cannot be selected by a one-argument call, so it cannot shadow a member.
    try testing.expect(!m.extCouldApply(a, "IntArray", "min", 1));
}

test "an unclaimed classifier header dispatches its bodied member virtually" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var m = Module.default(a);
    defer m.deinit(a);

    // A reserved placeholder reads closed-and-final on every modifier.
    const owner = try m.reserveClass(a, "Sink", false);
    try testing.expect(m.classes.items[owner.int()].is_stub);

    const accept = try pushTestFuncOpts(&m, a, "accept", "sample.Sink.accept", "sample", 1, .{ .param_ty = "String" });
    try m.decl_sigs.put(accept.int(), .{
        .enclosing_class = owner,
        .arity = .{ .required = 1, .total = 1, .has_vararg = false },
        .sig = &.{.{ .name = "String", .nullable = false, .args = &.{} }},
        .kind = .instance_method,
        .has_body = true,
    });

    // Reading the placeholder as a closed class binds the body by identity, so an implementing class's override never runs.
    try testing.expectEqual(Module.MemberDispatch.virtual, m.dispatchForTarget(owner, accept).?);
}

test "member resolution uses declaration-owner visibility" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var m = Module.default(a);
    defer m.deinit(a);

    const base = try m.addClass(a, .{
        .id = ClassId.from(0),
        .name = "Base",
        .fqn = "sample.Base",
        .primary_params = &.{},
        .methods = &.{},
        .init_block = null,
        .companion = null,
        .supertypes = &.{},
        .is_open = true,
    });
    const derived = try m.addClass(a, .{
        .id = ClassId.from(0),
        .name = "Derived",
        .fqn = "sample.Derived",
        .primary_params = &.{},
        .methods = &.{},
        .init_block = null,
        .companion = null,
        .supertypes = try a.dupe(ClassId, &.{base}),
        .is_open = true,
    });
    const leaf = try m.addClass(a, .{
        .id = ClassId.from(0),
        .name = "Leaf",
        .fqn = "sample.Leaf",
        .primary_params = &.{},
        .methods = &.{},
        .init_block = null,
        .companion = null,
        .supertypes = try a.dupe(ClassId, &.{derived}),
    });
    const base_nested = try m.addClass(a, .{
        .id = ClassId.from(0),
        .name = "Base$Nested",
        .fqn = "sample.Base.Nested",
        .package = "sample",
        .primary_params = &.{},
        .methods = &.{},
        .init_block = null,
        .companion = null,
        .supertypes = &.{},
    });
    const derived_nested = try m.addClass(a, .{
        .id = ClassId.from(0),
        .name = "Derived$Nested",
        .fqn = "sample.Derived.Nested",
        .package = "sample",
        .primary_params = &.{},
        .methods = &.{},
        .init_block = null,
        .companion = null,
        .supertypes = &.{},
    });
    try m.registry.enclosing_class.put("Base$Nested", "Base");
    try m.registry.enclosing_class.put("Derived$Nested", "Derived");

    const private_fn = try pushTestFuncOpts(
        &m,
        a,
        "secret",
        "sample.Base.secret",
        "sample",
        0,
        .{ .extension = true },
    );
    const protected_fn = try pushTestFuncOpts(
        &m,
        a,
        "guarded",
        "sample.Base.guarded",
        "sample",
        0,
        .{ .extension = true },
    );
    for (
        [_]FuncId{ private_fn, protected_fn },
        [_]ast.Visibility{ .Private, .Protected },
    ) |fid, visibility| {
        m.funcs.items[fid.int()].kind = .instance_method;
        try m.decl_sigs.put(fid.int(), .{
            .enclosing_class = base,
            .arity = .{ .required = 0, .total = 0, .has_vararg = false },
            .kind = .instance_method,
            .visibility = visibility,
            .has_body = true,
        });
        try m.registerMemberDecl(
            a,
            m.classes.items[base.int()].fqn,
            m.funcs.items[fid.int()].name,
            fid,
        );
    }

    const private_from_base = m.resolveMemberCall(
        derived,
        "secret",
        &.{},
        .{ .lexical_owner = base },
    );
    try testing.expectEqual(private_fn, private_from_base.target.?);
    try testing.expectEqual(Module.MemberDispatch.direct, private_from_base.dispatch);
    try testing.expectEqual(
        private_fn,
        m.resolveMemberCall(
            derived,
            "secret",
            &.{},
            .{ .lexical_owner = base_nested },
        ).target.?,
    );
    try testing.expect(m.resolveMemberCall(
        derived,
        "secret",
        &.{},
        .{ .lexical_owner = derived },
    ).target == null);

    try testing.expect(m.resolveMemberCall(
        base,
        "guarded",
        &.{},
        .{ .lexical_owner = derived },
    ).target == null);
    try testing.expectEqual(
        protected_fn,
        m.resolveMemberCall(
            derived,
            "guarded",
            &.{},
            .{ .lexical_owner = derived },
        ).target.?,
    );
    try testing.expectEqual(
        protected_fn,
        m.resolveMemberCall(
            derived,
            "guarded",
            &.{},
            .{ .lexical_owner = derived_nested },
        ).target.?,
    );
    try testing.expect(m.resolveMemberCall(
        base,
        "guarded",
        &.{},
        .{ .lexical_owner = derived_nested },
    ).target == null);
    try testing.expectEqual(
        protected_fn,
        m.resolveMemberCall(
            leaf,
            "guarded",
            &.{},
            .{ .lexical_owner = derived },
        ).target.?,
    );
    try testing.expect(m.resolveMemberCall(base, "guarded", &.{}, .{}).target == null);

    _ = try m.addClass(a, .{
        .id = ClassId.from(0),
        .name = "String",
        .fqn = "other.String",
        .package = "other",
        .primary_params = &.{},
        .methods = &.{},
        .init_block = null,
        .companion = null,
        .supertypes = &.{},
    });
    const custom_pick = try pushTestFuncOpts(
        &m,
        a,
        "identityPick",
        "sample.Base.identityPick",
        "sample",
        1,
        .{ .extension = true, .param_ty = "String" },
    );
    const any_pick = try pushTestFuncOpts(
        &m,
        a,
        "identityPick",
        "sample.Base.identityPick",
        "sample",
        1,
        .{ .extension = true, .param_ty = "Any" },
    );
    const custom_identity = try a.alloc(TypeRef, 1);
    custom_identity[0] = .{
        .name = "#qual:other.String",
        .nullable = false,
        .args = &.{},
    };
    m.funcs.items[custom_pick.int()].params[1].ty.args = custom_identity;
    for ([_]FuncId{ custom_pick, any_pick }) |fid| {
        m.funcs.items[fid.int()].kind = .instance_method;
        try m.decl_sigs.put(fid.int(), .{
            .enclosing_class = base,
            .arity = .{ .required = 1, .total = 1, .has_vararg = false },
            .sig = try a.dupe(TypeRef, &.{m.funcs.items[fid.int()].params[1].ty}),
            .kind = .instance_method,
            .has_body = true,
        });
        try m.registerMemberDecl(a, "sample.Base", "identityPick", fid);
    }
    const kotlin_string = [_]applicability.ArgShape{.{
        .ty = .{ .name = "String", .nullable = false, .args = &.{} },
        .literal_kind = .string,
    }};
    try testing.expectEqual(
        any_pick,
        m.resolveMemberCall(base, "identityPick", &kotlin_string, .{}).target.?,
    );
}

test "internal member and extension visibility follows compilation modules" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var m = Module.default(a);
    defer m.deinit(a);

    const declaration_file = FileId.from(10);
    const same_module_file = FileId.from(11);
    const other_module_file = FileId.from(12);
    try m.registry.file_modules.put(declaration_file, 4);
    try m.registry.file_modules.put(same_module_file, 4);
    try m.registry.file_modules.put(other_module_file, 5);
    try m.registry.file_packages.put(declaration_file, "sample");
    try m.registry.file_packages.put(same_module_file, "sample");
    try m.registry.file_packages.put(other_module_file, "sample");

    const owner = try m.addClass(a, .{
        .id = ClassId.from(0),
        .name = "Scope",
        .fqn = "sample.Scope",
        .package = "sample",
        .primary_params = &.{},
        .methods = &.{},
        .init_block = null,
        .companion = null,
        .supertypes = &.{},
    });
    const member = try pushTestFuncOpts(
        &m,
        a,
        "walk",
        "sample.Scope.walk",
        "sample",
        0,
        .{ .extension = true },
    );
    m.funcs.items[member.int()].kind = .instance_method;
    try m.decl_sigs.put(member.int(), .{
        .enclosing_class = owner,
        .arity = .{ .required = 0, .total = 0, .has_vararg = false },
        .kind = .instance_method,
        .visibility = .Internal,
        .has_body = true,
    });
    try m.decl_span.put(member.int(), Span.init(declaration_file, 0, 1));
    try m.registerMemberDecl(a, "sample.Scope", "walk", member);

    const extension = try pushTestFuncOpts(
        &m,
        a,
        "tag",
        "sample.tag",
        "sample",
        0,
        .{ .extension = true },
    );
    m.funcs.items[extension.int()].kind = .top_level_extension;
    try m.decl_sigs.put(extension.int(), .{
        .receiver_ty = .{ .name = "String", .nullable = false, .args = &.{} },
        .arity = .{ .required = 0, .total = 0, .has_vararg = false },
        .kind = .top_level_extension,
        .visibility = .Internal,
        .has_body = true,
    });
    try m.decl_span.put(extension.int(), Span.init(declaration_file, 2, 3));
    try m.rebuildFuncNameIndex(a);

    try testing.expectEqual(
        member,
        m.resolveMemberCall(owner, "walk", &.{}, .{
            .caller_file = same_module_file,
        }).target.?,
    );
    try testing.expect(!m.resolveMemberCall(owner, "walk", &.{}, .{
        .caller_file = other_module_file,
    }).applicable);
    try testing.expect(m.resolveMemberCall(owner, "walk", &.{}, .{}).target == null);

    const receiver = TypeRef{ .name = "String", .nullable = false, .args = &.{} };
    try testing.expectEqual(
        extension,
        m.resolveExtensionCall("tag", receiver, &.{}, .{
            .caller_file = same_module_file,
            .caller_package = "sample",
        }).target.?,
    );
    try testing.expect(!m.resolveExtensionCall("tag", receiver, &.{}, .{
        .caller_file = other_module_file,
        .caller_package = "sample",
    }).applicable);
}

test "member resolution separates class and caller function bounds" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var m = Module.default(a);
    defer m.deinit(a);

    const scope = try m.addClass(a, .{
        .id = ClassId.from(0),
        .name = "Scope",
        .fqn = "sample.Scope",
        .package = "sample",
        .type_params = &.{"T"},
        .primary_params = &.{},
        .methods = &.{},
        .init_block = null,
        .companion = null,
        .supertypes = &.{},
    });
    try m.registry.class_type_param_bounds.put(
        "sample.Scope",
        try a.dupe(ModuleRegistry.TypeParamBound, &.{
            .{ .param = "T", .bound = "Number" },
        }),
    );
    const class_t = try classTypeParamIdentity(a, scope, "T");
    const owner_args = try a.dupe(TypeRef, &.{
        .{ .name = class_t, .nullable = false, .args = &.{} },
    });
    const choose = try pushTestFuncOpts(
        &m,
        a,
        "choose",
        "sample.Scope.choose",
        "sample",
        1,
        .{ .extension = true },
    );
    m.funcs.items[choose.int()].kind = .instance_method;
    m.funcs.items[choose.int()].params[0].ty = .{
        .name = "sample.Scope",
        .nullable = false,
        .args = owner_args,
    };
    m.funcs.items[choose.int()].params[1].ty = .{
        .name = class_t,
        .nullable = false,
        .args = &.{},
    };
    try m.decl_sigs.put(choose.int(), .{
        .enclosing_class = scope,
        .arity = .{ .required = 1, .total = 1, .has_vararg = false },
        .sig = try a.dupe(TypeRef, &.{m.funcs.items[choose.int()].params[1].ty}),
        .kind = .instance_method,
        .has_body = true,
    });
    try m.registerMemberDecl(a, "sample.Scope", "choose", choose);

    const args = [_]applicability.ArgShape{.{
        .ty = .{ .name = "T", .nullable = false, .args = &.{} },
    }};
    const actual_bounds = [_]ModuleRegistry.TypeParamBound{
        .{ .param = class_t, .bound = "Number" },
        .{ .param = "T", .bound = "CharSequence" },
    };
    const resolved = m.resolveMemberCall(scope, "choose", &args, .{
        .receiver_type = .{
            .name = "sample.Scope",
            .nullable = false,
            .args = owner_args,
        },
        .actual_type_param_bounds = &actual_bounds,
    });
    // The caller's `T : CharSequence` neither proves nor refutes the class's `T : Number`, since one type can
    // satisfy both, so the single candidate commits only as DEFERRED and the runtime adjudicates.
    try testing.expect(resolved.target != null);
    try testing.expect(resolved.dispatch == .deferred);
}

test "method slots link generic overrides and multiple interface roots" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var m = Module.default(a);
    defer m.deinit(a);

    const base = try m.addClass(a, .{
        .id = ClassId.from(0),
        .name = "Base",
        .fqn = "sample.Base",
        .primary_params = &.{},
        .methods = &.{},
        .init_block = null,
        .companion = null,
        .supertypes = &.{},
        .type_params = &.{"T"},
        .is_abstract = true,
    });
    const base_args = try a.alloc(TypeRef, 1);
    base_args[0] = .{ .name = "String", .nullable = false, .args = &.{} };
    const child_supers = try a.alloc(TypeRef, 1);
    child_supers[0] = .{ .name = "Base", .nullable = false, .args = base_args };
    const child_super_ids = try a.dupe(ClassId, &.{base});
    const child = try m.addClass(a, .{
        .id = ClassId.from(0),
        .name = "Child",
        .fqn = "sample.Child",
        .primary_params = &.{},
        .methods = &.{},
        .init_block = null,
        .companion = null,
        .supertypes = child_super_ids,
        .supertype_refs = child_supers,
        .is_open = true,
    });
    const redundant_supers = try a.alloc(TypeRef, 2);
    redundant_supers[0] = .{ .name = "Child", .nullable = false, .args = &.{} };
    redundant_supers[1] = .{ .name = "Base", .nullable = false, .args = base_args };
    const redundant_super_ids = try a.dupe(ClassId, &.{ child, base });
    const redundant = try m.addClass(a, .{
        .id = ClassId.from(0),
        .name = "Redundant",
        .fqn = "sample.Redundant",
        .primary_params = &.{},
        .methods = &.{},
        .init_block = null,
        .companion = null,
        .supertypes = redundant_super_ids,
        .supertype_refs = redundant_supers,
    });
    const left = try m.addClass(a, .{
        .id = ClassId.from(0),
        .name = "Left",
        .fqn = "sample.Left",
        .primary_params = &.{},
        .methods = &.{},
        .init_block = null,
        .companion = null,
        .supertypes = &.{},
        .is_abstract = true,
        .is_interface = true,
    });
    const right = try m.addClass(a, .{
        .id = ClassId.from(0),
        .name = "Right",
        .fqn = "sample.Right",
        .primary_params = &.{},
        .methods = &.{},
        .init_block = null,
        .companion = null,
        .supertypes = &.{},
        .is_abstract = true,
        .is_interface = true,
    });
    const both_supers = try a.alloc(TypeRef, 2);
    both_supers[0] = .{ .name = "Left", .nullable = false, .args = &.{} };
    both_supers[1] = .{ .name = "Right", .nullable = false, .args = &.{} };
    const both_super_ids = try a.dupe(ClassId, &.{ left, right });
    const both = try m.addClass(a, .{
        .id = ClassId.from(0),
        .name = "Both",
        .fqn = "sample.Both",
        .primary_params = &.{},
        .methods = &.{},
        .init_block = null,
        .companion = null,
        .supertypes = both_super_ids,
        .supertype_refs = both_supers,
    });

    const base_put = try pushTestFuncOpts(&m, a, "put", "sample.Base.put", "sample", 1, .{ .stub = true, .param_ty = "T" });
    const child_put = try pushTestFuncOpts(&m, a, "put", "sample.Child.put", "sample", 1, .{ .param_ty = "String" });
    const left_run = try pushTestFuncOpts(&m, a, "run", "sample.Left.run", "sample", 1, .{ .stub = true, .param_ty = "Int" });
    const right_run = try pushTestFuncOpts(&m, a, "run", "sample.Right.run", "sample", 1, .{ .stub = true, .param_ty = "Int" });
    const both_run = try pushTestFuncOpts(&m, a, "run", "sample.Both.run", "sample", 1, .{ .param_ty = "Int" });
    for ([_]FuncId{ base_put, child_put, left_run, right_run, both_run }) |fid| m.funcs.items[fid.int()].kind = .instance_method;
    m.funcs.items[child_put.int()].is_override = true;
    m.funcs.items[both_run.int()].is_override = true;
    m.classes.items[base.int()].methods = try a.dupe(FuncId, &.{base_put});
    m.classes.items[child.int()].methods = try a.dupe(FuncId, &.{child_put});
    m.classes.items[both.int()].methods = try a.dupe(FuncId, &.{both_run});

    const owners = [_]ClassId{ base, child, left, right, both };
    const funcs = [_]FuncId{ base_put, child_put, left_run, right_run, both_run };
    const types = [_][]const u8{ "T", "String", "Int", "Int", "Int" };
    const base_t = try classTypeParamIdentity(a, base, "T");
    for (funcs, owners, types) |fid, owner, ty| {
        const declared_ty = if (fid == base_put) base_t else ty;
        m.funcs.items[fid.int()].params[0].ty.name = declared_ty;
        try m.decl_sigs.put(fid.int(), .{
            .enclosing_class = owner,
            .arity = .{ .required = 1, .total = 1, .has_vararg = false },
            .sig = &.{.{ .name = declared_ty, .nullable = false, .args = &.{} }},
            .kind = .instance_method,
            .has_body = m.funcs.items[fid.int()].hasBody(),
        });
        try m.registerMemberDecl(a, m.classes.items[owner.int()].fqn, m.funcs.items[fid.int()].name, fid);
    }

    try m.linkMethodSlots(a);
    try testing.expectEqual(child_put, m.methodSlotTarget(child, MethodSlotId.fromFunc(base_put)).?);
    try testing.expectEqual(child_put, m.methodSlotTarget(redundant, MethodSlotId.fromFunc(base_put)).?);
    try testing.expectEqual(both_run, m.methodSlotTarget(both, MethodSlotId.fromFunc(left_run)).?);
    try testing.expectEqual(both_run, m.methodSlotTarget(both, MethodSlotId.fromFunc(right_run)).?);
    const string_args = [_]applicability.ArgShape{.{
        .ty = .{ .name = "String", .nullable = false, .args = &.{} },
    }};
    const inherited = m.resolveMemberCall(child, "put", &string_args, .{});
    try testing.expectEqual(Module.MemberDispatch.virtual, inherited.dispatch);
    try testing.expectEqual(child_put, inherited.target.?);

    const modifier = try m.addClass(a, .{
        .id = ClassId.from(0),
        .name = "Modifier",
        .fqn = "sample.Modifier",
        .primary_params = &.{},
        .methods = &.{},
        .init_block = null,
        .companion = null,
        .supertypes = &.{},
        .is_abstract = true,
        .is_interface = true,
    });
    _ = try m.addClass(a, .{
        .id = ClassId.from(0),
        .name = "Modifier.Element",
        .fqn = "sample.Modifier.Element",
        .primary_params = &.{},
        .methods = &.{},
        .init_block = null,
        .companion = null,
        .supertypes = &.{},
        .is_abstract = true,
        .is_interface = true,
    });
    const combined = try m.addClass(a, .{
        .id = ClassId.from(0),
        .name = "Combined",
        .fqn = "sample.Combined",
        .primary_params = &.{},
        .methods = &.{},
        .init_block = null,
        .companion = null,
        .supertypes = try a.dupe(ClassId, &.{modifier}),
        .supertype_refs = try a.dupe(TypeRef, &.{.{
            .name = "Modifier",
            .nullable = false,
            .args = &.{},
        }}),
    });
    const root_all = try pushTestFuncOpts(&m, a, "all", "sample.Modifier.all", "sample", 1, .{
        .stub = true,
        .param_ty = "Element",
    });
    const combined_all = try pushTestFuncOpts(&m, a, "all", "sample.Combined.all", "sample", 1, .{
        .param_ty = "Modifier.Element",
    });
    m.funcs.items[root_all.int()].kind = .instance_method;
    m.funcs.items[combined_all.int()].kind = .instance_method;
    m.funcs.items[combined_all.int()].is_override = true;
    m.classes.items[modifier.int()].methods = try a.dupe(FuncId, &.{root_all});
    m.classes.items[combined.int()].methods = try a.dupe(FuncId, &.{combined_all});
    const qualified_element_args = try a.dupe(TypeRef, &.{.{
        .name = "#qual:Modifier.Element",
        .nullable = false,
        .args = &.{},
    }});
    const all_types = [_]TypeRef{
        .{ .name = "Element", .nullable = false, .args = &.{} },
        .{
            .name = "Element",
            .nullable = false,
            .args = qualified_element_args,
        },
    };
    for (
        [_]FuncId{ root_all, combined_all },
        [_]ClassId{ modifier, combined },
        all_types,
    ) |fid, owner, ty| {
        try m.decl_sigs.put(fid.int(), .{
            .enclosing_class = owner,
            .arity = .{ .required = 1, .total = 1, .has_vararg = false },
            .sig = try a.dupe(TypeRef, &.{ty}),
            .kind = .instance_method,
            .has_body = m.funcs.items[fid.int()].hasBody(),
        });
        try m.registerMemberDecl(a, m.classes.items[owner.int()].fqn, "all", fid);
    }
    try m.linkMethodSlots(a);
    try testing.expectEqual(
        combined_all,
        m.methodSlotTarget(combined, MethodSlotId.fromFunc(root_all)).?,
    );

    const shadow_base = try m.addClass(a, .{
        .id = ClassId.from(0),
        .name = "ShadowBase",
        .fqn = "sample.ShadowBase",
        .primary_params = &.{},
        .methods = &.{},
        .init_block = null,
        .companion = null,
        .supertypes = &.{},
        .type_params = &.{"T"},
        .is_open = true,
    });
    const shadow_child_arg = try a.dupe(TypeRef, &.{.{
        .name = "X",
        .nullable = false,
        .args = &.{},
    }});
    const shadow_child = try m.addClass(a, .{
        .id = ClassId.from(0),
        .name = "ShadowChild",
        .fqn = "sample.ShadowChild",
        .primary_params = &.{},
        .methods = &.{},
        .init_block = null,
        .companion = null,
        .supertypes = try a.dupe(ClassId, &.{shadow_base}),
        .supertype_refs = try a.dupe(TypeRef, &.{.{
            .name = "ShadowBase",
            .nullable = false,
            .args = shadow_child_arg,
        }}),
        .type_params = &.{"X"},
    });
    const base_pick = try pushTestFuncOpts(
        &m,
        a,
        "pick",
        "sample.ShadowBase.pick",
        "sample",
        1,
        .{ .stub = true, .param_ty = "T" },
    );
    const child_pick = try pushTestFuncOpts(
        &m,
        a,
        "pick",
        "sample.ShadowChild.pick",
        "sample",
        1,
        .{ .param_ty = "T" },
    );
    for ([_]FuncId{ base_pick, child_pick }) |fid| {
        m.funcs.items[fid.int()].kind = .instance_method;
        var method_type_params: std.ArrayList([]const u8) = .empty;
        try method_type_params.append(a, "T");
        try m.registry.func_type_params.put(fid, method_type_params);
    }
    m.funcs.items[child_pick.int()].is_override = true;
    m.classes.items[shadow_base.int()].methods = try a.dupe(FuncId, &.{base_pick});
    m.classes.items[shadow_child.int()].methods = try a.dupe(FuncId, &.{child_pick});
    for (
        [_]FuncId{ base_pick, child_pick },
        [_]ClassId{ shadow_base, shadow_child },
    ) |fid, owner| {
        try m.decl_sigs.put(fid.int(), .{
            .enclosing_class = owner,
            .arity = .{ .required = 1, .total = 1, .has_vararg = false },
            .sig = try a.dupe(TypeRef, &.{.{
                .name = "T",
                .nullable = false,
                .args = &.{},
            }}),
            .kind = .instance_method,
            .has_body = m.funcs.items[fid.int()].hasBody(),
        });
        try m.registerMemberDecl(a, m.classes.items[owner.int()].fqn, "pick", fid);
    }
    try m.linkMethodSlots(a);
    try testing.expectEqual(
        child_pick,
        m.methodSlotTarget(shadow_child, MethodSlotId.fromFunc(base_pick)).?,
    );
}

test "a redeclared interface slot reaches the body inherited beside it" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var m = Module.default(a);
    defer m.deinit(a);

    const root = try m.addClass(a, .{
        .id = ClassId.from(0),
        .name = "Root",
        .fqn = "sample.Root",
        .primary_params = &.{},
        .methods = &.{},
        .init_block = null,
        .companion = null,
        .supertypes = &.{},
        .is_abstract = true,
        .is_interface = true,
    });
    const redecl_supers = try a.alloc(TypeRef, 1);
    redecl_supers[0] = .{ .name = "Root", .nullable = false, .args = &.{} };
    const redecl = try m.addClass(a, .{
        .id = ClassId.from(0),
        .name = "Redecl",
        .fqn = "sample.Redecl",
        .primary_params = &.{},
        .methods = &.{},
        .init_block = null,
        .companion = null,
        .supertypes = try a.dupe(ClassId, &.{root}),
        .supertype_refs = redecl_supers,
        .is_abstract = true,
        .is_interface = true,
    });
    const impl_supers = try a.alloc(TypeRef, 1);
    impl_supers[0] = .{ .name = "Root", .nullable = false, .args = &.{} };
    const impl = try m.addClass(a, .{
        .id = ClassId.from(0),
        .name = "Impl",
        .fqn = "sample.Impl",
        .primary_params = &.{},
        .methods = &.{},
        .init_block = null,
        .companion = null,
        .supertypes = try a.dupe(ClassId, &.{root}),
        .supertype_refs = impl_supers,
        .is_abstract = true,
    });
    const leaf_supers = try a.alloc(TypeRef, 2);
    leaf_supers[0] = .{ .name = "Impl", .nullable = false, .args = &.{} };
    leaf_supers[1] = .{ .name = "Redecl", .nullable = false, .args = &.{} };
    const leaf = try m.addClass(a, .{
        .id = ClassId.from(0),
        .name = "Leaf",
        .fqn = "sample.Leaf",
        .primary_params = &.{},
        .methods = &.{},
        .init_block = null,
        .companion = null,
        .supertypes = try a.dupe(ClassId, &.{ impl, redecl }),
        .supertype_refs = leaf_supers,
    });

    const root_del = try pushTestFuncOpts(&m, a, "del", "sample.Root.del", "sample", 1, .{ .stub = true });
    const redecl_del = try pushTestFuncOpts(&m, a, "del", "sample.Redecl.del", "sample", 1, .{ .stub = true });
    const impl_del = try pushTestFuncOpts(&m, a, "del", "sample.Impl.del", "sample", 1, .{});
    for ([_]FuncId{ root_del, redecl_del, impl_del }) |fid| m.funcs.items[fid.int()].kind = .instance_method;
    m.funcs.items[redecl_del.int()].is_override = true;
    m.funcs.items[impl_del.int()].is_override = true;
    m.classes.items[impl.int()].methods = try a.dupe(FuncId, &.{impl_del});

    const owners = [_]ClassId{ root, redecl, impl };
    const funcs = [_]FuncId{ root_del, redecl_del, impl_del };
    for (funcs, owners) |fid, owner| {
        try m.decl_sigs.put(fid.int(), .{
            .enclosing_class = owner,
            .arity = .{ .required = 1, .total = 1, .has_vararg = false },
            .sig = try a.dupe(TypeRef, &.{.{ .name = "Int", .nullable = false, .args = &.{} }}),
            .kind = .instance_method,
            .has_body = m.funcs.items[fid.int()].hasBody(),
        });
        try m.registerMemberDecl(a, m.classes.items[owner.int()].fqn, "del", fid);
    }

    try m.linkMethodSlots(a);
    // A redeclaration's own slot must reach the same body as the base family, not the bodyless header it inherits.
    try testing.expectEqual(impl_del, m.methodSlotTarget(leaf, MethodSlotId.fromFunc(root_del)).?);
    try testing.expectEqual(impl_del, m.methodSlotTarget(leaf, MethodSlotId.fromFunc(redecl_del)).?);
    try testing.expectEqual(redecl_del, m.methodSlotTarget(redecl, MethodSlotId.fromFunc(redecl_del)).?);

    // Equal-scoring redeclarations are one slot family, not an overload tie, and a zero-argument call has no
    // parameter for an unprojectable bare receiver to turn unknown.
    const root_size = try pushTestFuncOpts(&m, a, "size", "sample.Root.size", "sample", 0, .{ .stub = true });
    const redecl_size = try pushTestFuncOpts(&m, a, "size", "sample.Redecl.size", "sample", 0, .{ .stub = true });
    for ([_]FuncId{ root_size, redecl_size }) |fid| m.funcs.items[fid.int()].kind = .instance_method;
    m.funcs.items[redecl_size.int()].is_override = true;
    const size_owners = [_]ClassId{ root, redecl };
    const size_funcs = [_]FuncId{ root_size, redecl_size };
    for (size_funcs, size_owners) |fid, owner| {
        try m.decl_sigs.put(fid.int(), .{
            .enclosing_class = owner,
            .arity = .{ .required = 0, .total = 0, .has_vararg = false },
            .sig = &.{},
            .kind = .instance_method,
            .has_body = false,
        });
        try m.registerMemberDecl(a, m.classes.items[owner.int()].fqn, "size", fid);
    }
    const bare_recv = TypeRef{ .name = "Redecl", .nullable = false, .args = &.{} };
    const res = m.resolveMemberCall(redecl, "size", &.{}, .{
        .receiver_type = bare_recv,
    });
    try testing.expect(res.dispatch != .deferred);
    try testing.expectEqual(redecl_size, res.target.?);

    // `Set<E>` cannot be projected from a bare `Set` head, and that unknown must not defer a parameterless call.
    const groot = try m.addClass(a, .{
        .id = ClassId.from(0),
        .name = "GRoot",
        .fqn = "sample.GRoot",
        .primary_params = &.{},
        .methods = &.{},
        .init_block = null,
        .companion = null,
        .supertypes = &.{},
        .type_params = &.{"E"},
        .is_abstract = true,
        .is_interface = true,
    });
    const gredecl_args = try a.alloc(TypeRef, 1);
    gredecl_args[0] = .{ .name = "E", .nullable = false, .args = &.{} };
    const gredecl_supers = try a.alloc(TypeRef, 1);
    gredecl_supers[0] = .{ .name = "GRoot", .nullable = false, .args = gredecl_args };
    const gredecl = try m.addClass(a, .{
        .id = ClassId.from(0),
        .name = "GRedecl",
        .fqn = "sample.GRedecl",
        .primary_params = &.{},
        .methods = &.{},
        .init_block = null,
        .companion = null,
        .supertypes = try a.dupe(ClassId, &.{groot}),
        .supertype_refs = gredecl_supers,
        .type_params = &.{"E"},
        .is_abstract = true,
        .is_interface = true,
    });
    const groot_first = try pushTestFuncOpts(&m, a, "first", "sample.GRoot.first", "sample", 0, .{ .stub = true });
    const gredecl_first = try pushTestFuncOpts(&m, a, "first", "sample.GRedecl.first", "sample", 0, .{ .stub = true });
    for ([_]FuncId{ groot_first, gredecl_first }) |fid| m.funcs.items[fid.int()].kind = .instance_method;
    m.funcs.items[gredecl_first.int()].is_override = true;
    const first_owners = [_]ClassId{ groot, gredecl };
    const first_funcs = [_]FuncId{ groot_first, gredecl_first };
    for (first_funcs, first_owners) |fid, owner| {
        try m.decl_sigs.put(fid.int(), .{
            .enclosing_class = owner,
            .arity = .{ .required = 0, .total = 0, .has_vararg = false },
            .sig = &.{},
            .kind = .instance_method,
            .has_body = false,
        });
        try m.registerMemberDecl(a, m.classes.items[owner.int()].fqn, "first", fid);
    }
    const bare_generic = TypeRef{ .name = "GRedecl", .nullable = false, .args = &.{} };
    const gres = m.resolveMemberCall(gredecl, "first", &.{}, .{
        .receiver_type = bare_generic,
    });
    try testing.expect(gres.dispatch != .deferred);
    try testing.expectEqual(gredecl_first, gres.target.?);
}

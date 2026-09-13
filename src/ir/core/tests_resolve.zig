const std = @import("std");
const applicability = @import("applicability");
const testing = std.testing;
const root_ir = @import("../ir.zig");
const core_ids = @import("ids.zig");
const core_registry = @import("registry.zig");
const t_support = @import("tests_support.zig");

const ClassId = core_ids.ClassId;
const FileId = root_ir.FileId;
const Module = root_ir.Module;
const ModuleRegistry = core_registry.ModuleRegistry;
const TypeRef = core_ids.TypeRef;
const deferReasonOf = t_support.deferReasonOf;
const freeTestModule = t_support.freeTestModule;
const pushTestClass = t_support.pushTestClass;
const pushTestFunc = t_support.pushTestFunc;
const pushTestFuncOpts = t_support.pushTestFuncOpts;
const putTestDeclSig = t_support.putTestDeclSig;

test "symbol index proves stub signatures through the declared record" {
    const a = testing.allocator;
    var m = Module.default(a);
    defer freeTestModule(&m, a);
    // One lowered body plus one forward-referenced stub of the same
    // name/arity. With a matching declared signature recorded at phase 1
    // the set is provably identical (ambiguous); without any record the
    // proof is forfeited (type overload).
    _ = try pushTestFunc(&m, a, "g", "app.g", "app", 1);
    const stub = try pushTestFuncOpts(&m, a, "g", "app.g2.g", "app", 0, .{ .stub = true });
    try m.decl_user_arity.put(stub.int(), .{ .required = 1, .total = 1, .has_vararg = false });
    try m.rebuildFuncNameIndex(a);

    const unproven = m.resolveBareCallIndexed("g", "app", FileId.from(0), 1, false);
    try testing.expectEqual(Module.ResolveDeferReason.type_overload, deferReasonOf(unproven).?);

    try putTestDeclSig(&m, a, stub, "Int", 1);
    const proven = m.resolveBareCallIndexed("g", "app", FileId.from(0), 1, false);
    try testing.expectEqual(Module.ResolveDeferReason.ambiguous_tier, deferReasonOf(proven).?);
}

test "resolveCall ranks a body-declared forward overload" {
    const a = testing.allocator;
    var m = Module.default(a);
    defer freeTestModule(&m, a);
    _ = try pushTestFuncOpts(&m, a, "choose", "app.choose", "app", 1, .{ .param_ty = "String" });
    const forward = try pushTestFuncOpts(&m, a, "choose", "app.choose", "app", 1, .{ .stub = true, .param_ty = "Boolean" });
    try m.decl_user_arity.put(forward.int(), .{ .required = 1, .total = 1, .has_vararg = false });
    try putTestDeclSig(&m, a, forward, "Boolean", 1);
    try m.decl_sigs.put(forward.int(), .{
        .arity = .{ .required = 1, .total = 1, .has_vararg = false },
        .sig = m.decl_user_sig.get(forward.int()).?,
        .has_body = true,
    });
    try m.rebuildFuncNameIndex(a);

    const args = [_]applicability.ArgShape{.{
        .ty = .{ .name = "Boolean", .nullable = false, .args = &.{} },
    }};
    const resolved = try m.resolveCall(a, "choose", "app", FileId.from(0), &args, false, .{});
    defer a.free(resolved.candidate_set);
    try testing.expectEqual(forward.int(), resolved.target.?.int());
    try testing.expectEqual(Module.Confidence.exact, resolved.confidence);
}

test "resolveCall keeps an applicable trailing-lambda overload over the arity index" {
    const a = testing.allocator;
    var m = Module.default(a);
    defer freeTestModule(&m, a);
    const trailing = try pushTestFuncOpts(&m, a, "verify", "app.verify", "app", 2, .{
        .fn_tail_with_defaults = true,
    });
    const scalar = try pushTestFuncOpts(&m, a, "verify", "app.verify", "app", 2, .{
        .param_ty = "Boolean",
    });
    m.funcs.items[scalar.int()].params[1].ty.name = "String";
    m.funcs.items[scalar.int()].params[1].has_default = true;
    try m.rebuildFuncNameIndex(a);

    const args = [_]applicability.ArgShape{.{
        .is_lambda = true,
        .lambda_arity = 0,
        .lambda_is_literal = true,
    }};
    const indexed = m.resolveBareCallIndexed("verify", "app", FileId.from(0), 1, true);
    try testing.expectEqual(scalar.int(), indexed.pick().?.int());
    const resolved = try m.resolveCall(a, "verify", "app", FileId.from(0), &args, true, .{});
    defer a.free(resolved.candidate_set);
    try testing.expectEqual(trailing.int(), resolved.target.?.int());
}

test "resolveCall selects scope after applicability" {
    const a = testing.allocator;
    var m = Module.default(a);
    defer freeTestModule(&m, a);

    const own = try pushTestFuncOpts(&m, a, "pick", "app.pick", "app", 1, .{
        .param_ty = "Function1",
    });
    _ = try pushTestFuncOpts(&m, a, "pick", "imports.pick", "imports", 1, .{
        .param_ty = "Int",
    });
    var paths: std.ArrayList(ModuleRegistry.ImportPath) = .empty;
    const segs = try a.alloc([]const u8, 2);
    segs[0] = "imports";
    segs[1] = "pick";
    try paths.append(a, .{
        .fqn = try a.dupe(u8, "imports.pick"),
        .segs = segs,
    });
    var inner = std.StringHashMap(std.ArrayList(ModuleRegistry.ImportPath)).init(a);
    try inner.put("pick", paths);
    try m.registry.import_aliases.put(FileId.from(0), inner);
    try m.rebuildFuncNameIndex(a);

    const args = [_]applicability.ArgShape{.{
        .is_lambda = true,
        .lambda_arity = 1,
        .lambda_is_literal = true,
    }};
    const indexed = m.resolveBareCallIndexed("pick", "app", FileId.from(0), 1, false);
    try testing.expectEqual(@as(u8, 0), indexed.tier);

    const resolved = try m.resolveCall(a, "pick", "app", FileId.from(0), &args, false, .{});
    defer a.free(resolved.candidate_set);
    try testing.expectEqual(own, resolved.target.?);
    try testing.expectEqual(@as(u8, 1), resolved.tier);
    try testing.expect(resolved.target_final);
}

test "resolveCall commits a uniquely applicable source vararg" {
    const a = testing.allocator;
    var m = Module.default(a);
    defer freeTestModule(&m, a);

    const vararg = try pushTestFuncOpts(&m, a, "inspect", "app.inspect", "app", 1, .{
        .last_vararg = true,
        .param_ty = "Function1",
    });
    try m.rebuildFuncNameIndex(a);

    const args = [_]applicability.ArgShape{
        .{ .is_lambda = true, .lambda_arity = 1, .lambda_is_literal = true },
        .{ .is_lambda = true, .lambda_arity = 1, .lambda_is_literal = true },
    };
    const resolved = try m.resolveCall(a, "inspect", "app", FileId.from(0), &args, false, .{});
    defer a.free(resolved.candidate_set);
    try testing.expectEqual(vararg, resolved.target.?);
    try testing.expectEqual(Module.EmitForm.Call, resolved.emit_form);
    try testing.expect(resolved.target_final);
}

test "resolveCall keeps tied unknown overloads non-final" {
    const a = testing.allocator;
    var m = Module.default(a);
    defer freeTestModule(&m, a);

    _ = try pushTestFuncOpts(&m, a, "choose", "app.choose", "app", 1, .{
        .param_ty = "Int",
    });
    _ = try pushTestFuncOpts(&m, a, "choose", "app.choose", "app", 1, .{
        .param_ty = "String",
    });
    try m.rebuildFuncNameIndex(a);

    const resolved = try m.resolveCall(
        a,
        "choose",
        "app",
        FileId.from(0),
        &.{.{}},
        false,
        .{},
    );
    defer a.free(resolved.candidate_set);
    try testing.expect(resolved.target != null);
    try testing.expectEqual(Module.EmitForm.Call, resolved.emit_form);
    try testing.expect(!resolved.target_final);
}

test "resolveCall removes a statically incompatible overload before finalizing" {
    const a = testing.allocator;
    var m = Module.default(a);
    defer freeTestModule(&m, a);

    const generic = try pushTestFuncOpts(&m, a, "choose", "app.choose", "app", 1, .{
        .param_ty = "T",
    });
    _ = try pushTestFuncOpts(&m, a, "choose", "app.choose", "app", 1, .{
        .param_ty = "String",
    });
    var type_params: std.ArrayList([]const u8) = .empty;
    try type_params.append(a, "T");
    try m.registry.func_type_params.put(generic, type_params);
    try m.rebuildFuncNameIndex(a);

    const args = [_]applicability.ArgShape{.{
        .ty = .{ .name = "Any", .nullable = false, .args = &.{} },
    }};
    const resolved = try m.resolveCall(
        a,
        "choose",
        "app",
        FileId.from(0),
        &args,
        false,
        .{},
    );
    defer a.free(resolved.candidate_set);
    try testing.expectEqual(generic, resolved.target.?);
    try testing.expect(resolved.target_final);
}

test "resolveCall prefers a fixed overload for a named argument" {
    const a = testing.allocator;
    var m = Module.default(a);
    defer freeTestModule(&m, a);

    _ = try pushTestFuncOpts(&m, a, "choose", "app.choose", "app", 1, .{
        .last_vararg = true,
    });
    const fixed = try pushTestFunc(&m, a, "choose", "app.choose", "app", 1);
    m.funcs.items[fixed.int()].params[0].name = "x";
    m.funcs.items[fixed.int() - 1].params[0].name = "x";
    try m.rebuildFuncNameIndex(a);

    const args = [_]applicability.ArgShape{.{
        .ty = .{ .name = "Int", .nullable = false, .args = &.{} },
        .named = "x",
    }};
    const resolved = try m.resolveCall(
        a,
        "choose",
        "app",
        FileId.from(0),
        &args,
        false,
        .{},
    );
    defer a.free(resolved.candidate_set);
    try testing.expectEqual(fixed, resolved.target.?);
    try testing.expect(resolved.target_final);
}

test "resolveCall preserves a trailing lambda before the Compose pair" {
    const a = testing.allocator;
    var m = Module.default(a);
    defer freeTestModule(&m, a);
    const short = try pushTestFunc(&m, a, "Box", "app.Box", "app", 3);
    const content = try pushTestFunc(&m, a, "Box", "app.Box", "app", 6);

    const short_params = m.funcs.items[short.int()].params;
    short_params[0].name = "modifier";
    short_params[0].ty.name = "Modifier";
    short_params[1].name = "$composer";
    short_params[1].ty.name = "Composer";
    short_params[2].name = "$changed";

    const content_params = m.funcs.items[content.int()].params;
    content_params[0].name = "modifier";
    content_params[0].ty.name = "Modifier";
    content_params[0].has_default = true;
    content_params[1].name = "alignment";
    content_params[1].ty.name = "Alignment";
    content_params[1].has_default = true;
    content_params[2].name = "propagate";
    content_params[2].ty.name = "Boolean";
    content_params[2].has_default = true;
    content_params[3].name = "content";
    content_params[3].ty.name = "Function0";
    content_params[4].name = "$composer";
    content_params[4].ty.name = "Composer";
    content_params[5].name = "$changed";
    try m.rebuildFuncNameIndex(a);

    const args = [_]applicability.ArgShape{
        .{ .ty = .{ .name = "Function0", .nullable = false, .args = &.{} }, .is_lambda = true },
        .{ .ty = .{ .name = "Composer", .nullable = false, .args = &.{} }, .named = "$composer" },
        .{ .ty = .{ .name = "Int", .nullable = false, .args = &.{} }, .named = "$changed" },
    };
    const resolved = try m.resolveCall(
        a,
        "Box",
        "app",
        FileId.from(0),
        &args,
        false,
        .{},
    );
    defer a.free(resolved.candidate_set);
    try testing.expectEqual(content, resolved.target.?);
}

test "resolveCall commits a callable vararg before the Compose pair" {
    const a = testing.allocator;
    var m = Module.default(a);
    defer freeTestModule(&m, a);
    const inspect = try pushTestFunc(&m, a, "inspect", "app.inspect", "app", 4);
    const params = m.funcs.items[inspect.int()].params;
    params[0].name = "item";
    params[1].name = "selectors";
    params[1].ty.name = "Function1";
    params[1].is_vararg = true;
    params[2].name = "$composer";
    params[2].ty.name = "Composer";
    params[3].name = "$changed";
    try m.rebuildFuncNameIndex(a);

    const args = [_]applicability.ArgShape{
        .{ .ty = .{ .name = "Int", .nullable = false, .args = &.{} } },
        .{
            .ty = .{ .name = "Function1", .nullable = false, .args = &.{} },
            .is_lambda = true,
            .lambda_arity = 1,
            .lambda_is_literal = true,
        },
        .{
            .ty = .{ .name = "Function1", .nullable = false, .args = &.{} },
            .is_lambda = true,
            .lambda_arity = 1,
            .lambda_is_literal = true,
        },
        .{
            .ty = .{ .name = "Composer", .nullable = false, .args = &.{} },
            .named = "$composer",
        },
        .{
            .ty = .{ .name = "Int", .nullable = false, .args = &.{} },
            .named = "$changed",
        },
    };
    const resolved = try m.resolveCall(
        a,
        "inspect",
        "app",
        FileId.from(0),
        &args,
        false,
        .{},
    );
    defer a.free(resolved.candidate_set);
    try testing.expectEqual(inspect, resolved.target.?);
    try testing.expectEqual(Module.EmitForm.Call, resolved.emit_form);
    try testing.expect(resolved.target_final);
}

test "symbol index distinguishes overloads by generic arguments" {
    const a = testing.allocator;
    var m = Module.default(a);
    defer freeTestModule(&m, a);
    // Two same-package stubs whose declared params differ only in the
    // generic argument (`List<Int>` vs `List<String>`): a legal Kotlin
    // overload set the runtime dispatches by argument type, never an
    // ambiguity. Rewriting the second record to `List<Int>` makes the
    // pair a true duplicate and the verdict flips to ambiguous.
    const s1 = try pushTestFuncOpts(&m, a, "pick", "app.pick", "app", 0, .{ .stub = true });
    try m.decl_user_arity.put(s1.int(), .{ .required = 1, .total = 1, .has_vararg = false });
    {
        const sig = try a.alloc(TypeRef, 1);
        const args = try a.alloc(TypeRef, 1);
        args[0] = .{ .name = try a.dupe(u8, "Int"), .nullable = false, .args = &.{} };
        sig[0] = .{ .name = try a.dupe(u8, "List"), .nullable = false, .args = args };
        try m.decl_user_sig.put(s1.int(), sig);
    }
    const s2 = try pushTestFuncOpts(&m, a, "pick", "app.pick", "app", 0, .{ .stub = true });
    try m.decl_user_arity.put(s2.int(), .{ .required = 1, .total = 1, .has_vararg = false });
    {
        const sig = try a.alloc(TypeRef, 1);
        const args = try a.alloc(TypeRef, 1);
        args[0] = .{ .name = try a.dupe(u8, "String"), .nullable = false, .args = &.{} };
        sig[0] = .{ .name = try a.dupe(u8, "List"), .nullable = false, .args = args };
        try m.decl_user_sig.put(s2.int(), sig);
    }
    try m.rebuildFuncNameIndex(a);

    const got = m.resolveBareCallIndexed("pick", "app", FileId.from(0), 1, false);
    try testing.expectEqual(Module.ResolveDeferReason.type_overload, deferReasonOf(got).?);

    // Make the second stub's declared type IDENTICAL (`List<Int>`):
    // now nothing distinguishes the pair and it is a real ambiguity.
    {
        const old = m.decl_user_sig.fetchRemove(s2.int()).?;
        for (old.value) |*ty| ty.deinit(a);
        a.free(old.value);
        const fresh = try a.alloc(TypeRef, 1);
        const args = try a.alloc(TypeRef, 1);
        args[0] = .{ .name = try a.dupe(u8, "Int"), .nullable = false, .args = &.{} };
        fresh[0] = .{ .name = try a.dupe(u8, "List"), .nullable = false, .args = args };
        try m.decl_user_sig.put(s2.int(), fresh);
    }
    const got2 = m.resolveBareCallIndexed("pick", "app", FileId.from(0), 1, false);
    try testing.expectEqual(Module.ResolveDeferReason.ambiguous_tier, deferReasonOf(got2).?);
}

test "symbol index distinguishes a stub overload by its declared types" {
    const a = testing.allocator;
    var m = Module.default(a);
    defer freeTestModule(&m, a);
    // Body takes Int, forward-referenced stub declares String: a
    // type-dispatched overload set even though one body is unlowered.
    _ = try pushTestFunc(&m, a, "h2", "app.h2", "app", 1);
    const stub = try pushTestFuncOpts(&m, a, "h2", "app.x.h2", "app", 0, .{ .stub = true });
    try m.decl_user_arity.put(stub.int(), .{ .required = 1, .total = 1, .has_vararg = false });
    try putTestDeclSig(&m, a, stub, "String", 1);
    try m.rebuildFuncNameIndex(a);

    const got = m.resolveBareCallIndexed("h2", "app", FileId.from(0), 1, false);
    try testing.expectEqual(Module.ResolveDeferReason.type_overload, deferReasonOf(got).?);
}

test "resolveCall: an exact non-extension resolves to a static Call" {
    const a = testing.allocator;
    var m = Module.default(a);
    defer freeTestModule(&m, a);
    const g = try pushTestFunc(&m, a, "g", "app.g", "app", 1);
    try m.rebuildFuncNameIndex(a);
    const args = [_]applicability.ArgShape{.{}};
    const res = try m.resolveCall(a, "g", "app", FileId.from(0), &args, false, .{});
    defer a.free(res.candidate_set);
    try testing.expectEqual(Module.EmitForm.Call, res.emit_form);
    try testing.expectEqual(Module.Confidence.exact, res.confidence);
    try testing.expectEqual(g.int(), res.target.?.int());
}

test "resolveCall: an extension requires an implicit receiver context" {
    const a = testing.allocator;
    var m = Module.default(a);
    defer freeTestModule(&m, a);

    const extension = try pushTestFuncOpts(
        &m,
        a,
        "contentColorFor",
        "app.contentColorFor",
        "app",
        1,
        .{ .extension = true },
    );
    m.funcs.items[extension.int()].kind = .top_level_extension;
    const composable = try pushTestFunc(
        &m,
        a,
        "contentColorFor",
        "app.contentColorFor",
        "app",
        3,
    );
    m.funcs.items[composable.int()].params[1].name = "$composer";
    m.funcs.items[composable.int()].params[1].ty.name = "Composer";
    m.funcs.items[composable.int()].params[2].name = "$changed";
    try m.rebuildFuncNameIndex(a);

    const source_args = [_]applicability.ArgShape{.{}};
    const source = try m.resolveCall(
        a,
        "contentColorFor",
        "app",
        FileId.from(0),
        &source_args,
        false,
        .{},
    );
    defer a.free(source.candidate_set);
    try testing.expect(source.target == null);

    const source_in_composition = try m.resolveCall(
        a,
        "contentColorFor",
        "app",
        FileId.from(0),
        &source_args,
        false,
        .{ .has_composer = true },
    );
    defer a.free(source_in_composition.candidate_set);
    try testing.expectEqual(composable, source_in_composition.target.?);

    const threaded_args = [_]applicability.ArgShape{ .{}, .{}, .{} };
    const threaded = try m.resolveCall(
        a,
        "contentColorFor",
        "app",
        FileId.from(0),
        &threaded_args,
        false,
        .{},
    );
    defer a.free(threaded.candidate_set);
    try testing.expectEqual(composable, threaded.target.?);
    try testing.expectEqual(Module.EmitForm.Call, threaded.emit_form);
}

test "resolveCall ignores inapplicable callables on a known receiver tower" {
    const a = testing.allocator;
    var m = Module.default(a);
    defer freeTestModule(&m, a);

    _ = try pushTestClass(&m, a, "String", "kotlin.String", "kotlin");
    _ = try pushTestClass(&m, a, "FractionalParser", "kotlin.time.FractionalParser", "kotlin.time");
    const global = try pushTestFuncOpts(&m, a, "repeat", "kotlin.repeat", "kotlin", 2, .{});
    m.funcs.items[global.int()].params[1].ty.name = "Function1";

    const string_repeat = try pushTestFuncOpts(
        &m,
        a,
        "repeat",
        "kotlin.text.repeat",
        "kotlin.text",
        1,
        .{ .extension = true },
    );
    m.funcs.items[string_repeat.int()].kind = .top_level_extension;
    const string_repeat_sig = [_]TypeRef{
        .{ .name = "Int", .nullable = false, .args = &.{} },
    };
    try m.decl_sigs.put(string_repeat.int(), .{
        .receiver_ty = .{ .name = "String", .nullable = false, .args = &.{} },
        .arity = .{ .required = 1, .total = 1, .has_vararg = false },
        .sig = &string_repeat_sig,
        .kind = .top_level_extension,
        .has_body = true,
    });
    try m.rebuildFuncNameIndex(a);

    const args = [_]applicability.ArgShape{
        .{ .ty = .{ .name = "Int", .nullable = false, .args = &.{} } },
        .{
            .ty = .{ .name = "Function1", .nullable = false, .args = &.{} },
            .is_lambda = true,
            .lambda_arity = 1,
        },
    };
    const res = try m.resolveCall(a, "repeat", "app", FileId.from(0), &args, true, .{
        .in_receiver_context = true,
        .unknown_receiver = true,
        .recv_ty = "String",
        .recv_type = .{ .name = "String", .nullable = false, .args = &.{} },
        .owner_class = "FractionalParser",
        .receiver_scope_complete = true,
    });
    defer a.free(res.candidate_set);
    try testing.expectEqual(global, res.target.?);
    try testing.expectEqual(Module.EmitForm.Call, res.emit_form);
    try testing.expectEqual(Module.Confidence.exact, res.confidence);
}

test "resolveCall retains a vararg extension on a known receiver" {
    const a = testing.allocator;
    var m = Module.default(a);
    defer freeTestModule(&m, a);

    _ = try pushTestClass(&m, a, "String", "kotlin.String", "kotlin");
    const global = try pushTestFunc(&m, a, "pick", "app.pick", "app", 1);
    const extension = try pushTestFuncOpts(
        &m,
        a,
        "pick",
        "app.stringPick",
        "app",
        1,
        .{ .extension = true, .last_vararg = true },
    );
    m.funcs.items[extension.int()].kind = .top_level_extension;
    try m.decl_sigs.put(extension.int(), .{
        .receiver_ty = .{ .name = "String", .nullable = false, .args = &.{} },
        .arity = .{ .required = 0, .total = 1, .has_vararg = true },
        .sig = &.{},
        .kind = .top_level_extension,
        .has_body = true,
    });
    try m.rebuildFuncNameIndex(a);

    const args = [_]applicability.ArgShape{
        .{ .ty = .{ .name = "Int", .nullable = false, .args = &.{} } },
    };
    const res = try m.resolveCall(a, "pick", "app", FileId.from(0), &args, false, .{
        .in_receiver_context = true,
        .unknown_receiver = true,
        .recv_ty = "String",
        .recv_type = .{ .name = "String", .nullable = false, .args = &.{} },
        .receiver_scope_complete = true,
    });
    defer a.free(res.candidate_set);
    try testing.expectEqual(global, res.target.?);
    try testing.expectEqual(Module.EmitForm.CallMemberOrGlobal, res.emit_form);
    try testing.expectEqual(Module.Confidence.virtual, res.confidence);
}

test "known receiver applicability keeps same-name classes distinct" {
    const a = testing.allocator;
    var m = Module.default(a);
    defer freeTestModule(&m, a);

    _ = try pushTestClass(&m, a, "Scope", "left.Scope", "left");
    const owner = try pushTestClass(&m, a, "Scope", "right.Scope", "right");
    const choose = try pushTestFunc(&m, a, "choose", "right.Scope.choose", "right", 1);
    m.funcs.items[choose.int()].kind = .instance_method;
    const choose_sig = [_]TypeRef{
        .{ .name = "Int", .nullable = false, .args = &.{} },
    };
    try m.decl_sigs.put(choose.int(), .{
        .enclosing_class = owner,
        .arity = .{ .required = 1, .total = 1, .has_vararg = false },
        .sig = &choose_sig,
        .kind = .instance_method,
        .has_body = true,
    });
    try m.registerMemberDecl(a, "right.Scope", "choose", choose);

    const args = [_]applicability.ArgShape{
        .{ .ty = .{ .name = "Int", .nullable = false, .args = &.{} } },
    };
    try testing.expectEqual(true, m.knownReceiverCallableApplicable(
        "choose",
        "app",
        FileId.from(0),
        &args,
        .{
            .recv_ty = "left.Scope",
            .recv_type = .{ .name = "left.Scope", .nullable = false, .args = &.{} },
            .owner_class = "right.Scope",
            .receiver_scope_complete = true,
        },
    ).?);

    const left_qualifier = [_]TypeRef{
        .{ .name = "#qual:left.Scope", .nullable = false, .args = &.{} },
    };
    try testing.expect(m.knownReceiverCallableApplicable(
        "choose",
        "app",
        FileId.from(0),
        &args,
        .{
            .recv_ty = "Scope",
            .recv_type = .{ .name = "Scope", .nullable = false, .args = @constCast(&left_qualifier) },
            .owner_class = "Scope",
            .receiver_scope_complete = true,
        },
    ) == null);
}

test "known receiver applicability keeps nullable extension and dispatch receivers" {
    const a = testing.allocator;
    var m = Module.default(a);
    defer freeTestModule(&m, a);

    _ = try pushTestClass(&m, a, "Scope", "app.Scope", "app");
    const choose = try pushTestFuncOpts(
        &m,
        a,
        "choose",
        "app.choose",
        "app",
        1,
        .{ .extension = true },
    );
    m.funcs.items[choose.int()].params[0].ty.name = "app.Scope";
    m.funcs.items[choose.int()].kind = .top_level_extension;
    const choose_sig = [_]TypeRef{
        .{ .name = "Int", .nullable = false, .args = &.{} },
    };
    try m.decl_sigs.put(choose.int(), .{
        .receiver_ty = .{ .name = "app.Scope", .nullable = false, .args = &.{} },
        .arity = .{ .required = 1, .total = 1, .has_vararg = false },
        .sig = &choose_sig,
        .kind = .top_level_extension,
        .has_body = true,
    });
    try m.rebuildFuncNameIndex(a);

    const args = [_]applicability.ArgShape{
        .{ .ty = .{ .name = "Int", .nullable = false, .args = &.{} } },
    };
    try testing.expectEqual(true, m.knownReceiverCallableApplicable(
        "choose",
        "app",
        FileId.from(0),
        &args,
        .{
            .recv_ty = "app.Scope",
            .recv_type = .{ .name = "app.Scope", .nullable = true, .args = &.{} },
            .owner_class = "app.Scope",
            .receiver_scope_complete = true,
        },
    ).?);
}

test "known receiver applicability checks exact receivers before erased generic owners" {
    const a = testing.allocator;
    var m = Module.default(a);
    defer freeTestModule(&m, a);

    _ = try pushTestClass(&m, a, "String", "kotlin.String", "kotlin");
    _ = try m.addClass(a, .{
        .id = ClassId.from(0),
        .name = "Box",
        .fqn = "app.Box",
        .package = "app",
        .type_params = &.{"T"},
        .primary_params = &.{},
        .methods = &.{},
        .init_block = null,
        .companion = null,
        .supertypes = &.{},
    });
    try m.registry.class_type_param_bounds.put("app.Box", try a.dupe(ModuleRegistry.TypeParamBound, &.{
        .{ .param = "T", .bound = "kotlin.Any" },
    }));
    const choose = try pushTestFuncOpts(
        &m,
        a,
        "choose",
        "app.stringChoose",
        "app",
        1,
        .{ .extension = true },
    );
    m.funcs.items[choose.int()].kind = .top_level_extension;
    const choose_sig = [_]TypeRef{
        .{ .name = "Int", .nullable = false, .args = &.{} },
    };
    try m.decl_sigs.put(choose.int(), .{
        .receiver_ty = .{ .name = "String", .nullable = false, .args = &.{} },
        .arity = .{ .required = 1, .total = 1, .has_vararg = false },
        .sig = &choose_sig,
        .kind = .top_level_extension,
        .has_body = true,
    });
    try m.rebuildFuncNameIndex(a);

    const args = [_]applicability.ArgShape{
        .{ .ty = .{ .name = "Int", .nullable = false, .args = &.{} } },
    };
    const ctx = Module.ResolveCtx{
        .recv_ty = "String",
        .recv_type = .{ .name = "String", .nullable = false, .args = &.{} },
        .owner_class = "Box",
        .receiver_scope_complete = true,
    };
    try testing.expectEqual(true, m.knownReceiverCallableApplicable(
        "choose",
        "app",
        FileId.from(0),
        &args,
        ctx,
    ).?);
    try testing.expectEqual(false, m.knownReceiverCallableApplicable(
        "missing",
        "app",
        FileId.from(0),
        &args,
        ctx,
    ).?);
}

test "an imported same-name upper bound cannot complete raw bound evidence" {
    const a = testing.allocator;
    var m = Module.default(a);
    defer freeTestModule(&m, a);

    const left = try pushTestClass(&m, a, "Bound", "left.Bound", "left");
    _ = try pushTestClass(&m, a, "Bound", "right.Bound", "right");
    _ = try m.addClass(a, .{
        .id = ClassId.from(0),
        .name = "Box",
        .fqn = "app.Box",
        .package = "app",
        .type_params = &.{"T"},
        .primary_params = &.{},
        .methods = &.{},
        .init_block = null,
        .companion = null,
        .supertypes = &.{},
    });
    try m.registry.class_type_param_bounds.put("app.Box", try a.dupe(ModuleRegistry.TypeParamBound, &.{
        .{ .param = "T", .bound = "Bound", .complete = true },
    }));

    var paths: std.ArrayList(ModuleRegistry.ImportPath) = .empty;
    const segs = try a.alloc([]const u8, 2);
    segs[0] = "left";
    segs[1] = "Bound";
    try paths.append(a, .{ .fqn = try a.dupe(u8, "left.Bound"), .segs = segs });
    var imports = std.StringHashMap(std.ArrayList(ModuleRegistry.ImportPath)).init(a);
    try imports.put("Bound", paths);
    try m.registry.import_aliases.put(FileId.from(0), imports);
    try testing.expectEqual(left, m.classIdIndexed("Bound", "app", FileId.from(0)).?);

    try testing.expect(m.knownReceiverCallableApplicable(
        "missing",
        "app",
        FileId.from(0),
        &.{},
        .{
            .in_receiver_context = true,
            .receiver_known = true,
            .owner_class = "Box",
            .receiver_scope_complete = true,
        },
    ) == null);

    _ = try pushTestClass(&m, a, "U", "app.U", "app");
    _ = try m.addClass(a, .{
        .id = ClassId.from(0),
        .name = "Wrapper",
        .fqn = "app.Wrapper",
        .package = "app",
        .type_params = &.{"T"},
        .primary_params = &.{},
        .methods = &.{},
        .init_block = null,
        .companion = null,
        .supertypes = &.{},
    });
    const dependent_bounds = [_]ModuleRegistry.TypeParamBound{
        .{ .param = "T", .bound = "U", .complete = true },
        .{ .param = "U", .bound = "Comparable", .complete = false },
    };
    const wrapper_args = [_]TypeRef{
        .{ .name = "T", .nullable = false, .args = &.{} },
    };
    try testing.expect(!m.staticTypeProofComplete(.{
        .name = "Wrapper",
        .nullable = false,
        .args = @constCast(&wrapper_args),
    }, &dependent_bounds));
}

test "dependent candidate bounds use declaration bindings not caller names" {
    const a = testing.allocator;
    var m = Module.default(a);
    defer freeTestModule(&m, a);

    _ = try m.addClass(a, .{
        .id = ClassId.from(0),
        .name = "Pair",
        .fqn = "app.Pair",
        .package = "app",
        .type_params = &.{ "First", "Second" },
        .primary_params = &.{},
        .methods = &.{},
        .init_block = null,
        .companion = null,
        .supertypes = &.{},
    });
    const declared_bounds = [_]ModuleRegistry.TypeParamBound{
        .{ .param = "T", .bound = "U" },
        .{ .param = "U", .bound = "Number" },
    };
    const caller_bounds = [_]ModuleRegistry.TypeParamBound{
        .{ .param = "A", .bound = "U" },
        .{ .param = "U", .bound = "Number" },
        .{ .param = "V", .bound = "Number" },
    };
    const pattern_args = [_]TypeRef{
        .{ .name = "T", .nullable = false, .args = &.{} },
        .{ .name = "U", .nullable = false, .args = &.{} },
    };
    const pattern = TypeRef{
        .name = "Pair",
        .nullable = false,
        .args = @constCast(&pattern_args),
    };
    const invalid_args = [_]TypeRef{
        .{ .name = "A", .nullable = false, .args = &.{} },
        .{ .name = "V", .nullable = false, .args = &.{} },
    };
    try testing.expect(!(try m.staticGenericReceiverApplicable(
        a,
        .{ .name = "Pair", .nullable = false, .args = @constCast(&invalid_args) },
        pattern,
        &declared_bounds,
        &caller_bounds,
    )));
    const valid_args = [_]TypeRef{
        .{ .name = "A", .nullable = false, .args = &.{} },
        .{ .name = "U", .nullable = false, .args = &.{} },
    };
    try testing.expect(try m.staticGenericReceiverApplicable(
        a,
        .{ .name = "Pair", .nullable = false, .args = @constCast(&valid_args) },
        pattern,
        &declared_bounds,
        &caller_bounds,
    ));

    const any_declared_bounds = [_]ModuleRegistry.TypeParamBound{
        .{ .param = "T", .bound = "Any" },
        .{ .param = "Any", .bound = "Number" },
    };
    const any_caller_bounds = [_]ModuleRegistry.TypeParamBound{
        .{ .param = "A", .bound = "Any" },
        .{ .param = "Any", .bound = "Number" },
        .{ .param = "V", .bound = "Number" },
    };
    const any_pattern_args = [_]TypeRef{
        .{ .name = "T", .nullable = false, .args = &.{} },
        .{ .name = "Any", .nullable = false, .args = &.{} },
    };
    const any_pattern = TypeRef{
        .name = "Pair",
        .nullable = false,
        .args = @constCast(&any_pattern_args),
    };
    try testing.expect(!(try m.staticGenericReceiverApplicable(
        a,
        .{ .name = "Pair", .nullable = false, .args = @constCast(&invalid_args) },
        any_pattern,
        &any_declared_bounds,
        &any_caller_bounds,
    )));
    const synthetic_any_bounds = [_]ModuleRegistry.TypeParamBound{
        .{ .param = "T", .bound = "kotlin.Any" },
        .{ .param = "Any", .bound = "Number" },
    };
    try testing.expect(try m.staticGenericReceiverApplicable(
        a,
        .{ .name = "Pair", .nullable = false, .args = @constCast(&invalid_args) },
        any_pattern,
        &synthetic_any_bounds,
        &any_caller_bounds,
    ));

    const base = try pushTestClass(&m, a, "Base", "app.Base", "app");
    const supers = [_]ClassId{base};
    _ = try m.addClass(a, .{
        .id = ClassId.from(0),
        .name = "Sub",
        .fqn = "app.Sub",
        .package = "app",
        .primary_params = &.{},
        .methods = &.{},
        .init_block = null,
        .companion = null,
        .supertypes = @constCast(&supers),
    });
    const nominal_declared_bounds = [_]ModuleRegistry.TypeParamBound{
        .{ .param = "T", .bound = "U" },
        .{ .param = "U", .bound = "kotlin.Any" },
    };
    const nominal_caller_bounds = [_]ModuleRegistry.TypeParamBound{
        .{ .param = "A", .bound = "Sub" },
        .{ .param = "Base", .bound = "kotlin.Any" },
    };
    const nominal_args = [_]TypeRef{
        .{ .name = "A", .nullable = false, .args = &.{} },
        .{ .name = "Base", .nullable = false, .args = &.{} },
    };
    try testing.expect(!(try m.staticGenericReceiverApplicable(
        a,
        .{ .name = "Pair", .nullable = false, .args = @constCast(&nominal_args) },
        pattern,
        &nominal_declared_bounds,
        &nominal_caller_bounds,
    )));
}

test "resolveCall retains a generic dispatch-owner extension" {
    const a = testing.allocator;
    var m = Module.default(a);
    defer freeTestModule(&m, a);

    _ = try m.addClass(a, .{
        .id = ClassId.from(0),
        .name = "Box",
        .fqn = "app.Box",
        .package = "app",
        .type_params = &.{"T"},
        .primary_params = &.{},
        .methods = &.{},
        .init_block = null,
        .companion = null,
        .supertypes = &.{},
    });
    try m.registry.class_type_param_bounds.put("app.Box", try a.dupe(ModuleRegistry.TypeParamBound, &.{
        .{ .param = "T", .bound = "kotlin.Any" },
    }));
    const global = try pushTestFunc(&m, a, "pick", "app.pick", "app", 0);
    const extension = try pushTestFuncOpts(
        &m,
        a,
        "pick",
        "app.boxPick",
        "app",
        0,
        .{ .extension = true },
    );
    const box_args = [_]TypeRef{
        .{ .name = "T", .nullable = false, .args = &.{} },
    };
    const box_t = TypeRef{
        .name = "Box",
        .nullable = false,
        .args = @constCast(&box_args),
    };
    m.funcs.items[extension.int()].params[0].ty = box_t;
    m.funcs.items[extension.int()].kind = .top_level_extension;
    try m.decl_sigs.put(extension.int(), .{
        .receiver_ty = box_t,
        .arity = .{ .required = 0, .total = 0, .has_vararg = false },
        .sig = &.{},
        .kind = .top_level_extension,
        .has_body = true,
    });
    try m.rebuildFuncNameIndex(a);

    const res = try m.resolveCall(a, "pick", "app", FileId.from(0), &.{}, false, .{
        .in_receiver_context = true,
        .receiver_known = true,
        .owner_class = "Box",
        .receiver_scope_complete = true,
    });
    defer a.free(res.candidate_set);
    try testing.expectEqual(global, res.target.?);
    try testing.expectEqual(Module.EmitForm.CallMemberOrGlobal, res.emit_form);
    try testing.expectEqual(Module.Confidence.virtual, res.confidence);

    const global_wrong = try pushTestFunc(&m, a, "wrong", "app.wrong", "app", 0);
    const concrete_extension = try pushTestFuncOpts(
        &m,
        a,
        "wrong",
        "app.stringBoxWrong",
        "app",
        0,
        .{ .extension = true },
    );
    const string_args = [_]TypeRef{
        .{ .name = "String", .nullable = false, .args = &.{} },
    };
    const box_string = TypeRef{
        .name = "Box",
        .nullable = false,
        .args = @constCast(&string_args),
    };
    m.funcs.items[concrete_extension.int()].params[0].ty = box_string;
    m.funcs.items[concrete_extension.int()].kind = .top_level_extension;
    try m.decl_sigs.put(concrete_extension.int(), .{
        .receiver_ty = box_string,
        .arity = .{ .required = 0, .total = 0, .has_vararg = false },
        .sig = &.{},
        .kind = .top_level_extension,
        .has_body = true,
    });
    try m.rebuildFuncNameIndex(a);

    const wrong = try m.resolveCall(a, "wrong", "app", FileId.from(0), &.{}, false, .{
        .in_receiver_context = true,
        .receiver_known = true,
        .owner_class = "Box",
        .receiver_scope_complete = true,
    });
    defer a.free(wrong.candidate_set);
    try testing.expectEqual(global_wrong, wrong.target.?);
    try testing.expectEqual(Module.EmitForm.Call, wrong.emit_form);
    try testing.expectEqual(Module.Confidence.exact, wrong.confidence);
}

test "resolveCall applies a generic dispatch-owner upper bound" {
    const a = testing.allocator;
    var m = Module.default(a);
    defer freeTestModule(&m, a);

    _ = try m.addClass(a, .{
        .id = ClassId.from(0),
        .name = "Box",
        .fqn = "app.Box",
        .package = "app",
        .type_params = &.{"T"},
        .type_param_variance = &.{.Out},
        .primary_params = &.{},
        .methods = &.{},
        .init_block = null,
        .companion = null,
        .supertypes = &.{},
    });
    try m.registry.class_type_param_bounds.put("app.Box", try a.dupe(ModuleRegistry.TypeParamBound, &.{
        .{ .param = "T", .bound = "Number" },
    }));
    const global = try pushTestFunc(&m, a, "bounded", "app.bounded", "app", 0);
    const extension = try pushTestFuncOpts(
        &m,
        a,
        "bounded",
        "app.boundedBox",
        "app",
        0,
        .{ .extension = true },
    );
    const number_args = [_]TypeRef{
        .{ .name = "Number", .nullable = false, .args = &.{} },
    };
    const box_number = TypeRef{
        .name = "Box",
        .nullable = false,
        .args = @constCast(&number_args),
    };
    m.funcs.items[extension.int()].params[0].ty = box_number;
    m.funcs.items[extension.int()].kind = .top_level_extension;
    try m.decl_sigs.put(extension.int(), .{
        .receiver_ty = box_number,
        .arity = .{ .required = 0, .total = 0, .has_vararg = false },
        .sig = &.{},
        .kind = .top_level_extension,
        .has_body = true,
    });
    try m.rebuildFuncNameIndex(a);

    const res = try m.resolveCall(a, "bounded", "app", FileId.from(0), &.{}, false, .{
        .in_receiver_context = true,
        .receiver_known = true,
        .owner_class = "Box",
        .receiver_scope_complete = true,
    });
    defer a.free(res.candidate_set);
    try testing.expectEqual(global, res.target.?);
    try testing.expectEqual(Module.EmitForm.CallMemberOrGlobal, res.emit_form);
    try testing.expectEqual(Module.Confidence.virtual, res.confidence);

    @constCast(m.registry.class_type_param_bounds.get("app.Box").?)[0].complete = false;
    const uncertain_global = try pushTestFunc(&m, a, "uncertain", "app.uncertain", "app", 0);
    const uncertain_extension = try pushTestFuncOpts(
        &m,
        a,
        "uncertain",
        "app.uncertainStringBox",
        "app",
        0,
        .{ .extension = true },
    );
    const string_args = [_]TypeRef{
        .{ .name = "String", .nullable = false, .args = &.{} },
    };
    const box_string = TypeRef{
        .name = "Box",
        .nullable = false,
        .args = @constCast(&string_args),
    };
    m.funcs.items[uncertain_extension.int()].params[0].ty = box_string;
    m.funcs.items[uncertain_extension.int()].kind = .top_level_extension;
    try m.decl_sigs.put(uncertain_extension.int(), .{
        .receiver_ty = box_string,
        .arity = .{ .required = 0, .total = 0, .has_vararg = false },
        .sig = &.{},
        .kind = .top_level_extension,
        .has_body = true,
    });
    try m.rebuildFuncNameIndex(a);
    const uncertain = try m.resolveCall(
        a,
        "uncertain",
        "app",
        FileId.from(0),
        &.{},
        false,
        .{
            .in_receiver_context = true,
            .receiver_known = true,
            .owner_class = "Box",
            .receiver_scope_complete = true,
        },
    );
    defer a.free(uncertain.candidate_set);
    try testing.expectEqual(uncertain_global, uncertain.target.?);
    try testing.expectEqual(Module.EmitForm.CallMemberOrGlobal, uncertain.emit_form);
    try testing.expectEqual(Module.Confidence.virtual, uncertain.confidence);
}

test "resolveCall binds bodyless host declarations by FuncId" {
    const a = testing.allocator;
    var m = Module.default(a);
    defer freeTestModule(&m, a);

    const println = try pushTestFuncOpts(&m, a, "println", "kotlin.io.println", "kotlin.io", 1, .{ .stub = true });
    try m.decl_user_arity.put(println.int(), .{ .required = 1, .total = 1, .has_vararg = false });
    try putTestDeclSig(&m, a, println, "Any", 1);
    try m.decl_sigs.put(println.int(), .{
        .arity = .{ .required = 1, .total = 1, .has_vararg = false },
        .sig = m.decl_user_sig.get(println.int()).?,
        .host_symbol = "kotlin.io.println",
    });

    const ints = try pushTestFuncOpts(&m, a, "intArrayOf", "kotlin.intArrayOf", "kotlin", 1, .{
        .stub = true,
        .last_vararg = true,
    });
    try m.decl_user_arity.put(ints.int(), .{ .required = 0, .total = 1, .has_vararg = true });
    try putTestDeclSig(&m, a, ints, "Int", 1);
    try m.decl_sigs.put(ints.int(), .{
        .arity = .{ .required = 0, .total = 1, .has_vararg = true },
        .sig = m.decl_user_sig.get(ints.int()).?,
        .host_symbol = "kotlin.intArrayOf",
    });
    try m.rebuildFuncNameIndex(a);

    const println_args = [_]applicability.ArgShape{.{
        .ty = .{ .name = "String", .nullable = false, .args = &.{} },
    }};
    const print_res = try m.resolveCall(a, "println", "app", FileId.from(0), &println_args, false, .{});
    defer a.free(print_res.candidate_set);
    try testing.expectEqual(println.int(), print_res.target.?.int());
    try testing.expectEqual(Module.EmitForm.Call, print_res.emit_form);
    try testing.expect(print_res.target_final);

    const int_args = [_]applicability.ArgShape{
        .{ .ty = .{ .name = "Int", .nullable = false, .args = &.{} } },
        .{ .ty = .{ .name = "Int", .nullable = false, .args = &.{} } },
        .{ .ty = .{ .name = "Int", .nullable = false, .args = &.{} } },
    };
    const ints_res = try m.resolveCall(a, "intArrayOf", "app", FileId.from(0), &int_args, false, .{});
    defer a.free(ints_res.candidate_set);
    try testing.expectEqual(ints.int(), ints_res.target.?.int());
    try testing.expectEqual(Module.EmitForm.Call, ints_res.emit_form);
    try testing.expect(ints_res.target_final);
}

test "resolveCall binds a bodyless expect declaration" {
    const a = testing.allocator;
    var m = Module.default(a);
    defer freeTestModule(&m, a);

    const intrinsic = try pushTestFuncOpts(
        &m,
        a,
        "enumEntriesIntrinsic",
        "kotlin.enums.enumEntriesIntrinsic",
        "kotlin.enums",
        0,
        .{ .stub = true },
    );
    m.funcs.items[intrinsic.int()].is_expect = true;
    try m.decl_sigs.put(intrinsic.int(), .{
        .arity = .{ .required = 0, .total = 0, .has_vararg = false },
        .sig = &.{},
        .has_body = false,
    });
    try m.rebuildFuncNameIndex(a);

    const resolved = try m.resolveCall(
        a,
        "enumEntriesIntrinsic",
        "kotlin.enums",
        FileId.from(0),
        &.{},
        false,
        .{},
    );
    defer a.free(resolved.candidate_set);
    try testing.expectEqual(intrinsic, resolved.target.?);
    try testing.expectEqual(Module.EmitForm.Call, resolved.emit_form);
    try testing.expect(resolved.target_final);
}

test "resolveCall: a resolved extension in a receiver context defers to CallMemberOrGlobal" {
    const a = testing.allocator;
    var m = Module.default(a);
    defer freeTestModule(&m, a);
    // The only candidate is an extension; applicability resolves it and the
    // emission decision retains the member-first walk.
    const ext = try pushTestFuncOpts(&m, a, "ext", "app.ext", "app", 1, .{ .extension = true });
    try m.rebuildFuncNameIndex(a);
    const args = [_]applicability.ArgShape{.{}};
    const res = try m.resolveCall(a, "ext", "app", FileId.from(0), &args, false, .{
        .in_receiver_context = true,
        .unknown_receiver = true,
    });
    defer a.free(res.candidate_set);
    try testing.expectEqual(Module.EmitForm.CallMemberOrGlobal, res.emit_form);
    try testing.expectEqual(Module.Confidence.virtual, res.confidence);
    try testing.expectEqual(ext.int(), res.target.?.int());
}

test "resolveCall: a type-distinguishable stub overload defers to a receiver probe" {
    const a = testing.allocator;
    var m = Module.default(a);
    defer freeTestModule(&m, a);
    // Two incomplete same-arity stubs of different declared types carry no
    // canonical declaration record, so applicability cannot rank either and
    // the call remains a runtime probe.

    const s1 = try pushTestFuncOpts(&m, a, "minOf", "app.minOf", "app", 0, .{ .stub = true });
    try m.decl_user_arity.put(s1.int(), .{ .required = 1, .total = 1, .has_vararg = false });
    try putTestDeclSig(&m, a, s1, "Int", 1);
    const s2 = try pushTestFuncOpts(&m, a, "minOf", "app.x.minOf", "app", 0, .{ .stub = true });
    try m.decl_user_arity.put(s2.int(), .{ .required = 1, .total = 1, .has_vararg = false });
    try putTestDeclSig(&m, a, s2, "String", 1);
    try m.rebuildFuncNameIndex(a);
    const args = [_]applicability.ArgShape{.{}};
    const res = try m.resolveCall(a, "minOf", "app", FileId.from(0), &args, false, .{ .in_receiver_context = true });
    defer a.free(res.candidate_set);
    try testing.expectEqual(Module.ResolveDeferReason.type_overload, res.reason.?);
    try testing.expect(res.target == null);
    try testing.expectEqual(Module.EmitForm.CallMemberOrGlobal, res.emit_form);
    try testing.expectEqual(Module.Confidence.deferred, res.confidence);
}

test "resolveCall: a shadowed value capture defers to CallValue" {
    const a = testing.allocator;
    var m = Module.default(a);
    defer freeTestModule(&m, a);
    // No same-name top-level function exists; the name is a captured local.
    try m.rebuildFuncNameIndex(a);
    const args = [_]applicability.ArgShape{.{}};
    const res = try m.resolveCall(a, "cb", "app", FileId.from(0), &args, false, .{ .is_value_capture = true });
    defer a.free(res.candidate_set);
    try testing.expectEqual(Module.EmitForm.CallValue, res.emit_form);
    try testing.expectEqual(Module.Confidence.deferred, res.confidence);
    try testing.expect(res.target == null);
}

test "symbol index never resolves an extension form" {
    const a = testing.allocator;
    var m = Module.default(a);
    defer freeTestModule(&m, a);
    // One candidate, an extension (leading `this` param): the index does
    // not model receiver resolution, so it defers to the heuristic.
    _ = try pushTestFuncOpts(&m, a, "ext", "app.ext", "app", 0, .{ .extension = true });
    try m.rebuildFuncNameIndex(a);

    const got = m.resolveBareCallIndexed("ext", "app", FileId.from(0), 0, false);
    try testing.expectEqual(Module.ResolveDeferReason.extension_form, deferReasonOf(got).?);
}

test "symbol index defers an unknown name as no_candidates" {
    const a = testing.allocator;
    var m = Module.default(a);
    defer freeTestModule(&m, a);
    try m.rebuildFuncNameIndex(a);

    const got = m.resolveBareCallIndexed("nope", "app", FileId.from(0), 0, false);
    try testing.expectEqual(Module.ResolveDeferReason.no_candidates, deferReasonOf(got).?);
}

test "symbol index resolves an intrinsic-backed name like any other symbol" {
    const a = testing.allocator;
    var m = Module.default(a);
    defer freeTestModule(&m, a);
    // `compareValues` is an ordinary symbol: it resolves through the index like
    // any other function. Its native intrinsic attaches at run time via
    // `resolvedNativeForm`, not through a name-based index escape hatch.
    const fid = try pushTestFunc(&m, a, "compareValues", "kotlin.comparisons.compareValues", "kotlin.comparisons", 2);
    try m.rebuildFuncNameIndex(a);

    const got = m.resolveBareCallIndexed("compareValues", "app", FileId.from(0), 2, false);
    try testing.expectEqual(fid, got.pick().?);
}

test "symbol index defers an arity mismatch in the winning tier" {
    const a = testing.allocator;
    var m = Module.default(a);
    defer freeTestModule(&m, a);
    _ = try pushTestFunc(&m, a, "f", "app.f", "app", 2);
    try m.rebuildFuncNameIndex(a);

    const got = m.resolveBareCallIndexed("f", "app", FileId.from(0), 1, false);
    try testing.expectEqual(Module.ResolveDeferReason.arity_mismatch, deferReasonOf(got).?);
    try testing.expectEqual(@as(u8, 1), got.tier);
}

test "symbol index defers a bodyless decl with no declared-arity record" {
    const a = testing.allocator;
    var m = Module.default(a);
    defer freeTestModule(&m, a);
    // A bodyless func without a `decl_user_arity` entry cannot be ranked.
    _ = try pushTestFuncOpts(&m, a, "g", "app.g", "app", 0, .{ .stub = true });
    try m.rebuildFuncNameIndex(a);

    const got = m.resolveBareCallIndexed("g", "app", FileId.from(0), 0, false);
    try testing.expectEqual(Module.ResolveDeferReason.bodyless_only, deferReasonOf(got).?);
}

test "symbol index defers when only a low-priority overload matches" {
    const a = testing.allocator;
    var m = Module.default(a);
    defer freeTestModule(&m, a);
    _ = try pushTestFuncOpts(&m, a, "lp", "app.lp", "app", 1, .{ .low_priority = true });
    try m.rebuildFuncNameIndex(a);

    const got = m.resolveBareCallIndexed("lp", "app", FileId.from(0), 1, false);
    try testing.expectEqual(Module.ResolveDeferReason.low_priority_only, deferReasonOf(got).?);
}

test "symbol index defers a trailing-vararg candidate" {
    const a = testing.allocator;
    var m = Module.default(a);
    defer freeTestModule(&m, a);
    _ = try pushTestFuncOpts(&m, a, "va", "app.va", "app", 1, .{ .last_vararg = true });
    try m.rebuildFuncNameIndex(a);

    const got = m.resolveBareCallIndexed("va", "app", FileId.from(0), 1, false);
    try testing.expectEqual(Module.ResolveDeferReason.vararg_only, deferReasonOf(got).?);
}

test "symbol index defers a default-gap trailing-lambda shape" {
    const a = testing.allocator;
    var m = Module.default(a);
    defer freeTestModule(&m, a);
    // `fun tl(x: Int = 0, body: () -> Unit)` called as `tl { ... }`:
    // one supplied arg (the lambda), the gap param defaulted — the
    // heuristic's trailing-lambda rung handles this, the index defers.
    _ = try pushTestFuncOpts(&m, a, "tl", "app.tl", "app", 2, .{ .fn_tail_with_defaults = true });
    try m.rebuildFuncNameIndex(a);

    const got = m.resolveBareCallIndexed("tl", "app", FileId.from(0), 1, true);
    try testing.expectEqual(Module.ResolveDeferReason.trailing_lambda_shape, deferReasonOf(got).?);

    // Without the trailing lambda the same call is a plain arity miss.
    const got2 = m.resolveBareCallIndexed("tl", "app", FileId.from(0), 1, false);
    try testing.expectEqual(Module.ResolveDeferReason.arity_mismatch, deferReasonOf(got2).?);
}

test "symbol index ranks a forward-referenced stub by declared arity" {
    const a = testing.allocator;
    var m = Module.default(a);
    defer freeTestModule(&m, a);
    // An own-package phase-1 stub (body not lowered yet) with a recorded
    // exact declared arity resolves, independent of lowering order.
    const stub = try pushTestFuncOpts(&m, a, "fwd", "app.fwd", "app", 0, .{ .stub = true });
    try m.decl_user_arity.put(stub.int(), .{ .required = 1, .total = 1, .has_vararg = false });
    _ = try pushTestFunc(&m, a, "fwd", "lib.fwd", "lib", 1);
    try m.rebuildFuncNameIndex(a);

    const got = m.resolveBareCallIndexed("fwd", "app", FileId.from(0), 1, false);
    try testing.expect(got.outcome == .resolved);
    try testing.expectEqual(stub.int(), got.outcome.resolved.int());
    try testing.expectEqual(@as(u8, 1), got.tier);
}

test "symbol index resolves a default-compatible stub and defers varargs" {
    const a = testing.allocator;
    var m = Module.default(a);
    defer freeTestModule(&m, a);
    const dflt = try pushTestFuncOpts(&m, a, "d", "app.d", "app", 2, .{ .stub = true });
    m.funcByIdMut(dflt).?.params[1].has_default = true;
    try m.decl_user_arity.put(dflt.int(), .{ .required = 1, .total = 2, .has_vararg = false });
    const va = try pushTestFuncOpts(&m, a, "v", "app.v", "app", 1, .{ .stub = true, .last_vararg = true });
    try m.decl_user_arity.put(va.int(), .{ .required = 0, .total = 1, .has_vararg = true });
    try m.rebuildFuncNameIndex(a);

    const got_d = m.resolveBareCallIndexed("d", "app", FileId.from(0), 1, false);
    try testing.expect(got_d.outcome == .resolved);
    try testing.expectEqual(dflt.int(), got_d.outcome.resolved.int());
    const got_v = m.resolveBareCallIndexed("v", "app", FileId.from(0), 1, false);
    try testing.expectEqual(Module.ResolveDeferReason.vararg_only, deferReasonOf(got_v).?);
}

test "symbol index resolves a default-bearing body" {
    const a = testing.allocator;
    var m = Module.default(a);
    defer freeTestModule(&m, a);
    // `fun d(x: Int, y: Int = 0)` binds both its full and under-applied
    // positional forms to the same static target.
    const body = try pushTestFuncOpts(&m, a, "d", "app.d", "app", 2, .{});
    m.funcByIdMut(body).?.params[1].has_default = true;
    try m.rebuildFuncNameIndex(a);

    const full = m.resolveBareCallIndexed("d", "app", FileId.from(0), 2, false);
    try testing.expect(full.outcome == .resolved);
    try testing.expectEqual(body.int(), full.outcome.resolved.int());
    const omitted = m.resolveBareCallIndexed("d", "app", FileId.from(0), 1, false);
    try testing.expect(omitted.outcome == .resolved);
    try testing.expectEqual(body.int(), omitted.outcome.resolved.int());
}

test "symbol index prefers exact arity over a default-consuming overload" {
    const a = testing.allocator;
    var m = Module.default(a);
    defer freeTestModule(&m, a);
    const exact = try pushTestFuncOpts(&m, a, "d", "app.d1", "app", 1, .{});
    const wider = try pushTestFuncOpts(&m, a, "d", "app.d2", "app", 2, .{});
    m.funcByIdMut(wider).?.params[1].has_default = true;
    try m.rebuildFuncNameIndex(a);

    const got = m.resolveBareCallIndexed("d", "app", FileId.from(0), 1, false);
    try testing.expect(got.outcome == .resolved);
    try testing.expectEqual(exact.int(), got.outcome.resolved.int());
}

test "resolveCall emits a static Call for an omitted default" {
    const a = testing.allocator;
    var m = Module.default(a);
    defer freeTestModule(&m, a);
    const target = try pushTestFuncOpts(&m, a, "Job", "app.Job", "app", 1, .{});
    m.funcByIdMut(target).?.params[0].has_default = true;
    try m.rebuildFuncNameIndex(a);

    const res = try m.resolveCall(a, "Job", "app", FileId.from(0), &.{}, false, .{});
    defer a.free(res.candidate_set);
    try testing.expectEqual(Module.EmitForm.Call, res.emit_form);
    try testing.expectEqual(Module.Confidence.exact, res.confidence);
    try testing.expectEqual(target.int(), res.target.?.int());
}

test "packageHeadDeclared distinguishes a package head from a member head" {
    const a = testing.allocator;
    var m = Module.default(a);
    defer {
        for (m.funcs.items) |f| {
            a.free(f.params);
            a.free(f.blocks);
        }
        m.deinit(a);
    }
    // A top-level func in package `mypkg` makes `mypkg` a declared package
    // head; a top-level func with no package (`helper`) is not a head.
    _ = try pushTestFunc(&m, a, "build", "mypkg.build", "mypkg", 0);
    _ = try pushTestFunc(&m, a, "helper", "helper", "", 0);

    // `mypkg.build(...)` — `mypkg` is the first segment of a declared FQN,
    // so it is a package head that flattens to a global load.
    try testing.expect(m.packageHeadDeclared("mypkg"));
    // `helper.foo` — `helper` names a top-level symbol, not a package
    // prefix, so it is a member/receiver head, not a package head.
    try testing.expect(!m.packageHeadDeclared("helper"));
    // A name with no declaration at all (a receiver member like `inner`)
    // is never a package head.
    try testing.expect(!m.packageHeadDeclared("inner"));
    try testing.expect(!m.packageHeadDeclared(""));
}

test "funcId ranks a user declaration above a shipped same-name" {
    const a = testing.allocator;
    var m = Module.default(a);
    defer freeTestModule(&m, a);
    // Shipped decl concatenates first (packs precede user sources).
    _ = try pushTestFunc(&m, a, "shuffle", "kotlin.collections.shuffle", "kotlin.collections", 1);
    const user = try pushTestFunc(&m, a, "shuffle", "shuffle", "", 1);
    try m.rebuildFuncNameIndex(a);
    try testing.expectEqual(user.int(), m.funcId("shuffle").?.int());

    // The package classification is a head-segment match, not a raw
    // prefix: a user package starting with `kotlinx2` is not shipped.
    var m2 = Module.default(a);
    defer freeTestModule(&m2, a);
    _ = try pushTestFunc(&m2, a, "go", "kotlinx.coroutines.go", "kotlinx.coroutines", 0);
    const user2 = try pushTestFunc(&m2, a, "go", "kotlinx2.go", "kotlinx2", 0);
    try m2.rebuildFuncNameIndex(a);
    try testing.expectEqual(user2.int(), m2.funcId("go").?.int());
}

test "funcId prefers a body sibling over a bodyless shipped pair" {
    const a = testing.allocator;
    var m = Module.default(a);
    defer freeTestModule(&m, a);
    // Both shipped: the bodyless `expect` must not hide the body sibling.
    _ = try pushTestFuncOpts(&m, a, "now", "kotlin.time.now", "kotlin.time", 0, .{ .stub = true });
    const actual = try pushTestFunc(&m, a, "now", "kotlin.time.now.actual", "kotlin.time", 0);
    try m.rebuildFuncNameIndex(a);
    try testing.expectEqual(actual.int(), m.funcId("now").?.int());
}

test "hasFuncNamed answers over the name index" {
    const a = testing.allocator;
    var m = Module.default(a);
    defer freeTestModule(&m, a);
    _ = try pushTestFunc(&m, a, "f", "pkg.f", "pkg", 0);
    try m.rebuildFuncNameIndex(a);
    try testing.expect(m.hasFuncNamed("f"));
    try testing.expect(!m.hasFuncNamed("g"));
}

test "uniqueClassIdBySimpleName caches without changing scan semantics" {
    const a = testing.allocator;
    var m = Module.default(a);
    defer m.deinit(a);
    const solo = try pushTestClass(&m, a, "Solo", "lib.Solo", "lib");
    const inner = try pushTestClass(&m, a, "Outer$Inner", "lib.Outer.Inner", "lib");
    // Unique names resolve, via both the class name and the FQN's last segment.
    try testing.expectEqual(solo.int(), m.uniqueClassIdBySimpleName("Solo").?.int());
    try testing.expectEqual(inner.int(), m.uniqueClassIdBySimpleName("Inner").?.int());
    try testing.expectEqual(inner.int(), m.uniqueClassIdBySimpleName("Outer$Inner").?.int());
    try testing.expect(m.uniqueClassIdBySimpleName("Missing") == null);
    // A class appended after the first lookup is visible to the next one,
    // and a second identity under the same simple name makes it ambiguous.
    _ = try pushTestClass(&m, a, "Solo", "app.Solo", "app");
    try testing.expect(m.uniqueClassIdBySimpleName("Solo") == null);
    try testing.expectEqual(inner.int(), m.uniqueClassIdBySimpleName("Inner").?.int());
}

test "classIdIndexed prefers the caller's own package on a collision" {
    const a = testing.allocator;
    var m = Module.default(a);
    defer m.deinit(a);
    const lib = try pushTestClass(&m, a, "Config", "lib.Config", "lib");
    const app = try pushTestClass(&m, a, "Config", "app.Config", "app");
    // Flat lookup returns the first declaration regardless of caller.
    try testing.expectEqual(lib.int(), m.classId("Config").?.int());
    // The indexed lookup binds the class the caller's package declares.
    try testing.expectEqual(app.int(), m.classIdIndexed("Config", "app", FileId.from(0)).?.int());
    try testing.expectEqual(lib.int(), m.classIdIndexed("Config", "lib", FileId.from(0)).?.int());
    // A caller in neither package keeps the declaration-order pick.
    try testing.expectEqual(lib.int(), m.classIdIndexed("Config", "other", FileId.from(0)).?.int());
    try testing.expect(m.classIdIndexed("Missing", "app", FileId.from(0)) == null);
}

test "bare-ref index resolves a unique candidate with no arity filter" {
    const a = testing.allocator;
    var m = Module.default(a);
    defer freeTestModule(&m, a);
    // Vararg and defaulted shapes the CALL index defers on still
    // resolve as references.
    const f = try pushTestFuncOpts(&m, a, "fmt", "app.fmt", "app", 2, .{ .last_vararg = true });
    try m.rebuildFuncNameIndex(a);
    try testing.expectEqual(f.int(), m.resolveBareRefIndexed("fmt", "app", FileId.from(0)).?.int());
    // Cross-package: the caller's own package wins over another package.
    const own = try pushTestFunc(&m, a, "pick", "app.pick", "app", 0);
    _ = try pushTestFunc(&m, a, "pick", "lib.pick", "lib", 0);
    try m.rebuildFuncNameIndex(a);
    try testing.expectEqual(own.int(), m.resolveBareRefIndexed("pick", "app", FileId.from(0)).?.int());
}

test "bare-ref index defers ambiguity, extensions, and unknown names" {
    const a = testing.allocator;
    var m = Module.default(a);
    defer freeTestModule(&m, a);
    // Two same-tier candidates: ambiguous, defer.
    _ = try pushTestFunc(&m, a, "h", "app.h", "app", 0);
    _ = try pushTestFunc(&m, a, "h", "app.util.h", "app", 1);
    // A single extension-form candidate: never a bare reference.
    _ = try pushTestFuncOpts(&m, a, "ext", "app.ext", "app", 1, .{ .extension = true });
    try m.rebuildFuncNameIndex(a);
    try testing.expect(m.resolveBareRefIndexed("h", "app", FileId.from(0)) == null);
    try testing.expect(m.resolveBareRefIndexed("ext", "app", FileId.from(0)) == null);
    try testing.expect(m.resolveBareRefIndexed("missing", "app", FileId.from(0)) == null);
    try testing.expect(m.resolveBareRefIndexed("compareValues", "app", FileId.from(0)) == null);
}

test "a cross-file private declaration is not a bare-call candidate" {
    const a = testing.allocator;
    var m = Module.default(a);
    defer freeTestModule(&m, a);
    // A private member extension declared in file 7 (a test class's
    // `CoroutineScope.block(context)`) must not enter another file's
    // candidate set; the same-file query still sees it.
    const priv = try pushTestFuncOpts(&m, a, "block", "lib.T.block", "lib", 1, .{ .extension = true });
    m.funcs.items[priv.int()].kind = .member_extension;
    try m.registry.member_ext_owner_class.put(priv, "T");
    try m.registry.private_fn_files.put(priv, FileId.from(7));
    try m.rebuildFuncNameIndex(a);
    const cross = try m.bareCallCandidates(a, "block", FileId.from(3));
    defer a.free(cross);
    try testing.expectEqual(@as(usize, 0), cross.len);
    const same = try m.bareCallCandidates(a, "block", FileId.from(7));
    defer a.free(same);
    try testing.expectEqual(@as(usize, 1), same.len);
}

test "classIdIndexed ranks a named import above the own package" {
    const a = testing.allocator;
    var m = Module.default(a);
    defer m.deinit(a);
    _ = try pushTestClass(&m, a, "Config", "app.Config", "app");
    const imported = try pushTestClass(&m, a, "Config", "lib.Config", "lib");
    var paths: std.ArrayList(ModuleRegistry.ImportPath) = .empty;
    const segs = try a.alloc([]const u8, 2);
    segs[0] = "lib";
    segs[1] = "Config";
    try paths.append(a, .{ .fqn = try a.dupe(u8, "lib.Config"), .segs = segs });
    var inner = std.StringHashMap(std.ArrayList(ModuleRegistry.ImportPath)).init(a);
    try inner.put("Config", paths);
    try m.registry.import_aliases.put(FileId.from(0), inner);
    try testing.expectEqual(imported.int(), m.classIdIndexed("Config", "app", FileId.from(0)).?.int());
    // A file without the import resolves the own-package class.
    try testing.expectEqual(
        m.classIdByFqn("app.Config").?.int(),
        m.classIdIndexed("Config", "app", FileId.from(1)).?.int(),
    );
}

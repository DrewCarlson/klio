const std = @import("std");
const applicability = @import("applicability");
const testing = std.testing;
const root_ir = @import("../ir.zig");
const core_ids = @import("ids.zig");
const core_registry = @import("registry.zig");
const t_support = @import("tests_support.zig");

const ClassId = core_ids.ClassId;
const FileId = root_ir.FileId;
const FuncId = core_ids.FuncId;
const Module = root_ir.Module;
const ModuleRegistry = core_registry.ModuleRegistry;
const Span = root_ir.Span;
const TypeRef = core_ids.TypeRef;
const classTypeParamIdentity = core_ids.classTypeParamIdentity;
const deferReasonOf = t_support.deferReasonOf;
const freeTestModule = t_support.freeTestModule;
const pushTestFunc = t_support.pushTestFunc;
const pushTestFuncOpts = t_support.pushTestFuncOpts;

test "a bare call never binds a member extension of an unrelated class" {
    const a = testing.allocator;
    var m = Module.default(a);
    defer freeTestModule(&m, a);
    // `kotlin.with(receiver, block)` and, in another library, the member
    // extension `KeyframeEntity.with(easing)` declared inside
    // `KeyframesSpecConfig`.
    const std_with = try pushTestFuncOpts(&m, a, "with", "kotlin.with", "kotlin", 2, .{ .stub = true });
    const member_with = try pushTestFuncOpts(&m, a, "with", "with", "", 1, .{ .stub = true, .extension = true });
    m.funcs.items[std_with.int()].params[0].ty.name = "Any";
    m.funcs.items[std_with.int()].params[1].ty.name = "Function1";
    m.funcs.items[member_with.int()].kind = .member_extension;
    try m.registry.member_ext_owner_class.put(member_with, "KeyframesSpecConfig");
    const std_sig = [_]TypeRef{
        .{ .name = "Any", .nullable = false, .args = &.{} },
        .{ .name = "Function1", .nullable = false, .args = &.{} },
    };
    try m.decl_sigs.put(std_with.int(), .{
        .arity = .{ .required = 2, .total = 2, .has_vararg = false },
        .sig = &std_sig,
        .kind = .plain,
        .has_body = true,
    });
    const member_sig = [_]TypeRef{
        .{ .name = "Int", .nullable = false, .args = &.{} },
    };
    try m.decl_sigs.put(member_with.int(), .{
        .arity = .{ .required = 1, .total = 1, .has_vararg = false },
        .receiver_ty = .{ .name = "String", .nullable = false, .args = &.{} },
        .sig = &member_sig,
        .kind = .member_extension,
        .has_body = true,
    });
    try m.rebuildFuncNameIndex(a);

    const global_args = [_]applicability.ArgShape{
        .{ .ty = .{ .name = "String", .nullable = false, .args = &.{} } },
        .{ .is_lambda = true, .lambda_arity = 1 },
    };
    // A caller inside an unrelated class has no `KeyframesSpecConfig`
    // receiver, so the member extension is not a candidate: `kotlin.with`.
    const res = try m.resolveCall(a, "with", "androidx.compose.ui.text", FileId.from(0), &global_args, true, .{
        .in_receiver_context = true,
        .owner_class = "MultiParagraph",
    });
    defer a.free(res.candidate_set);
    try testing.expect(res.target != null);
    try testing.expectEqual(std_with.int(), res.target.?.int());

    // Inside the declaring class the member extension IS in scope.
    const member_args = [_]applicability.ArgShape{
        .{ .ty = .{ .name = "Int", .nullable = false, .args = &.{} } },
    };
    const own = try m.resolveCall(a, "with", "androidx.compose.animation.core", FileId.from(0), &member_args, false, .{
        .in_receiver_context = true,
        .owner_class = "KeyframesSpecConfig",
    });
    defer a.free(own.candidate_set);
    try testing.expect(own.target != null);
    try testing.expectEqual(member_with.int(), own.target.?.int());
}

test "extension resolver proves receiver, scope, and overload identity" {
    const a = testing.allocator;
    var m = Module.default(a);
    defer freeTestModule(&m, a);

    const int_arg = try pushTestFuncOpts(&m, a, "paint", "app.paint", "app", 1, .{ .extension = true });
    m.funcs.items[int_arg.int()].kind = .top_level_extension;
    const string_arg = try pushTestFuncOpts(&m, a, "paint", "app.paint", "app", 1, .{ .extension = true, .param_ty = "String" });
    m.funcs.items[string_arg.int()].kind = .top_level_extension;
    const any_arg = try pushTestFuncOpts(&m, a, "paint", "app.paint", "app", 1, .{ .extension = true, .param_ty = "Any" });
    m.funcs.items[any_arg.int()].kind = .top_level_extension;
    const int_receiver = try pushTestFuncOpts(&m, a, "paint", "app.paint", "app", 1, .{ .extension = true });
    m.funcs.items[int_receiver.int()].kind = .top_level_extension;
    m.funcs.items[int_receiver.int()].params[0].ty.name = "Int";
    _ = try pushTestFuncOpts(&m, a, "hidden", "other.hidden", "other", 0, .{ .extension = true });
    m.funcs.items[m.funcs.items.len - 1].kind = .top_level_extension;
    const repeat = try pushTestFuncOpts(&m, a, "repeat", "kotlin.text.repeat", "kotlin.text", 1, .{
        .stub = true,
        .extension = true,
    });
    m.funcs.items[repeat.int()].kind = .top_level_extension;
    m.funcs.items[repeat.int()].params[0].ty.name = "CharSequence";
    try m.decl_sigs.put(repeat.int(), .{
        .receiver_ty = .{ .name = "CharSequence", .nullable = false, .args = &.{} },
        .arity = .{ .required = 1, .total = 1, .has_vararg = false },
        .sig = &.{.{ .name = "Int", .nullable = false, .args = &.{} }},
        .kind = .top_level_extension,
        .host_symbol = "kotlin.CharSequence.repeat",
    });
    const starts_with = try pushTestFuncOpts(&m, a, "startsWith", "kotlin.text.startsWith", "kotlin.text", 2, .{
        .stub = true,
        .extension = true,
        .param_ty = "String",
    });
    m.funcs.items[starts_with.int()].kind = .top_level_extension;
    m.funcs.items[starts_with.int()].params[2].ty.name = "Boolean";
    m.funcs.items[starts_with.int()].params[2].has_default = true;
    try m.decl_sigs.put(starts_with.int(), .{
        .receiver_ty = .{ .name = "String", .nullable = false, .args = &.{} },
        .arity = .{ .required = 1, .total = 2, .has_vararg = false },
        .sig = &.{
            .{ .name = "String", .nullable = false, .args = &.{} },
            .{ .name = "Boolean", .nullable = false, .args = &.{} },
        },
        .kind = .top_level_extension,
        .host_symbol = "kotlin.String.startsWith",
    });
    const shipped_origin = try pushTestFuncOpts(&m, a, "origin", "kotlin.text.origin", "kotlin.text", 0, .{
        .extension = true,
    });
    m.funcs.items[shipped_origin.int()].kind = .top_level_extension;
    const user_origin = try pushTestFuncOpts(&m, a, "origin", "user.extensions.origin", "user.extensions", 0, .{
        .extension = true,
    });
    m.funcs.items[user_origin.int()].kind = .top_level_extension;
    m.funcs.items[user_origin.int()].params[0].ty.name = "Any";
    var origin_wildcards: std.ArrayList([]const u8) = .empty;
    try origin_wildcards.append(a, try a.dupe(u8, "kotlin.text"));
    try origin_wildcards.append(a, try a.dupe(u8, "user.extensions"));
    try m.registry.import_wildcards.put(FileId.from(1), origin_wildcards);

    const long_literal = try pushTestFuncOpts(&m, a, "literalPick", "app.literalPick", "app", 1, .{
        .extension = true,
        .param_ty = "Long",
    });
    m.funcs.items[long_literal.int()].kind = .top_level_extension;
    const any_literal = try pushTestFuncOpts(&m, a, "literalPick", "app.literalPick", "app", 1, .{
        .extension = true,
        .param_ty = "Any",
    });
    m.funcs.items[any_literal.int()].kind = .top_level_extension;

    const alias_pick = try pushTestFuncOpts(&m, a, "aliasPick", "app.aliasPick", "app", 0, .{
        .extension = true,
    });
    m.funcs.items[alias_pick.int()].kind = .top_level_extension;
    m.funcs.items[alias_pick.int()].params[0].ty.name = "Text";
    const any_alias_pick = try pushTestFuncOpts(&m, a, "aliasPick", "app.aliasPick", "app", 0, .{
        .extension = true,
    });
    m.funcs.items[any_alias_pick.int()].kind = .top_level_extension;
    m.funcs.items[any_alias_pick.int()].params[0].ty.name = "Any";
    try m.registry.type_aliases.put("Text", "String");

    const bounded_pick = try pushTestFuncOpts(&m, a, "boundedPick", "app.boundedPick", "app", 0, .{
        .extension = true,
    });
    m.funcs.items[bounded_pick.int()].kind = .top_level_extension;
    m.funcs.items[bounded_pick.int()].params[0].ty.name = "CharSequence";
    const any_bounded_pick = try pushTestFuncOpts(&m, a, "boundedPick", "app.boundedPick", "app", 0, .{
        .extension = true,
    });
    m.funcs.items[any_bounded_pick.int()].kind = .top_level_extension;
    m.funcs.items[any_bounded_pick.int()].params[0].ty.name = "Any";
    try m.rebuildFuncNameIndex(a);

    const typed_args = [_]applicability.ArgShape{.{
        .ty = .{ .name = "Int", .nullable = false, .args = &.{} },
    }};
    const resolved = m.resolveExtensionCall("paint", .{
        .name = "String",
        .nullable = false,
        .args = &.{},
    }, &typed_args, .{ .caller_file = FileId.from(0), .caller_package = "app" });
    try testing.expect(resolved.target != null);
    try testing.expectEqual(int_arg.int(), resolved.target.?.int());

    const ambiguous = m.resolveExtensionCall("paint", .{
        .name = "String",
        .nullable = false,
        .args = &.{},
    }, &.{.{}}, .{ .caller_file = FileId.from(0), .caller_package = "app" });
    try testing.expect(ambiguous.target == null);

    const out_of_scope = m.resolveExtensionCall("hidden", .{
        .name = "String",
        .nullable = false,
        .args = &.{},
    }, &.{}, .{ .caller_file = FileId.from(0), .caller_package = "app" });
    try testing.expect(out_of_scope.target == null);

    const host_backed = m.resolveExtensionCall("repeat", .{
        .name = "String",
        .nullable = false,
        .args = &.{},
    }, &typed_args, .{ .caller_file = FileId.from(0), .caller_package = "app" });
    try testing.expectEqual(repeat.int(), host_backed.target.?.int());

    const string_args = [_]applicability.ArgShape{.{
        .ty = .{ .name = "String", .nullable = false, .args = &.{} },
    }};
    const defaulted = m.resolveExtensionCall("startsWith", .{
        .name = "String",
        .nullable = false,
        .args = &.{},
    }, &string_args, .{ .caller_file = FileId.from(0), .caller_package = "app" });
    try testing.expectEqual(starts_with.int(), defaulted.target.?.int());

    const ordered_named_args = [_]applicability.ArgShape{.{
        .ty = .{ .name = "String", .nullable = false, .args = &.{} },
        .named = "x",
    }};
    const ordered_named = m.resolveExtensionCall("startsWith", .{
        .name = "String",
        .nullable = false,
        .args = &.{},
    }, &ordered_named_args, .{
        .caller_file = FileId.from(0),
        .caller_package = "app",
    });
    try testing.expectEqual(starts_with.int(), ordered_named.target.?.int());

    const wrong_named_args = [_]applicability.ArgShape{.{
        .ty = .{ .name = "String", .nullable = false, .args = &.{} },
        .named = "other",
    }};
    try testing.expect(m.resolveExtensionCall("startsWith", .{
        .name = "String",
        .nullable = false,
        .args = &.{},
    }, &wrong_named_args, .{
        .caller_file = FileId.from(0),
        .caller_package = "app",
    }).target == null);

    const origin = m.resolveExtensionCall("origin", .{
        .name = "String",
        .nullable = false,
        .args = &.{},
    }, &.{}, .{ .caller_file = FileId.from(1), .caller_package = "app" });
    try testing.expectEqual(shipped_origin.int(), origin.target.?.int());

    const numeric_literal = [_]applicability.ArgShape{.{
        .ty = .{ .name = "Int", .nullable = false, .args = &.{} },
        .literal_kind = .numeric,
    }};
    // kotlinc: an integer literal materializes as Long in a Long slot, and
    // the Long overload is more specific than Any — the pick is static.
    try testing.expectEqual(long_literal.int(), m.resolveExtensionCall("literalPick", .{
        .name = "String",
        .nullable = false,
        .args = &.{},
    }, &numeric_literal, .{
        .caller_file = FileId.from(0),
        .caller_package = "app",
    }).target.?.int());

    try testing.expect(m.resolveExtensionCall("aliasPick", .{
        .name = "String",
        .nullable = false,
        .args = &.{},
    }, &.{}, .{
        .caller_file = FileId.from(0),
        .caller_package = "app",
    }).target == null);

    try testing.expect(m.resolveExtensionCall("boundedPick", .{
        .name = "T",
        .nullable = false,
        .args = &.{},
    }, &.{}, .{
        .caller_file = FileId.from(0),
        .caller_package = "app",
    }).target == null);
}

test "extension resolver expands receiver aliases in their file scope" {
    const a = testing.allocator;
    var m = Module.default(a);
    defer freeTestModule(&m, a);

    const compound = try pushTestFuncOpts(
        &m,
        a,
        "compoundWith",
        "app.compoundWith",
        "app",
        0,
        .{ .extension = true },
    );
    m.funcs.items[compound.int()].kind = .top_level_extension;
    m.funcs.items[compound.int()].params[0].ty.name = "Long";
    try m.decl_sigs.put(compound.int(), .{
        .receiver_ty = .{
            .name = "CompositeKeyHashCode",
            .nullable = false,
            .args = &.{},
        },
        .arity = .{ .required = 0, .total = 0, .has_vararg = false },
        .sig = &.{},
        .kind = .top_level_extension,
        .has_body = true,
    });
    try m.decl_span.put(
        compound.int(),
        Span.init(FileId.from(1), 0, 1),
    );
    try m.registry.file_packages.put(FileId.from(1), "app");
    try m.registry.file_packages.put(FileId.from(2), "app");
    try m.registry.type_alias_types.put("app.CompositeKeyHashCode", .{
        .type_params = &.{},
        .target = .{ .name = "Long", .nullable = false, .args = &.{} },
    });
    try m.registry.type_alias_types.put("other.CompositeKeyHashCode", .{
        .type_params = &.{},
        .target = .{ .name = "String", .nullable = false, .args = &.{} },
    });
    try m.registry.type_alias_types.put("CompositeKeyHashCode", .{
        .type_params = &.{},
        .target = .{ .name = "String", .nullable = false, .args = &.{} },
    });
    try m.registry.type_aliases.put("CompositeKeyHashCode", "String");
    try m.rebuildFuncNameIndex(a);

    const resolved = m.resolveExtensionCall(
        "compoundWith",
        .{
            .name = "CompositeKeyHashCode",
            .nullable = false,
            .args = &.{},
        },
        &.{},
        .{
            .caller_file = FileId.from(2),
            .caller_package = "app",
        },
    );
    try testing.expectEqual(compound, resolved.target.?);
}

test "extension resolver admits source bodies and defers possible member shadows" {
    const a = testing.allocator;
    var m = Module.default(a);
    defer freeTestModule(&m, a);

    const source = try pushTestFuncOpts(&m, a, "sourceOnly", "kotlin.text.sourceOnly", "kotlin.text", 0, .{
        .stub = true,
        .extension = true,
    });
    m.funcs.items[source.int()].kind = .top_level_extension;
    try m.decl_sigs.put(source.int(), .{
        .receiver_ty = .{ .name = "String", .nullable = false, .args = &.{} },
        .arity = .{ .required = 0, .total = 0, .has_vararg = false },
        .sig = &.{},
        .kind = .top_level_extension,
        .has_body = true,
    });
    try m.decl_ast_body.put(source.int(), {});
    const stdlib = try pushTestFuncOpts(&m, a, "isBlank", "kotlin.text.isBlank", "kotlin.text", 0, .{
        .extension = true,
    });
    m.funcs.items[stdlib.int()].kind = .top_level_extension;
    const member = try pushTestFuncOpts(&m, a, "isBlank", "app.Scope.isBlank", "app", 0, .{
        .extension = true,
    });
    m.funcs.items[member.int()].kind = .member_extension;
    try m.registry.member_ext_owner_class.put(member, "Scope");
    const bodyless = try pushTestFuncOpts(&m, a, "headerOnly", "kotlin.text.headerOnly", "kotlin.text", 0, .{
        .stub = true,
        .extension = true,
    });
    m.funcs.items[bodyless.int()].kind = .top_level_extension;

    const generic_top = try pushTestFuncOpts(&m, a, "tag", "app.tag", "app", 0, .{
        .extension = true,
    });
    m.funcs.items[generic_top.int()].kind = .top_level_extension;
    const generic_member = try pushTestFuncOpts(&m, a, "tag", "app.Scope.tag", "app", 0, .{
        .extension = true,
    });
    m.funcs.items[generic_member.int()].kind = .member_extension;
    try m.registry.member_ext_owner_class.put(generic_member, "Scope");
    const string_receiver_args = try a.alloc(TypeRef, 1);
    defer a.free(string_receiver_args);
    string_receiver_args[0] = .{ .name = "String", .nullable = false, .args = &.{} };
    m.funcs.items[generic_top.int()].params[0].ty = .{
        .name = "List",
        .nullable = false,
        .args = string_receiver_args,
    };
    const type_var_receiver_args = try a.alloc(TypeRef, 1);
    defer a.free(type_var_receiver_args);
    type_var_receiver_args[0] = .{ .name = "T", .nullable = false, .args = &.{} };
    m.funcs.items[generic_member.int()].params[0].ty = .{
        .name = "List",
        .nullable = false,
        .args = type_var_receiver_args,
    };

    const starts_with = try pushTestFuncOpts(&m, a, "startsWith", "kotlin.text.startsWith", "kotlin.text", 1, .{
        .extension = true,
        .param_ty = "String",
    });
    m.funcs.items[starts_with.int()].kind = .top_level_extension;
    const hidden_starts_with = try pushTestFuncOpts(&m, a, "startsWith", "app.HiddenExtensions.startsWith", "app", 1, .{
        .extension = true,
        .param_ty = "String",
    });
    m.funcs.items[hidden_starts_with.int()].kind = .member_extension;
    try m.registry.member_ext_owner_class.put(hidden_starts_with, "HiddenExtensions");
    try m.registry.object_names.append(a, "HiddenExtensions");
    try m.rebuildFuncNameIndex(a);

    const receiver = TypeRef{ .name = "String", .nullable = false, .args = &.{} };
    const source_body = m.resolveExtensionCall("sourceOnly", receiver, &.{}, .{
        .caller_file = FileId.from(0),
        .caller_package = "app",
    });
    try testing.expectEqual(source.int(), source_body.target.?.int());

    const unshadowed = m.resolveExtensionCall("isBlank", receiver, &.{}, .{
        .caller_file = FileId.from(0),
        .caller_package = "app",
    });
    try testing.expectEqual(stdlib.int(), unshadowed.target.?.int());
    const shadowed = m.resolveExtensionCall("isBlank", receiver, &.{}, .{
        .caller_file = FileId.from(0),
        .caller_package = "app",
        .lexical_owner = "Scope",
    });
    try testing.expectEqual(member, shadowed.target.?);

    const unresolved = m.resolveExtensionCall("headerOnly", receiver, &.{}, .{
        .caller_file = FileId.from(0),
        .caller_package = "app",
    });
    try testing.expect(unresolved.target == null);

    const generic_shadow = m.resolveExtensionCall("tag", .{
        .name = "List",
        .nullable = false,
        .args = string_receiver_args,
    }, &.{}, .{
        .caller_file = FileId.from(0),
        .caller_package = "app",
    });
    try testing.expectEqual(generic_top.int(), generic_shadow.target.?.int());
    const scoped_generic_shadow = m.resolveExtensionCall("tag", .{
        .name = "List",
        .nullable = false,
        .args = string_receiver_args,
    }, &.{}, .{
        .caller_file = FileId.from(0),
        .caller_package = "app",
        .implicit_dispatch_owners = &.{"Scope"},
    });
    try testing.expect(scoped_generic_shadow.target == null);

    const string_arg = [_]applicability.ArgShape{.{
        .ty = .{ .name = "String", .nullable = false, .args = &.{} },
    }};
    const hidden_object = m.resolveExtensionCall("startsWith", receiver, &string_arg, .{
        .caller_file = FileId.from(0),
        .caller_package = "app",
    });
    try testing.expectEqual(starts_with.int(), hidden_object.target.?.int());

    const visible_object = m.resolveExtensionCall("startsWith", receiver, &string_arg, .{
        .caller_file = FileId.from(0),
        .caller_package = "app",
        .implicit_dispatch_owners = &.{"StringBuilder"},
        .lexical_owner = "HiddenExtensions",
    });
    try testing.expectEqual(hidden_starts_with, visible_object.target.?);
}

test "member extension resolution keeps qualified declaring owners distinct" {
    const a = testing.allocator;
    var m = Module.default(a);
    defer freeTestModule(&m, a);

    const left_owner = try m.addClass(a, .{
        .id = ClassId.from(0),
        .name = "Scope",
        .fqn = "left.Scope",
        .package = "left",
        .primary_params = &.{},
        .methods = &.{},
        .init_block = null,
        .companion = null,
        .supertypes = &.{},
    });
    const right_owner = try m.addClass(a, .{
        .id = ClassId.from(0),
        .name = "Scope",
        .fqn = "right.Scope",
        .package = "right",
        .primary_params = &.{},
        .methods = &.{},
        .init_block = null,
        .companion = null,
        .supertypes = &.{},
    });
    const left = try pushTestFuncOpts(
        &m,
        a,
        "tag",
        "left.Scope.tag",
        "left",
        0,
        .{ .extension = true },
    );
    const right = try pushTestFuncOpts(
        &m,
        a,
        "tag",
        "right.Scope.tag",
        "right",
        0,
        .{ .extension = true },
    );
    for ([_]struct { fid: FuncId, owner: ClassId, fqn: []const u8 }{
        .{ .fid = left, .owner = left_owner, .fqn = "left.Scope" },
        .{ .fid = right, .owner = right_owner, .fqn = "right.Scope" },
    }) |entry| {
        m.funcs.items[entry.fid.int()].kind = .member_extension;
        m.funcs.items[entry.fid.int()].params[0].ty = .{
            .name = "String",
            .nullable = false,
            .args = &.{},
        };
        try m.registry.member_ext_owner_class.put(entry.fid, entry.fqn);
        try m.decl_sigs.put(entry.fid.int(), .{
            .enclosing_class = entry.owner,
            .receiver_ty = m.funcs.items[entry.fid.int()].params[0].ty,
            .arity = .{ .required = 0, .total = 0, .has_vararg = false },
            .sig = &.{},
            .kind = .member_extension,
            .has_body = true,
        });
    }
    try m.rebuildFuncNameIndex(a);

    const resolved = m.resolveExtensionCall(
        "tag",
        .{ .name = "String", .nullable = false, .args = &.{} },
        &.{},
        .{
            .caller_file = FileId.from(0),
            .caller_package = "left",
            .lexical_owner = "Scope",
        },
    );
    try testing.expectEqual(left, resolved.target.?);
    try testing.expectEqual(left_owner, resolved.dispatch_owner.?);

    const right_innermost = m.resolveExtensionCall(
        "tag",
        .{ .name = "String", .nullable = false, .args = &.{} },
        &.{},
        .{
            .caller_file = FileId.from(0),
            .caller_package = "left",
            .implicit_dispatch_owners = &.{ "right.Scope", "left.Scope" },
        },
    );
    try testing.expectEqual(right, right_innermost.target.?);
    try testing.expectEqual(right_owner, right_innermost.dispatch_owner.?);

    const left_innermost = m.resolveExtensionCall(
        "tag",
        .{ .name = "String", .nullable = false, .args = &.{} },
        &.{},
        .{
            .caller_file = FileId.from(0),
            .caller_package = "right",
            .implicit_dispatch_owners = &.{ "left.Scope", "right.Scope" },
        },
    );
    try testing.expectEqual(left, left_innermost.target.?);
    try testing.expectEqual(left_owner, left_innermost.dispatch_owner.?);
}

test "extension resolver does not erase incompatible generic receiver arguments" {
    const a = testing.allocator;
    var m = Module.default(a);
    defer freeTestModule(&m, a);

    const ext = try pushTestFuncOpts(&m, a, "consume", "app.consume", "app", 0, .{
        .extension = true,
    });
    m.funcs.items[ext.int()].kind = .top_level_extension;
    const int_args = try a.alloc(TypeRef, 1);
    defer a.free(int_args);
    int_args[0] = .{ .name = "Int", .nullable = false, .args = &.{} };
    m.funcs.items[ext.int()].params[0].ty = .{
        .name = "Iterable",
        .nullable = false,
        .args = int_args,
    };
    const broad = try pushTestFuncOpts(&m, a, "consume", "app.consume", "app", 0, .{
        .extension = true,
    });
    m.funcs.items[broad.int()].kind = .top_level_extension;
    m.funcs.items[broad.int()].params[0].ty.name = "Any";
    const generic = try pushTestFuncOpts(&m, a, "genericConsume", "app.genericConsume", "app", 0, .{
        .extension = true,
    });
    m.funcs.items[generic.int()].kind = .top_level_extension;
    const generic_args = try a.alloc(TypeRef, 1);
    defer a.free(generic_args);
    generic_args[0] = .{ .name = "T", .nullable = false, .args = &.{} };
    m.funcs.items[generic.int()].params[0].ty = .{
        .name = "Iterable",
        .nullable = false,
        .args = generic_args,
    };
    var type_params: std.ArrayList([]const u8) = .empty;
    try type_params.append(a, "T");
    try m.registry.func_type_params.put(generic, type_params);
    try m.rebuildFuncNameIndex(a);

    const string_args = try a.alloc(TypeRef, 1);
    defer a.free(string_args);
    string_args[0] = .{ .name = "String", .nullable = false, .args = &.{} };
    const resolved = m.resolveExtensionCall("consume", .{
        .name = "Iterable",
        .nullable = false,
        .args = string_args,
    }, &.{}, .{
        .caller_file = FileId.from(0),
        .caller_package = "app",
    });
    try testing.expectEqual(broad.int(), resolved.target.?.int());

    const generic_proven = m.resolveExtensionCall("genericConsume", .{
        .name = "Iterable",
        .nullable = false,
        .args = string_args,
    }, &.{}, .{
        .caller_file = FileId.from(0),
        .caller_package = "app",
    });
    try testing.expectEqual(generic, generic_proven.target.?);
}

test "extension resolver retains a unique generic receiver lambda target" {
    const a = testing.allocator;
    var m = Module.default(a);
    defer freeTestModule(&m, a);

    const apply = try pushTestFuncOpts(&m, a, "apply", "kotlin.apply", "kotlin", 1, .{
        .extension = true,
        .param_ty = "Function0",
    });
    m.funcs.items[apply.int()].kind = .top_level_extension;
    m.funcs.items[apply.int()].params[0].ty.name = "T";
    const function_args = try a.alloc(TypeRef, 2);
    defer a.free(function_args);
    function_args[0] = .{ .name = "T", .nullable = false, .args = &.{} };
    function_args[1] = .{ .name = "Unit", .nullable = false, .args = &.{} };
    m.funcs.items[apply.int()].params[1].ty.args = function_args;
    var type_params: std.ArrayList([]const u8) = .empty;
    try type_params.append(a, "T");
    try type_params.append(a, "R");
    try m.registry.func_type_params.put(apply, type_params);
    try m.rebuildFuncNameIndex(a);

    const args = [_]applicability.ArgShape{.{
        .is_lambda = true,
        .lambda_arity = 0,
        .lambda_is_literal = true,
    }};
    const resolved = m.resolveExtensionCall("apply", .{
        .name = "LongArray",
        .nullable = false,
        .args = &.{},
    }, &args, .{
        .caller_file = FileId.from(0),
        .caller_package = "app",
    });
    try testing.expectEqual(apply, resolved.target.?);
}

test "callable extension properties resolve instance and companion receivers" {
    const a = testing.allocator;
    var m = Module.default(a);
    defer freeTestModule(&m, a);

    var actions: std.ArrayList(ModuleRegistry.CallableExtensionProp) = .empty;
    try actions.append(a, .{
        .fqn = "app.action",
        .package = "app",
        .receiver = "Widget",
        .file = FileId.from(1),
        .value_arity = 1,
        .is_private = false,
    });
    try m.registry.callable_extension_props.put("action", actions);

    const action = m.resolveCallableExtensionProperty(
        "action",
        "Widget",
        false,
        1,
        "app",
        FileId.from(0),
    ) orelse return error.TestUnexpectedResult;
    try testing.expectEqualStrings("app.action", action.fqn);
    try testing.expect(m.resolveCallableExtensionProperty(
        "action",
        "Widget",
        false,
        0,
        "app",
        FileId.from(0),
    ) == null);

    var insets: std.ArrayList(ModuleRegistry.CallableExtensionProp) = .empty;
    try insets.append(a, .{
        .fqn = "app.systemBars",
        .package = "app",
        .receiver = "WindowInsets.Companion",
        .file = FileId.from(1),
        .value_arity = 0,
        .is_private = false,
    });
    try m.registry.callable_extension_props.put("systemBars", insets);

    const system_bars = m.resolveCallableExtensionProperty(
        "systemBars",
        "WindowInsets",
        true,
        0,
        "app",
        FileId.from(0),
    ) orelse return error.TestUnexpectedResult;
    try testing.expectEqualStrings("app.systemBars", system_bars.fqn);
    try testing.expect(m.resolveCallableExtensionProperty(
        "systemBars",
        "WindowInsets",
        false,
        0,
        "app",
        FileId.from(0),
    ) == null);
}

test "extension resolver ranks proven generic argument structure" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var m = Module.default(a);
    defer m.deinit(a);

    const element = try pushTestFuncOpts(&m, a, "plus", "app.plus", "app", 1, .{
        .extension = true,
        .param_ty = "T",
    });
    const array = try pushTestFuncOpts(&m, a, "plus", "app.plus", "app", 1, .{
        .extension = true,
        .param_ty = "Array",
    });
    const sequence = try pushTestFuncOpts(&m, a, "plus", "app.plus", "app", 1, .{
        .extension = true,
        .param_ty = "Sequence",
    });
    const t_args = try a.alloc(TypeRef, 1);
    t_args[0] = .{ .name = "T", .nullable = false, .args = &.{} };
    for ([_]FuncId{ element, array, sequence }) |fid| {
        m.funcs.items[fid.int()].kind = .top_level_extension;
        m.funcs.items[fid.int()].params[0].ty = .{
            .name = "Collection",
            .nullable = false,
            .args = t_args,
        };
        var type_params: std.ArrayList([]const u8) = .empty;
        try type_params.append(a, "T");
        try m.registry.func_type_params.put(fid, type_params);
    }
    m.funcs.items[array.int()].params[1].ty.args = t_args;
    m.funcs.items[sequence.int()].params[1].ty.args = t_args;
    m.funcs.items[sequence.int()].return_ty = .{
        .name = "Sequence",
        .nullable = false,
        .args = t_args,
    };
    try m.rebuildFuncNameIndex(a);

    const int_args = try a.alloc(TypeRef, 1);
    int_args[0] = .{ .name = "Int", .nullable = false, .args = &.{} };
    const receiver = TypeRef{
        .name = "Collection",
        .nullable = false,
        .args = int_args,
    };
    const args = [_]applicability.ArgShape{.{
        .ty = .{ .name = "Sequence", .nullable = false, .args = int_args },
    }};
    const resolved = m.resolveExtensionCall("plus", receiver, &args, .{
        .caller_file = FileId.from(0),
        .caller_package = "app",
    });
    try testing.expectEqual(sequence, resolved.target.?);

    var return_ty = (try m.instantiatedCallReturnType(
        a,
        sequence,
        receiver,
        null,
        &args,
        &.{},
    )).?;
    defer return_ty.deinit(a);
    try testing.expectEqualStrings("Sequence", return_ty.name);
    try testing.expectEqual(@as(usize, 1), return_ty.args.len);
    try testing.expectEqualStrings("Int", return_ty.args[0].name);
}

test "member return instantiation separates class and function type parameters" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var m = Module.default(a);
    defer m.deinit(a);

    const box = try m.addClass(a, .{
        .id = ClassId.from(0),
        .name = "Box",
        .fqn = "app.Box",
        .package = "app",
        .type_params = &.{"String"},
        .primary_params = &.{},
        .methods = &.{},
        .init_block = null,
        .companion = null,
        .supertypes = &.{},
    });
    const class_identity = try classTypeParamIdentity(a, box, "String");
    const class_arg = try a.dupe(TypeRef, &.{
        .{ .name = class_identity, .nullable = false, .args = &.{} },
    });
    const actual_arg = try a.dupe(TypeRef, &.{
        .{ .name = "Int", .nullable = false, .args = &.{} },
    });
    const box_pattern = TypeRef{
        .name = "app.Box",
        .nullable = false,
        .args = class_arg,
    };
    const box_int = TypeRef{
        .name = "app.Box",
        .nullable = false,
        .args = actual_arg,
    };

    const get = try pushTestFuncOpts(&m, a, "get", "app.Box.get", "app", 0, .{
        .extension = true,
    });
    m.funcs.items[get.int()].kind = .instance_method;
    m.funcs.items[get.int()].params[0].ty = box_pattern;
    m.funcs.items[get.int()].return_ty = class_arg[0];
    try m.decl_sigs.put(get.int(), .{
        .enclosing_class = box,
        .arity = .{ .required = 0, .total = 0, .has_vararg = false },
        .sig = &.{},
        .kind = .instance_method,
        .has_body = true,
    });

    var class_result = (try m.instantiatedCallReturnType(
        a,
        get,
        box_int,
        box_int,
        &.{},
        &.{},
    )).?;
    defer class_result.deinit(a);
    try testing.expectEqualStrings("Int", class_result.name);

    const shadow = try pushTestFuncOpts(
        &m,
        a,
        "shadow",
        "app.Box.shadow",
        "app",
        1,
        .{ .extension = true },
    );
    m.funcs.items[shadow.int()].kind = .instance_method;
    m.funcs.items[shadow.int()].params[0].ty = box_pattern;
    const function_param_ty = TypeRef{
        .name = "String",
        .nullable = false,
        .args = &.{},
    };
    m.funcs.items[shadow.int()].params[1].ty = function_param_ty;
    m.funcs.items[shadow.int()].return_ty = function_param_ty;
    var function_params: std.ArrayList([]const u8) = .empty;
    try function_params.append(a, "String");
    try m.registry.func_type_params.put(shadow, function_params);
    const shadow_sig = try a.dupe(TypeRef, &.{function_param_ty});
    try m.decl_sigs.put(shadow.int(), .{
        .enclosing_class = box,
        .arity = .{ .required = 1, .total = 1, .has_vararg = false },
        .sig = shadow_sig,
        .kind = .instance_method,
        .has_body = true,
    });
    const bool_args = [_]applicability.ArgShape{.{
        .ty = .{ .name = "Boolean", .nullable = false, .args = &.{} },
    }};
    var function_result = (try m.instantiatedCallReturnType(
        a,
        shadow,
        box_int,
        box_int,
        &bool_args,
        &.{},
    )).?;
    defer function_result.deinit(a);
    try testing.expectEqualStrings("Boolean", function_result.name);

    const qualified_args = try a.dupe(TypeRef, &.{
        .{ .name = "#qual:kotlin.String", .nullable = false, .args = &.{} },
    });
    const qualified_string = TypeRef{
        .name = "String",
        .nullable = false,
        .args = qualified_args,
    };
    const literal = try pushTestFuncOpts(
        &m,
        a,
        "literal",
        "app.Box.literal",
        "app",
        0,
        .{ .extension = true },
    );
    m.funcs.items[literal.int()].kind = .instance_method;
    m.funcs.items[literal.int()].params[0].ty = box_pattern;
    m.funcs.items[literal.int()].return_ty = qualified_string;
    try m.decl_sigs.put(literal.int(), .{
        .enclosing_class = box,
        .arity = .{ .required = 0, .total = 0, .has_vararg = false },
        .sig = &.{},
        .kind = .instance_method,
        .has_body = true,
    });
    var literal_result = (try m.instantiatedCallReturnType(
        a,
        literal,
        box_int,
        box_int,
        &.{},
        &.{},
    )).?;
    defer literal_result.deinit(a);
    try testing.expectEqualStrings("String", literal_result.name);
    try testing.expectEqualStrings(
        "#qual:kotlin.String",
        literal_result.args[literal_result.args.len - 1].name,
    );
}

test "extension return instantiation projects a subtype receiver" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var m = Module.default(a);
    defer m.deinit(a);

    const parent = try m.addClass(a, .{
        .id = ClassId.from(0),
        .name = "Parent",
        .fqn = "app.Parent",
        .package = "app",
        .type_params = &.{"T"},
        .primary_params = &.{},
        .methods = &.{},
        .init_block = null,
        .companion = null,
        .supertypes = &.{},
    });
    const t_args = try a.dupe(TypeRef, &.{
        .{ .name = "T", .nullable = false, .args = &.{} },
    });
    const supers = try a.dupe(ClassId, &.{parent});
    const super_refs = try a.dupe(TypeRef, &.{
        .{ .name = "app.Parent", .nullable = false, .args = t_args },
    });
    _ = try m.addClass(a, .{
        .id = ClassId.from(0),
        .name = "Child",
        .fqn = "app.Child",
        .package = "app",
        .type_params = &.{"T"},
        .primary_params = &.{},
        .methods = &.{},
        .init_block = null,
        .companion = null,
        .supertypes = supers,
        .supertype_refs = super_refs,
    });

    const wrap = try pushTestFuncOpts(&m, a, "wrap", "app.wrap", "app", 0, .{
        .extension = true,
    });
    m.funcs.items[wrap.int()].kind = .top_level_extension;
    m.funcs.items[wrap.int()].params[0].ty = .{
        .name = "app.Parent",
        .nullable = false,
        .args = t_args,
    };
    m.funcs.items[wrap.int()].return_ty = .{
        .name = "app.Child",
        .nullable = false,
        .args = t_args,
    };
    var type_params: std.ArrayList([]const u8) = .empty;
    try type_params.append(a, "T");
    try m.registry.func_type_params.put(wrap, type_params);

    const int_args = try a.dupe(TypeRef, &.{
        .{ .name = "Int", .nullable = false, .args = &.{} },
    });
    var result = (try m.instantiatedCallReturnType(
        a,
        wrap,
        .{ .name = "app.Child", .nullable = false, .args = int_args },
        null,
        &.{},
        &.{},
    )).?;
    defer result.deinit(a);
    try testing.expectEqualStrings("app.Child", result.name);
    try testing.expectEqual(@as(usize, 1), result.args.len);
    try testing.expectEqualStrings("Int", result.args[0].name);

    const shadow_parent = try m.addClass(a, .{
        .id = ClassId.from(0),
        .name = "ShadowParent",
        .fqn = "app.ShadowParent",
        .package = "app",
        .type_params = &.{"T"},
        .primary_params = &.{},
        .methods = &.{},
        .init_block = null,
        .companion = null,
        .supertypes = &.{},
    });
    const qualified_string_args = try a.dupe(TypeRef, &.{
        .{ .name = "#qual:kotlin.String", .nullable = false, .args = &.{} },
    });
    const shadow_supers = try a.dupe(ClassId, &.{shadow_parent});
    const shadow_super_refs = try a.dupe(TypeRef, &.{
        .{
            .name = "app.ShadowParent",
            .nullable = false,
            .args = try a.dupe(TypeRef, &.{
                .{ .name = "String", .nullable = false, .args = qualified_string_args },
            }),
        },
    });
    const shadow_child = try m.addClass(a, .{
        .id = ClassId.from(0),
        .name = "ShadowChild",
        .fqn = "app.ShadowChild",
        .package = "app",
        .type_params = &.{"String"},
        .primary_params = &.{},
        .methods = &.{},
        .init_block = null,
        .companion = null,
        .supertypes = shadow_supers,
        .supertype_refs = shadow_super_refs,
    });
    const shadow_actual_args = try a.dupe(TypeRef, &.{
        .{ .name = "Int", .nullable = false, .args = &.{} },
    });
    const projected = (try m.projectTypeToClass(
        a,
        .{
            .name = m.classes.items[shadow_child.int()].fqn,
            .nullable = false,
            .args = shadow_actual_args,
        },
        shadow_parent,
    )).?;
    try testing.expectEqualStrings("app.ShadowParent", projected.name);
    try testing.expectEqual(@as(usize, 1), projected.args.len);
    try testing.expectEqualStrings("String", projected.args[0].name);
    try testing.expectEqualStrings(
        "#qual:kotlin.String",
        projected.args[0].args[projected.args[0].args.len - 1].name,
    );
}

test "member extension return instantiation uses the dispatch receiver" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var m = Module.default(a);
    defer m.deinit(a);

    const scope = try m.addClass(a, .{
        .id = ClassId.from(0),
        .name = "Scope",
        .fqn = "app.Scope",
        .package = "app",
        .type_params = &.{"T"},
        .primary_params = &.{},
        .methods = &.{},
        .init_block = null,
        .companion = null,
        .supertypes = &.{},
    });
    const value = try pushTestFuncOpts(&m, a, "value", "app.Scope.value", "app", 0, .{
        .extension = true,
    });
    const class_identity = try classTypeParamIdentity(a, scope, "T");
    m.funcs.items[value.int()].kind = .member_extension;
    m.funcs.items[value.int()].params[0].ty = .{
        .name = "String",
        .nullable = false,
        .args = &.{},
    };
    m.funcs.items[value.int()].return_ty = .{
        .name = class_identity,
        .nullable = false,
        .args = &.{},
    };
    try m.decl_sigs.put(value.int(), .{
        .enclosing_class = scope,
        .receiver_ty = m.funcs.items[value.int()].params[0].ty,
        .arity = .{ .required = 0, .total = 0, .has_vararg = false },
        .sig = &.{},
        .kind = .member_extension,
        .has_body = true,
    });
    const scope_args = try a.dupe(TypeRef, &.{
        .{ .name = "Int", .nullable = false, .args = &.{} },
    });
    try testing.expect((try m.instantiatedCallReturnType(
        a,
        value,
        .{ .name = "String", .nullable = false, .args = &.{} },
        null,
        &.{},
        &.{},
    )) == null);
    var result = (try m.instantiatedCallReturnType(
        a,
        value,
        .{ .name = "String", .nullable = false, .args = &.{} },
        .{ .name = "app.Scope", .nullable = false, .args = scope_args },
        &.{},
        &.{},
    )).?;
    defer result.deinit(a);
    try testing.expectEqualStrings("Int", result.name);
}

test "extension resolver substitutes bounded caller type parameters" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var m = Module.default(a);
    defer m.deinit(a);

    const generic = try pushTestFuncOpts(&m, a, "minOrNull", "kotlin.collections.minOrNull", "kotlin.collections", 0, .{
        .extension = true,
    });
    m.funcs.items[generic.int()].kind = .top_level_extension;
    const generic_receiver_args = try a.alloc(TypeRef, 1);
    generic_receiver_args[0] = .{ .name = "out#E", .nullable = false, .args = &.{} };
    m.funcs.items[generic.int()].params[0].ty = .{
        .name = "Array",
        .nullable = false,
        .args = generic_receiver_args,
    };
    var generic_params: std.ArrayList([]const u8) = .empty;
    try generic_params.append(a, "E");
    try m.registry.func_type_params.put(generic, generic_params);
    try m.registry.func_type_param_bounds.put(generic, &.{
        .{ .param = "E", .bound = "Comparable" },
    });

    const doubles = try pushTestFuncOpts(&m, a, "minOrNull", "kotlin.collections.minOrNull", "kotlin.collections", 0, .{
        .extension = true,
    });
    m.funcs.items[doubles.int()].kind = .top_level_extension;
    const double_receiver_args = try a.alloc(TypeRef, 1);
    double_receiver_args[0] = .{ .name = "Double", .nullable = false, .args = &.{} };
    m.funcs.items[doubles.int()].params[0].ty = .{
        .name = "Array",
        .nullable = false,
        .args = double_receiver_args,
    };
    try m.rebuildFuncNameIndex(a);

    const actual_args = try a.alloc(TypeRef, 1);
    actual_args[0] = .{ .name = "T", .nullable = false, .args = &.{} };
    const actual_receiver = TypeRef{
        .name = "Array",
        .nullable = false,
        .args = actual_args,
    };
    const actual_bounds = [_]ModuleRegistry.TypeParamBound{
        .{ .param = "T", .bound = "Comparable" },
    };
    const declared_bounds = try m.declaredTypeParamBounds(a, generic);
    try testing.expect(m.staticBoundProofComplete(
        declared_bounds[0],
        declared_bounds,
        0,
    ));
    try testing.expect(try m.staticTypeIsSubtypeWithBounds(
        a,
        .{ .name = "T", .nullable = false, .args = &.{} },
        .{ .name = "Comparable", .nullable = false, .args = &.{} },
        &actual_bounds,
    ));
    try testing.expect(try m.staticGenericReceiverApplicable(
        a,
        actual_receiver,
        m.funcs.items[generic.int()].params[0].ty,
        declared_bounds,
        &actual_bounds,
    ));
    const resolved = m.resolveExtensionCall("minOrNull", actual_receiver, &.{}, .{
        .caller_file = FileId.from(0),
        .caller_package = "app",
        .actual_type_param_bounds = &actual_bounds,
    });
    try testing.expectEqual(generic, resolved.target.?);

    const comparable_args = try a.alloc(TypeRef, 1);
    const comparable_type_args = try a.alloc(TypeRef, 1);
    comparable_type_args[0] = .{ .name = "Any", .nullable = false, .args = &.{} };
    comparable_args[0] = .{
        .name = "Comparable",
        .nullable = false,
        .args = comparable_type_args,
    };
    const concrete = m.resolveExtensionCall("minOrNull", .{
        .name = "Array",
        .nullable = false,
        .args = comparable_args,
    }, &.{}, .{
        .caller_file = FileId.from(0),
        .caller_package = "app",
    });
    try testing.expectEqual(generic, concrete.target.?);
}

test "a tie on the lambda return alone still lends the lambda param types" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var m = Module.default(a);
    defer m.deinit(a);

    // Two `Iterable<T>.flatMapX(transform)` overloads whose lambdas differ
    // only in RETURN type (`Iterable<R>` vs `Sequence<R>`) — the
    // `flatMapIndexed` shape. The tie is genuine, but both candidates hand
    // the closure the same parameter types, so param_rep names one of them.
    const fids = [_]FuncId{
        try pushTestFuncOpts(&m, a, "flatMapX", "kotlin.collections.flatMapX", "kotlin.collections", 1, .{ .extension = true }),
        try pushTestFuncOpts(&m, a, "flatMapX", "kotlin.collections.flatMapX", "kotlin.collections", 1, .{ .extension = true }),
    };
    const lambda_return_heads = [_][]const u8{ "Iterable", "Sequence" };
    for (fids, lambda_return_heads) |fid, ret_head| {
        m.funcs.items[fid.int()].kind = .top_level_extension;
        const recv_args = try a.alloc(TypeRef, 1);
        recv_args[0] = .{ .name = "T", .nullable = false, .args = &.{} };
        m.funcs.items[fid.int()].params[0].ty = .{ .name = "Iterable", .nullable = false, .args = recv_args };
        const ret_args = try a.alloc(TypeRef, 1);
        ret_args[0] = .{ .name = "R", .nullable = false, .args = &.{} };
        const lam_args = try a.alloc(TypeRef, 3);
        lam_args[0] = .{ .name = "Int", .nullable = false, .args = &.{} };
        lam_args[1] = .{ .name = "T", .nullable = false, .args = &.{} };
        lam_args[2] = .{ .name = ret_head, .nullable = false, .args = ret_args };
        m.funcs.items[fid.int()].params[1].ty = .{ .name = "Function2", .nullable = false, .args = lam_args };
        var tps: std.ArrayList([]const u8) = .empty;
        try tps.append(a, "T");
        try tps.append(a, "R");
        try m.registry.func_type_params.put(fid, tps);
    }
    try m.rebuildFuncNameIndex(a);

    const recv_string = try a.alloc(TypeRef, 1);
    recv_string[0] = .{ .name = "String", .nullable = false, .args = &.{} };
    var shapes = [_]applicability.ArgShape{
        .{ .is_lambda = true, .lambda_arity = 2 },
    };
    const res = m.resolveExtensionCall(
        "flatMapX",
        .{ .name = "Iterable", .nullable = false, .args = recv_string },
        &shapes,
        .{ .caller_file = FileId.from(0), .caller_package = "app" },
    );
    try testing.expect(res.target == null);
    try testing.expect(res.applicable);
    try testing.expectEqual(fids[0], res.param_rep.?);

    // Overloads that also differ in a lambda PARAMETER position lend
    // nothing: whichever wins changes what the closure body sees.
    const third = try pushTestFuncOpts(&m, a, "flatMapY", "kotlin.collections.flatMapY", "kotlin.collections", 1, .{ .extension = true });
    const fourth = try pushTestFuncOpts(&m, a, "flatMapY", "kotlin.collections.flatMapY", "kotlin.collections", 1, .{ .extension = true });
    const param_heads = [_][]const u8{ "Int", "Long" };
    for ([_]FuncId{ third, fourth }, param_heads) |fid, param_head| {
        m.funcs.items[fid.int()].kind = .top_level_extension;
        const recv_args = try a.alloc(TypeRef, 1);
        recv_args[0] = .{ .name = "T", .nullable = false, .args = &.{} };
        m.funcs.items[fid.int()].params[0].ty = .{ .name = "Iterable", .nullable = false, .args = recv_args };
        const lam_args = try a.alloc(TypeRef, 3);
        lam_args[0] = .{ .name = param_head, .nullable = false, .args = &.{} };
        lam_args[1] = .{ .name = "T", .nullable = false, .args = &.{} };
        lam_args[2] = .{ .name = "Any", .nullable = false, .args = &.{} };
        m.funcs.items[fid.int()].params[1].ty = .{ .name = "Function2", .nullable = false, .args = lam_args };
        var tps: std.ArrayList([]const u8) = .empty;
        try tps.append(a, "T");
        try m.registry.func_type_params.put(fid, tps);
    }
    try m.rebuildFuncNameIndex(a);
    const res2 = m.resolveExtensionCall(
        "flatMapY",
        .{ .name = "Iterable", .nullable = false, .args = recv_string },
        &shapes,
        .{ .caller_file = FileId.from(0), .caller_package = "app" },
    );
    try testing.expect(res2.target == null);
    try testing.expect(res2.param_rep == null);
}

test "named arguments may skip defaulted parameters and still resolve" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var m = Module.default(a);
    defer m.deinit(a);

    // The rangesDelimitedBy shape: `f(x, ignoreCase = ..., limit = ...)`
    // skips the defaulted `startIndex`, and the CharArray/Array overload
    // pair is discriminated by the first positional argument.
    const heads = [_][]const u8{ "CharArray", "IntArray" };
    var fids: [2]FuncId = undefined;
    for (heads, 0..) |head, idx| {
        const fid = try pushTestFuncOpts(&m, a, "myRanges", "app.myRanges", "app", 4, .{ .extension = true });
        m.funcs.items[fid.int()].kind = .top_level_extension;
        m.funcs.items[fid.int()].params[0].ty = .{ .name = "CharSequence", .nullable = false, .args = &.{} };
        m.funcs.items[fid.int()].params[1] = .{ .name = "delims", .ty = .{ .name = head, .nullable = false, .args = &.{} }, .default = null };
        m.funcs.items[fid.int()].params[2] = .{ .name = "startIndex", .ty = .{ .name = "Int", .nullable = false, .args = &.{} }, .default = null, .has_default = true };
        m.funcs.items[fid.int()].params[3] = .{ .name = "ignoreCase", .ty = .{ .name = "Boolean", .nullable = false, .args = &.{} }, .default = null, .has_default = true };
        m.funcs.items[fid.int()].params[4] = .{ .name = "limit", .ty = .{ .name = "Int", .nullable = false, .args = &.{} }, .default = null, .has_default = true };
        fids[idx] = fid;
    }
    try m.rebuildFuncNameIndex(a);

    var shapes = [_]applicability.ArgShape{
        .{ .ty = .{ .name = "CharArray", .nullable = false, .args = &.{} } },
        .{ .ty = .{ .name = "Boolean", .nullable = false, .args = &.{} }, .named = "ignoreCase" },
        .{ .ty = .{ .name = "Int", .nullable = false, .args = &.{} }, .named = "limit" },
    };
    const res = m.resolveExtensionCall(
        "myRanges",
        .{ .name = "CharSequence", .nullable = false, .args = &.{} },
        &shapes,
        .{ .caller_file = FileId.from(0), .caller_package = "app" },
    );
    // The skip COMMITS: the emitted call carries the names and the host
    // boundary binds them by declaration parameter.
    try testing.expectEqual(fids[0], res.target.?);

    // A named argument no parameter carries still drops the candidate.
    var wrong = [_]applicability.ArgShape{
        .{ .ty = .{ .name = "CharArray", .nullable = false, .args = &.{} } },
        .{ .ty = .{ .name = "Boolean", .nullable = false, .args = &.{} }, .named = "nope" },
    };
    const res2 = m.resolveExtensionCall(
        "myRanges",
        .{ .name = "CharSequence", .nullable = false, .args = &.{} },
        &wrong,
        .{ .caller_file = FileId.from(0), .caller_package = "app" },
    );
    try testing.expect(res2.target == null);

    // A skipped parameter WITHOUT a default keeps the strict rule: naming
    // `limit` past a required `mustGive` defers rather than committing.
    const strict = try pushTestFuncOpts(&m, a, "strictRanges", "app.strictRanges", "app", 3, .{ .extension = true });
    m.funcs.items[strict.int()].kind = .top_level_extension;
    m.funcs.items[strict.int()].params[0].ty = .{ .name = "CharSequence", .nullable = false, .args = &.{} };
    m.funcs.items[strict.int()].params[1] = .{ .name = "delims", .ty = .{ .name = "CharArray", .nullable = false, .args = &.{} }, .default = null };
    m.funcs.items[strict.int()].params[2] = .{ .name = "mustGive", .ty = .{ .name = "Int", .nullable = false, .args = &.{} }, .default = null };
    m.funcs.items[strict.int()].params[3] = .{ .name = "limit", .ty = .{ .name = "Int", .nullable = false, .args = &.{} }, .default = null, .has_default = true };
    try m.rebuildFuncNameIndex(a);
    var skip_required = [_]applicability.ArgShape{
        .{ .ty = .{ .name = "CharArray", .nullable = false, .args = &.{} } },
        .{ .ty = .{ .name = "Int", .nullable = false, .args = &.{} }, .named = "limit" },
    };
    const res3 = m.resolveExtensionCall(
        "strictRanges",
        .{ .name = "CharSequence", .nullable = false, .args = &.{} },
        &skip_required,
        .{ .caller_file = FileId.from(0), .caller_package = "app" },
    );
    try testing.expect(res3.target == null);
}

test "dependent bound with unbound referenced parameter does not refute" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var m = Module.default(a);
    defer m.deinit(a);

    // `fun <S, T : S> Iterable<T>.reduce(op: (S, T) -> S)` against an
    // `Iterable<String>` receiver: binding produces only `T := String`, and
    // `S` (value-parameter and return positions only) stays free for the
    // call's inference, so `T <: S` cannot refute the candidate.
    const type_vars = [_]TypeRef{.{ .name = "T", .nullable = false, .args = &.{} }};
    const strings = [_]TypeRef{.{ .name = "String", .nullable = false, .args = &.{} }};
    const pattern = TypeRef{ .name = "Iterable", .nullable = false, .args = @constCast(&type_vars) };
    const actual = TypeRef{ .name = "Iterable", .nullable = false, .args = @constCast(&strings) };
    const declared = [_]ModuleRegistry.TypeParamBound{
        .{ .param = "S", .bound = "kotlin.Any" },
        .{ .param = "T", .bound = "S" },
    };
    try testing.expect(try m.staticGenericReceiverApplicable(
        a,
        actual,
        pattern,
        &declared,
        &.{},
    ));
    // A dependent bound whose referenced parameter IS bound still proves:
    // `Map<K, V>.getRid(k: K)` shapes bind both sides from the receiver.
    const bound_both = [_]ModuleRegistry.TypeParamBound{
        .{ .param = "T", .bound = "V" },
        .{ .param = "V", .bound = "kotlin.Any" },
    };
    const pair_vars = [_]TypeRef{
        .{ .name = "T", .nullable = false, .args = &.{} },
        .{ .name = "V", .nullable = false, .args = &.{} },
    };
    const int_string = [_]TypeRef{
        .{ .name = "Int", .nullable = false, .args = &.{} },
        .{ .name = "String", .nullable = false, .args = &.{} },
    };
    const pair_pattern = TypeRef{ .name = "Pair", .nullable = false, .args = @constCast(&pair_vars) };
    const pair_actual = TypeRef{ .name = "Pair", .nullable = false, .args = @constCast(&int_string) };
    try testing.expect(!(try m.staticGenericReceiverApplicable(
        a,
        pair_actual,
        pair_pattern,
        &bound_both,
        &.{},
    )));
}

test "static subtype proof respects variance, bottom, stars, and aliases" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var m = Module.default(a);
    defer m.deinit(a);

    _ = try m.addClass(a, .{
        .id = ClassId.from(0),
        .name = "List",
        .fqn = "kotlin.collections.List",
        .package = "kotlin.collections",
        .primary_params = &.{},
        .methods = &.{},
        .init_block = null,
        .companion = null,
        .supertypes = &.{},
        .type_params = &.{"T"},
        .type_param_variance = &.{.Out},
        .is_interface = true,
        .is_abstract = true,
    });
    _ = try m.addClass(a, .{
        .id = ClassId.from(0),
        .name = "MutableList",
        .fqn = "kotlin.collections.MutableList",
        .package = "kotlin.collections",
        .primary_params = &.{},
        .methods = &.{},
        .init_block = null,
        .companion = null,
        .supertypes = &.{},
        .type_params = &.{"T"},
        .type_param_variance = &.{.Invariant},
        .is_interface = true,
        .is_abstract = true,
    });

    const strings = [_]TypeRef{.{ .name = "String", .nullable = false, .args = &.{} }};
    const ints = [_]TypeRef{.{ .name = "Int", .nullable = false, .args = &.{} }};
    const bottoms = [_]TypeRef{.{ .name = "Nothing", .nullable = false, .args = &.{} }};
    const stars = [_]TypeRef{.{ .name = "*", .nullable = false, .args = &.{} }};
    const list_strings = TypeRef{ .name = "List", .nullable = false, .args = @constCast(&strings) };
    try testing.expect(try m.staticTypeIsSubtype(
        a,
        .{ .name = "List", .nullable = false, .args = @constCast(&bottoms) },
        list_strings,
    ));
    try testing.expect(!(try m.staticTypeIsSubtype(
        a,
        .{ .name = "List", .nullable = false, .args = @constCast(&ints) },
        list_strings,
    )));
    try testing.expect(!(try m.staticTypeIsSubtype(
        a,
        .{ .name = "List", .nullable = false, .args = @constCast(&stars) },
        list_strings,
    )));
    const projected_strings = [_]TypeRef{
        .{ .name = "out#String", .nullable = false, .args = &.{} },
    };
    try testing.expect(try m.staticTypeIsSubtype(
        a,
        .{
            .name = "List",
            .nullable = false,
            .args = @constCast(&projected_strings),
        },
        list_strings,
    ));

    const type_vars = [_]TypeRef{.{
        .name = "T",
        .nullable = false,
        .args = &.{},
    }};
    const char_sequences = [_]TypeRef{.{
        .name = "CharSequence",
        .nullable = false,
        .args = &.{},
    }};
    try testing.expect(try m.staticTypeIsSubtypeWithBounds(
        a,
        .{ .name = "List", .nullable = false, .args = @constCast(&type_vars) },
        .{
            .name = "List",
            .nullable = false,
            .args = @constCast(&char_sequences),
        },
        &.{.{ .param = "T", .bound = "CharSequence" }},
    ));
    try testing.expect(!(try m.staticGenericReceiverApplicable(
        a,
        .{ .name = "List", .nullable = false, .args = @constCast(&ints) },
        .{ .name = "List", .nullable = false, .args = @constCast(&type_vars) },
        &.{.{ .param = "T", .bound = "CharSequence" }},
        &.{},
    )));
    try testing.expect(try m.staticGenericReceiverApplicable(
        a,
        list_strings,
        .{ .name = "List", .nullable = false, .args = @constCast(&type_vars) },
        &.{.{ .param = "T", .bound = "CharSequence" }},
        &.{},
    ));

    try m.registry.type_alias_types.put("Ints", .{
        .type_params = &.{},
        .target = .{
            .name = "MutableList",
            .nullable = false,
            .args = @constCast(&ints),
        },
    });
    try testing.expect(!(try m.staticTypeIsSubtype(
        a,
        .{ .name = "Ints", .nullable = false, .args = &.{} },
        .{
            .name = "MutableList",
            .nullable = false,
            .args = @constCast(&strings),
        },
    )));

    try m.registry.type_alias_types.put("alpha.Items", .{
        .type_params = &.{"T"},
        .target = .{
            .name = "MutableList",
            .nullable = false,
            .args = @constCast(&type_vars),
        },
    });
    try m.registry.type_alias_types.put("beta.Items", .{
        .type_params = &.{"T"},
        .target = .{
            .name = "MutableList",
            .nullable = false,
            .args = @constCast(&strings),
        },
    });
    const qualified_ints = [_]TypeRef{
        .{ .name = "Int", .nullable = false, .args = &.{} },
        .{ .name = "#qual:alpha.Items", .nullable = false, .args = &.{} },
    };
    try testing.expect(!(try m.staticTypeIsSubtype(
        a,
        .{
            .name = "Items",
            .nullable = false,
            .args = @constCast(&qualified_ints),
        },
        .{
            .name = "MutableList",
            .nullable = false,
            .args = @constCast(&strings),
        },
    )));
}

test "symbol index prefers the caller's own package" {
    const a = testing.allocator;
    var m = Module.default(a);
    defer freeTestModule(&m, a);
    // Two same-name, same-arity funcs in different packages.
    const own = try pushTestFunc(&m, a, "greet", "app.greet", "app", 0);
    _ = try pushTestFunc(&m, a, "greet", "lib.greet", "lib", 0);
    try m.rebuildFuncNameIndex(a);

    // A caller in package `app` resolves its own `greet`, not lib's.
    const got = m.resolveBareCallIndexed("greet", "app", FileId.from(0), 0, false);
    try testing.expect(got.outcome == .resolved);
    try testing.expectEqual(own.int(), got.outcome.resolved.int());
    try testing.expectEqual(@as(u8, 1), got.tier);
    try testing.expectEqual(@as(usize, 1), got.tier_count);
}

test "symbol index ranks a named import above the caller's own package" {
    const a = testing.allocator;
    var m = Module.default(a);
    defer freeTestModule(&m, a);
    // Kotlin's scoping: an explicit `import lib.greet` outranks even a
    // declaration in the caller's own package (and file).
    _ = try pushTestFunc(&m, a, "greet", "app.greet", "app", 0);
    const imported = try pushTestFunc(&m, a, "greet", "lib.greet", "lib", 0);
    var paths: std.ArrayList(ModuleRegistry.ImportPath) = .empty;
    const segs = try a.alloc([]const u8, 2);
    segs[0] = "lib";
    segs[1] = "greet";
    try paths.append(a, .{ .fqn = try a.dupe(u8, "lib.greet"), .segs = segs });
    var inner = std.StringHashMap(std.ArrayList(ModuleRegistry.ImportPath)).init(a);
    try inner.put("greet", paths);
    try m.registry.import_aliases.put(FileId.from(0), inner);
    try m.rebuildFuncNameIndex(a);

    const got = m.resolveBareCallIndexed("greet", "app", FileId.from(0), 0, false);
    try testing.expect(got.outcome == .resolved);
    try testing.expectEqual(imported.int(), got.outcome.resolved.int());
    try testing.expectEqual(@as(u8, 0), got.tier);

    // From a file without the import the own-package declaration wins.
    const got2 = m.resolveBareCallIndexed("greet", "app", FileId.from(1), 0, false);
    try testing.expect(got2.outcome == .resolved);
    try testing.expectEqual(@as(u8, 1), got2.tier);
}

test "renamed imports enter the canonical candidate set by exact identity" {
    const a = testing.allocator;
    var m = Module.default(a);
    defer freeTestModule(&m, a);

    const own = try pushTestFunc(&m, a, "hello", "app.hello", "app", 0);
    const imported = try pushTestFunc(&m, a, "greet", "lib.greet", "lib", 0);
    const imported_int = try pushTestFuncOpts(
        &m,
        a,
        "greet",
        "lib.greet",
        "lib",
        1,
        .{ .param_ty = "Int" },
    );
    _ = try pushTestFunc(&m, a, "greet", "other.greet", "other", 0);
    var paths: std.ArrayList(ModuleRegistry.ImportPath) = .empty;
    const segs = try a.alloc([]const u8, 2);
    segs[0] = "lib";
    segs[1] = "greet";
    try paths.append(a, .{ .fqn = try a.dupe(u8, "lib.greet"), .segs = segs });
    var imports = std.StringHashMap(std.ArrayList(ModuleRegistry.ImportPath)).init(a);
    try imports.put("hello", paths);
    try m.registry.import_aliases.put(FileId.from(0), imports);
    try m.rebuildFuncNameIndex(a);

    const candidates = try m.bareCallCandidates(a, "hello", FileId.from(0));
    defer a.free(candidates);
    try testing.expectEqual(@as(usize, 3), candidates.len);
    try testing.expectEqual(own, candidates[0]);
    try testing.expectEqual(imported, candidates[1]);
    try testing.expectEqual(imported_int, candidates[2]);

    const call = m.resolveBareCallIndexed("hello", "app", FileId.from(0), 0, false);
    try testing.expectEqual(imported, call.pick().?);
    try testing.expectEqual(@as(u8, 0), call.tier);
    try testing.expect(m.resolveBareRefIndexed(
        "hello",
        "app",
        FileId.from(0),
    ) == null);
    const zero_ref = try m.resolveBareRefExpected(
        a,
        "hello",
        "app",
        FileId.from(0),
        &.{},
    );
    try testing.expectEqual(imported, zero_ref.?);
    const int_ref_args = [_]applicability.ArgShape{.{
        .ty = .{ .name = "Int", .nullable = false, .args = &.{} },
        .ty_authoritative = true,
    }};
    const int_ref = try m.resolveBareRefExpected(
        a,
        "hello",
        "app",
        FileId.from(0),
        &int_ref_args,
    );
    try testing.expectEqual(imported_int, int_ref.?);

    const other_file = m.resolveBareCallIndexed("hello", "app", FileId.from(1), 0, false);
    try testing.expectEqual(own, other_file.pick().?);
}

test "symbol index defers an out-of-scope pick when an in-scope extension exists" {
    const a = testing.allocator;
    var m = Module.default(a);
    defer freeTestModule(&m, a);
    // The only non-extension candidate lives in a package the caller
    // (kotlin.text) cannot see; a same-package extension also exists.
    // The call may bind the extension via an implicit receiver, so the
    // index must defer to the receiver-aware heuristic instead of
    // resolving (and later rejecting) the invisible function.
    _ = try pushTestFunc(&m, a, "firstOrNull", "firstOrNull", "", 1);
    _ = try pushTestFuncOpts(&m, a, "firstOrNull", "kotlin.text.firstOrNull", "kotlin.text", 1, .{ .extension = true });
    try m.rebuildFuncNameIndex(a);

    const got = m.resolveBareCallIndexed("firstOrNull", "kotlin.text", FileId.from(0), 1, false);
    try testing.expectEqual(Module.ResolveDeferReason.extension_form, deferReasonOf(got).?);

    // Without the extension, the invisible candidate still resolves (the
    // out-of-scope diagnostic is the lowering's call), tier 5.
    var m2 = Module.default(a);
    defer freeTestModule(&m2, a);
    _ = try pushTestFunc(&m2, a, "firstOrNull", "firstOrNull", "", 1);
    try m2.rebuildFuncNameIndex(a);
    const got2 = m2.resolveBareCallIndexed("firstOrNull", "kotlin.text", FileId.from(0), 1, false);
    try testing.expect(got2.outcome == .resolved);
    try testing.expectEqual(Module.other_package_tier, got2.tier);
}

test "symbol index defers when the preferred tier is ambiguous" {
    const a = testing.allocator;
    var m = Module.default(a);
    defer freeTestModule(&m, a);
    // Two same-name, same-arity, same-signature funcs in the CALLER's
    // package: in scope and indistinguishable, the index must defer as
    // ambiguous rather than pick one.
    const p_id = try pushTestFunc(&m, a, "h", "user.h", "user", 1);
    const q_id = try pushTestFunc(&m, a, "h", "user.x.h", "user", 1);
    try m.rebuildFuncNameIndex(a);

    const got = m.resolveBareCallIndexed("h", "user", FileId.from(0), 1, false);
    try testing.expectEqual(Module.ResolveDeferReason.ambiguous_tier, deferReasonOf(got).?);
    try testing.expectEqual(@as(usize, 2), got.tier_count);
    try testing.expectEqual(p_id.int(), got.first.?.int());
    try testing.expectEqual(q_id.int(), got.second.?.int());
}

test "symbol index classifies an out-of-scope identical set as unimported" {
    const a = testing.allocator;
    var m = Module.default(a);
    defer freeTestModule(&m, a);
    // Two identical funcs in two packages the caller neither declares
    // nor imports: Kotlin would resolve neither, so klio's lenient
    // cross-package pick stays with the heuristic instead of erroring.
    _ = try pushTestFunc(&m, a, "h", "p.h", "p", 1);
    _ = try pushTestFunc(&m, a, "h", "q.h", "q", 1);
    try m.rebuildFuncNameIndex(a);

    const got = m.resolveBareCallIndexed("h", "user", FileId.from(0), 1, false);
    try testing.expectEqual(Module.ResolveDeferReason.unimported_set, deferReasonOf(got).?);
}

test "symbol index ranks a default-import package above other built-ins" {
    const a = testing.allocator;
    var m = Module.default(a);
    defer freeTestModule(&m, a);
    // `kotlin.collections` is implicitly imported in every file; a
    // same-name sibling in a non-default kotlinx package is not in
    // scope, so the default-import candidate resolves uniquely.
    const dflt = try pushTestFunc(&m, a, "chk", "kotlin.collections.chk", "kotlin.collections", 1);
    _ = try pushTestFunc(&m, a, "chk", "kotlinx.other.chk", "kotlinx.other", 1);
    try m.rebuildFuncNameIndex(a);

    const got = m.resolveBareCallIndexed("chk", "user", FileId.from(0), 1, false);
    try testing.expect(got.outcome == .resolved);
    try testing.expectEqual(dflt.int(), got.outcome.resolved.int());
    try testing.expectEqual(@as(u8, 3), got.tier);
}

test "symbol index prefers a wildcard-imported package over other packages" {
    const a = testing.allocator;
    var m = Module.default(a);
    defer freeTestModule(&m, a);
    // Same name/arity in two non-caller packages; the caller's file
    // wildcard-imports one of them, which disambiguates (real Kotlin
    // scoping: explicit imports outrank everything but the own package).
    const imported = try pushTestFunc(&m, a, "sync", "locks.sync", "locks", 1);
    _ = try pushTestFunc(&m, a, "sync", "other.sync", "other", 1);
    var wl: std.ArrayList([]const u8) = .empty;
    try wl.append(a, try a.dupe(u8, "locks"));
    try m.registry.import_wildcards.put(FileId.from(0), wl);
    try m.rebuildFuncNameIndex(a);

    const got = m.resolveBareCallIndexed("sync", "user", FileId.from(0), 1, false);
    try testing.expect(got.outcome == .resolved);
    try testing.expectEqual(imported.int(), got.outcome.resolved.int());
    try testing.expectEqual(@as(u8, 2), got.tier);

    // From a different file (no wildcard import) neither candidate is in
    // scope; the identical tie defers to the lenient heuristic.
    const got2 = m.resolveBareCallIndexed("sync", "user", FileId.from(1), 1, false);
    try testing.expectEqual(Module.ResolveDeferReason.unimported_set, deferReasonOf(got2).?);
}

test "symbol index classifies a type-distinguishable overload set" {
    const a = testing.allocator;
    var m = Module.default(a);
    defer freeTestModule(&m, a);
    // Same package, same arity, DIFFERENT parameter types: runtime
    // argument types pick the overload, so this is never an ambiguity.
    _ = try pushTestFuncOpts(&m, a, "f", "app.f", "app", 1, .{ .param_ty = "Int" });
    _ = try pushTestFuncOpts(&m, a, "f", "app.f", "app", 1, .{ .param_ty = "String" });
    try m.rebuildFuncNameIndex(a);

    const got = m.resolveBareCallIndexed("f", "app", FileId.from(0), 1, false);
    try testing.expectEqual(Module.ResolveDeferReason.type_overload, deferReasonOf(got).?);
    try testing.expectEqual(@as(usize, 2), got.tier_count);
}

test "bounded call candidates never widen beyond the caller scope" {
    const a = testing.allocator;
    var m = Module.default(a);
    defer freeTestModule(&m, a);
    const app_int = try pushTestFuncOpts(&m, a, "choose", "app.choose", "app", 1, .{ .param_ty = "Int" });
    const app_string = try pushTestFuncOpts(&m, a, "choose", "app.choose", "app", 1, .{ .param_ty = "String" });
    _ = try pushTestFuncOpts(&m, a, "choose", "lib.choose", "lib", 1, .{ .param_ty = "Int" });
    try m.rebuildFuncNameIndex(a);

    const scoped = (try m.boundedCallCandidates(a, "choose", "app", FileId.from(0), 1)).?;
    defer a.free(scoped);
    try testing.expectEqual(@as(usize, 2), scoped.len);
    try testing.expectEqual(app_int.int(), scoped[0].int());
    try testing.expectEqual(app_string.int(), scoped[1].int());

    const invisible = (try m.boundedCallCandidates(a, "choose", "other", FileId.from(0), 1)).?;
    defer a.free(invisible);
    try testing.expectEqual(@as(usize, 0), invisible.len);
    try testing.expect((try m.boundedCallCandidates(a, "missing", "app", FileId.from(0), 0)) == null);
}

test "bounded call candidates retain lower visible tiers for applicability" {
    const a = testing.allocator;
    var m = Module.default(a);
    defer freeTestModule(&m, a);
    const local = try pushTestFuncOpts(&m, a, "assertContentEquals", "test.text.assertContentEquals", "test.text", 2, .{ .param_ty = "String" });
    const imported = try pushTestFuncOpts(&m, a, "assertContentEquals", "kotlin.test.assertContentEquals", "kotlin.test", 2, .{ .param_ty = "Sequence" });
    _ = try pushTestFuncOpts(&m, a, "assertContentEquals", "other.assertContentEquals", "other", 2, .{});
    var wildcards: std.ArrayList([]const u8) = .empty;
    try wildcards.append(a, try a.dupe(u8, "kotlin.test"));
    try m.registry.import_wildcards.put(FileId.from(0), wildcards);
    try m.rebuildFuncNameIndex(a);

    const scoped = (try m.boundedCallCandidates(a, "assertContentEquals", "test.text", FileId.from(0), 2)).?;
    defer a.free(scoped);
    try testing.expectEqual(@as(usize, 2), scoped.len);
    try testing.expectEqual(local.int(), scoped[0].int());
    try testing.expectEqual(imported.int(), scoped[1].int());
}

test "bounded call candidates preserve the incomplete-header host boundary" {
    const a = testing.allocator;
    var m = Module.default(a);
    defer freeTestModule(&m, a);
    _ = try pushTestFuncOpts(&m, a, "hostOnly", "platform.hostOnly", "platform", 1, .{ .stub = true });
    try m.rebuildFuncNameIndex(a);

    try testing.expect((try m.boundedCallCandidates(a, "hostOnly", "app", FileId.from(0), 1)) == null);
}

test "bounded global candidates ignore a same-name member tier" {
    const a = testing.allocator;
    var m = Module.default(a);
    defer freeTestModule(&m, a);
    const global = try pushTestFuncOpts(&m, a, "minOf", "kotlin.comparisons.minOf", "kotlin.comparisons", 2, .{});
    const member = try pushTestFuncOpts(&m, a, "minOf", "test.collections.CollectionTest.minOf", "test.collections", 0, .{});
    try m.decl_sigs.put(member.int(), .{
        .arity = .{ .required = 0, .total = 0, .has_vararg = false },
        .kind = .instance_method,
        .has_body = true,
    });
    try m.rebuildFuncNameIndex(a);

    const scoped = (try m.boundedCallCandidates(a, "minOf", "test.collections", FileId.from(0), 2)).?;
    defer a.free(scoped);
    try testing.expectEqual(@as(usize, 1), scoped.len);
    try testing.expectEqual(global.int(), scoped[0].int());
    try testing.expect((try m.boundedCallCandidates(a, "minOf", "test.collections", FileId.from(0), 4)) == null);
}

test "bounded spread candidates keep only varargs in the winning scope" {
    const a = testing.allocator;
    var m = Module.default(a);
    defer freeTestModule(&m, a);
    _ = try pushTestFuncOpts(&m, a, "pick", "app.pick", "app", 2, .{});
    const app_ints = try pushTestFuncOpts(&m, a, "pick", "app.pick", "app", 2, .{ .last_vararg = true, .param_ty = "Int" });
    const app_strings = try pushTestFuncOpts(&m, a, "pick", "app.pick", "app", 2, .{ .last_vararg = true, .param_ty = "String" });
    _ = try pushTestFuncOpts(&m, a, "pick", "other.pick", "other", 2, .{ .last_vararg = true });
    try m.rebuildFuncNameIndex(a);

    const scoped = (try m.boundedSpreadCandidates(a, "pick", "app", FileId.from(0))).?;
    defer a.free(scoped);
    try testing.expectEqual(@as(usize, 2), scoped.len);
    try testing.expectEqual(app_ints.int(), scoped[0].int());
    try testing.expectEqual(app_strings.int(), scoped[1].int());
}

test "bounded spread candidates retain renamed import identity" {
    const a = testing.allocator;
    var m = Module.default(a);
    defer freeTestModule(&m, a);
    const imported = try pushTestFuncOpts(
        &m,
        a,
        "merge",
        "lib.merge",
        "lib",
        1,
        .{ .last_vararg = true },
    );
    _ = try pushTestFuncOpts(
        &m,
        a,
        "merge",
        "other.merge",
        "other",
        1,
        .{ .last_vararg = true },
    );
    var paths: std.ArrayList(ModuleRegistry.ImportPath) = .empty;
    const segs = try a.alloc([]const u8, 2);
    segs[0] = "lib";
    segs[1] = "merge";
    try paths.append(a, .{ .fqn = try a.dupe(u8, "lib.merge"), .segs = segs });
    var imports = std.StringHashMap(std.ArrayList(ModuleRegistry.ImportPath)).init(a);
    try imports.put("originalMerge", paths);
    try m.registry.import_aliases.put(FileId.from(0), imports);
    try m.rebuildFuncNameIndex(a);

    const scoped = (try m.boundedSpreadCandidates(
        a,
        "originalMerge",
        "app",
        FileId.from(0),
    )).?;
    defer a.free(scoped);
    try testing.expectEqualSlices(FuncId, &.{imported}, scoped);
}

test "bounded spread candidates do not widen past a fixed-only tier" {
    const a = testing.allocator;
    var m = Module.default(a);
    defer freeTestModule(&m, a);
    _ = try pushTestFuncOpts(&m, a, "pick", "imports.pick", "imports", 2, .{});
    _ = try pushTestFuncOpts(&m, a, "pick", "app.pick", "app", 2, .{ .last_vararg = true });
    var paths: std.ArrayList(ModuleRegistry.ImportPath) = .empty;
    const segs = try a.alloc([]const u8, 2);
    segs[0] = "imports";
    segs[1] = "pick";
    try paths.append(a, .{ .fqn = try a.dupe(u8, "imports.pick"), .segs = segs });
    var inner = std.StringHashMap(std.ArrayList(ModuleRegistry.ImportPath)).init(a);
    try inner.put("pick", paths);
    try m.registry.import_aliases.put(FileId.from(0), inner);
    try m.rebuildFuncNameIndex(a);

    const scoped = (try m.boundedSpreadCandidates(a, "pick", "app", FileId.from(0))).?;
    defer a.free(scoped);
    try testing.expectEqual(@as(usize, 0), scoped.len);
}

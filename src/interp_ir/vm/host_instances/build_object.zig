//! Anonymous objects: the captures a site snapshots, the synthesized property
//! thunks, and building the instance `object : Super { ... }` produces.

const std = @import("std");

const ir = @import("ir");
const runtime = @import("runtime");
const ast = @import("ast");
const stdlib = @import("stdlib");

const root = @import("../../interp_ir.zig");
const vmhost = @import("../vmhost.zig");
const host_globals = @import("../host_globals.zig");
const host_classes = @import("../host_classes.zig");
const host_call_func = @import("../host_call_func.zig");
const host_call_member = @import("../host_call_member.zig");
const host_fields = @import("../host_fields.zig");
const host_call_value = @import("../host_call_value.zig");
const VmHost = vmhost.VmHost;
const VmIntrinsicHost = vmhost.VmIntrinsicHost;

const build = @import("../../build.zig");
const FF = runtime.forest.ForestField;

const Allocator = std.mem.Allocator;
const Value = runtime.Value;
const ObjRef = runtime.ObjRef;
const InstanceData = runtime.InstanceData;
const ClassDef = runtime.ClassDef;
const Env = runtime.Env;
const PropertyDef = runtime.PropertyDef;
const MethodDef = runtime.MethodDef;
const SupertypeDelegate = runtime.SupertypeDelegate;
const TypeShape = runtime.TypeShape;
const StdlibFn = runtime.StdlibFn;
const CallCtx = runtime.CallCtx;
const Module = ir.Module;
const ClassId = ir.ClassId;
const FuncId = ir.FuncId;
const TypeRef = ir.TypeRef;
const EvalResult = ir.eval.EvalResult;
const EvalError = ir.eval.EvalError;
const StrPair = ir.StrPair;
const StringSet = std.StringHashMap(void);
const AnonMethodEntry = root.AnonMethodEntry;
const NameValue = root.NameValue;

const common = @import("common.zig");
const AnonComplexInit = common.AnonComplexInit;
const AnonDelegateThunk = common.AnonDelegateThunk;
const AnonInitThunk = common.AnonInitThunk;
const AnonSuperArgThunk = common.AnonSuperArgThunk;
const anonLowerEnter = common.anonLowerEnter;
const anonLowerExit = common.anonLowerExit;
const anonSiteModule = common.anonSiteModule;
const anonSiteName = common.anonSiteName;
const anonSiteThunksGet = common.anonSiteThunksGet;
const anonSiteThunksPut = common.anonSiteThunksPut;
const gcMarkAnonSites = common.gcMarkAnonSites;
const typeErr = common.typeErr;

const ctor_defaults = @import("ctor_defaults.zig");
const packPrimaryCtorVarargs = ctor_defaults.packPrimaryCtorVarargs;
const simpleLiteral = ctor_defaults.simpleLiteral;

const ctor_path = @import("ctor_path.zig");
const classDefFqn = ctor_path.classDefFqn;
const classDefIsInterface = ctor_path.classDefIsInterface;
const classDefName = ctor_path.classDefName;
const padParentCtorDefaults = ctor_path.padParentCtorDefaults;
const reorderNamedSuperArgs = ctor_path.reorderNamedSuperArgs;

const ctor_select = @import("ctor_select.zig");
const DeferredCtorBody = ctor_select.DeferredCtorBody;
const appendPrimaryCtorPropertyFields = ctor_select.appendPrimaryCtorPropertyFields;
const bodyPropInit = ctor_select.bodyPropInit;
const classDefByName = ctor_select.classDefByName;
const evalThunk = ctor_select.evalThunk;
const expandParentSecondaryThisArgs = ctor_select.expandParentSecondaryThisArgs;
const funcAt = ctor_select.funcAt;
const nextInstanceId = ctor_select.nextInstanceId;
const trivialInitServe = ctor_select.trivialInitServe;

const super_chain = @import("super_chain.zig");
const ChainEntry = super_chain.ChainEntry;
const bindThrowableArgs = super_chain.bindThrowableArgs;
const extendAnonymousParentCtorArgs = super_chain.extendAnonymousParentCtorArgs;
const isBuiltinThrowableName = super_chain.isBuiltinThrowableName;
const runInitBlocksAt = super_chain.runInitBlocksAt;

/// `(class, member)` key for `anon_methods`, unit-separated. Must match
/// `run.zig`/`host_fields.zig`/`host_call_member.zig`.
pub fn anonKey(allocator: Allocator, class_name: []const u8, member: []const u8) Allocator.Error![]const u8 {
    return std.fmt.allocPrint(allocator, "{s}\u{1f}{s}", .{ class_name, member });
}

pub fn buildCapturePairs(allocator: Allocator, captured_names: []const []const u8, captures: []const Value) Allocator.Error![]NameValue {
    const n = @min(captured_names.len, captures.len);
    var pairs = try allocator.alloc(NameValue, n);
    for (0..n) |i| {
        // The instance holds these captures for its whole lifetime; retain so a
        // captured value outlives the frame that produced it. No-op under arena.
        if (runtime.reclaimEnabled()) captures[i].retain();
        pairs[i] = .{ .name = captured_names[i], .value = captures[i] };
    }
    return pairs;
}

pub fn findCapture(pairs: []const NameValue, name: []const u8) ?Value {
    for (pairs) |p| {
        if (std.mem.eql(u8, p.name, name)) return p.value;
    }
    return null;
}

/// A captured mutable local arrives as its shared cell; a field or super-arg
/// initialized from it snapshots the content so later writes are not seen.
pub fn snapshotCapture(v: Value) Value {
    switch (v) {
        .Cell => |c| {
            const g = c.borrow();
            defer g.deinit();
            const inner = g.get().*;
            inner.retain();
            return inner;
        },
        else => return v,
    }
}

/// Whether `expr` is a bare name a direct capture resolves; these fill without a thunk.
pub fn bareCaptureResolvable(expr: *const ast.Expr, pairs: []const NameValue) bool {
    if (expr.* != .Path or expr.Path.segments.len != 1) return false;
    const nm = expr.Path.segments[0].name;
    // Direct captures only: the site-static name list makes this per-site cached
    // answer hold everywhere, and a delegated local's value needs `getValue`.
    if (capturedDelegateOf(pairs, nm)) return false;
    return findCapture(pairs, nm) != null;
}

/// Whether `name` is a delegated local: its `name$klio_delegate` capture exists.
pub fn capturedDelegateOf(pairs: []const NameValue, name: []const u8) bool {
    var buf: [512]u8 = undefined;
    const dname = std.fmt.bufPrint(&buf, "{s}$klio_delegate", .{name}) catch return false;
    return findCapture(pairs, dname) != null;
}

/// `synthThunk` plus the setter's value parameter, so `override var x
/// set(value)` lowers as a 1-arg method the field-write path dispatches.
pub fn synthSetterThunk(allocator: Allocator, name: ast.Ident, value_param: ast.Ident, body: ast.FunctionBody, is_override: bool) Allocator.Error!ast.Function {
    var f = synthThunk(name, body, null, is_override);
    const params = try allocator.alloc(ast.Param, 1);
    params[0] = .{
        .name = value_param,
        .ty = .{
            .name = .{ .name = "Any", .span = value_param.span },
            .nullable = true,
            .span = value_param.span,
            .type_args = &.{},
            .function = null,
            .definitely_non_null = false,
            .annotations = &.{},
            .qualified_path = null,
        },
        .default = null,
        .is_vararg = false,
        .is_crossinline = false,
        .is_noinline = false,
        .annotations = &.{},
        .span = value_param.span,
    };
    f.params = params;
    return f;
}

/// A 0-arg getter/init thunk `Function` over an accessor or expression body.
pub fn synthThunk(name: ast.Ident, body: ast.FunctionBody, return_type: ?ast.TypeRef, is_override: bool) ast.Function {
    return .{
        .name = name,
        .receiver_type = null,
        .type_params = &.{},
        .where_bounds = &.{},
        .params = &.{},
        .return_type = return_type,
        .body = body,
        .is_open = false,
        .is_override = is_override,
        .is_abstract = false,
        .is_operator = false,
        .is_inline = false,
        .is_infix = false,
        .is_tailrec = false,
        .is_suspend = false,
        .is_expect = false,
        .is_actual = false,
        .visibility = .Public,
        .annotations = &.{},
        .span = name.span,
    };
}

/// Record the enclosing declaration's type-parameter names for a lowered anon
/// method, so adjudication reads them as type variables, not nominal classes.
pub fn inheritAnonTypeParams(self: *VmHost, tps: []const []const u8, fid: FuncId) void {
    if (tps.len == 0) return;
    const mg = self.module.borrowMut();
    defer mg.deinit();
    const reg = &mg.get().registry;
    if (reg.func_type_params.contains(fid)) return;
    var lst: std.ArrayList([]const u8) = .empty;
    for (tps) |tp| {
        const d = reg.allocator.dupe(u8, tp) catch return;
        lst.append(reg.allocator, d) catch return;
    }
    reg.func_type_params.put(fid, lst) catch {};
}

pub fn buildObject(self: *VmHost, allocator: Allocator, expr: *const ast.Expr, captured_names: []const []const u8, captures: []const Value, scope_renames: []const ir.ScopeRename, scope_classes: []const ir.ScopeClassRef) Allocator.Error!EvalResult {
    var obj_bodies_run: std.ArrayList(DeferredCtorBody) = .empty;
    defer {
        for (obj_bodies_run.items) |d| allocator.free(d.args);
        obj_bodies_run.deinit(allocator);
    }
    if (expr.* != .ObjectExpr) {
        return .{ .err = try typeErr(allocator, "Vm::build_object: not an ObjectExpr AST node", .{}) };
    }
    if (runtime.gc.gc_enabled and !common.anon_site_thunks_root_registered.swap(true, .monotonic)) {
        runtime.gc.registerRoot(gcMarkAnonSites);
    }
    // Member bodies lower into fresh side modules with none of the build's scope
    // registries; the site's rename snapshot keeps mangled private types resolving.
    const prev_renames = ir.build.setLowerAnonScopeRenames(scope_renames);
    defer _ = ir.build.setLowerAnonScopeRenames(prev_renames);
    const prev_classes = ir.build.setLowerAnonScopeClasses(scope_classes);
    defer _ = ir.build.setLowerAnonScopeClasses(prev_classes);
    const prev_caps = ir.build.setLowerAnonCaptureNames(captured_names);
    defer _ = ir.build.setLowerAnonCaptureNames(prev_caps);
    const obj = expr.ObjectExpr;
    const members = obj.members;
    const supertypes = obj.supertypes;
    const supertype_args = obj.supertype_args;

    const capture_pairs = try buildCapturePairs(allocator, captured_names, captures);
    // The retained values move into the instance's `anon_captures`; free only the
    // array spine here, the instance owns the values.
    defer if (runtime.freeScratch()) allocator.free(capture_pairs);
    const identity = nextInstanceId(self);
    // Site-stable name: the class and method registries do not grow per instance.
    const synth_class_name = anonSiteName(expr);
    // On a hit only the per-instance captures, initializers and allocation run.
    const site_built = blk: {
        const g = self.classes.borrow();
        defer g.deinit();
        break :blk g.get().contains(synth_class_name);
    };
    if (runtime.envOnce("KLIO_ANON_AUDIT") != null) {
        std.debug.print("[ANON] site name={s} built={} ptr=0x{x} members={d}\n", .{ synth_class_name, site_built, @intFromPtr(expr), members.len });
    }

    var site_mod: ?ObjRef(Module) = null;
    defer if (site_mod) |m| m.deinit();

    // Member names that let a bare identifier in a method body resolve via `this`.
    var own_members = StringSet.init(allocator);
    defer own_members.deinit();
    for (members) |*m| {
        switch (m.*) {
            .Property => |p| try own_members.put(p.name.name, {}),
            .Function => |*f| try own_members.put(f.name.name, {}),
            else => {},
        }
    }
    for (supertypes) |*sup| {
        const sup_name = ir.build.anonScopeRename(sup.name.name) orelse sup.name.name;
        const pdef = classDefByName(self, sup_name) orelse continue;
        defer pdef.deinit();
        const dg = pdef.borrow();
        defer dg.deinit();
        for (dg.get().primary_params) |p| try own_members.put(p.name, {});
        for (dg.get().body_properties) |p| try own_members.put(p.name, {});
        for (dg.get().methods) |me| try own_members.put(me.name, {});
    }
    if (findCapture(capture_pairs, "this")) |tv| {
        if (tv == .Instance) {
            const ig = tv.Instance.borrow();
            defer ig.deinit();
            const cg = ig.get().class.borrow();
            defer cg.deinit();
            for (cg.get().primary_params) |p| try own_members.put(p.name, {});
            for (cg.get().body_properties) |p| try own_members.put(p.name, {});
            for (cg.get().methods) |me| try own_members.put(me.name, {});
        }
    }

    // A captured callable whose name matches a top-level extension fn is dropped
    // so a bare call resolves through the global path, unless the object overrides
    // that name. Kotlin scoping keeps a non-callable local ahead of the extension.
    var anon_cap_set = StringSet.init(allocator);
    for (captured_names) |n| {
        var names_extension = false;
        const mg = self.module.borrow();
        const m = mg.get();
        for (m.funcsBySimpleName(n)) |fid| {
            if (m.funcById(fid)) |f| {
                if (f.params.len > 0 and std.mem.eql(u8, f.params[0].name, "this")) {
                    names_extension = true;
                    break;
                }
            }
        }
        mg.deinit();
        const captured_callable = if (findCapture(capture_pairs, n)) |v| switch (v) {
            .IrClosure, .Intrinsic, .BoundMethod, .PropertyRef => true,
            else => false,
        } else false;
        if (!names_extension or !captured_callable or own_members.contains(n)) try anon_cap_set.put(n, {});
    }
    if (runtime.envOnce("KLIO_ANON_AUDIT") != null) {
        std.debug.print("[ANON] site={s} captured=", .{synth_class_name});
        for (captured_names) |n| std.debug.print("{s},", .{n});
        std.debug.print("\n", .{});
    }
    ir.lower.setLowerAnonCaptures(anon_cap_set);
    // `setLowerAnonCaptures` takes ownership; clear it after lowering.

    // Property type heads for the member lowerings: the declared annotation, else
    // the captured value's runtime class, so sibling bodies bind bare reads statically.
    var prop_heads: std.ArrayList(ir.build.AnonPropHead) = .empty;
    defer prop_heads.deinit(allocator);
    if (!std.mem.eql(u8, runtime.envOnce("KLIO_ANON_PROP") orelse "1", "0")) {
        for (members) |*m| {
            if (m.* != .Property) continue;
            const p = m.Property;
            if (p.ty) |*ty| {
                try prop_heads.append(allocator, .{
                    .owner = synth_class_name,
                    .name = p.name.name,
                    .head = ty.name.name,
                });
                continue;
            }
            const init_expr: *const ast.Expr = if (p.init) |*e| e else continue;
            const head: ?[]const u8 = blk: {
                if (init_expr.* == .Path and init_expr.Path.segments.len == 1) {
                    const v = findCapture(capture_pairs, init_expr.Path.segments[0].name) orelse break :blk null;
                    break :blk v.typeFqn();
                }
                if (init_expr.* != .Call) break :blk null;
                const callee = init_expr.Call.callee;
                if (callee.* != .Member) break :blk null;
                const recv = callee.Member.receiver;
                if (recv.* != .Path or recv.Path.segments.len != 1) break :blk null;
                const rv: Value = findCapture(capture_pairs, recv.Path.segments[0].name) orelse rblk: {
                    const tv = findCapture(capture_pairs, "this") orelse break :blk null;
                    if (tv != .Instance) break :blk null;
                    const ig = tv.Instance.borrow();
                    defer ig.deinit();
                    for (ig.get().fields.items) |fld| {
                        if (std.mem.eql(u8, fld.name, recv.Path.segments[0].name)) break :rblk fld.value;
                    }
                    break :blk null;
                };
                const mg = self.module.borrow();
                defer mg.deinit();
                const module = mg.get();
                const owner_cid = module.classIdByFqn(rv.typeFqn()) orelse break :blk null;
                const recv_ref: ir.TypeRef = .{ .name = rv.typeFqn(), .nullable = false, .args = &.{} };
                const resolved = module.resolveMemberCall(owner_cid, callee.Member.name.name, &.{}, .{
                    .caller_file = obj.span.file,
                    .lexical_owner = null,
                    .actual_type_param_bounds = &.{},
                    .receiver_type = recv_ref,
                });
                const target = resolved.target orelse break :blk null;
                const f = module.funcById(target) orelse break :blk null;
                var h = std.mem.trimEnd(u8, f.return_ty.name, "?");
                if (std.mem.findScalar(u8, h, '<')) |lt| h = h[0..lt];
                if (h.len == 0 or std.mem.eql(u8, h, "Unit")) break :blk null;
                // A return left as the owner's type parameter names no class.
                if (module.classIdByFqn(h) == null and module.uniqueClassIdBySimpleName(h) == null) break :blk null;
                break :blk h;
            };
            if (runtime.envOnce("KLIO_ANON_AUDIT") != null) {
                std.debug.print("[ANON] prop {s}.{s} head={s}\n", .{ synth_class_name, p.name.name, head orelse "<none>" });
            }
            if (head) |h| {
                try prop_heads.append(allocator, .{
                    .owner = synth_class_name,
                    .name = p.name.name,
                    .head = h,
                });
            }
        }
    }
    const prev_prop_heads = ir.build.setLowerAnonPropHeads(prop_heads.items);
    defer _ = ir.build.setLowerAnonPropHeads(prev_prop_heads);

    // Methods and getters lower into `anon_methods` once per site under the
    // anon-lower lock; the enclosing type params ride along so `Key` stays a variable.
    const inherited_tps: []const []const u8 =
        if (site_built) &.{} else ir.eval.currentFrameTypeParams();
    anonLowerEnter();
    // Nested and inner classes register before any member body runs: a class body
    // is one scope, so an initializer may construct a class declared further down.
    if (!site_built) try host_classes.registerNestedClassMembers(self, allocator, synth_class_name, members);
    // Two same-arity overloads share the `name#arity` key, so each also registers indexed.
    var overload_seen = std.StringHashMap(usize).init(allocator);
    defer overload_seen.deinit();
    for (members) |*m| {
        switch (m.*) {
            .Function => |*f| {
                if (f.body == null) {
                    if (runtime.envOnce("KLIO_ANON_AUDIT") != null) {
                        std.debug.print("[ANON] skip bodyless fn {s}.{s}\n", .{ synth_class_name, f.name.name });
                    }
                    continue;
                }
                if (site_built) continue;
                const sub_ref = try anonSiteModule(self, allocator, &site_mod);
                const func = try ir.lower.lowerMethod(&sub_ref.cell.data, f, synth_class_name, &own_members);
                const fid = func.id;
                const tbl = self.anon_methods.borrowMut();
                inheritAnonTypeParams(self, inherited_tps, fid);
                const arity_name = try std.fmt.allocPrint(allocator, "{s}#{d}", .{ f.name.name, f.params.len });
                const gop = try overload_seen.getOrPut(arity_name);
                if (!gop.found_existing) gop.value_ptr.* = 0 else gop.value_ptr.* += 1;
                const overload_name = try root.anonOverloadMemberName(allocator, arity_name, gop.value_ptr.*);
                tbl.get().put(try anonKey(allocator, synth_class_name, overload_name), .{ .module = sub_ref.clone(), .func = fid, .captures = &.{} }) catch {};
                if (runtime.envOnce("KLIO_ANON_AUDIT") != null) {
                    std.debug.print("[ANON] method {s}.{s} fid={d}\n", .{ synth_class_name, arity_name, fid.int() });
                }
                // Captures live per-instance in `InstanceData.anon_captures`; this
                // entry is site-stable and would otherwise root them forever.
                tbl.get().put(try anonKey(allocator, synth_class_name, arity_name), .{ .module = sub_ref, .func = fid, .captures = &.{} }) catch {};
                tbl.get().put(try anonKey(allocator, synth_class_name, f.name.name), .{ .module = sub_ref.clone(), .func = fid, .captures = &.{} }) catch {};
                tbl.deinit();
            },
            .Property => |p| {
                if (p.getter) |getter| if (!site_built) {
                    const gbody = try host_classes.rewriteAccessorFieldRefs(std.heap.page_allocator, getter.body, p.name.name);
                    const thunk = synthThunk(p.name, gbody, getter.return_type, p.is_override);
                    const sub_ref = try anonSiteModule(self, allocator, &site_mod);
                    const func = try ir.lower.lowerMethod(&sub_ref.cell.data, &thunk, synth_class_name, &own_members);
                    const fid = func.id;
                    if (runtime.envOnce("KLIO_ANON_AUDIT") != null) {
                        std.debug.print("[ANON] getter {s}.{s} fid={d}\n", .{ synth_class_name, p.name.name, fid.int() });
                    }
                    const key = try std.fmt.allocPrint(allocator, "$get${s}", .{p.name.name});
                    const tbl = self.anon_methods.borrowMut();
                    tbl.get().put(try anonKey(allocator, synth_class_name, key), .{ .module = sub_ref, .func = fid, .captures = &.{} }) catch {};
                    tbl.deinit();
                };
                // A `by`-delegated property gets a getter thunk dispatching
                // `getValue` on the `<name>$klio_delegate` field.
                if (p.delegate != null) if (!site_built) {
                    const dfield = try std.fmt.allocPrint(allocator, "{s}$klio_delegate", .{p.name.name});
                    const recv_expr = try allocator.create(ast.Expr);
                    const segs = try allocator.alloc(ast.Ident, 1);
                    segs[0] = .{ .name = dfield, .span = p.name.span };
                    recv_expr.* = .{ .Path = .{ .segments = segs, .span = p.name.span } };
                    const callee = try allocator.create(ast.Expr);
                    callee.* = .{ .Member = .{
                        .receiver = recv_expr,
                        .name = .{ .name = "getValue", .span = p.name.span },
                        .safe = false,
                        .span = p.name.span,
                    } };
                    const call_args = try allocator.alloc(ast.Expr, 2);
                    call_args[0] = .{ .NullLit = .{ .span = p.name.span } };
                    call_args[1] = .{ .NullLit = .{ .span = p.name.span } };
                    const arg_names = try allocator.alloc(?[]const u8, 2);
                    arg_names[0] = null;
                    arg_names[1] = null;
                    const body_expr: ast.Expr = .{ .Call = .{
                        .callee = callee,
                        .args = call_args,
                        .arg_names = arg_names,
                        .type_args = &.{},
                        .is_infix = false,
                        .span = p.name.span,
                    } };
                    const thunk = synthThunk(p.name, .{ .Expr = body_expr }, p.ty, p.is_override);
                    const sub_ref = try anonSiteModule(self, allocator, &site_mod);
                    const func = try ir.lower.lowerMethod(&sub_ref.cell.data, &thunk, synth_class_name, &own_members);
                    const key = try std.fmt.allocPrint(allocator, "$get${s}", .{p.name.name});
                    const tbl = self.anon_methods.borrowMut();
                    tbl.get().put(try anonKey(allocator, synth_class_name, key), .{ .module = sub_ref, .func = func.id, .captures = &.{} }) catch {};
                    tbl.deinit();
                };
                // A custom setter's 1-arg thunk makes `obj.x = v` dispatch the override.
                if (p.setter) |setter| if (!site_built) {
                    const vp: ast.Ident = if (setter.params.len != 0) setter.params[0] else .{ .name = "value", .span = p.name.span };
                    const thunk = try synthSetterThunk(allocator, p.name, vp, setter.body, p.is_override);
                    const sub_ref = try anonSiteModule(self, allocator, &site_mod);
                    const func = try ir.lower.lowerMethod(&sub_ref.cell.data, &thunk, synth_class_name, &own_members);
                    const fid = func.id;
                    const key = try std.fmt.allocPrint(allocator, "$set${s}", .{p.name.name});
                    const tbl = self.anon_methods.borrowMut();
                    tbl.get().put(try anonKey(allocator, synth_class_name, key), .{ .module = sub_ref, .func = fid, .captures = &.{} }) catch {};
                    tbl.deinit();
                };
            },
            else => {},
        }
    }

    anonLowerExit();

    // Property-init, `init { … }` and super-arg thunks are site-stable: lowered
    // once, keyed by AST site address, kept alive by `gcMarkAnonSites`.
    const site_key = @intFromPtr(expr);
    var complex_prop_inits: []const AnonComplexInit = &.{};
    var init_thunks: []const AnonInitThunk = &.{};
    var super_arg_thunks: []const []const ?AnonSuperArgThunk = &.{};
    var delegate_thunks: []const ?AnonDelegateThunk = &.{};
    if (anonSiteThunksGet(site_key)) |cached| {
        complex_prop_inits = cached.complex_prop_inits;
        init_thunks = cached.init_thunks;
        super_arg_thunks = cached.super_arg_thunks;
        delegate_thunks = cached.delegate_thunks;
        ir.lower.setLowerAnonCaptures(null);
    } else {
        anonLowerEnter();
        defer anonLowerExit();
        // Past a literal or a bare captured name, an initializer needs a thunk.
        var complex_local: std.ArrayList(AnonComplexInit) = .empty;
        for (members) |*m| {
            if (m.* != .Property) continue;
            const p = m.Property;
            if (p.delegate) |*dexpr| {
                const dfield = try std.fmt.allocPrint(allocator, "{s}$klio_delegate", .{p.name.name});
                const thunk_name: ast.Ident = .{
                    .name = try std.fmt.allocPrint(allocator, "$init${s}", .{dfield}),
                    .span = p.name.span,
                };
                const thunk = synthThunk(thunk_name, .{ .Expr = dexpr.*.* }, null, false);
                const sub_ref = try anonSiteModule(self, allocator, &site_mod);
                const func = try ir.lower.lowerMethod(&sub_ref.cell.data, &thunk, synth_class_name, &own_members);
                try complex_local.append(allocator, .{ .name = dfield, .module = sub_ref, .func = func.id });
                continue;
            }
            const init_expr: *const ast.Expr = if (p.init) |*e|
                e
            else if (p.explicit_field) |ef|
                (if (ef.init) |*finit| finit else continue)
            else
                continue;
            const is_lit = (try simpleLiteral(allocator, init_expr)) != null;
            if (is_lit) continue;
            // A name the captured scope resolves fills directly at field init.
            if (bareCaptureResolvable(init_expr, capture_pairs)) continue;
            const thunk_name: ast.Ident = .{
                .name = try std.fmt.allocPrint(allocator, "$init${s}", .{p.name.name}),
                .span = p.name.span,
            };
            const thunk = synthThunk(thunk_name, .{ .Expr = init_expr.* }, null, false);
            const sub_ref = try anonSiteModule(self, allocator, &site_mod);
            const func = try ir.lower.lowerMethod(&sub_ref.cell.data, &thunk, synth_class_name, &own_members);
            try complex_local.append(allocator, .{ .name = p.name.name, .module = sub_ref, .func = func.id });
        }

        // `init { … }` blocks lower as 0-arg thunks over `this`, tagged with the
        // count of preceding properties so the run below keeps declaration order.
        var init_local: std.ArrayList(AnonInitThunk) = .empty;
        for (obj.init_blocks, 0..) |*blk, idx| {
            const member_pos = if (idx < obj.init_block_positions.len) obj.init_block_positions[idx] else members.len;
            const upto = @min(member_pos, members.len);
            var prop_pos: usize = 0;
            for (members[0..upto]) |*m| {
                if (m.* == .Property) prop_pos += 1;
            }
            const thunk_name: ast.Ident = .{
                .name = try std.fmt.allocPrint(allocator, "$init$block${d}", .{idx}),
                .span = blk.span,
            };
            const thunk = synthThunk(thunk_name, .{ .Block = blk.* }, null, false);
            const sub_ref = try anonSiteModule(self, allocator, &site_mod);
            const func = try ir.lower.lowerMethod(&sub_ref.cell.data, &thunk, synth_class_name, &own_members);
            try init_local.append(allocator, .{ .module = sub_ref, .func = func.id, .prop_pos = prop_pos });
        }

        // Super-ctor args the captured scope cannot resolve thunk against the
        // enclosing `this`: they run before the object exists, so no member set.
        const super_local = try allocator.alloc([]const ?AnonSuperArgThunk, supertypes.len);
        {
            var no_members = StringSet.init(allocator);
            defer no_members.deinit();
            for (supertypes, 0..) |_, si| {
                const arg_exprs: []const ast.Expr = blk: {
                    if (si < supertype_args.len) {
                        if (supertype_args[si]) |ae| break :blk ae;
                    }
                    break :blk &.{};
                };
                const slots = try allocator.alloc(?AnonSuperArgThunk, arg_exprs.len);
                for (arg_exprs, 0..) |*ae, ai| {
                    slots[ai] = null;
                    if ((try simpleLiteral(allocator, ae)) != null) continue;
                    if (bareCaptureResolvable(ae, capture_pairs)) continue;
                    // The thunk module has no class registry; `evalSuperArg` resolves companions.
                    if (ae.* == .Path and ae.Path.segments.len == 1) {
                        const cn = ae.Path.segments[0].name;
                        const has_comp = blk2: {
                            const mg = self.module.borrow();
                            defer mg.deinit();
                            break :blk2 mg.get().registry.companion_singletons.get(cn) != null;
                        };
                        if (has_comp and findCapture(capture_pairs, cn) == null) continue;
                    }
                    const thunk_name: ast.Ident = .{
                        .name = try std.fmt.allocPrint(allocator, "$superarg${d}${d}", .{ si, ai }),
                        .span = obj.span,
                    };
                    const thunk = synthThunk(thunk_name, .{ .Expr = ae.* }, null, false);
                    const sub_ref = try anonSiteModule(self, allocator, &site_mod);
                    const func = try ir.lower.lowerMethod(&sub_ref.cell.data, &thunk, synth_class_name, &no_members);
                    slots[ai] = .{ .module = sub_ref, .func = func.id };
                }
                super_local[si] = slots;
            }
        }

        // A supertype delegate past a bare captured name thunks against the enclosing scope.
        const del_local = try allocator.alloc(?AnonDelegateThunk, supertypes.len);
        {
            var no_members2 = StringSet.init(allocator);
            defer no_members2.deinit();
            for (supertypes, 0..) |_, si| {
                del_local[si] = null;
                if (si >= obj.supertype_delegates.len) continue;
                const de = obj.supertype_delegates[si] orelse continue;
                if (bareCaptureResolvable(&de, capture_pairs)) continue;
                const thunk_name: ast.Ident = .{
                    .name = try std.fmt.allocPrint(allocator, "$delegate${d}", .{si}),
                    .span = obj.span,
                };
                const thunk = synthThunk(thunk_name, .{ .Expr = de }, null, false);
                const sub_ref = try anonSiteModule(self, allocator, &site_mod);
                const func = try ir.lower.lowerMethod(&sub_ref.cell.data, &thunk, synth_class_name, &no_members2);
                del_local[si] = .{ .module = sub_ref, .func = func.id };
            }
        }
        ir.lower.setLowerAnonCaptures(null);

        // Permanent copies so `gcMarkAnonSites` reads them cross-thread and the
        // lowered sub-modules stay rooted for later instantiations.
        const pa = std.heap.page_allocator;
        const cpi_perm = pa.dupe(AnonComplexInit, complex_local.items) catch @panic("KGC: anon-site thunk cache alloc failed");
        const it_perm = pa.dupe(AnonInitThunk, init_local.items) catch @panic("KGC: anon-site thunk cache alloc failed");
        const sat_perm = pa.alloc([]const ?AnonSuperArgThunk, super_local.len) catch @panic("KGC: anon-site thunk cache alloc failed");
        for (super_local, 0..) |slots, i| sat_perm[i] = pa.dupe(?AnonSuperArgThunk, slots) catch @panic("KGC: anon-site thunk cache alloc failed");
        const del_perm = pa.dupe(?AnonDelegateThunk, del_local) catch @panic("KGC: anon-site thunk cache alloc failed");
        if (runtime.freeScratch()) {
            complex_local.deinit(allocator);
            init_local.deinit(allocator);
            for (super_local) |slots| allocator.free(slots);
            allocator.free(super_local);
            allocator.free(del_local);
        }
        const winner = anonSiteThunksPut(site_key, .{
            .complex_prop_inits = cpi_perm,
            .init_thunks = it_perm,
            .super_arg_thunks = sat_perm,
            .delegate_thunks = del_perm,
        });
        complex_prop_inits = winner.complex_prop_inits;
        init_thunks = winner.init_thunks;
        super_arg_thunks = winner.super_arg_thunks;
        delegate_thunks = winner.delegate_thunks;
    }

    // The ClassDef is site-stable; per-instance captures and fields apply below.
    const class_def = if (site_built) blk: {
        const g = self.classes.borrow();
        defer g.deinit();
        break :blk g.get().get(synth_class_name).?.clone();
    } else blk: {
        var body_props: std.ArrayList(PropertyDef) = .empty;
        for (members) |*m| {
            if (m.* != .Property) continue;
            const p = m.Property;
            const storage_init: ?*const ast.Expr = if (p.init) |*e|
                e
            else if (p.explicit_field) |ef|
                (if (ef.init) |*finit| finit else null)
            else
                null;
            try body_props.append(allocator, .{
                .name = p.name.name,
                .mutable = p.mutable,
                .init = if (storage_init) |e| FF(ast.Expr).fromPtr(e) else null,
                .getter = if (p.getter) |g| FF(ast.Accessor).fromPtr(g) else null,
                .setter = if (p.setter) |s| FF(ast.Accessor).fromPtr(s) else null,
                .delegate = if (p.delegate) |e| FF(ast.Expr).fromPtr(e) else null,
                .is_abstract = p.is_abstract,
                .is_lateinit = p.is_lateinit,
                .primitive_zero = build.primitiveZeroFor(p),
                .scalar_nn = build.scalarNonNullProp(p),
            });
        }
        var fn_extra: usize = 0;
        for (supertypes) |*t| if (t.function) |ft| {
            const tags = try ir.lower.decl.functionSupertypeTags(allocator, ft);
            fn_extra += tags.len - 1;
        };
        var supertype_names = try allocator.alloc([]const u8, supertypes.len + fn_extra);
        var extra_slot: usize = supertypes.len;
        for (supertypes, 0..) |*t, i| {
            if (t.function) |ft| {
                const tags = try ir.lower.decl.functionSupertypeTags(allocator, ft);
                supertype_names[i] = tags[0];
                for (tags[1..]) |tag| {
                    supertype_names[extra_slot] = tag;
                    extra_slot += 1;
                }
                continue;
            }
            supertype_names[i] = ir.build.anonScopeRename(t.name.name) orelse sup: {
                // A qualified supertype names a lifted nested class registered as
                // `Outer$Inner`; the bare name would match any same-named class.
                if (t.qualified_path) |qp| {
                    const mangled = try allocator.dupe(u8, qp);
                    for (mangled) |*ch| {
                        if (ch.* == '.') ch.* = '$';
                    }
                    if (classDefByName(self, mangled)) |def| {
                        def.deinit();
                        break :sup mangled;
                    }
                    allocator.free(mangled);
                }
                break :sup t.name.name;
            };
        }

        var anon_parent: ?ObjRef(ClassDef) = null;
        for (supertype_names) |sn| {
            const def = classDefByName(self, sn) orelse continue;
            const is_iface = b2: {
                const dg = def.borrow();
                defer dg.deinit();
                break :b2 dg.get().is_interface;
            };
            if (!is_iface) {
                anon_parent = def;
                break;
            }
            def.deinit();
        }

        const env = try ObjRef(Env).init(allocator, Env.init(allocator));
        const cd = try ObjRef(ClassDef).init(allocator, .{
            .name = synth_class_name,
            .fqn = synth_class_name,
            .annotation_names = &.{},
            .primary_params = &.{},
            .methods = &.{},
            .body_properties = try body_props.toOwnedSlice(allocator),
            .init_blocks = &.{},
            .init_block_property_positions = &.{},
            .is_data = false,
            .is_value = false,
            .is_object = false,
            .is_enum = false,
            .is_sealed = false,
            .supertype_names = supertype_names,
            .parent = anon_parent,
            .interfaces = &.{},
            .is_interface = false,
            .is_fun_interface = false,
            .parent_ctor_args = &.{},
            .is_open = false,
            .is_abstract = false,
            .is_inner = false,
            .is_anonymous = true,
            .secondary_ctors = &.{},
            .enum_entries = &.{},
            .companion = try ObjRef(?ObjRef(InstanceData)).init(allocator, null),
            .enclosing_class = try ObjRef(?ObjRef(ClassDef)).init(allocator, null),
            .nested_classes = &.{},
            .captured_env = env,
            .supertype_delegates = &.{},
            .delegate_forwarders = &.{},
            .object_singleton = try ObjRef(?ObjRef(InstanceData)).init(allocator, null),
        });
        {
            const g = self.classes.borrowMut();
            defer g.deinit();
            try g.get().put(synth_class_name, cd.clone());
        }
        try host_classes.registerNestedMembers(self, allocator, synth_class_name, members);
        break :blk cd;
    };
    // Until the instance adopts it the class def lives only in this stack local;
    // pin it so a collection during the initializer evals cannot sweep it.
    const ka_class = self.ka.mark();
    defer self.ka.restore(ka_class);
    runtime.keepalivePushCell(&class_def.cell.hdr);

    var fields: std.ArrayList(InstanceData.Field) = .empty;
    {
        const cg = class_def.borrow();
        defer cg.deinit();
        for (cg.get().body_properties) |p| {
            // An abstract or getter/delegate-backed property has no backing
            // field; seeding a Null slot would shadow the overriding getter.
            if (p.is_abstract or p.getter != null or p.delegate != null) continue;
            var v: Value = .Null;
            if (p.init) |init_field| {
                const init_expr = init_field.get();
                if (try simpleLiteral(allocator, init_expr)) |lit| {
                    v = lit;
                } else if (init_expr.* == .Path and init_expr.Path.segments.len == 1) {
                    const nm = init_expr.Path.segments[0].name;
                    if (findCapture(capture_pairs, nm)) |cv| {
                        v = snapshotCapture(cv);
                    } else if (findCapture(capture_pairs, "this")) |tv| {
                        if (tv == .Instance) {
                            const ig = tv.Instance.borrow();
                            defer ig.deinit();
                            if (ig.get().get(nm)) |fv| v = fv;
                        }
                    }
                }
            } else if (p.primitive_zero) |pz| {
                v = pz;
            }
            try fields.append(allocator, .{ .name = p.name, .value = v });
        }
    }

    // Parent primary-param fields from the supertype ctor args. A pre-lowered
    // thunk evaluates in the enclosing scope; the direct path covers literals.
    var super_args_by_class = std.StringHashMap([]Value).init(allocator);
    defer super_args_by_class.deinit();
    var direct_parent: ?ObjRef(ClassDef) = null;
    defer if (direct_parent) |p| p.deinit();
    // A builtin throwable base has no ClassDef to run a ctor chain through; its
    // args bind `message`/`cause` once the instance exists.
    var throwable_args: ?[]const Value = null;
    for (supertypes, 0..) |*sup, idx| {
        const arg_exprs = if (idx < supertype_args.len) (supertype_args[idx] orelse continue) else continue;
        var vals = try allocator.alloc(Value, arg_exprs.len);
        for (arg_exprs, 0..) |*ae, ai| {
            if (idx < super_arg_thunks.len and ai < super_arg_thunks[idx].len and super_arg_thunks[idx][ai] != null) {
                const th = super_arg_thunks[idx][ai].?;
                const outer_this: Value = findCapture(capture_pairs, "this") orelse .Null;
                switch (try runAnonThunk(self, allocator, th.module, th.func, &outer_this, capture_pairs)) {
                    .ok => |v| vals[ai] = v,
                    .err => |e| return .{ .err = e },
                }
            } else {
                vals[ai] = try evalSuperArg(self, allocator, ae, capture_pairs);
            }
        }
        const resolved_name = blk: {
            const cg = class_def.borrow();
            defer cg.deinit();
            break :blk if (idx < cg.get().supertype_names.len) cg.get().supertype_names[idx] else sup.name.name;
        };
        const parent_def = classDefByName(self, resolved_name);
        if (parent_def == null) {
            const simple = if (std.mem.findScalarLast(u8, resolved_name, '.')) |d| resolved_name[d + 1 ..] else resolved_name;
            if (isBuiltinThrowableName(simple)) throwable_args = vals;
        }
        if (parent_def) |pdef| {
            defer pdef.deinit();
            var ordered = std.ArrayList(Value).fromOwnedSlice(vals);
            const arg_names = if (idx < obj.supertype_arg_names.len) obj.supertype_arg_names[idx] else null;
            switch (try reorderNamedSuperArgs(self, allocator, pdef, classDefFqn(pdef), classDefName(pdef), arg_names, &ordered, null)) {
                .ok => {},
                .err => |e| return .{ .err = e },
            }
            // A superclass ctor call may select a secondary constructor; expanding
            // it before padding gives the primary's fields the delegated values.
            var obj_super_args: ?std.ArrayList(Value) = null;
            switch (try expandParentSecondaryThisArgs(self, allocator, classDefFqn(pdef), classDefName(pdef), &ordered, null, &obj_bodies_run, &obj_super_args)) {
                .ok => {},
                .err => |e| return .{ .err = e },
            }
            switch (try padParentCtorDefaults(self, allocator, pdef, classDefFqn(pdef), classDefName(pdef), &ordered, null)) {
                .ok => {},
                .err => |e| return .{ .err = e },
            }
            vals = try packPrimaryCtorVarargs(self, classDefFqn(pdef), classDefName(pdef), try ordered.toOwnedSlice(allocator));
            try appendPrimaryCtorPropertyFields(allocator, &fields, pdef, vals);
            if (!classDefIsInterface(pdef) and direct_parent == null) direct_parent = pdef.clone();
        }
        try super_args_by_class.put(resolved_name, vals);
    }

    if (direct_parent) |pdef| {
        const direct_name = classDefName(pdef);
        if (super_args_by_class.get(direct_name)) |direct_args| {
            const outer_hint: ?Value = findCapture(capture_pairs, "this");
            switch (try extendAnonymousParentCtorArgs(
                self,
                allocator,
                pdef,
                direct_args,
                if (outer_hint) |*v| v else null,
                &fields,
                &super_args_by_class,
            )) {
                .ok => {},
                .err => |e| return .{ .err = e },
            }
        }
    }

    const outer: ?Value = findCapture(capture_pairs, "this");
    // `outer` is an owned field of the instance (its teardown releases it);
    // `findCapture` returns a borrow, so retain before adopting it.
    if (outer) |o| o.retain();
    // The instance takes ownership of the refs `buildCapturePairs` retained and
    // releases them on teardown; only the `capture_pairs` spine is freed here.
    const anon_caps = try allocator.alloc(InstanceData.Capture, capture_pairs.len);
    for (capture_pairs, 0..) |p, i| anon_caps[i] = .{ .name = p.name, .value = p.value };
    const anon_enclosing = try ir.eval.captureChainAlloc(allocator);
    if (runtime.reclaimEnabled()) {
        for (anon_enclosing) |e| e.v.retain();
    }
    const inst = try ObjRef(InstanceData).init(allocator, .{
        .class = class_def,
        .fields = fields,
        .outer = outer,
        .identity = identity,
        .native_state = null,
        .anon_captures = anon_caps,
        .anon_enclosing = anon_enclosing,
    });
    if (throwable_args) |ta| try bindThrowableArgs(self, inst, ta, true);
    const inst_value: Value = .{ .Instance = inst.clone() };
    // The bare-name construction path carries no outer, so an `inner` class of
    // the body takes this object from the default-outer table.
    for (members) |*m| {
        if (m.* != .Class or !m.Class.is_inner) continue;
        const g = self.class_default_outer.borrowMut();
        defer g.deinit();
        if (runtime.reclaimEnabled()) inst_value.retain();
        try g.get().put(m.Class.name.name, inst_value);
    }

    var parent_chain: std.ArrayList(ObjRef(ClassDef)) = .empty;
    defer {
        for (parent_chain.items) |c| c.deinit();
        parent_chain.deinit(allocator);
    }
    {
        var cur: ?ObjRef(ClassDef) = blk: {
            const ig = inst.borrow();
            defer ig.deinit();
            const cg = ig.get().class.borrow();
            defer cg.deinit();
            break :blk if (cg.get().parent) |p| p.clone() else null;
        };
        var step: usize = 0;
        while (cur) |c| {
            if (step > 128) {
                c.deinit();
                break;
            }
            step += 1;
            const next = blk: {
                const cg = c.borrow();
                defer cg.deinit();
                break :blk if (cg.get().parent) |p| p.clone() else null;
            };
            try parent_chain.append(allocator, c);
            cur = next;
        }
    }
    // Bottom-up so a parent's field exists before a nearer ancestor, each level's
    // `init { … }` blocks interleaved with its properties in declaration order.
    var super_chain_entries: std.ArrayList(ChainEntry) = .empty;
    defer super_chain_entries.deinit(allocator);
    for (parent_chain.items) |c| {
        const cg = c.borrow();
        const cname = cg.get().name;
        cg.deinit();
        try super_chain_entries.append(allocator, .{
            .name = cname,
            .args = super_args_by_class.get(cname) orelse &.{},
        });
    }
    var ci: usize = parent_chain.items.len;
    while (ci > 0) {
        ci -= 1;
        const cls = parent_chain.items[ci];
        const cls_name = blk: {
            const cg = cls.borrow();
            defer cg.deinit();
            break :blk cg.get().name;
        };
        const cls_fqn = classDefFqn(cls);
        const cls_args: []Value = super_args_by_class.get(cls_name) orelse &.{};
        const props = blk: {
            const cg = cls.borrow();
            defer cg.deinit();
            break :blk try allocator.dupe(PropertyDef, cg.get().body_properties);
        };
        // The dupe is a shallow array of `PropertyDef` (each field a borrow into
        // the class def / AST); free the array spine once this level is built.
        defer if (runtime.freeScratch()) allocator.free(props);
        for (props, 0..) |p, pi| {
            switch (try runInitBlocksAt(self, cls, pi, &inst_value, super_chain_entries.items, cls_args)) {
                .ok => {},
                .err => |e| return .{ .err = e },
            }
            const fid = bodyPropInit(self, cls_fqn, cls_name, p.name) orelse continue;
            const mg = self.module.borrow();
            const m = mg.get();
            const func = m.funcById(fid) orelse {
                mg.deinit();
                continue;
            };
            mg.deinit();
            var all: std.ArrayList(Value) = .empty;
            try all.append(allocator, inst_value);
            try all.appendSlice(allocator, cls_args);
            const module_ref = self.module.clone();
            served: {
                const mg2 = module_ref.borrow();
                const v = trivialInitServe(allocator, mg2.get(), func, all.items) catch |e| {
                    mg2.deinit();
                    module_ref.deinit();
                    return e;
                } orelse {
                    mg2.deinit();
                    break :served;
                };
                mg2.deinit();
                module_ref.deinit();
                all.deinit(allocator);
                const already = blk: {
                    const ig = inst.borrow();
                    defer ig.deinit();
                    break :blk ig.get().get(p.name) != null;
                };
                if (!already) {
                    const ig = inst.borrowMut();
                    defer ig.deinit();
                    try ig.get().define(allocator, p.name, v);
                } else if (runtime.reclaimEnabled()) v.release(allocator);
                continue;
            }
            vmhost.emitPath(allocator, "object_build", func.fqn, fid, &inst_value, cls_args);
            const r = try ir.eval.evalWith(VmHost, allocator, module_ref.borrow().get(), func, all, self);
            module_ref.deinit();
            switch (r) {
                .ok => |v| {
                    const already = blk: {
                        const ig = inst.borrow();
                        defer ig.deinit();
                        break :blk ig.get().get(p.name) != null;
                    };
                    if (!already) {
                        const ig = inst.borrowMut();
                        defer ig.deinit();
                        try ig.get().define(allocator, p.name, v);
                    }
                },
                .err => |e| return .{ .err = e },
            }
        }
        switch (try runInitBlocksAt(self, cls, props.len, &inst_value, super_chain_entries.items, cls_args)) {
            .ok => {},
            .err => |e| return .{ .err = e },
        }
    }

    // The object's own `init { … }` blocks and property inits run in declaration order.
    var next_init: usize = 0;
    var prop_idx: usize = 0;
    for (members) |*m| {
        if (m.* != .Property) continue;
        while (next_init < init_thunks.len and init_thunks[next_init].prop_pos <= prop_idx) : (next_init += 1) {
            const it = init_thunks[next_init];
            switch (try runAnonThunk(self, allocator, it.module, it.func, &inst_value, capture_pairs)) {
                .ok => {},
                .err => |e| return .{ .err = e },
            }
        }
        prop_idx += 1;
        const pname = m.Property.name.name;
        const cpi: ?AnonComplexInit = blk: {
            for (complex_prop_inits) |c| {
                if (std.mem.eql(u8, c.name, pname)) break :blk c;
                // A delegated property stores the delegate under `<name>$klio_delegate`.
                if (c.name.len == pname.len + "$klio_delegate".len and
                    std.mem.startsWith(u8, c.name, pname) and
                    std.mem.endsWith(u8, c.name, "$klio_delegate"))
                {
                    break :blk c;
                }
            }
            break :blk null;
        };
        const c = cpi orelse continue;
        switch (try runAnonThunk(self, allocator, c.module, c.func, &inst_value, capture_pairs)) {
            .ok => |v| {
                const ig = inst.borrowMut();
                defer ig.deinit();
                try ig.get().define(allocator, c.name, v);
            },
            .err => |e| return .{ .err = e },
        }
    }
    while (next_init < init_thunks.len) : (next_init += 1) {
        const it = init_thunks[next_init];
        switch (try runAnonThunk(self, allocator, it.module, it.func, &inst_value, capture_pairs)) {
            .ok => {},
            .err => |e| return .{ .err = e },
        }
    }

    // Interface delegation stores the value in the `__delegate__<Iface>` field the forwarders read.
    {
        const delegates = obj.supertype_delegates;
        for (supertypes, 0..) |*sup, i| {
            if (i >= delegates.len) break;
            const de = delegates[i] orelse continue;
            var dv: ?Value = switch (de) {
                .Path => |p| if (p.segments.len == 1) findCapture(capture_pairs, p.segments[0].name) else null,
                else => null,
            };
            if (dv == null and i < delegate_thunks.len) {
                if (delegate_thunks[i]) |th| {
                    switch (try runAnonThunk(self, allocator, th.module, th.func, &inst_value, capture_pairs)) {
                        .ok => |v2| dv = v2,
                        .err => |e| return .{ .err = e },
                    }
                }
            }
            const v = dv orelse continue;
            const key = try std.fmt.allocPrint(allocator, "__delegate__{s}", .{sup.name.name});
            v.retain();
            const ig = inst.borrowMut();
            const already = ig.get().get(key) != null;
            if (!already) {
                try ig.get().fields.append(allocator, .{ .name = key, .value = v });
                ig.get().invalidateShape();
            } else {
                v.release(allocator);
            }
            ig.deinit();
        }
    }

    // Parent secondary-ctor bodies run on the finished instance, ancestors first.
    {
        var bi: usize = obj_bodies_run.items.len;
        while (bi > 0) {
            bi -= 1;
            const d = obj_bodies_run.items[bi];
            const fr = try funcAt(self, d.body, "secondary ctor body");
            switch (fr) {
                .err => {},
                .ok => |body_func| {
                    var all: std.ArrayList(Value) = .empty;
                    defer all.deinit(allocator);
                    try all.append(allocator, inst_value);
                    try all.appendSlice(allocator, d.args);
                    switch (try evalThunk(self, body_func, all.items)) {
                        .ok => {},
                        .err => |e| return .{ .err = e },
                    }
                },
            }
        }
    }
    return .{ .ok = inst_value };
}

/// Run one lowered anon-object thunk with `capture_pairs` layered over globals.
/// `inst_value` is `this`: the instance, or the enclosing receiver for super args.
pub fn runAnonThunk(
    self: *VmHost,
    allocator: Allocator,
    mref: ObjRef(Module),
    fid: FuncId,
    inst_value: *const Value,
    capture_pairs: []const NameValue,
) Allocator.Error!EvalResult {
    const mg = mref.borrow();
    const sub_mod = mg.get();
    const func = sub_mod.funcById(fid) orelse {
        mg.deinit();
        return .{ .ok = .Unit };
    };
    const prev = self.globals.clone();
    if (capture_pairs.len != 0) {
        const scoped = try ObjRef(Env).init(allocator, Env.withParent(allocator, self.globals.clone()));
        const sg = scoped.borrowMut();
        for (capture_pairs) |nv| sg.get().define(nv.name, nv.value) catch {};
        sg.deinit();
        self.globals = scoped;
    }
    // Pin the globals scope across the body eval: the transient capture layer is
    // reachable only through this stack-local field. Pin the sub-module too, held
    // only by `mref` while the frame keeps it as a raw pointer the collector misses.
    const ka = self.ka.mark();
    defer self.ka.restore(ka);
    runtime.keepalivePushCell(&self.globals.cell.hdr);
    runtime.keepalivePushCell(&mref.cell.hdr);
    var cap_vec: std.ArrayList(Value) = .empty;
    for (func.capture_order) |cn| {
        if (std.mem.eql(u8, cn, "this")) {
            try cap_vec.append(allocator, inst_value.*);
        } else {
            try cap_vec.append(allocator, findCapture(capture_pairs, cn) orelse .Null);
        }
    }
    var all: std.ArrayList(Value) = .empty;
    try all.append(allocator, inst_value.*);
    vmhost.emitPath(allocator, "object_build", func.fqn, fid, inst_value, &.{});
    const r = try ir.eval.evalWithCaptures(VmHost, allocator, sub_mod, func, all, cap_vec, self);
    mg.deinit();
    self.globals.deinit();
    self.globals = prev;
    return r;
}

/// Evaluate a super ctor-arg: literal, then captured name, then a field of the outer `this`.
pub fn evalSuperArg(self: *VmHost, allocator: Allocator, expr: *const ast.Expr, capture_pairs: []const NameValue) Allocator.Error!Value {
    if (expr.* == .Spread) return evalSuperArg(self, allocator, expr.Spread.expr, capture_pairs);
    if (try simpleLiteral(allocator, expr)) |v| return v;
    if (expr.* == .Path and expr.Path.segments.len == 1) {
        const nm = expr.Path.segments[0].name;
        if (findCapture(capture_pairs, nm)) |v| return snapshotCapture(v);
        // A bare class name in value position resolves to its companion object.
        const comp_name: ?[]const u8 = blk: {
            const mg = self.module.borrow();
            defer mg.deinit();
            break :blk mg.get().registry.companion_singletons.get(nm);
        };
        if (comp_name) |cn| {
            switch (try host_globals.ensureObjectSingleton(self, cn)) {
                .ok => |maybe| if (maybe) |v| return v,
                .err => {},
            }
        }
        if (findCapture(capture_pairs, "this")) |tv| {
            if (tv == .Instance) {
                const ig = tv.Instance.borrow();
                defer ig.deinit();
                if (ig.get().get(nm)) |v| return v;
            }
        }
    }
    return .Null;
}

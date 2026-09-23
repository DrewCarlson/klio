//! The static implicit-receiver walk.
//!
//! Kotlin resolves a bare name against the implicit receivers in scope,
//! innermost first: the first whose static type declares the name — as a
//! member, or through an extension that applies to it — binds it, and only
//! when none does is the name a top-level declaration. That is a question
//! about declarations, and lowering holds every input: the spliced subjects
//! with their heads, the declaration's own receiver, the class the body
//! belongs to, and the member surface of each class's hierarchy.
//!
//! `LoadFromThisOrGlobal`, `CallMemberOrGlobal` and `StoreToThisOrGlobal`
//! exist to run this walk at run time over the values the frame happens to
//! hold. The walk here answers the same question once, at lowering, and the
//! three instructions are emitted only where an input is genuinely missing —
//! which the verdict names, so the missing input can be supplied rather than
//! the walk deferred.

const std = @import("std");
const ast = @import("ast");
const runtime = @import("runtime");
const ir = @import("../../ir.zig");
const build = @import("../../build.zig");
const paths_mod = @import("paths.zig");
const emit = @import("emit.zig");
const lambda_body = @import("../lambda_body.zig");
const probe = @import("probe.zig");
const decl_mod = @import("../decl.zig");
const member_call = @import("member_call.zig");
const probe_mod = @import("probe.zig");
const type_probe = @import("type_probe.zig");
const audit = @import("audit.zig");
const applicability = @import("applicability");

const Allocator = std.mem.Allocator;
const FuncBuilder = build.FuncBuilder;
const Reg = ir.Reg;

/// The receiver that binds the name: its register, its static head, and the
/// class the head names. `fid` is the sole declaration at the asked arity when
/// the walk was asked with one and the class has exactly that.
pub const Hit = struct {
    reg: Reg,
    head: []const u8,
    cid: ir.ClassId,
    fid: ?ir.FuncId = null,
    /// The `this@<label>` the receiver answers to where a splice or body
    /// bound one; null for the ambient `this`.
    label: ?[]const u8 = null,
    /// The receiver binds the call through an extension of its type, not a
    /// member: the extension resolver named the declaration.
    via_extension: bool = false,
};

/// What kept the walk from deciding. Each names an input the emitter lacked.
pub const Why = enum {
    /// A spliced subject whose head lowering never recorded.
    subject_head_unknown,
    /// A head naming no class in the module.
    head_unresolvable,
    /// A receiver whose supertype chain has a hole, so "does not declare" is
    /// not provable for it.
    hierarchy_incomplete,
    /// An enclosing class declares the name, and the walk has no register for
    /// that class's instance.
    outer_class_declares,
    /// The declaration's own receiver declares the name, but inside an
    /// extension splice the ambient `this` is the spliced receiver and the own
    /// receiver has no register.
    own_receiver_unreachable,
    /// The dispatch receiver of a member extension (`fun Owner.Recv.f()`)
    /// declares the name, and the body holds no register for it: only the
    /// extension receiver is in `this`.
    dispatch_receiver_unreachable,
    /// No member of the receiver takes the call, but an extension of its type
    /// might, and the walk does not rank extensions.
    extension_unproven,
    /// A receiver declares the name but not as a sole callable at this arity:
    /// an overload set, or a property that may be function-typed.
    member_arity_unproven,
    /// No `this` is bound or capturable, yet the context is a receiver one.
    this_unavailable,
    /// A closure whose construction site recorded no receiver tower, so the
    /// head of its captured `this` is unknown.
    closure_tower_unknown,
    /// A receiver in the closure's tower behind the captured `this` declares
    /// the name, and the closure holds no register for that receiver.
    tower_outer_declares,
    /// The own class makes the name visible bare without declaring it as a
    /// member: an enum entry, a companion member or a nested classifier.
    own_static_name,
    /// `this` is bound to a register that is neither the innermost subject's
    /// nor the own receiver's: a window rebound it without recording a head.
    this_rebound_unknown,
    /// The name is one an anonymous object's body reaches as a runtime-scoped
    /// capture, which outranks any global the walk could name.
    scoped_capture,
    /// A receiver's member set names it, but no record says it is a property:
    /// an accessor-only property with no recorded type, or a nested class's
    /// member the set folded in.
    property_unproven,
};

pub const Verdict = union(enum) {
    member: Hit,
    /// Every receiver in scope has a complete, known hierarchy and none
    /// declares the name: it is a top-level declaration.
    global,
    undecided: Why,
};

/// Whether an extension the receiver would bind is a function (a call) or a
/// property (a read or write); `classifier` asks whether a receiver nests a
/// class of the name, which outranks a top-level class in value position.
pub const Kind = enum { call, property, classifier };

threadlocal var probe_state: u8 = 0;

pub fn probeOn() bool {
    if (probe_state == 0) probe_state = if (runtime.envOnce("KLIO_WALK_PROBE") != null) 2 else 1;
    return probe_state == 2;
}

fn note(b: *FuncBuilder, name: []const u8, site: []const u8, v: Verdict) void {
    if (!probeOn() or build.scratch_depth != 0) return;
    const fname = build.currentRealFn() orelse "-";
    switch (v) {
        .member => |h| {
            std.debug.print("[walk] site={s} verdict=member head={s} reg=r{d} name={s} fn={s} subjects={d} closure={} recv={s} splice={s} this={?}\n", .{
                site, h.head, h.reg.int(), name, fname, b.subject_binds.items.len, b.capturesThisSlot(), b.recvTy() orelse "-", b.spliceRecvTy() orelse "-", if (b.resolve("this")) |t| t.int() else null,
            });
            for (b.subject_binds.items, 0..) |sb, i| {
                std.debug.print("[walk-subject] {d} head={s} hint={} reg=r{d} prior={?}\n", .{ i, sb.head orelse "?", sb.head_hint, sb.reg.int(), if (sb.prior_this) |pr| pr.int() else null });
            }
            if (b.capturesThisSlot()) {
                std.debug.print("[walk-tower] name={s} label={s} tower=", .{ name, h.label orelse "-" });
                for (b.implicit_receiver_tower.items) |te| std.debug.print(" {s}/{s}", .{ if (te.head.len == 0) "?" else te.head, te.label orelse "-" });
                std.debug.print("\n", .{});
            }
        },
        .global => {
            // One line per record: the body pool lowers on several threads and
            // interleaves anything longer.
            var buf: [1024]u8 = undefined;
            var w = std.Io.Writer.fixed(&buf);
            w.print("[walk] site={s} verdict=global name={s} fn={s} closure={} tower_known={} recv={s} encl={s} owner={s} splice={s} subjects=[", .{
                site, name, fname, b.capturesThisSlot(), b.implicit_receiver_tower_known, b.recvTy() orelse "-", b.enclosingRecvTy() orelse "-", b.ownerClass() orelse "-", b.spliceRecvTy() orelse "-",
            }) catch {};
            for (b.subject_binds.items) |sb| w.print(" {s}{s}", .{ sb.head orelse "?", if (sb.head_hint) "(hint)" else "" }) catch {};
            w.print(" ] tower=[", .{}) catch {};
            for (b.implicit_receiver_tower.items) |te| {
                const resolved: []const u8 = if (te.head.len == 0) "?" else if (classOfHead(b, te.head)) |c| (if (c.int() < b.module.classes.items.len) b.module.classes.items[c.int()].fqn else "?") else "-";
                w.print(" {s}->{s}", .{ if (te.head.len == 0) "?" else te.head, resolved }) catch {};
            }
            w.print(" ] tp={} bound={s}\n", .{ b.isTypeParam("T"), if (b.typeParamBound("T")) |tb| tb.bound else "-" }) catch {};
            std.debug.print("{s}", .{w.buffered()});
        },
        .undecided => |w| {
            std.debug.print("[walk] site={s} verdict=undecided:{s} name={s} fn={s} head={s} closure={} subjects={d} splice={s} recv={s} owner={s} this={?d} captured={?d} binds=", .{
                site, @tagName(w), name, fname, if (w == .head_unresolvable) last_unresolvable_head else "-", b.capturesThisSlot(), b.subject_binds.items.len, b.spliceRecvTy() orelse "-", b.recvTy() orelse "-", b.ownerClass() orelse "-", if (b.resolve("this")) |t| t.int() else null, if (b.capture_regs.get("this")) |t| t.int() else null,
            });
            for (b.subject_binds.items) |sb| std.debug.print(" r{d}:{s}/{s}(prior={?d})", .{ sb.reg.int(), sb.head orelse "?", sb.label orelse "-", if (sb.prior_this) |pt| pt.int() else null });
            std.debug.print("\n", .{});
        },
    }
}

/// One receiver's answer for the name.
const Entry = enum { declares, absent, incomplete, unresolvable, arity_unproven, property_unproven, extension };

/// What a call brings to the receiver question beyond its arity: the
/// argument shapes the resolver ranks a receiver's overloads against, so a
/// receiver that declares the name binds the call only when one of its
/// members accepts the arguments, as Kotlin has it.
pub const CallQuery = struct {
    shapes: []const applicability.ArgShape,
    file: ir.FileId,
    lexical_owner: ?ir.ClassId,
    bounds: []const ir.ModuleRegistry.TypeParamBound,
    ident: ast.Ident,
    args: []const ast.Expr,
    ast_arg_names: []const ?[]const u8,
};

/// Whether `cid` or an ancestor declares `name` as a PROPERTY: a recorded
/// declared type, or a slot in the published layout, which holds every stored
/// property whether or not its type was recorded.
fn propertyOnChain(b: *FuncBuilder, cid: ir.ClassId, name: []const u8, depth: u8) bool {
    if (depth >= 64 or cid.int() >= b.module.classes.items.len) return false;
    const c = &b.module.classes.items[cid.int()];
    if (b.module.registry.class_prop_type_heads.get(.{ .a = c.name, .b = name }) != null) return true;
    if (b.module.registry.class_prop_type_heads.get(.{ .a = c.fqn, .b = name }) != null) return true;
    if (b.module.fieldSlotIndex(cid, name) != null) return true;
    for (c.supertypes) |p| {
        if (propertyOnChain(b, p, name, depth + 1)) return true;
    }
    return false;
}

/// Whether `cid` or an ancestor declares a member FUNCTION named `name`.
fn functionOnChain(b: *FuncBuilder, cid: ir.ClassId, name: []const u8, depth: u8) bool {
    if (depth >= 64 or cid.int() >= b.module.classes.items.len) return false;
    const c = &b.module.classes.items[cid.int()];
    if (b.module.registry.hierarchy_methods.get(c.name)) |set| {
        if (set.contains(name)) return true;
    }
    if (b.module.registry.hierarchy_methods.get(c.fqn)) |set| {
        if (set.contains(name)) return true;
    }
    for (c.methods) |mid| {
        if (b.module.funcById(mid)) |mf| {
            if (std.mem.eql(u8, mf.name, name)) return true;
        }
    }
    if (b.module.memberDecls(c.fqn, name).len != 0) return true;
    for (c.supertypes) |p| {
        if (functionOnChain(b, p, name, depth + 1)) return true;
    }
    return false;
}

/// The classifier `cid` or an ancestor nests under `name`.
pub fn nestedClassifierOnChain(b: *FuncBuilder, cid: ir.ClassId, name: []const u8, depth: u8) ?ir.ClassId {
    if (depth >= 64 or cid.int() >= b.module.classes.items.len) return null;
    if (b.module.classDirectChild(cid, name)) |kid| return kid;
    const c = &b.module.classes.items[cid.int()];
    for (c.supertypes) |p| {
        if (nestedClassifierOnChain(b, p, name, depth + 1)) |kid| return kid;
    }
    return null;
}

/// Whether the chain from `cid` has a class whose nested classifiers are not
/// recorded: a stub restored without its body.
fn chainHasStub(b: *FuncBuilder, cid: ir.ClassId, depth: u8) bool {
    if (depth >= 64 or cid.int() >= b.module.classes.items.len) return true;
    const c = &b.module.classes.items[cid.int()];
    if (c.is_stub) return true;
    for (c.supertypes) |p| {
        if (chainHasStub(b, p, depth + 1)) return true;
    }
    return false;
}

/// The head the last `unresolvable` entry was asked about, for the probe.
threadlocal var last_unresolvable_head: []const u8 = "";

/// A head spelled like a type parameter: one or two upper-case letters, or a
/// class-parameter identity. Such a head recorded off another declaration
/// names that declaration's parameter, which nothing here can instantiate.
fn typeParamShaped(head_in: []const u8) bool {
    var head = std.mem.trimEnd(u8, head_in, "?");
    if (std.mem.findScalar(u8, head, '<')) |lt| head = head[0..lt];
    if (head.len == 0) return false;
    if (head.len <= 2 and std.ascii.isUpper(head[0])) return true;
    return ir.parseClassTypeParamIdentity(head) != null;
}

fn classOfHead(b: *FuncBuilder, head_in: []const u8) ?ir.ClassId {
    var head = std.mem.trimEnd(u8, head_in, "?");
    if (std.mem.findScalar(u8, head, '<')) |lt| head = head[0..lt];
    if (head.len == 0) return null;
    const simple = if (std.mem.findScalarLast(u8, head, '.')) |i| head[i + 1 ..] else head;
    // A simple name several classes share names none of them here; a
    // first-wins pick would answer for the wrong one.
    // The owner-class ladder the explicit-receiver path runs: the file's
    // imports settle a shared simple name, a type parameter reads through its
    // bound, a nested class through its qualified suffix or the lexical chain.
    // No `Any` floor for an unbounded parameter: a tower head is recorded from
    // a callee's signature, where `T` may be that callee's own parameter and
    // not the one of this name in scope.
    const cid = blk: {
        // A type parameter in scope shadows any class of its name: it reads
        // through its bound, and through nothing without one.
        if (std.mem.findScalar(u8, head, '.') == null and b.isTypeParam(simple)) {
            const file = (b.self_decl_span orelse break :blk null).file;
            break :blk member_call.classIdForReceiverHead(b, head, simple, file, false);
        }
        if (b.module.classIdByFqn(head)) |c| break :blk c;
        if (b.module.uniqueClassIdBySimpleName(simple)) |c| break :blk c;
        const file: ir.FileId = if (b.self_decl_span) |sp| sp.file else if (b.body_span) |sp| sp.file else break :blk null;
        // The file's own scope, as a written receiver resolves: a
        // collision-mangled twin of the simple name (an `internal` class two
        // packages declare), and a nested classifier the file imports by name.
        if (std.mem.findScalar(u8, head, '.') == null) {
            if (paths_mod.scopeTypeRename(b, simple, file.int())) |renamed| {
                if (b.module.classIdByFqn(renamed) orelse b.module.classId(renamed)) |c| break :blk c;
            }
            if (b.module.classIdExactImport(simple, file)) |c| break :blk c;
        }
        break :blk member_call.classIdForReceiverHead(b, head, simple, file, false);
    };
    if (cid == null) {
        last_unresolvable_head = head_in;
        if (probeOn()) {
            const file_opt: ?ir.FileId = if (b.self_decl_span) |sp| sp.file else null;
            const n_cands: usize = if (b.module.classNameCandidates(simple)) |cs| cs.len else 0;
            std.debug.print("[head-unresolvable] head={s} decl_file={?d} cands={d} indexed={?d} fn={s}\n", .{
                head_in,
                if (file_opt) |f| f.int() else null,
                n_cands,
                if (file_opt) |f| (if (b.module.classIdIndexed(simple, b.self_package, f)) |c| c.int() else null) else null,
                build.currentRealFn() orelse "-",
            });
        }
    }
    return cid;
}

/// Whether "no declaration in the hierarchy" is a fact for this class. The
/// shadow set is the only record of a class's PROPERTY surface — the class
/// row lists methods, not properties — so a class without one, anywhere on
/// the chain, has a surface the walk cannot see and nothing is provable
/// about it.
fn hierarchyComplete(b: *FuncBuilder, cid: ir.ClassId) bool {
    return hierarchyCompleteDepth(b, cid, 0);
}

fn hierarchyCompleteDepth(b: *FuncBuilder, cid: ir.ClassId, depth: u8) bool {
    if (depth >= 64 or cid.int() >= b.module.classes.items.len) return false;
    const c = &b.module.classes.items[cid.int()];
    if (c.is_stub) return false;
    const hs = b.module.registry.hierarchy_shadow_names.get(c.name) orelse return false;
    if (!hs.complete) return false;
    for (c.supertypes) |p| {
        if (!hierarchyCompleteDepth(b, p, depth + 1)) return false;
    }
    return true;
}

/// Whether `cid` or an ancestor is an enum whose entries include `name`: an
/// entry is visible bare inside the enum's body and its entries' bodies, and
/// no member set lists it.
fn enumEntryOnChain(b: *FuncBuilder, cid: ir.ClassId, name: []const u8, depth: u8) bool {
    if (depth >= 64 or cid.int() >= b.module.classes.items.len) return false;
    const c = &b.module.classes.items[cid.int()];
    if (c.is_enum) {
        for (c.enum_entry_names) |e| {
            if (std.mem.eql(u8, e, name)) return true;
        }
    }
    for (c.supertypes) |p| {
        if (enumEntryOnChain(b, p, name, depth + 1)) return true;
    }
    return false;
}

/// Whether the class's companion, or an ancestor's, declares the name.
fn companionOnChain(b: *FuncBuilder, cid: ir.ClassId, name: []const u8, depth: u8) bool {
    if (depth >= 64 or cid.int() >= b.module.classes.items.len) return false;
    const c = &b.module.classes.items[cid.int()];
    if (c.companion) |comp| {
        if (b.module.classHierarchyDeclaresMember(comp, name)) return true;
    }
    for (c.supertypes) |p| {
        if (companionOnChain(b, p, name, depth + 1)) return true;
    }
    return false;
}

/// Whether a class enclosing `head` — the outer classes an inner or nested
/// class's bodies see — declares the name, as a member, an enum entry or a
/// companion member. Read from the module's own outer links, since a
/// builder's enclosing-name table is not installed in every body.
fn outerChainDeclares(b: *FuncBuilder, head: []const u8, name: []const u8) bool {
    var cur = head;
    var depth: usize = 0;
    while (depth < 32) : (depth += 1) {
        const enc = b.module.registry.enclosing_class.get(cur) orelse return false;
        if (classOfHead(b, enc)) |cid| {
            if (b.module.classHierarchyDeclaresMember(cid, name) or
                enumEntryOnChain(b, cid, name, 0) or companionOnChain(b, cid, name, 0)) return true;
        } else return true;
        cur = enc;
    }
    return true;
}

const EntryAnswer = struct { e: Entry, cid: ?ir.ClassId, fid: ?ir.FuncId, via_extension: bool = false };

fn entryFor(b: *FuncBuilder, head: []const u8, name: []const u8, arity: ?usize, kind: Kind, query: ?*const CallQuery) Allocator.Error!EntryAnswer {
    const cid = classOfHead(b, head) orelse return .{ .e = .unresolvable, .cid = null, .fid = null };
    if (enumEntryOnChain(b, cid, name, 0) or companionOnChain(b, cid, name, 0)) return .{ .e = .arity_unproven, .cid = cid, .fid = null };
    if (arity) |n| {
        // The sole declaration at this arity is the member Kotlin picks, and
        // an extension of the name that could serve the receiver withdraws it.
        if (emit.declaredSlotOn(b, head, name, n)) |fid| return .{ .e = .declares, .cid = cid, .fid = fid };
    }
    switch (kind) {
        .call => {
            const member_declares = b.module.classHierarchyDeclaresMember(cid, name);
            const ext_serves = b.module.extensionCouldServe(cid, name);
            if (member_declares) {
                if (query) |q| {
                    // A property of the name may be invocable, which the
                    // function candidates the resolver ranks cannot refute.
                    if (propertyOnChain(b, cid, name, 0)) return .{ .e = .arity_unproven, .cid = cid, .fid = null };
                    const res = b.module.resolveMemberCall(cid, name, q.shapes, .{
                        .caller_file = q.file,
                        .lexical_owner = q.lexical_owner,
                        .actual_type_param_bounds = q.bounds,
                        .receiver_type = .{ .name = head, .nullable = false, .args = &.{} },
                    });
                    if (res.applicable) return .{ .e = .declares, .cid = cid, .fid = res.target };
                    // Every member of the name refused the arguments: Kotlin
                    // goes on to the next receiver, unless an extension of
                    // this one could still take the call.
                    if (!ext_serves and hierarchyComplete(b, cid)) return .{ .e = .absent, .cid = cid, .fid = null };
                    return .{ .e = .arity_unproven, .cid = cid, .fid = null };
                }
                if (arity != null) return .{ .e = .arity_unproven, .cid = cid, .fid = null };
                return .{ .e = .declares, .cid = cid, .fid = null };
            }
            if (ext_serves) {
                // Kotlin tries this receiver's extensions before the next
                // receiver's members; the resolver names the one that fits.
                if (query) |q| {
                    const recv_ty = ir.TypeRef{ .name = head, .nullable = false, .args = &.{} };
                    const er = try member_call.resolveExtensionCallForArgs(b, recv_ty, q.ident, q.args, q.ast_arg_names, false);
                    if (er.target != null) return .{ .e = .declares, .cid = cid, .fid = er.target, .via_extension = true };
                    if (!er.applicable and er.sole_unknown == null and hierarchyComplete(b, cid)) return .{ .e = .absent, .cid = cid, .fid = null };
                }
                return .{ .e = .extension, .cid = cid, .fid = null };
            }
        },
        .property => {
            // A property access resolves only to properties: a receiver whose
            // sole member of the name is a function is skipped, as Kotlin
            // skips it, and the walk goes on outward.
            if (propertyOnChain(b, cid, name, 0) or emit.extensionPropOnHead(b, head, name)) {
                return .{ .e = .declares, .cid = cid, .fid = null };
            }
            if (!functionOnChain(b, cid, name, 0) and b.module.classHierarchyDeclaresMember(cid, name)) {
                return .{ .e = .property_unproven, .cid = cid, .fid = null };
            }
        },
        .classifier => {
            // The class rows record every nested classifier, so the question
            // is complete wherever no class on the chain is a stub.
            if (nestedClassifierOnChain(b, cid, name, 0) != null) return .{ .e = .declares, .cid = cid, .fid = null };
            if (chainHasStub(b, cid, 0)) return .{ .e = .incomplete, .cid = cid, .fid = null };
            return .{ .e = .absent, .cid = cid, .fid = null };
        },
    }
    if (!hierarchyComplete(b, cid)) return .{ .e = .incomplete, .cid = cid, .fid = null };
    return .{ .e = .absent, .cid = cid, .fid = null };
}

/// The register holding the lexical `this`, materialised from the capture
/// slot only when a hit needs it.
fn thisRegister(b: *FuncBuilder) Allocator.Error!?Reg {
    if (b.resolve("this")) |r| return r;
    if (b.capturesThisSlot() or b.knowsOuter("this")) return try lambda_body.resolveCapture(b, "this");
    return null;
}

/// Run the walk for `name`. `arity` is the call's argument count for a call
/// and null for a read or write; `site` labels the probe row.
pub fn walk(b: *FuncBuilder, name: []const u8, arity: ?usize, kind: Kind, site: []const u8) Allocator.Error!Verdict {
    const v = try walkInner(b, name, arity, kind, null);
    note(b, name, site, v);
    return v;
}

/// The walk for a call, carrying the call's argument shapes: a receiver
/// binds the call when one of its members accepts them, and a member set
/// the arity alone leaves open is settled by the resolver.
pub fn walkCall(
    b: *FuncBuilder,
    ident: ast.Ident,
    args: []const ast.Expr,
    ast_arg_names: []const ?[]const u8,
    site: []const u8,
) Allocator.Error!Verdict {
    const name = ident.name;
    const file = ident.span.file;
    var shape_set = try type_probe.buildStaticReturnArgShapes(b, args, ast_arg_names);
    defer shape_set.deinit(b.allocator);
    const owned_bounds = try b.typeParamBoundsSlice();
    defer if (owned_bounds) |bounds| b.allocator.free(bounds);
    const query = CallQuery{
        .shapes = shape_set.shapes,
        .file = file,
        .lexical_owner = emit.ownerClassIdOf(b, file),
        .bounds = owned_bounds orelse &.{},
        .ident = ident,
        .args = args,
        .ast_arg_names = ast_arg_names,
    };
    const v = try walkInner(b, name, args.len, .call, &query);
    note(b, name, site, v);
    return v;
}

/// The member call a `member` verdict of `walkCall` names, lowered on the
/// receiver's register through the resolved-member ladder as a call on
/// `this` of that head. Null where the ladder declines, which leaves the
/// caller's form in place.
pub fn lowerWalkedMemberCall(
    b: *FuncBuilder,
    hit: Hit,
    name: ast.Ident,
    args: []const ast.Expr,
    ast_arg_names: []const ?[]const u8,
    ast_type_args: []const ast.TypeRef,
    site: []const u8,
) Allocator.Error!?Reg {
    const ty = ir.TypeRef{ .name = hit.head, .nullable = false, .args = &.{} };
    if (hit.via_extension) {
        // The extension's receiver is an expression the call site never
        // wrote: the ambient `this`, or the labeled `this@<label>` a splice
        // or body bound for a receiver further out.
        const ambient = b.resolve("this") orelse b.capture_regs.get("this");
        const qualifier: ?ast.Ident = if (hit.label) |l|
            (if (ambient != null and ambient.? == hit.reg) null else ast.Ident{ .name = l, .span = name.span })
        else if (ambient != null and ambient.? == hit.reg)
            null
        else
            return null;
        const recv_expr = ast.Expr{ .This = .{ .qualifier = qualifier, .span = name.span } };
        if (try member_call.lowerResolvedExtensionCall(b, &recv_expr, name, args, ast_arg_names, ast_type_args, ty, false)) |r| {
            audit.orEmitAudit(b, site, "Call/walked-extension", name.name);
            return r;
        }
        audit.orEmitAudit(b, site, "walked-extension-declined", name.name);
        return null;
    }
    const this_expr = ast.Expr{ .This = .{ .qualifier = null, .span = name.span } };
    const outcome = try member_call.lowerResolvedMemberCall(
        b,
        &this_expr,
        name,
        args,
        ast_arg_names,
        ast_type_args,
        ty,
        .{ .reg = hit.reg, .non_null = true },
    );
    switch (outcome) {
        .lowered => |r| {
            audit.orEmitAudit(b, site, "Call/walked-member", name.name);
            return r;
        },
        .deferred => audit.orEmitAudit(b, site, "walked-member-deferred", name.name),
        .none => audit.orEmitAudit(b, site, "walked-member-declined", name.name),
    }
    return null;
}

/// Whether a tower entry nearer than `ti` carries `lbl`, so `this@<lbl>`
/// names it and not entry `ti`.
fn labelShadowedInTower(b: *FuncBuilder, ti: usize, lbl: []const u8) bool {
    for (b.implicit_receiver_tower.items[0..ti]) |e| {
        if (e.label) |l| if (std.mem.eql(u8, l, lbl)) return true;
    }
    return false;
}

/// Subject `i`'s label, when no subject bound after it (nearer) carries the
/// same one; `this@<label>` would name the nearer subject.
fn subjectLabel(sbs: []const build.SubjectBind, i: usize) ?[]const u8 {
    const lbl = sbs[i].label orelse return null;
    for (sbs[i + 1 ..]) |sb| {
        if (sb.label) |l| if (std.mem.eql(u8, l, lbl)) return null;
    }
    return lbl;
}

/// The register the own receiver's hit binds to, materialised only for a hit.
/// The register holding the dispatch receiver of the member extension this
/// body, or an enclosing one, belongs to: the body's own load, else the
/// `this@<Owner>` slot bound at its entry, captured through any closure.
pub fn dispatchRegister(b: *FuncBuilder, owner: []const u8) Allocator.Error!?Reg {
    if (b.dispatchThisReg()) |r| return r;
    // The capture record keeps the slot name, so it lives as long as the build.
    const slot = try std.fmt.allocPrint(b.allocator, "this@{s}", .{owner});
    if (b.resolve(slot)) |r| return r;
    if (b.knowsOuter(slot)) {
        const r = try b.loadCaptureHoisted(slot);
        try b.bind(slot, r);
        return r;
    }
    return null;
}

/// An enclosing class that declares the name, reached from the owner instance
/// along the inner-class outer links: one `LoadOuterThis` per hop, from the
/// body's own `this`, or the captured `this` when the closure's tower starts
/// at the owner. A hop through a class that is not inner has no instance to
/// load, and the answer stays with the enclosing-member set.
fn outerInstanceHit(b: *FuncBuilder, name: []const u8, arity: ?usize, kind: Kind, query: ?*const CallQuery) Allocator.Error!?Verdict {
    const owner = b.ownerClass() orelse return null;
    // `cur` is the class of the instance `loads` hops out from the base
    // register; in an inner class's constructor context the base is the
    // enclosing instance already.
    var cur = owner;
    var loads: usize = 0;
    if (b.thisIsOuter()) {
        if (b.capturesThisSlot()) return null;
        cur = b.module.registry.enclosing_class.get(owner) orelse return null;
    }
    var depth: usize = 0;
    while (depth < 32) : (depth += 1) {
        if (!std.mem.eql(u8, cur, owner)) {
            const r = try entryFor(b, cur, name, arity, kind, query);
            switch (r.e) {
                .declares => {
                    var reg: Reg = blk: {
                        if (b.capturesThisSlot()) {
                            if (!b.implicit_receiver_tower_known or b.implicit_receiver_tower.items.len == 0) return null;
                            if (!std.mem.eql(u8, b.implicit_receiver_tower.items[0].head, owner)) return null;
                            break :blk (try closureThisRegister(b)) orelse return null;
                        }
                        if (b.recvTy() != null and !b.thisIsOuter()) break :blk (try dispatchRegister(b, owner)) orelse return null;
                        break :blk (try ownRegister(b)) orelse return null;
                    };
                    var h: usize = 0;
                    while (h < loads) : (h += 1) {
                        const dst = b.allocReg();
                        try b.push(.{ .LoadOuterThis = .{ .dst = dst, .src = reg } });
                        reg = dst;
                    }
                    return .{ .member = .{ .reg = reg, .head = cur, .cid = r.cid.?, .fid = r.fid, .via_extension = r.via_extension } };
                },
                .absent => {},
                else => return null,
            }
        }
        // One hop out: only an inner class's instance links to its outer.
        const cur_cid = classOfHead(b, cur) orelse return null;
        if (cur_cid.int() >= b.module.classes.items.len or !b.module.classes.items[cur_cid.int()].is_inner) return null;
        cur = b.module.registry.enclosing_class.get(cur) orelse
            b.module.registry.enclosing_class.get(b.module.classes.items[cur_cid.int()].fqn) orelse return null;
        loads += 1;
    }
    return null;
}

/// `head` names `target` or a class extending it.
fn classNamedOrExtends(b: *FuncBuilder, head: []const u8, target: []const u8) bool {
    const h = simpleClassName(head);
    return std.mem.eql(u8, h, target) or b.module.classIsOrExtends(h, target);
}

fn simpleClassName(h: []const u8) []const u8 {
    var head = std.mem.trimEnd(u8, h, "?");
    if (std.mem.findScalar(u8, head, '<')) |lt| head = head[0..lt];
    return if (std.mem.findScalarLast(u8, head, '.')) |i| head[i + 1 ..] else head;
}

/// The register holding the instance of class `target` in scope here, by
/// structure: the own or dispatch register when `target` is the owner, one
/// `LoadOuterThis` per hop when `target` encloses the owner through inner
/// classes, and a closure's captured `this` or `this@<label>` slot when its
/// tower names `target`. Null when nothing here names it, which leaves the
/// site to the runtime's qualified-`this` walk.
pub fn instanceOfClassReg(b: *FuncBuilder, target_in: []const u8) Allocator.Error!?Reg {
    const target = simpleClassName(target_in);
    if (target.len == 0) return null;
    const owner = b.ownerClass();
    if (b.capturesThisSlot()) {
        if (!b.implicit_receiver_tower_known) return null;
        const tower = b.implicit_receiver_tower.items;
        for (tower, 0..) |entry, ti| {
            if (entry.head.len == 0 or !classNamedOrExtends(b, entry.head, target)) continue;
            if (ti == 0) return try closureThisRegister(b);
            const lbl = entry.label orelse return null;
            if (labelShadowedInTower(b, ti, lbl)) return null;
            for (b.subject_binds.items) |sb| if (sb.label) |l| if (std.mem.eql(u8, l, lbl)) return null;
            const slot = try std.fmt.allocPrint(b.allocator, "this@{s}", .{lbl});
            if (b.resolve(slot) == null and !b.knowsOuter(slot)) return null;
            return try lambda_body.resolveCapture(b, slot);
        }
        // The captured `this` is the owner's instance: hop out from it.
        const oc = owner orelse return null;
        if (tower.len == 0 or !std.mem.eql(u8, simpleClassName(tower[0].head), simpleClassName(oc))) return null;
        const base = (try closureThisRegister(b)) orelse return null;
        return try outerHopsTo(b, oc, target, base, 0);
    }
    // The spliced subjects `this` reaches, innermost first: inside
    // `with(other) { 5.scaled() }` the `Scaled` the call dispatches on is
    // `other`, ahead of the body's own receiver of the same type. A subject
    // `this` does not reach is hidden, as the walk and the tower treat it.
    {
        const sbs = b.subject_binds.items;
        var expect: ?Reg = b.resolve("this");
        var i = sbs.len;
        while (i > 0) {
            i -= 1;
            const reach = expect orelse break;
            if (sbs[i].reg != reach) continue;
            if (!sbs[i].head_hint) if (sbs[i].head) |h| {
                if (classNamedOrExtends(b, h, target)) return sbs[i].reg;
            };
            expect = sbs[i].prior_this;
        }
    }
    // An extension receiver of the class, or a subclass of it, is that
    // instance: `dp.toPx()` inside a `MeasureScope` body dispatches on the
    // `Density` the scope is.
    if (b.recvTy()) |rt| {
        if (classNamedOrExtends(b, rt, target)) return try ownRegister(b);
    }
    const oc = owner orelse return null;
    if (classNamedOrExtends(b, oc, target)) {
        if (b.thisIsOuter()) return null;
        if (b.recvTy() != null) return try dispatchRegister(b, oc);
        return try ownRegister(b);
    }
    if (b.thisIsOuter()) {
        const enc = b.module.registry.enclosing_class.get(oc) orelse return null;
        const base = (try ownRegister(b)) orelse return null;
        return try outerHopsTo(b, enc, target, base, 0);
    }
    const base: Reg = if (b.recvTy() != null) (try dispatchRegister(b, oc)) orelse return null else (try ownRegister(b)) orelse return null;
    return try outerHopsTo(b, oc, target, base, 0);
}

/// `base` holds an instance of `from`; the instance of `target` reached by
/// hopping out along inner-class outer links, `LoadOuterThis` per hop. Null
/// when a class on the way is not inner or `target` does not enclose `from`.
fn outerHopsTo(b: *FuncBuilder, from: []const u8, target: []const u8, base: Reg, preloaded: usize) Allocator.Error!?Reg {
    var cur = from;
    var loads: usize = preloaded;
    var depth: usize = 0;
    while (depth < 32) : (depth += 1) {
        if (std.mem.eql(u8, simpleClassName(cur), target)) {
            var reg = base;
            var h: usize = 0;
            while (h < loads) : (h += 1) {
                const dst = b.allocReg();
                try b.push(.{ .LoadOuterThis = .{ .dst = dst, .src = reg } });
                reg = dst;
            }
            return reg;
        }
        const cur_cid = classOfHead(b, cur) orelse return null;
        if (cur_cid.int() >= b.module.classes.items.len or !b.module.classes.items[cur_cid.int()].is_inner) return null;
        cur = b.module.registry.enclosing_class.get(cur) orelse
            b.module.registry.enclosing_class.get(b.module.classes.items[cur_cid.int()].fqn) orelse return null;
        loads += 1;
    }
    return null;
}

fn ownRegister(b: *FuncBuilder) Allocator.Error!?Reg {
    const sbs = b.subject_binds.items;
    if (sbs.len != 0) return sbs[0].prior_this;
    if (b.spliceRecvTy() != null) return null;
    return try thisRegister(b);
}

/// The register a closure body reads its captured `this` from: the one its
/// bottom subject displaced, else the capture itself, loaded on first use.
/// Under an extension splice with no subject the ambient `this` is the
/// spliced receiver, and the capture has no register here.
fn closureThisRegister(b: *FuncBuilder) Allocator.Error!?Reg {
    const sbs = b.subject_binds.items;
    if (sbs.len != 0) {
        if (sbs[0].prior_this) |r| return r;
        return try lambda_body.resolveCapture(b, "this");
    }
    if (b.spliceRecvTy() != null) return null;
    return try thisRegister(b);
}

fn walkInner(b: *FuncBuilder, name: []const u8, arity: ?usize, kind: Kind, query: ?*const CallQuery) Allocator.Error!Verdict {
    // A captured name an anonymous object's body reaches as a runtime-scoped
    // binding is nearer than any global.
    if (build.anonCaptureBinds(name) or decl_mod.isLowerAnonCapture(name)) return .{ .undecided = .scoped_capture };

    // A name the own class makes visible bare — an enum entry, a companion
    // member, a nested classifier — is not in any hierarchy's member set, so
    // no receiver's answer about it is complete.
    if (b.hasOwnMember(name)) {
        const owner_declares = blk: {
            const oc = b.ownerClass() orelse break :blk false;
            const cid = classOfHead(b, oc) orelse break :blk false;
            break :blk b.module.classHierarchyDeclaresMember(cid, name);
        };
        if (!owner_declares) return .{ .undecided = .own_static_name };
    }

    // A smart-cast `this` narrows the innermost receiver to a subtype whose
    // members the declared head does not list: `when (this) { is T -> }`
    // records it as the this-narrow, `if (this is T)` as the declared type
    // of the local named `this`. The declared type describes the
    // declaration's own receiver, so it is read only where `this` is still
    // that receiver: no splice window has rebound it and no closure captures it.
    const plain_body = b.subject_binds.items.len == 0 and b.spliceRecvTy() == null and !b.capturesThisSlot();
    if (b.thisNarrow() orelse (if (plain_body) b.localDeclType("this") else null)) |nh| {
        const r = try entryFor(b, nh, name, arity, kind, query);
        switch (r.e) {
            .declares => return .{ .member = .{ .reg = (try thisRegister(b)) orelse return .{ .undecided = .this_unavailable }, .head = nh, .cid = r.cid.?, .fid = r.fid, .via_extension = r.via_extension } },
            .arity_unproven => return .{ .undecided = .member_arity_unproven },
            .property_unproven => return .{ .undecided = .property_unproven },
            .extension => return .{ .undecided = .extension_unproven },
            .unresolvable => return .{ .undecided = .head_unresolvable },
            .incomplete => return .{ .undecided = .hierarchy_incomplete },
            .absent => {},
        }
    }

    // The spliced subjects `this` reaches, innermost first, as the tower a
    // closure inherits walks them: the innermost subject in scope is the one
    // `this` names now, and each further one is the `this` the nearer subject
    // displaced. A subject `this` does not reach is hidden: the receiver of an
    // inline function whose block takes no receiver (`lock.synchronized { }`)
    // is bound for the function's own body and is no receiver of the block.
    // Each visible subject carries the head lowering knew at the splice.
    const sbs = b.subject_binds.items;
    if (b.resolve("this")) |this_now| {
        // A closure body's `this` is its own declared receiver, bound at its
        // prologue, or the `this` it captured; any other register was bound by
        // a window that recorded no subject, and nothing here names it.
        if (sbs.len == 0 and b.capturesThisSlot() and b.recvTy() == null) {
            const captured: ?Reg = b.capture_regs.get("this");
            if (captured == null or captured.? != this_now) return .{ .undecided = .this_rebound_unknown };
        }
    }
    var expect: ?Reg = b.resolve("this") orelse b.capture_regs.get("this");
    var i = sbs.len;
    while (i > 0) {
        i -= 1;
        const reach = expect orelse break;
        if (sbs[i].reg != reach) continue;
        if (sbs[i].head_hint) return .{ .undecided = .subject_head_unknown };
        const h = sbs[i].head orelse return .{ .undecided = .subject_head_unknown };
        if (typeParamShaped(h)) return .{ .undecided = .subject_head_unknown };
        const r = try entryFor(b, h, name, arity, kind, query);
        switch (r.e) {
            .declares => return .{ .member = .{ .reg = sbs[i].reg, .head = h, .cid = r.cid.?, .fid = r.fid, .label = subjectLabel(sbs, i), .via_extension = r.via_extension } },
            .arity_unproven => return .{ .undecided = .member_arity_unproven },
            .property_unproven => return .{ .undecided = .property_unproven },
            .extension => return .{ .undecided = .extension_unproven },
            .unresolvable => return .{ .undecided = .head_unresolvable },
            .incomplete => return .{ .undecided = .hierarchy_incomplete },
            .absent => {},
        }
        expect = sbs[i].prior_this;
    }
    // Beneath the visible subjects stands the body's own `this`, the one the
    // bottom subject displaced: in a closure that had not loaded its captured
    // `this` when the subject bound, the capture itself. A different register
    // was bound by a window that recorded no subject.
    if (sbs.len != 0) {
        const own: ?Reg = sbs[0].prior_this orelse (if (b.capturesThisSlot()) b.capture_regs.get("this") else null);
        const same = if (expect) |e| (if (own) |o| e == o else false) else own == null;
        if (!same) return .{ .undecided = .this_rebound_unknown };
    }

    // The declaration's own receiver, beneath every subject. Inside a splice
    // the ambient `this` IS the innermost subject, so the own receiver is the
    // one bound before any subject did. An extension splice binds `this` to
    // the spliced receiver without a subject bind, so with one active the
    // ambient `this` is that receiver, checked first, and the own receiver has
    // no register at all.
    if (b.spliceRecvTy()) |sh| {
        if (sbs.len == 0) {
            const r = try entryFor(b, sh, name, arity, kind, query);
            switch (r.e) {
                .declares => return .{ .member = .{ .reg = (try thisRegister(b)) orelse return .{ .undecided = .this_unavailable }, .head = sh, .cid = r.cid.?, .fid = r.fid, .via_extension = r.via_extension } },
                .arity_unproven => return .{ .undecided = .member_arity_unproven },
                .property_unproven => return .{ .undecided = .property_unproven },
                .extension => return .{ .undecided = .extension_unproven },
                .unresolvable => return .{ .undecided = .head_unresolvable },
                .incomplete => return .{ .undecided = .hierarchy_incomplete },
                .absent => {},
            }
        }
    }
    // A closure's receivers are the tower its construction site recorded:
    // the captured `this` first, then every receiver that stood behind it
    // there. A site that recorded none leaves the captured `this` unnamed,
    // and a name it could bind is not the global.
    if (b.capturesThisSlot()) {
        if (!b.implicit_receiver_tower_known) return .{ .undecided = .closure_tower_unknown };
        for (b.implicit_receiver_tower.items, 0..) |entry, ti| {
            // A subject whose head the construction site did not know, or
            // recorded as a callee's type parameter uninstantiated: `T` there
            // is the callee's, not the one of that name in scope here.
            if (entry.head.len == 0 or typeParamShaped(entry.head)) return .{ .undecided = .subject_head_unknown };
            const r = try entryFor(b, entry.head, name, arity, kind, query);
            switch (r.e) {
                .declares => {
                    if (ti != 0) {
                        // A receiver behind the captured `this` is reached
                        // through the `this@<label>` slot its splice bound,
                        // captured like any other name the body reads.
                        const lbl = entry.label orelse return .{ .undecided = .tower_outer_declares };
                        // `this@<label>` names the INNERMOST receiver of that
                        // label: a nearer entry with the same one (two nested
                        // `let`s), in the tower or among this body's own
                        // subjects, makes the slot another receiver's.
                        if (labelShadowedInTower(b, ti, lbl)) return .{ .undecided = .tower_outer_declares };
                        for (sbs) |sb| if (sb.label) |l| if (std.mem.eql(u8, l, lbl)) return .{ .undecided = .tower_outer_declares };
                        const slot = try std.fmt.allocPrint(b.allocator, "this@{s}", .{lbl});
                        if (b.resolve(slot) == null and !b.knowsOuter(slot)) return .{ .undecided = .tower_outer_declares };
                        const reg = try lambda_body.resolveCapture(b, slot);
                        return .{ .member = .{ .reg = reg, .head = entry.head, .cid = r.cid.?, .fid = r.fid, .label = lbl, .via_extension = r.via_extension } };
                    }
                    // The captured `this` itself: the register the closure
                    // loaded it into, or the `this` its bottom subject displaced.
                    const reg = (try closureThisRegister(b)) orelse return .{ .undecided = .this_unavailable };
                    return .{ .member = .{ .reg = reg, .head = entry.head, .cid = r.cid.?, .fid = r.fid, .via_extension = r.via_extension } };
                },
                .arity_unproven => return .{ .undecided = .member_arity_unproven },
                .property_unproven => return .{ .undecided = .property_unproven },
                .extension => return .{ .undecided = .extension_unproven },
                .unresolvable => return .{ .undecided = .head_unresolvable },
                .incomplete => return .{ .undecided = .hierarchy_incomplete },
                .absent => {},
            }
        }
        if (try outerInstanceHit(b, name, arity, kind, query)) |v| return v;
        if (b.hasEnclosingMember(name) and !b.hasOwnMember(name)) return .{ .undecided = .outer_class_declares };
        if (b.ownerClass()) |oc| {
            if (outerChainDeclares(b, oc, name)) return .{ .undecided = .outer_class_declares };
        }
        return .global;
    }

    // The extension receiver, then the dispatch receiver: `fun Owner.Recv.f()`
    // sees `Recv` before `Owner`. A plain member body has only the owner, and
    // a lambda inside either carries the enclosing receiver.
    var heads_buf: [3][]const u8 = undefined;
    var n_heads: usize = 0;
    if (b.recvTy()) |h| {
        heads_buf[n_heads] = h;
        n_heads += 1;
    } else if (b.enclosingRecvTy()) |h| {
        heads_buf[n_heads] = h;
        n_heads += 1;
    }
    if (b.ownerClass()) |oc| {
        var dup = false;
        for (heads_buf[0..n_heads]) |h| {
            if (std.mem.eql(u8, h, oc)) dup = true;
        }
        if (!dup) {
            heads_buf[n_heads] = oc;
            n_heads += 1;
        }
    }
    for (heads_buf[0..n_heads], 0..) |h, hi| {
        const r = try entryFor(b, h, name, arity, kind, query);
        switch (r.e) {
            .declares => {
                // Only the first head is the value in `this`; the dispatch
                // receiver behind an extension receiver is the frame's own
                // slot in the body, the captured `this@<Owner>` in a closure.
                if (hi != 0) {
                    const dr = (try dispatchRegister(b, h)) orelse return .{ .undecided = .dispatch_receiver_unreachable };
                    return .{ .member = .{ .reg = dr, .head = h, .cid = r.cid.?, .fid = r.fid, .via_extension = r.via_extension } };
                }
                const reg = (try ownRegister(b)) orelse return .{ .undecided = .own_receiver_unreachable };
                return .{ .member = .{ .reg = reg, .head = h, .cid = r.cid.?, .fid = r.fid, .via_extension = r.via_extension } };
            },
            .arity_unproven => return .{ .undecided = .member_arity_unproven },
            .property_unproven => return .{ .undecided = .property_unproven },
            .extension => return .{ .undecided = .extension_unproven },
            .unresolvable => return .{ .undecided = .head_unresolvable },
            .incomplete => return .{ .undecided = .hierarchy_incomplete },
            .absent => {},
        }
    }

    // The enclosing classes. An inner class reaches its outer instance by
    // structure; a nested one has no instance of its outer, and lowering
    // records the enclosing member names as one set with no class behind
    // each name.
    if (try outerInstanceHit(b, name, arity, kind, query)) |v| return v;
    if (b.hasEnclosingMember(name) and !b.hasOwnMember(name)) return .{ .undecided = .outer_class_declares };
    if (b.ownerClass()) |oc| {
        if (outerChainDeclares(b, oc, name)) return .{ .undecided = .outer_class_declares };
    }

    // A receiver context in which the walk examined no receiver at all has a
    // `this` it cannot rule out.
    if (n_heads == 0 and sbs.len == 0 and probe.inReceiverContext(b)) return .{ .undecided = .this_unavailable };

    return .global;
}

/// How a member the walk found is called: directly, when nothing can override
/// it — a private or final declaration has no slot — or through its slot.
pub const CallForm = enum { direct, virtual };

pub fn callForm(b: *FuncBuilder, hit: Hit, fid: ir.FuncId) ?CallForm {
    const d = b.module.dispatchForTarget(hit.cid, fid) orelse return null;
    return switch (d) {
        .direct => .direct,
        .virtual => .virtual,
        .deferred => null,
    };
}

/// Emit the call of `fid` on the walk's receiver with `n` already-lowered
/// arguments at `run_start`, the receiver being placed in `recv_slot`, the
/// register allocated just before the run.
pub fn emitMemberCall(b: *FuncBuilder, hit: Hit, fid: ir.FuncId, form: CallForm, recv_slot: Reg, run_start: Reg, n: u32) Allocator.Error!Reg {
    const dst = b.allocReg();
    switch (form) {
        .direct => {
            try b.push(.{ .Move = .{ .dst = recv_slot, .src = hit.reg } });
            const ctx_handed = try probe_mod.contextHandoverBegin(b, fid, &.{});
            try b.push(.{ .Call = .{
                .dst = dst,
                .func = fid,
                .args = recv_slot,
                .n_args = n + 1,
                .exact = true,
            } });
            try probe_mod.contextHandoverEnd(b, ctx_handed);
        },
        .virtual => try b.push(.{ .CallVirtual = .{
            .dst = dst,
            .receiver = hit.reg,
            .slot = ir.MethodSlotId.fromFunc(fid),
            .args = run_start,
            .n_args = n,
        } }),
    }
    return dst;
}

/// A member read on the receiver the walk chose. The field is spelled with
/// the declaring class (`$sgetter$<owner>\u{1f}<prop>`), the form every bare
/// own-member read carries: the link pass settles it to the class's slot,
/// its accessor or the family's property slot, and the runtime's by-name
/// path reads the owner off it where the link had no answer. A private
/// accessor is bound here outright when its function already exists: no
/// subclass can redeclare it, and a same-named private property below is
/// another declaration.
pub fn emitRead(b: *FuncBuilder, hit: Hit, name: []const u8) Allocator.Error!Reg {
    const dst = b.allocReg();
    // The class's registered name, which is what the runtime's decoders and
    // the link pass compare a receiver's class against.
    const owner_name: []const u8 = if (hit.cid.int() < b.module.classes.items.len) b.module.classes.items[hit.cid.int()].name else "";
    const nm = if (owner_name.len != 0) blk: {
        const qual = try std.fmt.allocPrint(b.allocator, "$sgetter${s}\u{1f}{s}", .{ owner_name, name });
        break :blk try b.module.internConst(b.allocator, .{ .String = qual });
    } else try b.module.internConst(b.allocator, .{ .String = name });
    const private_getter = privateGetterOf(b, hit.cid, name);
    try b.push(.{ .GetField = .{
        .dst = dst,
        .receiver = hit.reg,
        .field = nm,
        .own_cls = hit.cid,
        .own_kind = if (private_getter != null) .getter else .none,
        .own_slot = if (private_getter) |g| g.int() else 0,
    } });
    return dst;
}

/// The private getter `cid` declares for `name`, when its function exists.
fn privateGetterOf(b: *FuncBuilder, cid: ir.ClassId, name: []const u8) ?ir.FuncId {
    if (cid.int() >= b.module.classes.items.len) return null;
    const c = &b.module.classes.items[cid.int()];
    if (c.name.len == 0) return null;
    var buf: [256]u8 = undefined;
    const key = std.fmt.bufPrint(&buf, "__get_{s}_{s}", .{ c.name, name }) catch return null;
    var found: ?ir.FuncId = null;
    for (b.module.funcsBySimpleName(key)) |fid| {
        const f = b.module.funcById(fid) orelse continue;
        if (!f.hasBody()) continue;
        if (found != null) return null;
        found = fid;
    }
    const fid = found orelse return null;
    const sig = b.module.decl_sigs.get(fid.int()) orelse return null;
    return if (sig.visibility == .Private) fid else null;
}

/// A member write on the receiver the walk chose.
pub fn emitWrite(b: *FuncBuilder, hit: Hit, name: []const u8, value: Reg) Allocator.Error!void {
    const nm = try b.module.internConst(b.allocator, .{ .String = name });
    try b.push(.{ .SetField = .{
        .receiver = hit.reg,
        .field = nm,
        .value = value,
        .own_cls = hit.cid,
    } });
}

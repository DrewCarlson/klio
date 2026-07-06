//! Annotation use-site targeting (Kotlin 2.4): the full acceptance
//! matrices for the `@all:` property meta-target (A1-A12) and the LV 2.4
//! defaulting rule for target-less property annotations (B1-B12).
//!
//! Diagnostic rows run lexer -> parser -> resolver -> typeck and assert
//! the compiler-named diagnostic and its message. Placement rows lower
//! the program through the real `interp_ir` build and assert the exact
//! per-anchor annotation records on the runtime class metadata (the
//! surface reflection-driven consumers such as the serializer read).

const std = @import("std");
const parity = @import("parity");
const lexer = @import("lexer");
const parser = @import("parser");
const resolver = @import("resolver");
const typeck = @import("typeck");
const interp_ir = @import("interp_ir");
const runtime = @import("runtime");
const span = @import("span");
const diagnostics = @import("diagnostics");

const FileId = span.FileId;
const Diagnostic = diagnostics.Diagnostic;
const PropertyAnchors = runtime.PropertyAnchors;

const TMP_DIR = "/tmp/klio_itest_annotation_targets";

// The klio pipeline installs process-global lowering/VM state backed by the
// run's allocator; one file-scoped arena over the page allocator backs every
// run here (matching the other parity itests).
var file_arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);

/// The annotation-class declarations of test matrix A.
const DECLS_A =
    \\@Target(AnnotationTarget.VALUE_PARAMETER, AnnotationTarget.PROPERTY,
    \\        AnnotationTarget.FIELD, AnnotationTarget.PROPERTY_GETTER)
    \\annotation class Wide
    \\@Target(AnnotationTarget.FIELD) annotation class FieldOnly
    \\@Target(AnnotationTarget.PROPERTY_GETTER) annotation class GetOnly
    \\@Target(AnnotationTarget.FUNCTION) annotation class FunOnly
    \\@Target(AnnotationTarget.VALUE_PARAMETER) annotation class ParamOnly
    \\
;

/// The annotation-class declarations of test matrix B.
const DECLS_B =
    \\@Target(AnnotationTarget.VALUE_PARAMETER, AnnotationTarget.PROPERTY, AnnotationTarget.FIELD)
    \\annotation class PPF
    \\@Target(AnnotationTarget.VALUE_PARAMETER, AnnotationTarget.FIELD) annotation class PF
    \\@Target(AnnotationTarget.VALUE_PARAMETER) annotation class P
    \\@Target(AnnotationTarget.PROPERTY, AnnotationTarget.FIELD) annotation class RF
    \\@Target(AnnotationTarget.FIELD) annotation class F
    \\@Target(AnnotationTarget.PROPERTY_GETTER) annotation class G
    \\
;

fn cat(a: std.mem.Allocator, decls: []const u8, body: []const u8) []const u8 {
    return std.fmt.allocPrint(a, "{s}{s}", .{ decls, body }) catch @panic("OOM");
}

// ---------------------------------------------------------------------------
// Diagnostics harness (lexer -> parser -> resolver -> typeck).
// ---------------------------------------------------------------------------

/// Every diagnostic (parser + typeck) the front-end emits for `src`.
fn frontendDiags(a: std.mem.Allocator, src: []const u8) ![]const Diagnostic {
    var lx = try lexer.Lexer.init(a, FileId.from(0), src);
    const lexed = try lx.tokenize();
    const p = parser.Parser.new(a, FileId.from(0), src, lexed.tokens);
    const kf = p.parseFile();
    var out: std.ArrayList(Diagnostic) = .empty;
    try out.appendSlice(a, p.diagnostics.diags());
    if (!p.diagnostics.hasErrors()) {
        var r = try resolver.resolve(a, &kf);
        var tc = try typeck.typecheck(a, &kf, &r);
        try out.appendSlice(a, tc.diagnostics.diags());
    }
    return out.items;
}

/// Assert `src` produces a diagnostic whose factory name is `factory_name`
/// and whose message contains `msg_needle`.
fn assertDiag(src: []const u8, factory_name: []const u8, msg_needle: []const u8) !void {
    const a = file_arena.allocator();
    const diags = try frontendDiags(a, src);
    for (diags) |d| {
        const fname = if (d.factory) |f| f.name else continue;
        if (!std.mem.eql(u8, fname, factory_name)) continue;
        if (std.mem.indexOf(u8, d.message, msg_needle) != null) return;
    }
    std.debug.print("expected `{s}` containing `{s}`; got:\n", .{ factory_name, msg_needle });
    for (diags) |d| {
        const fname = if (d.factory) |f| f.name else "-";
        std.debug.print("  [{s}] {s}\n", .{ fname, d.message });
    }
    return error.MissingExpectedDiagnostic;
}

/// Assert `src` type-checks with no error diagnostics.
fn assertNoErrors(src: []const u8) !void {
    const a = file_arena.allocator();
    const diags = try frontendDiags(a, src);
    for (diags) |d| {
        if (d.severity == .Error) {
            std.debug.print("unexpected error: {s}\n", .{d.message});
            return error.UnexpectedError;
        }
    }
}

fn assertKlio(name: []const u8, src: []const u8, expected: []const u8) !void {
    const a = file_arena.allocator();

    var threaded: std.Io.Threaded = .init(a, .{});
    defer threaded.deinit();
    const io = threaded.io();

    std.Io.Dir.cwd().createDirPath(io, TMP_DIR) catch {};
    const path = try std.fmt.allocPrint(a, "{s}/{s}.kt", .{ TMP_DIR, name });
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = src });

    const res = try parity.runWithPacks(a, io, path);
    switch (res) {
        .ok => |got| try std.testing.expectEqualStrings(expected, got),
        .err => |m| {
            std.debug.print("klio run failed for `{s}`: {s}\n", .{ name, m });
            return error.KlioRunFailed;
        },
    }
}

// ---------------------------------------------------------------------------
// Placement harness: lower through the real interp_ir build and read the
// per-anchor annotation records off the runtime class metadata.
// ---------------------------------------------------------------------------

const Lowered = struct {
    built: interp_ir.build.BuiltModule,

    /// Anchors of a primary-constructor property.
    fn ctorAnchors(self: *const Lowered, class_name: []const u8, prop: []const u8) !PropertyAnchors {
        const def = self.built.classes.get(class_name) orelse return error.ClassNotFound;
        const cd = def.asPtr();
        for (cd.primary_params) |*p| {
            if (std.mem.eql(u8, p.name, prop)) return p.anchors;
        }
        return error.PropertyNotFound;
    }

    /// Anchors of a class-body property.
    fn bodyAnchors(self: *const Lowered, class_name: []const u8, prop: []const u8) !PropertyAnchors {
        const def = self.built.classes.get(class_name) orelse return error.ClassNotFound;
        const cd = def.asPtr();
        for (cd.body_properties) |*p| {
            if (std.mem.eql(u8, p.name, prop)) return p.anchors;
        }
        return error.PropertyNotFound;
    }
};

/// Parse `src` (tolerating parser diagnostics — A8 recovers past its
/// bracket error) and lower it through the interp_ir build.
fn lower(a: std.mem.Allocator, src: []const u8) !Lowered {
    var lx = try lexer.Lexer.init(a, FileId.from(0), src);
    const lexed = try lx.tokenize();
    const p = parser.Parser.new(a, FileId.from(0), src, lexed.tokens);
    const kf = p.parseFile();
    const built = try interp_ir.build.buildModule(a, &kf);
    return .{ .built = built };
}

fn hasRecord(records: []const runtime.AnnotationRecord, name: []const u8) bool {
    for (records) |*rec| {
        if (rec.is(name)) return true;
    }
    return false;
}

/// Assert the exact anchor placement of annotation `name`: present on
/// every anchor named in `expect`, absent from every other one.
fn assertPlacement(anchors: PropertyAnchors, name: []const u8, expect: []const []const u8) !void {
    const anchor_fields = [_][]const u8{ "param", "property", "field", "get", "set", "setparam", "delegate" };
    inline for (anchor_fields) |fname| {
        const got = hasRecord(@field(anchors, fname), name);
        var want = false;
        for (expect) |e| {
            if (std.mem.eql(u8, e, fname)) want = true;
        }
        if (got != want) {
            std.debug.print("anchor `{s}`: expected {}, got {} for @{s}\n", .{ fname, want, got, name });
            return error.WrongPlacement;
        }
    }
}

// ---------------------------------------------------------------------------
// Matrix A: `@all:` meta-target.
// ---------------------------------------------------------------------------

// A1: ctor val — param, property, field, get; no setparam.
test "a01_all_on_ctor_val" {
    _ = file_arena.reset(.retain_capacity);
    const a = file_arena.allocator();
    const src = cat(a, DECLS_A, "class U(@all:Wide val e: String)\nfun main() {}\n");
    try assertNoErrors(src);
    const l = try lower(a, src);
    try assertPlacement(try l.ctorAnchors("U", "e"), "Wide", &.{ "param", "property", "field", "get" });
}

// A2: ctor var — VALUE_PARAMETER also covers setparam.
test "a02_all_on_ctor_var" {
    _ = file_arena.reset(.retain_capacity);
    const a = file_arena.allocator();
    const src = cat(a, DECLS_A, "class U(@all:Wide var e: String)\nfun main() {}\n");
    try assertNoErrors(src);
    const l = try lower(a, src);
    try assertPlacement(try l.ctorAnchors("U", "e"), "Wide", &.{ "param", "property", "field", "get", "setparam" });
}

// A3: member property — no param anchor exists.
test "a03_all_on_member_property" {
    _ = file_arena.reset(.retain_capacity);
    const a = file_arena.allocator();
    const src = cat(a, DECLS_A, "class U { @all:Wide val e: String = \"x\" }\nfun main() {}\n");
    try assertNoErrors(src);
    const l = try lower(a, src);
    try assertPlacement(try l.bodyAnchors("U", "e"), "Wide", &.{ "property", "field", "get" });
}

// A4: custom getter, no backing field — get only, field skipped silently.
test "a04_all_getter_only_no_backing_field" {
    _ = file_arena.reset(.retain_capacity);
    const a = file_arena.allocator();
    const src = cat(a, DECLS_A, "class U { @all:GetOnly val e: String get() = \"x\" }\nfun main() {}\n");
    try assertNoErrors(src);
    const l = try lower(a, src);
    try assertPlacement(try l.bodyAnchors("U", "e"), "GetOnly", &.{"get"});
}

// A5: nothing applicable — error, nothing placed.
test "a05_all_nothing_applicable" {
    _ = file_arena.reset(.retain_capacity);
    const a = file_arena.allocator();
    const src = cat(a, DECLS_A, "class U(@all:FunOnly val e: String)\nfun main() {}\n");
    try assertDiag(src, "WRONG_ANNOTATION_TARGET_WITH_USE_SITE_TARGET", "not applicable to target 'property' and use-site target '@all'");
}

// A6: delegated property anchor is rejected.
test "a06_all_on_delegated_property" {
    _ = file_arena.reset(.retain_capacity);
    const a = file_arena.allocator();
    const src = cat(a, DECLS_A, "class U { @all:Wide val e: String by lazy { \"x\" } }\nfun main() {}\n");
    try assertDiag(src, "INAPPLICABLE_ALL_TARGET", "'@all:' annotations cannot be applied to delegated properties.");
}

// A7: local property anchor is rejected.
test "a07_all_on_local_property" {
    _ = file_arena.reset(.retain_capacity);
    const a = file_arena.allocator();
    const src = cat(a, DECLS_A, "fun f() { @all:Wide val x = 1\nprintln(x) }\nfun main() { f() }\n");
    try assertDiag(src, "INAPPLICABLE_ALL_TARGET", "cannot be applied to local properties, only member or top-level properties are allowed.");
}

// A8: bracket syntax is forbidden under @all; the sibling entry is unaffected.
test "a08_all_multi_annotation_bracket" {
    _ = file_arena.reset(.retain_capacity);
    const a = file_arena.allocator();
    const src = cat(a, DECLS_A, "class U(@all:Wide val e: String, @all:[Wide FieldOnly] val f: String)\nfun main() {}\n");
    try assertDiag(src, "INAPPLICABLE_ALL_TARGET_IN_MULTI_ANNOTATION", "Multiple annotation syntax with '@all:' use-site target is forbidden");
    const l = try lower(a, src);
    try assertPlacement(try l.ctorAnchors("U", "e"), "Wide", &.{ "param", "property", "field", "get" });
}

// A9: param-only annotation lands on param alone, everything else skipped.
test "a09_all_param_only" {
    _ = file_arena.reset(.retain_capacity);
    const a = file_arena.allocator();
    const src = cat(a, DECLS_A, "class U(@all:ParamOnly val e: String)\nfun main() {}\n");
    try assertNoErrors(src);
    const l = try lower(a, src);
    try assertPlacement(try l.ctorAnchors("U", "e"), "ParamOnly", &.{"param"});
}

// A10: @all + @field both resolve to the backing field — repetition.
test "a10_all_plus_field_repeated" {
    _ = file_arena.reset(.retain_capacity);
    const a = file_arena.allocator();
    const src = cat(a, DECLS_A, "class U(@all:FieldOnly @field:FieldOnly val e: String)\nfun main() {}\n");
    try assertDiag(src, "REPEATED_ANNOTATION", "This annotation is not repeatable.");
}

// A11: plain ctor parameter (no val/var) is not a property anchor.
test "a11_all_on_plain_ctor_param" {
    _ = file_arena.reset(.retain_capacity);
    const a = file_arena.allocator();
    const src = cat(a, DECLS_A, "class U(@all:Wide x: String)\nfun main() {}\n");
    try assertDiag(src, "INAPPLICABLE_ALL_TARGET", "constructor parameters without corresponding property (consider adding val/var)");
}

// A12: top-level properties are valid anchors (property, field, get — the
// member expansion of A3 minus param, pinned by the shared machinery's
// unit tests; top-level properties keep no runtime anchor table).
test "a12_all_on_top_level_property" {
    _ = file_arena.reset(.retain_capacity);
    const a = file_arena.allocator();
    const src = cat(a, DECLS_A, "@all:Wide val top: Int = 1\nfun main() { println(top) }\n");
    try assertNoErrors(src);
    try assertKlio("a12", src, "1\n");
}

// ---------------------------------------------------------------------------
// Matrix B: defaulting for annotations without a use-site target.
// ---------------------------------------------------------------------------

// B1: param + property (the LV 2.4 change; old rule placed param only).
test "b01_ppf_ctor_val" {
    _ = file_arena.reset(.retain_capacity);
    const a = file_arena.allocator();
    const src = cat(a, DECLS_B, "class C(@PPF val x: Int)\nfun main() {}\n");
    try assertNoErrors(src);
    const l = try lower(a, src);
    try assertPlacement(try l.ctorAnchors("C", "x"), "PPF", &.{ "param", "property" });
}

// B2: param + field when PROPERTY is absent.
test "b02_pf_ctor_val" {
    _ = file_arena.reset(.retain_capacity);
    const a = file_arena.allocator();
    const src = cat(a, DECLS_B, "class C(@PF val x: Int)\nfun main() {}\n");
    try assertNoErrors(src);
    const l = try lower(a, src);
    try assertPlacement(try l.ctorAnchors("C", "x"), "PF", &.{ "param", "field" });
}

// B3: param only.
test "b03_p_ctor_val" {
    _ = file_arena.reset(.retain_capacity);
    const a = file_arena.allocator();
    const src = cat(a, DECLS_B, "class C(@P val x: Int)\nfun main() {}\n");
    try assertNoErrors(src);
    const l = try lower(a, src);
    try assertPlacement(try l.ctorAnchors("C", "x"), "P", &.{"param"});
}

// B4: property only when param is not admitted.
test "b04_rf_ctor_val" {
    _ = file_arena.reset(.retain_capacity);
    const a = file_arena.allocator();
    const src = cat(a, DECLS_B, "class C(@RF val x: Int)\nfun main() {}\n");
    try assertNoErrors(src);
    const l = try lower(a, src);
    try assertPlacement(try l.ctorAnchors("C", "x"), "RF", &.{"property"});
}

// B5: member property prefers the property anchor.
test "b05_ppf_member_property" {
    _ = file_arena.reset(.retain_capacity);
    const a = file_arena.allocator();
    const src = cat(a, DECLS_B, "class C { @PPF val x = 1 }\nfun main() {}\n");
    try assertNoErrors(src);
    const l = try lower(a, src);
    try assertPlacement(try l.bodyAnchors("C", "x"), "PPF", &.{"property"});
}

// B6: field only.
test "b06_f_member_property" {
    _ = file_arena.reset(.retain_capacity);
    const a = file_arena.allocator();
    const src = cat(a, DECLS_B, "class C { @F val x = 1 }\nfun main() {}\n");
    try assertNoErrors(src);
    const l = try lower(a, src);
    try assertPlacement(try l.bodyAnchors("C", "x"), "F", &.{"field"});
}

// B7: field-only annotation on a property without a backing field.
test "b07_f_no_backing_field" {
    _ = file_arena.reset(.retain_capacity);
    const a = file_arena.allocator();
    const src = cat(a, DECLS_B, "class C { @F val x: Int get() = 1 }\nfun main() {}\n");
    try assertDiag(src, "WRONG_ANNOTATION_TARGET", "not applicable to target 'member property without backing field or delegate'");
}

// B8: defaulting never reaches `get`; explicit @get:G is required.
test "b08_g_member_property" {
    _ = file_arena.reset(.retain_capacity);
    const a = file_arena.allocator();
    const src = cat(a, DECLS_B, "class C { @G val x = 1 }\nfun main() {}\n");
    try assertDiag(src, "WRONG_ANNOTATION_TARGET", "not applicable to target 'member property with backing field'");
}

// B9: delegated property with PROPERTY admitted — property anchor.
test "b09_rf_delegated_property" {
    _ = file_arena.reset(.retain_capacity);
    const a = file_arena.allocator();
    const src = cat(a, DECLS_B, "class C { @RF val x: Int by lazy { 1 } }\nfun main() {}\n");
    try assertNoErrors(src);
    const l = try lower(a, src);
    try assertPlacement(try l.bodyAnchors("C", "x"), "RF", &.{"property"});
}

// B10: annotation-class ctor property suppresses the field placement.
test "b10_pf_annotation_class_ctor" {
    _ = file_arena.reset(.retain_capacity);
    const a = file_arena.allocator();
    const src = cat(a, DECLS_B, "annotation class Meta(@PF val x: Int)\nfun main() {}\n");
    try assertNoErrors(src);
    const l = try lower(a, src);
    try assertPlacement(try l.ctorAnchors("Meta", "x"), "PF", &.{"param"});
}

// B11: var changes nothing — defaulting never targets setparam.
test "b11_pf_ctor_var" {
    _ = file_arena.reset(.retain_capacity);
    const a = file_arena.allocator();
    const src = cat(a, DECLS_B, "class C(@PF var x: Int)\nfun main() {}\n");
    try assertNoErrors(src);
    const l = try lower(a, src);
    try assertPlacement(try l.ctorAnchors("C", "x"), "PF", &.{ "param", "field" });
}

// B12: an explicit use-site target disables defaulting entirely.
test "b12_explicit_param_target" {
    _ = file_arena.reset(.retain_capacity);
    const a = file_arena.allocator();
    const src = cat(a, DECLS_B, "class C(@param:PPF val x: Int)\nfun main() {}\n");
    try assertNoErrors(src);
    const l = try lower(a, src);
    try assertPlacement(try l.ctorAnchors("C", "x"), "PPF", &.{"param"});
}

// The annotation's resolved constructor arguments ride along on the anchor
// records (the surface the serializer's @SerialName reads).
test "anchor_records_carry_string_args" {
    _ = file_arena.reset(.retain_capacity);
    const a = file_arena.allocator();
    const src =
        \\@Target(AnnotationTarget.PROPERTY) annotation class Named(val value: String)
        \\class C(@Named("wire") val x: Int)
        \\fun main() {}
        \\
    ;
    const l = try lower(a, src);
    const anchors = try l.ctorAnchors("C", "x");
    try std.testing.expectEqual(@as(usize, 1), anchors.property.len);
    const rec = &anchors.property[0];
    try std.testing.expect(rec.is("Named"));
    try std.testing.expectEqualStrings("wire", rec.stringArg("value").?);
}

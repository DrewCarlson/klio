//! Annotation use-site targeting: the acceptance matrix for the `@all:`
//! property meta-target, and the defaulting rule for target-less property
//! annotations under language version 2.4. Diagnostic rows assert the
//! compiler-named diagnostic; placement rows assert the per-anchor annotation
//! records the runtime class metadata exposes to reflective consumers.

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

// The pipeline's process-global state points into the run allocator.
var file_arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);

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

/// Assert some diagnostic from `factory_name` contains `msg_needle`.
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

const Lowered = struct {
    built: interp_ir.build.BuiltModule,

    fn ctorAnchors(self: *const Lowered, class_name: []const u8, prop: []const u8) !PropertyAnchors {
        const def = self.built.classes.get(class_name) orelse return error.ClassNotFound;
        const cd = def.asPtr();
        for (cd.primary_params) |*p| {
            if (std.mem.eql(u8, p.name, prop)) return p.anchors;
        }
        return error.PropertyNotFound;
    }

    fn bodyAnchors(self: *const Lowered, class_name: []const u8, prop: []const u8) !PropertyAnchors {
        const def = self.built.classes.get(class_name) orelse return error.ClassNotFound;
        const cd = def.asPtr();
        for (cd.body_properties) |*p| {
            if (std.mem.eql(u8, p.name, prop)) return p.anchors;
        }
        return error.PropertyNotFound;
    }
};

/// Lower `src`, tolerating parser diagnostics so the bracket-error row runs.
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

/// Assert `name` is present on every anchor in `expect` and absent elsewhere.
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

// Matrix A: the `@all:` meta-target.

test "a01_all_on_ctor_val" {
    _ = file_arena.reset(.retain_capacity);
    const a = file_arena.allocator();
    const src = cat(a, DECLS_A, "class U(@all:Wide val e: String)\nfun main() {}\n");
    try assertNoErrors(src);
    const l = try lower(a, src);
    try assertPlacement(try l.ctorAnchors("U", "e"), "Wide", &.{ "param", "property", "field", "get" });
}

// On a `var`, VALUE_PARAMETER also covers the setter parameter.
test "a02_all_on_ctor_var" {
    _ = file_arena.reset(.retain_capacity);
    const a = file_arena.allocator();
    const src = cat(a, DECLS_A, "class U(@all:Wide var e: String)\nfun main() {}\n");
    try assertNoErrors(src);
    const l = try lower(a, src);
    try assertPlacement(try l.ctorAnchors("U", "e"), "Wide", &.{ "param", "property", "field", "get", "setparam" });
}

test "a03_all_on_member_property" {
    _ = file_arena.reset(.retain_capacity);
    const a = file_arena.allocator();
    const src = cat(a, DECLS_A, "class U { @all:Wide val e: String = \"x\" }\nfun main() {}\n");
    try assertNoErrors(src);
    const l = try lower(a, src);
    try assertPlacement(try l.bodyAnchors("U", "e"), "Wide", &.{ "property", "field", "get" });
}

// With no backing field only `get` receives the annotation; `field` is
// skipped without a diagnostic.
test "a04_all_getter_only_no_backing_field" {
    _ = file_arena.reset(.retain_capacity);
    const a = file_arena.allocator();
    const src = cat(a, DECLS_A, "class U { @all:GetOnly val e: String get() = \"x\" }\nfun main() {}\n");
    try assertNoErrors(src);
    const l = try lower(a, src);
    try assertPlacement(try l.bodyAnchors("U", "e"), "GetOnly", &.{"get"});
}

test "a05_all_nothing_applicable" {
    _ = file_arena.reset(.retain_capacity);
    const a = file_arena.allocator();
    const src = cat(a, DECLS_A, "class U(@all:FunOnly val e: String)\nfun main() {}\n");
    try assertDiag(src, "WRONG_ANNOTATION_TARGET_WITH_USE_SITE_TARGET", "not applicable to target 'property' and use-site target '@all'");
}

test "a06_all_on_delegated_property" {
    _ = file_arena.reset(.retain_capacity);
    const a = file_arena.allocator();
    const src = cat(a, DECLS_A, "class U { @all:Wide val e: String by lazy { \"x\" } }\nfun main() {}\n");
    try assertDiag(src, "INAPPLICABLE_ALL_TARGET", "'@all:' annotations cannot be applied to delegated properties.");
}

test "a07_all_on_local_property" {
    _ = file_arena.reset(.retain_capacity);
    const a = file_arena.allocator();
    const src = cat(a, DECLS_A, "fun f() { @all:Wide val x = 1\nprintln(x) }\nfun main() { f() }\n");
    try assertDiag(src, "INAPPLICABLE_ALL_TARGET", "cannot be applied to local properties, only member or top-level properties are allowed.");
}

// Bracket syntax is forbidden under `@all:`, and the sibling entry in the
// same bracket still applies.
test "a08_all_multi_annotation_bracket" {
    _ = file_arena.reset(.retain_capacity);
    const a = file_arena.allocator();
    const src = cat(a, DECLS_A, "class U(@all:Wide val e: String, @all:[Wide FieldOnly] val f: String)\nfun main() {}\n");
    try assertDiag(src, "INAPPLICABLE_ALL_TARGET_IN_MULTI_ANNOTATION", "Multiple annotation syntax with '@all:' use-site target is forbidden");
    const l = try lower(a, src);
    try assertPlacement(try l.ctorAnchors("U", "e"), "Wide", &.{ "param", "property", "field", "get" });
}

test "a09_all_param_only" {
    _ = file_arena.reset(.retain_capacity);
    const a = file_arena.allocator();
    const src = cat(a, DECLS_A, "class U(@all:ParamOnly val e: String)\nfun main() {}\n");
    try assertNoErrors(src);
    const l = try lower(a, src);
    try assertPlacement(try l.ctorAnchors("U", "e"), "ParamOnly", &.{"param"});
}

// `@all:` and `@field:` both resolve to the backing field, so the record repeats.
test "a10_all_plus_field_repeated" {
    _ = file_arena.reset(.retain_capacity);
    const a = file_arena.allocator();
    const src = cat(a, DECLS_A, "class U(@all:FieldOnly @field:FieldOnly val e: String)\nfun main() {}\n");
    try assertDiag(src, "REPEATED_ANNOTATION", "This annotation is not repeatable.");
}

test "a11_all_on_plain_ctor_param" {
    _ = file_arena.reset(.retain_capacity);
    const a = file_arena.allocator();
    const src = cat(a, DECLS_A, "class U(@all:Wide x: String)\nfun main() {}\n");
    try assertDiag(src, "INAPPLICABLE_ALL_TARGET", "constructor parameters without corresponding property (consider adding val/var)");
}

// A top-level property keeps no runtime anchor table, so this asserts output.
test "a12_all_on_top_level_property" {
    _ = file_arena.reset(.retain_capacity);
    const a = file_arena.allocator();
    const src = cat(a, DECLS_A, "@all:Wide val top: Int = 1\nfun main() { println(top) }\n");
    try assertNoErrors(src);
    try assertKlio("a12", src, "1\n");
}

// Matrix B: defaulting for annotations without a use-site target.

test "b01_ppf_ctor_val" {
    _ = file_arena.reset(.retain_capacity);
    const a = file_arena.allocator();
    const src = cat(a, DECLS_B, "class C(@PPF val x: Int)\nfun main() {}\n");
    try assertNoErrors(src);
    const l = try lower(a, src);
    try assertPlacement(try l.ctorAnchors("C", "x"), "PPF", &.{ "param", "property" });
}

test "b02_pf_ctor_val" {
    _ = file_arena.reset(.retain_capacity);
    const a = file_arena.allocator();
    const src = cat(a, DECLS_B, "class C(@PF val x: Int)\nfun main() {}\n");
    try assertNoErrors(src);
    const l = try lower(a, src);
    try assertPlacement(try l.ctorAnchors("C", "x"), "PF", &.{ "param", "field" });
}

test "b03_p_ctor_val" {
    _ = file_arena.reset(.retain_capacity);
    const a = file_arena.allocator();
    const src = cat(a, DECLS_B, "class C(@P val x: Int)\nfun main() {}\n");
    try assertNoErrors(src);
    const l = try lower(a, src);
    try assertPlacement(try l.ctorAnchors("C", "x"), "P", &.{"param"});
}

test "b04_rf_ctor_val" {
    _ = file_arena.reset(.retain_capacity);
    const a = file_arena.allocator();
    const src = cat(a, DECLS_B, "class C(@RF val x: Int)\nfun main() {}\n");
    try assertNoErrors(src);
    const l = try lower(a, src);
    try assertPlacement(try l.ctorAnchors("C", "x"), "RF", &.{"property"});
}

test "b05_ppf_member_property" {
    _ = file_arena.reset(.retain_capacity);
    const a = file_arena.allocator();
    const src = cat(a, DECLS_B, "class C { @PPF val x = 1 }\nfun main() {}\n");
    try assertNoErrors(src);
    const l = try lower(a, src);
    try assertPlacement(try l.bodyAnchors("C", "x"), "PPF", &.{"property"});
}

test "b06_f_member_property" {
    _ = file_arena.reset(.retain_capacity);
    const a = file_arena.allocator();
    const src = cat(a, DECLS_B, "class C { @F val x = 1 }\nfun main() {}\n");
    try assertNoErrors(src);
    const l = try lower(a, src);
    try assertPlacement(try l.bodyAnchors("C", "x"), "F", &.{"field"});
}

test "b07_f_no_backing_field" {
    _ = file_arena.reset(.retain_capacity);
    const a = file_arena.allocator();
    const src = cat(a, DECLS_B, "class C { @F val x: Int get() = 1 }\nfun main() {}\n");
    try assertDiag(src, "WRONG_ANNOTATION_TARGET", "not applicable to target 'member property without backing field or delegate'");
}

// Defaulting never reaches `get`; an explicit `@get:` target is required.
test "b08_g_member_property" {
    _ = file_arena.reset(.retain_capacity);
    const a = file_arena.allocator();
    const src = cat(a, DECLS_B, "class C { @G val x = 1 }\nfun main() {}\n");
    try assertDiag(src, "WRONG_ANNOTATION_TARGET", "not applicable to target 'member property with backing field'");
}

test "b09_rf_delegated_property" {
    _ = file_arena.reset(.retain_capacity);
    const a = file_arena.allocator();
    const src = cat(a, DECLS_B, "class C { @RF val x: Int by lazy { 1 } }\nfun main() {}\n");
    try assertNoErrors(src);
    const l = try lower(a, src);
    try assertPlacement(try l.bodyAnchors("C", "x"), "RF", &.{"property"});
}

// A property of an annotation class has no backing field, so field is skipped.
test "b10_pf_annotation_class_ctor" {
    _ = file_arena.reset(.retain_capacity);
    const a = file_arena.allocator();
    const src = cat(a, DECLS_B, "annotation class Meta(@PF val x: Int)\nfun main() {}\n");
    try assertNoErrors(src);
    const l = try lower(a, src);
    try assertPlacement(try l.ctorAnchors("Meta", "x"), "PF", &.{"param"});
}

// `var` changes nothing: defaulting never targets the setter parameter.
test "b11_pf_ctor_var" {
    _ = file_arena.reset(.retain_capacity);
    const a = file_arena.allocator();
    const src = cat(a, DECLS_B, "class C(@PF var x: Int)\nfun main() {}\n");
    try assertNoErrors(src);
    const l = try lower(a, src);
    try assertPlacement(try l.ctorAnchors("C", "x"), "PF", &.{ "param", "field" });
}

test "b12_explicit_param_target" {
    _ = file_arena.reset(.retain_capacity);
    const a = file_arena.allocator();
    const src = cat(a, DECLS_B, "class C(@param:PPF val x: Int)\nfun main() {}\n");
    try assertNoErrors(src);
    const l = try lower(a, src);
    try assertPlacement(try l.ctorAnchors("C", "x"), "PPF", &.{"param"});
}

// Resolved constructor arguments ride along on the anchor records, the surface
// `@SerialName` reads.
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

//! `KLIO_SLAB_CENSUS`: the byte size of each shape the pipeline allocates in
//! volume, printed beside the slab's live-by-site report so a site's byte
//! total reads as a count of nodes.
const std = @import("std");
const ast = @import("ast");
const lexer = @import("lexer");
const ir = @import("ir");
const typeck = @import("typeck");
const interp_ir = @import("interp_ir");
const span = @import("span");

fn row(comptime name: []const u8, comptime T: type) void {
    std.debug.print("[census] sizeof {s} = {d}\n", .{ name, @sizeOf(T) });
}

pub fn printTypeSizes() void {
    row("span.Span", span.Span);
    row("lexer.Token", lexer.Token);
    row("ast.Ident", ast.Ident);
    row("ast.TypeRef", ast.TypeRef);
    row("ast.TypeArg", ast.TypeArg);
    row("ast.FunctionTypeRef", ast.FunctionTypeRef);
    row("ast.Annotation", ast.Annotation);
    row("ast.Expr", ast.Expr);
    row("ast.Stmt", ast.Stmt);
    row("ast.Block", ast.Block);
    row("ast.Decl", ast.Decl);
    row("ast.Function", ast.Function);
    row("ast.Property", ast.Property);
    row("ast.Class", ast.Class);
    row("ast.ObjectDecl", ast.ObjectDecl);
    row("ast.Param", ast.Param);
    row("ast.TypeParam", ast.TypeParam);
    row("ast.Accessor", ast.Accessor);
    row("ast.WhenBranch", ast.WhenBranch);
    row("ast.StringPart", ast.StringPart);
    row("ast.KotlinFile", ast.KotlinFile);
    row("ir.TypeRef", ir.TypeRef);
    row("ir.Param", ir.Param);
    row("ir.Func", ir.Func);
    row("ir.Block", ir.Block);
    row("ir.Inst", ir.Inst);
    row("ir.Terminator", ir.Terminator);
    row("ir.Class", ir.Class);
    row("ir.Const", ir.Const);
    row("typeck.Type", typeck.check.Type);
    row("interp_ir.ProgramImage", interp_ir.ProgramImage);
}

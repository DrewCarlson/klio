//! Parser corpus tests. Each `.kt` snippet is parsed end-to-end and the
//! pretty-printed AST + any diagnostics are snapshot-compared via `insta`.

use ktc_ast::{
    AssignOp, BinOp, Decl, Expr, FunctionBody, KotlinFile, PostfixOp, Stmt, StringPart, TypeRef,
    UnOp,
};
use ktc_lexer::Lexer;
use ktc_parser::Parser;
use ktc_span::SourceMap;

fn render(src: &str) -> String {
    let mut map = SourceMap::new();
    let id = map.add("corpus.kt", src);
    let owned = map.get(id).source.clone();
    let lexed = Lexer::new(id, &owned).tokenize();
    let (ast, diags) = Parser::new(id, &owned, &lexed.tokens).parse_file();

    let mut out = String::new();
    out.push_str("# ast\n");
    Printer::new(&mut out).file(&ast);

    let mut all = lexed.diagnostics.diagnostics().to_vec();
    all.extend(diags.diagnostics().iter().cloned());
    if !all.is_empty() {
        out.push_str("\n# diagnostics\n");
        for d in &all {
            let code = d.code().unwrap_or("");
            out.push_str(&format!(
                "[{code}] {sev:?} {msg} @{start}..{end}\n",
                sev = d.severity,
                msg = d.message,
                start = d.primary.span.start,
                end = d.primary.span.end,
            ));
        }
    }
    out
}

struct Printer<'a> {
    out: &'a mut String,
    indent: usize,
}

impl<'a> Printer<'a> {
    fn new(out: &'a mut String) -> Self { Self { out, indent: 0 } }

    fn pad(&mut self) {
        for _ in 0..self.indent { self.out.push_str("  "); }
    }

    fn line(&mut self, s: &str) {
        self.pad();
        self.out.push_str(s);
        self.out.push('\n');
    }

    fn nest(&mut self, body: impl FnOnce(&mut Self)) {
        self.indent += 1;
        body(self);
        self.indent -= 1;
    }

    fn file(&mut self, f: &KotlinFile) {
        if let Some(p) = &f.package {
            let segs: Vec<_> = p.path.iter().map(|i| i.name.as_str()).collect();
            self.line(&format!("package {}", segs.join(".")));
        }
        for imp in &f.imports {
            let segs: Vec<_> = imp.path.iter().map(|i| i.name.as_str()).collect();
            let star = if imp.wildcard { ".*" } else { "" };
            let alias = imp.alias.as_ref().map(|a| format!(" as {}", a.name)).unwrap_or_default();
            self.line(&format!("import {}{}{}", segs.join("."), star, alias));
        }
        for d in &f.decls { self.decl(d); }
    }

    fn decl(&mut self, d: &Decl) {
        match d {
            Decl::Function(fn_) => {
                let params: Vec<String> = fn_.params.iter()
                    .map(|p| format!("{}:{}", p.name.name, render_type(&p.ty)))
                    .collect();
                let ret = fn_.return_type.as_ref().map(|t| format!(":{}", render_type(t))).unwrap_or_default();
                self.line(&format!("fun {}({}){}", fn_.name.name, params.join(","), ret));
                self.nest(|p| match &fn_.body {
                    Some(FunctionBody::Block(b)) => {
                        p.line("body=block");
                        p.nest(|p| for s in &b.stmts { p.stmt(s); });
                    }
                    Some(FunctionBody::Expr(e)) => {
                        p.line("body=expr");
                        p.nest(|p| p.expr(e));
                    }
                    None => p.line("body=<none>"),
                });
            }
            Decl::Property(prop) => {
                let kw = if prop.mutable { "var" } else { "val" };
                let ty = prop.ty.as_ref().map(|t| format!(":{}", render_type(t))).unwrap_or_default();
                self.line(&format!("{} {}{}", kw, prop.name.name, ty));
                if let Some(init) = &prop.init {
                    self.nest(|p| { p.line("init="); p.nest(|p| p.expr(init)); });
                }
            }
            Decl::Class(c) => {
                self.line(&format!("class {}", c.name.name));
                self.nest(|p| for m in &c.members { p.decl(m); });
            }
            Decl::Object(o) => {
                self.line(&format!("object {}", o.name.name));
                self.nest(|p| for m in &o.members { p.decl(m); });
            }
            Decl::TypeAlias(a) => {
                self.line(&format!("typealias {}={}", a.name.name, render_type(&a.target)));
            }
        }
    }

    fn stmt(&mut self, s: &Stmt) {
        match s {
            Stmt::Expr(e) => { self.line("stmt-expr"); self.nest(|p| p.expr(e)); }
            Stmt::Decl(d) => { self.line("stmt-decl"); self.nest(|p| p.decl(d)); }
            Stmt::Assign { target, op, value, .. } => {
                self.line(&format!("assign {}", render_assign_op(*op)));
                self.nest(|p| { p.line("target="); p.nest(|p| p.expr(target));
                                p.line("value="); p.nest(|p| p.expr(value)); });
            }
            Stmt::DestructuringDecl { mutable, names, init, .. } => {
                let kw = if *mutable { "var" } else { "val" };
                let joined = names.iter().map(|n| n.name.as_str()).collect::<Vec<_>>().join(", ");
                self.line(&format!("{kw} ({joined}) ="));
                self.nest(|p| p.expr(init));
            }
        }
    }

    fn expr(&mut self, e: &Expr) {
        match e {
            Expr::IntLit { value, .. } => self.line(&format!("int {value}")),
            Expr::FloatLit { value, .. } => self.line(&format!("float {value}")),
            Expr::BoolLit { value, .. } => self.line(&format!("bool {value}")),
            Expr::NullLit { .. } => self.line("null"),
            Expr::CharLit { value, .. } => self.line(&format!("char {value:?}")),
            Expr::StringTemplate { parts, .. } => {
                self.line("string-template");
                self.nest(|p| for part in parts { match part {
                    StringPart::Text(t) => p.line(&format!("text {t:?}")),
                    StringPart::ShortInterp(id) => p.line(&format!("short-interp ${}", id.name)),
                    StringPart::Interp(e) => { p.line("interp"); p.nest(|p| p.expr(e)); }
                }});
            }
            Expr::Path { segments, .. } => {
                let names: Vec<_> = segments.iter().map(|s| s.name.as_str()).collect();
                self.line(&format!("path {}", names.join(".")));
            }
            Expr::Member { receiver, name, safe, .. } => {
                self.line(&format!("member{} .{}", if *safe { "?" } else { "" }, name.name));
                self.nest(|p| p.expr(receiver));
            }
            Expr::Call { callee, args, .. } => {
                self.line(&format!("call (#args={})", args.len()));
                self.nest(|p| { p.line("callee="); p.nest(|p| p.expr(callee));
                                for (i, a) in args.iter().enumerate() {
                                    p.line(&format!("arg[{i}]="));
                                    p.nest(|p| p.expr(a));
                                } });
            }
            Expr::Index { receiver, args, .. } => {
                self.line(&format!("index (#args={})", args.len()));
                self.nest(|p| { p.line("recv="); p.nest(|p| p.expr(receiver));
                                for (i, a) in args.iter().enumerate() {
                                    p.line(&format!("arg[{i}]="));
                                    p.nest(|p| p.expr(a));
                                } });
            }
            Expr::Binary { op, lhs, rhs, .. } => {
                self.line(&format!("binop {}", render_binop(*op)));
                self.nest(|p| { p.expr(lhs); p.expr(rhs); });
            }
            Expr::Unary { op, expr, .. } => {
                self.line(&format!("unop {}", render_unop(*op)));
                self.nest(|p| p.expr(expr));
            }
            Expr::Postfix { op, expr, .. } => {
                self.line(&format!("postfix {}", render_postfix(*op)));
                self.nest(|p| p.expr(expr));
            }
            Expr::If { cond, then_branch, else_branch, .. } => {
                self.line("if");
                self.nest(|p| { p.line("cond="); p.nest(|p| p.expr(cond));
                                p.line("then="); p.nest(|p| p.expr(then_branch));
                                if let Some(e) = else_branch { p.line("else="); p.nest(|p| p.expr(e)); } });
            }
            Expr::While { cond, body, .. } => {
                self.line("while");
                self.nest(|p| { p.line("cond="); p.nest(|p| p.expr(cond));
                                p.line("body="); p.nest(|p| p.expr(body)); });
            }
            Expr::For { vars, var_ty, iter, body, .. } => {
                let ty = var_ty.as_ref().map(|t| format!(":{}", render_type(t))).unwrap_or_default();
                let names: Vec<_> = vars.iter().map(|v| v.name.as_str()).collect();
                self.line(&format!("for ({}){}", names.join(","), ty));
                self.nest(|p| { p.line("iter="); p.nest(|p| p.expr(iter));
                                p.line("body="); p.nest(|p| p.expr(body)); });
            }
            Expr::Return { value, label, .. } => {
                let lbl = label.as_ref().map(|l| format!("@{}", l.name)).unwrap_or_default();
                self.line(&format!("return{lbl}"));
                if let Some(v) = value { self.nest(|p| p.expr(v)); }
            }
            Expr::Break { label, .. } => {
                let lbl = label.as_ref().map(|l| format!("@{}", l.name)).unwrap_or_default();
                self.line(&format!("break{lbl}"));
            }
            Expr::Continue { label, .. } => {
                let lbl = label.as_ref().map(|l| format!("@{}", l.name)).unwrap_or_default();
                self.line(&format!("continue{lbl}"));
            }
            Expr::Labeled { label, expr, .. } => {
                self.line(&format!("labeled {}@", label.name));
                self.nest(|p| p.expr(expr));
            }
            Expr::Block(b) => {
                self.line("block");
                self.nest(|p| for s in &b.stmts { p.stmt(s); });
            }
            Expr::Throw { value, .. } => {
                self.line("throw");
                self.nest(|p| p.expr(value));
            }
            Expr::Try { body, catches, finally, .. } => {
                self.line("try");
                self.nest(|p| {
                    p.line("body=block");
                    p.nest(|p| for s in &body.stmts { p.stmt(s); });
                    for c in catches {
                        p.line(&format!("catch {}:{}", c.binding.name, render_type(&c.ty)));
                        p.nest(|p| for s in &c.body.stmts { p.stmt(s); });
                    }
                    if let Some(fb) = finally {
                        p.line("finally=block");
                        p.nest(|p| for s in &fb.stmts { p.stmt(s); });
                    }
                });
            }
            Expr::Lambda { params, body, .. } => {
                let names: Vec<_> = params.iter().map(|p| p.name.as_str()).collect();
                self.line(&format!("lambda ({})", names.join(",")));
                self.nest(|p| for s in &body.stmts { p.stmt(s); });
            }
            Expr::This { .. } => self.line("this"),
            Expr::Super { .. } => self.line("super"),
            Expr::IsCheck { expr, ty, negated, .. } => {
                self.line(&format!(
                    "{} {}",
                    if *negated { "!is" } else { "is" },
                    render_type(ty)
                ));
                self.nest(|p| p.expr(expr));
            }
            Expr::When { subject, branches, .. } => {
                self.line("when");
                self.nest(|p| {
                    if let Some(s) = subject {
                        p.line("subject");
                        p.nest(|p| p.expr(s));
                    }
                    for b in branches {
                        p.line("branch");
                        p.nest(|p| {
                            for pat in &b.patterns {
                                match &pat.kind {
                                    ktc_ast::WhenPatternKind::Else => p.line("else"),
                                    ktc_ast::WhenPatternKind::Value(e) => {
                                        p.line("value");
                                        p.nest(|p| p.expr(e));
                                    }
                                    ktc_ast::WhenPatternKind::InRange(e) => {
                                        p.line("in");
                                        p.nest(|p| p.expr(e));
                                    }
                                    ktc_ast::WhenPatternKind::NotInRange(e) => {
                                        p.line("!in");
                                        p.nest(|p| p.expr(e));
                                    }
                                    ktc_ast::WhenPatternKind::IsType(t) => {
                                        p.line(&format!("is {}", render_type(t)))
                                    }
                                    ktc_ast::WhenPatternKind::NotIsType(t) => {
                                        p.line(&format!("!is {}", render_type(t)))
                                    }
                                }
                            }
                            p.line("body");
                            p.nest(|p| p.expr(&b.body));
                        });
                    }
                });
            }
            Expr::PropertyRef { name, .. } => {
                self.line(&format!("property-ref ::{}", name.name));
            }
            Expr::MemberRef { receiver, name, .. } => {
                self.line(&format!("member-ref ::{}", name.name));
                self.nest(|p| p.expr(receiver));
            }
            Expr::ObjectExpr { supertypes, members, .. } => {
                let supers: Vec<_> = supertypes.iter().map(render_type).collect();
                self.line(&format!("object-expr [{}]", supers.join(",")));
                self.nest(|p| for m in members { p.decl(m); });
            }
            Expr::As { expr, ty, safe, .. } => {
                let op = if *safe { "as?" } else { "as" };
                self.line(&format!("{op} {}", render_type(ty)));
                self.nest(|p| p.expr(expr));
            }
            Expr::AnonFun { params, return_ty, .. } => {
                let ps: Vec<_> = params.iter().map(|p| p.name.name.clone()).collect();
                let rt = return_ty.as_ref().map(render_type).unwrap_or_default();
                self.line(&format!("anon-fun ({}){}", ps.join(","),
                    if rt.is_empty() { String::new() } else { format!(": {rt}") }));
            }
            Expr::Spread { expr, .. } => {
                self.line("spread *");
                self.nest(|p| p.expr(expr));
            }
        }
    }
}

fn render_type(t: &TypeRef) -> String {
    if t.nullable { format!("{}?", t.name.name) } else { t.name.name.clone() }
}

fn render_binop(op: BinOp) -> &'static str {
    match op {
        BinOp::Add => "+", BinOp::Sub => "-", BinOp::Mul => "*", BinOp::Div => "/", BinOp::Rem => "%",
        BinOp::Eq => "==", BinOp::Neq => "!=", BinOp::IdentEq => "===", BinOp::IdentNeq => "!==",
        BinOp::Lt => "<", BinOp::Le => "<=", BinOp::Gt => ">", BinOp::Ge => ">=",
        BinOp::And => "&&", BinOp::Or => "||",
        BinOp::Range => "..", BinOp::RangeUntil => "..<",
        BinOp::Elvis => "?:", BinOp::Assign => "=",
        BinOp::In => "in", BinOp::NotIn => "!in",
    }
}

fn render_unop(op: UnOp) -> &'static str {
    match op { UnOp::Neg => "-", UnOp::Pos => "+", UnOp::Not => "!", UnOp::PreInc => "++", UnOp::PreDec => "--" }
}

fn render_postfix(op: PostfixOp) -> &'static str {
    match op { PostfixOp::Inc => "++", PostfixOp::Dec => "--", PostfixOp::NotNull => "!!" }
}

fn render_assign_op(op: AssignOp) -> &'static str {
    match op {
        AssignOp::Assign => "=", AssignOp::Add => "+=", AssignOp::Sub => "-=",
        AssignOp::Mul => "*=", AssignOp::Div => "/=", AssignOp::Rem => "%=",
    }
}

macro_rules! corpus_test {
    ($name:ident, $file:expr) => {
        #[test]
        fn $name() {
            let src = include_str!(concat!("corpus/", $file));
            insta::assert_snapshot!(stringify!($name), render(src), src);
        }
    };
}

corpus_test!(hello, "hello.kt");
corpus_test!(arithmetic_precedence, "arithmetic.kt");
corpus_test!(strings_templates, "strings.kt");
corpus_test!(declarations, "declarations.kt");
corpus_test!(control_flow, "control_flow.kt");
corpus_test!(package_and_imports, "imports.kt");
corpus_test!(expression_body_fun, "expr_body.kt");
corpus_test!(member_and_calls, "members.kt");
corpus_test!(diag_missing_paren, "diag_missing_paren.kt");
corpus_test!(diag_top_level_garbage, "diag_top_level_garbage.kt");

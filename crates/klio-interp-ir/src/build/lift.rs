use super::{Decl, Expr, Ident};

/// Replace every bare `field` identifier in `expr` with
/// `this.<prop_name>`. Used by accessor-body lowering so the IR
/// thunk reads / writes the backing field on the receiver.
pub(crate) fn substitute_field_with_this(prop_name: &str, expr: &Expr) -> Expr {
    use klio_span::{FileId, Span};
    let dummy = Span::new(FileId(0), 0, 0);
    let mut out = expr.clone();
    walk_field(&mut out, prop_name, dummy);
    out
}

pub(crate) fn walk_field(e: &mut Expr, prop: &str, dummy: klio_span::Span) {
    let mut replace = None;
    if let Expr::Path { segments, .. } = e
        && segments.len() == 1
        && segments[0].name == "field"
    {
        // Rewrite the raw `field` reference to a synthetic member
        // access on `this` that names the backing slot. Vm
        // get_field / set_field detect the `__klio_field__`
        // prefix and skip the custom-getter/setter dispatch.
        let backing = format!("__klio_field__{prop}");
        replace = Some(Expr::Member {
            receiver: Box::new(Expr::Path {
                segments: vec![Ident {
                    name: "this".into(),
                    span: dummy,
                }],
                span: dummy,
            }),
            name: Ident {
                name: backing,
                span: dummy,
            },
            safe: false,
            span: dummy,
        });
    }
    if let Some(r) = replace {
        *e = r;
        return;
    }
    match e {
        Expr::Call { callee, args, .. } => {
            walk_field(callee, prop, dummy);
            for a in args {
                walk_field(a, prop, dummy);
            }
        }
        Expr::Member { receiver, .. } => walk_field(receiver, prop, dummy),
        Expr::Binary { lhs, rhs, .. } => {
            walk_field(lhs, prop, dummy);
            walk_field(rhs, prop, dummy);
        }
        Expr::Unary { expr, .. }
        | Expr::Postfix { expr, .. }
        | Expr::IsCheck { expr, .. }
        | Expr::As { expr, .. }
        | Expr::Spread { expr, .. } => walk_field(expr, prop, dummy),
        Expr::If {
            cond,
            then_branch,
            else_branch,
            ..
        } => {
            walk_field(cond, prop, dummy);
            walk_field(then_branch, prop, dummy);
            if let Some(e) = else_branch.as_deref_mut() {
                walk_field(e, prop, dummy);
            }
        }
        Expr::Index { receiver, args, .. } => {
            walk_field(receiver, prop, dummy);
            for a in args {
                walk_field(a, prop, dummy);
            }
        }
        Expr::Block(b) => {
            for s in &mut b.stmts {
                match s {
                    klio_ast::Stmt::Expr(e) => walk_field(e, prop, dummy),
                    klio_ast::Stmt::Assign { target, value, .. } => {
                        walk_field(target, prop, dummy);
                        walk_field(value, prop, dummy);
                    }
                    _ => {}
                }
            }
        }
        Expr::StringTemplate { parts, .. } => {
            for p in parts {
                if let klio_ast::StringPart::Interp(e) = p {
                    walk_field(e, prop, dummy);
                }
            }
        }
        Expr::Return { value, .. } => {
            if let Some(v) = value.as_deref_mut() {
                walk_field(v, prop, dummy);
            }
        }
        Expr::Throw { value, .. } => walk_field(value, prop, dummy),
        _ => {}
    }
}

pub(crate) fn rewrite_block_field(block: &klio_ast::Block, prop: &str) -> klio_ast::Block {
    use klio_span::{FileId, Span};
    let dummy = Span::new(FileId(0), 0, 0);
    let mut out = block.clone();
    for s in &mut out.stmts {
        match s {
            klio_ast::Stmt::Expr(e) => walk_field(e, prop, dummy),
            klio_ast::Stmt::Assign { target, value, .. } => {
                walk_field(target, prop, dummy);
                walk_field(value, prop, dummy);
            }
            _ => {}
        }
    }
    out
}

/// Recursively walk a class's members and lift companion objects,
/// plain nested classes, and inner classes to top-level entries in
/// `out_decls`. Companion singletons are registered with the Vm's
/// `companion_singletons` table and tagged with the outer's
/// visible-member set in `nested_outer_members`. Returns nothing —
/// mutates the passed-in collections.
pub(crate) fn collect_enclosing_member_names(
    c: &klio_ast::Class,
) -> std::collections::HashSet<String> {
    let mut s: std::collections::HashSet<String> = std::collections::HashSet::new();
    for p in &c.primary_params {
        s.insert(p.name.name.clone());
    }
    for m in &c.members {
        match m {
            Decl::Property(p) => {
                s.insert(p.name.name.clone());
            }
            Decl::Function(f) => {
                s.insert(f.name.name.clone());
            }
            Decl::Class(nested) if nested.is_companion => {
                // Companion's members are visible bare-name to
                // siblings (and to nested classes that walk the
                // enclosing chain).
                for m2 in &nested.members {
                    match m2 {
                        Decl::Property(p) => {
                            s.insert(p.name.name.clone());
                        }
                        Decl::Function(f) => {
                            s.insert(f.name.name.clone());
                        }
                        _ => {}
                    }
                }
            }
            _ => {}
        }
    }
    if c.is_enum {
        s.insert("entries".to_string());
        s.insert("values".to_string());
        s.insert("valueOf".to_string());
        for e in &c.enum_entries {
            s.insert(e.name.name.clone());
        }
    }
    s
}

// Threads several `&mut` accumulators through the recursive lift;
// bundling them would churn the cross-module caller in build.rs.
#[allow(clippy::too_many_arguments, clippy::too_many_lines)]
pub(crate) fn lift_class_recursive(
    c: &klio_ast::Class,
    enclosing_chain: &[klio_ast::Class],
    out_decls: &mut Vec<Decl>,
    object_names: &mut Vec<String>,
    companion_singletons: &mut std::collections::HashMap<String, String>,
    nested_outer_members: &mut std::collections::HashMap<String, std::collections::HashSet<String>>,
    enclosing_class: &mut std::collections::HashMap<String, String>,
    nested_object_aliases: &mut std::collections::HashMap<
        String,
        std::collections::HashMap<String, String>,
    >,
    top_level_type_names: &std::collections::HashSet<String>,
) {
    for m in &c.members {
        if let Decl::Object(co) = m {
            // Nested `object Foo { … }` inside a class. Lift as
            // a standalone singleton class. Rename the lifted class to
            // `Outer$Foo` when the source marked it `private` OR when its
            // bare name collides with a true top-level type — otherwise the
            // bare lift would overwrite that top-level class in the global
            // table (last writer wins, source-order-dependent). The alias
            // keeps the outer's own bodies resolving bare `Foo`; `get_field`
            // on a class receiver resolves the mangled name for external
            // `Outer.Foo` access.
            let is_private = matches!(co.visibility, klio_ast::Visibility::Private);
            let collides = top_level_type_names.contains(&co.name.name);
            let (lifted_name, alias_simple) = if is_private || collides {
                let renamed = format!("{}${}", c.name.name, co.name.name);
                (renamed, Some(co.name.name.clone()))
            } else {
                (co.name.name.clone(), None)
            };
            let is_private = is_private || collides;
            object_names.push(lifted_name.clone());
            enclosing_class.insert(lifted_name.clone(), c.name.name.clone());
            let mut extras: std::collections::HashSet<String> = collect_enclosing_member_names(c);
            for outer_c in enclosing_chain.iter().rev() {
                extras.extend(collect_enclosing_member_names(outer_c));
            }
            nested_outer_members.insert(lifted_name.clone(), extras);
            if let Some(simple) = alias_simple {
                nested_object_aliases
                    .entry(c.name.name.clone())
                    .or_default()
                    .insert(simple, lifted_name.clone());
            }
            let mut synth = synthesize_class_from_object(co);
            if is_private {
                synth.name = klio_ast::Ident {
                    name: lifted_name,
                    span: co.name.span,
                };
            }
            out_decls.push(Decl::Class(synth));
        } else if let Decl::Class(nested) = m {
            if nested.is_companion {
                let comp_name = format!("{}$Companion${}", c.name.name, nested.name.name);
                let mut renamed = nested.clone();
                renamed.name = klio_ast::Ident {
                    name: comp_name.clone(),
                    span: nested.name.span,
                };
                renamed.is_companion = false;
                let mut extras: std::collections::HashSet<String> =
                    std::collections::HashSet::new();
                for p in &c.primary_params {
                    extras.insert(p.name.name.clone());
                }
                for m2 in &c.members {
                    match m2 {
                        Decl::Property(p) => {
                            extras.insert(p.name.name.clone());
                        }
                        Decl::Function(f) => {
                            extras.insert(f.name.name.clone());
                        }
                        _ => {}
                    }
                }
                if c.is_enum {
                    extras.insert("entries".to_string());
                    extras.insert("values".to_string());
                    extras.insert("valueOf".to_string());
                    for e in &c.enum_entries {
                        extras.insert(e.name.name.clone());
                    }
                }
                // Layer in members visible up the enclosing chain
                // so nested companions can reach the outer's
                // companion statics by bare name.
                for outer_c in enclosing_chain.iter().rev() {
                    extras.extend(collect_enclosing_member_names(outer_c));
                }
                nested_outer_members.insert(comp_name.clone(), extras);
                object_names.push(comp_name.clone());
                enclosing_class.insert(comp_name.clone(), c.name.name.clone());
                let mut next_chain: Vec<klio_ast::Class> = enclosing_chain.to_vec();
                next_chain.push(c.clone());
                lift_class_recursive(
                    &renamed,
                    &next_chain,
                    out_decls,
                    object_names,
                    companion_singletons,
                    nested_outer_members,
                    enclosing_class,
                    nested_object_aliases,
                    top_level_type_names,
                );
                out_decls.push(Decl::Class(renamed));
                companion_singletons.insert(c.name.name.clone(), comp_name);
            } else {
                let mut extras: std::collections::HashSet<String> =
                    std::collections::HashSet::new();
                for p in &c.primary_params {
                    extras.insert(p.name.name.clone());
                }
                for m2 in &c.members {
                    match m2 {
                        Decl::Property(p) => {
                            extras.insert(p.name.name.clone());
                        }
                        Decl::Function(f) => {
                            extras.insert(f.name.name.clone());
                        }
                        _ => {}
                    }
                }
                for outer_c in enclosing_chain.iter().rev() {
                    extras.extend(collect_enclosing_member_names(outer_c));
                }
                nested_outer_members.insert(nested.name.name.clone(), extras);
                enclosing_class.insert(nested.name.name.clone(), c.name.name.clone());
                let mut next_chain: Vec<klio_ast::Class> = enclosing_chain.to_vec();
                next_chain.push(c.clone());
                lift_class_recursive(
                    nested,
                    &next_chain,
                    out_decls,
                    object_names,
                    companion_singletons,
                    nested_outer_members,
                    enclosing_class,
                    nested_object_aliases,
                    top_level_type_names,
                );
                out_decls.push(Decl::Class(nested.clone()));
            }
        }
    }
}

/// Synthesise a `Class` AST node that mirrors an `ObjectDecl`. The
/// resulting class participates in the regular class-lowering pipeline
/// (members, supertype delegation, init blocks); a separate
/// `object_singletons` map then allocates one instance per name and
/// the Vm publishes it as a global at startup.
pub(crate) fn synthesize_class_from_object(o: &klio_ast::ObjectDecl) -> klio_ast::Class {
    let members: Vec<Decl> = o.members.clone();
    klio_ast::Class {
        name: o.name.clone(),
        type_params: Vec::new(),
        where_bounds: Vec::new(),
        primary_params: Vec::new(),
        init_blocks: Vec::new(),
        init_block_positions: Vec::new(),
        supertypes: o.supertypes.clone(),
        supertype_args: o.supertype_args.clone(),
        supertype_delegates: o.supertypes.iter().map(|_| None).collect(),
        is_data: o.is_data,
        is_companion: false,
        is_enum: false,
        is_sealed: false,
        is_expect: o.is_expect,
        is_actual: o.is_actual,
        is_open: false,
        is_abstract: false,
        is_inner: false,
        secondary_ctors: Vec::new(),
        is_interface: false,
        is_fun_interface: false,
        is_value: false,
        is_annotation: false,
        enum_entries: Vec::new(),
        members,
        visibility: klio_ast::Visibility::Public,
        primary_ctor_visibility: None,
        annotations: Vec::new(),
        span: o.span,
    }
}

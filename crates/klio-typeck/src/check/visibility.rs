use super::{
    AssignOp, Checker, ClassInfo, Diagnostic, Expr, HashSet, Span, Type, TypeRef, Visibility,
    at_least_as_applicable, codes, has_published_api,
};

/// A conflicting-overload pair: the two declaration spans, the shared
/// function name, and each overload's parameter-name list.
type OverloadPair = (Span, Span, String, Vec<String>, Vec<String>);

impl Checker<'_> {
    /// Look up the effective visibility a class declares for a member.
    /// Walks the supertype chain so inherited members are seen with the
    /// declaring class's annotation. Returns `(visibility, declaring_class)`.
    pub(crate) fn lookup_member_visibility(
        &self,
        class: &str,
        name: &str,
    ) -> Option<(Visibility, String)> {
        let mut seen: HashSet<String> = HashSet::new();
        let mut frontier: Vec<String> = vec![class.to_string()];
        let mut steps = 0;
        while let Some(c) = frontier.pop() {
            if steps > 64 {
                break;
            }
            steps += 1;
            if !seen.insert(c.clone()) {
                continue;
            }
            let Some(info) = self.classes.get(&c) else {
                continue;
            };
            if let Some(v) = info.member_visibility.get(name).copied() {
                return Some((v, c));
            }
            if info.members.contains_key(name) {
                return Some((Visibility::Public, c));
            }
            for s in &info.supertypes {
                frontier.push(s.clone());
            }
        }
        None
    }

    /// `protected` access through a receiver is allowed only when (a) the
    /// current enclosing class is the declaring class or a subclass, AND
    /// (b) the receiver's static class is the current enclosing class or
    /// a subclass of it. Matches kotlinc's qualified-access rule.
    pub(crate) fn protected_access_allowed(
        &self,
        declaring_class: &str,
        recv_class: Option<&str>,
    ) -> bool {
        let Some(enclosing) = self.class_stack.last() else {
            return false;
        };
        let in_subclass =
            enclosing == declaring_class || self.is_subtype_of(enclosing, declaring_class);
        if !in_subclass {
            return false;
        }
        match recv_class {
            None => true,
            Some(rc) => {
                rc == enclosing.as_str()
                    || self.is_subtype_of(rc, enclosing)
                    || rc == declaring_class
                    || self.is_subtype_of(rc, declaring_class)
            }
        }
    }

    /// Emit T0031 when access at `member_span` to `name` on `declaring_class`
    /// is forbidden by visibility. `recv_class` is the receiver's static
    /// user-class when known, used for the `protected` qualified-access rule.
    pub(crate) fn check_member_visibility(
        &mut self,
        declaring_class: &str,
        name: &str,
        recv_class: Option<&str>,
        member_span: Span,
    ) {
        let Some((v, decl_class)) = self.lookup_member_visibility(declaring_class, name) else {
            return;
        };
        let allowed = match v {
            Visibility::Public | Visibility::Internal => true,
            Visibility::Private => self.class_stack.last().is_some_and(|c| c == &decl_class),
            Visibility::Protected => self.protected_access_allowed(&decl_class, recv_class),
        };
        if allowed {
            return;
        }
        let kind = match v {
            Visibility::Private => "private",
            Visibility::Protected => "protected",
            _ => "invisible",
        };
        self.diagnostics.emit(
            Diagnostic::error(
                format!("Cannot access `{name}`: it is {kind} in `{decl_class}`"),
                member_span,
            )
            .with_code(codes::TYPE_INVISIBLE_MEMBER),
        );
    }

    /// Constructor / class-as-reference visibility. `private` top-level
    /// class is reachable only from inside its file; `protected` at the
    /// top level is illegal in Kotlin and we conservatively treat it the
    /// same as `private`.
    pub(crate) fn check_class_use_visibility(
        &mut self,
        name: &str,
        info: &ClassInfo,
        use_span: Span,
    ) {
        // Spec §4.6: a per-primary-ctor visibility (`class Foo private
        // constructor(...)`) gates constructor invocations independently of
        // the class visibility itself.
        let same_file = info.decl_file.is_none_or(|f| f == use_span.file);
        if let Some(pcv) = info.primary_ctor_visibility
            && matches!(pcv, Visibility::Private)
            && !same_file
        {
            self.diagnostics.emit(
                Diagnostic::error(
                    format!("Cannot access `{name}`: primary constructor is private"),
                    use_span,
                )
                .with_code(codes::TYPE_INVISIBLE_MEMBER),
            );
            return;
        }
        if matches!(
            info.decl_visibility,
            Visibility::Public | Visibility::Internal
        ) {
            return;
        }
        match info.decl_visibility {
            Visibility::Private if same_file => return,
            Visibility::Protected if self.protected_access_allowed(name, None) => {
                return;
            }
            _ => {}
        }
        let kind = match info.decl_visibility {
            Visibility::Private => "private",
            Visibility::Protected => "protected",
            _ => "invisible",
        };
        self.diagnostics.emit(
            Diagnostic::error(format!("Cannot access `{name}`: class is {kind}"), use_span)
                .with_code(codes::TYPE_INVISIBLE_MEMBER),
        );
    }

    /// J6: when inside the body of a `public inline` function, references
    /// to an `internal` top-level declaration require `@PublishedApi`.
    pub(crate) fn check_published_api_use(
        &mut self,
        name: &str,
        visibility: Visibility,
        target_anns: &[klio_ast::Annotation],
        use_span: Span,
    ) {
        if !matches!(visibility, Visibility::Internal) {
            return;
        }
        if !self.public_inline_stack.last().copied().unwrap_or(false) {
            return;
        }
        if has_published_api(target_anns) {
            return;
        }
        self.diagnostics.emit(
            Diagnostic::error(
                format!(
                    "Cannot access `{name}` from a public inline function: it is `internal` and not annotated `@PublishedApi`"
                ),
                use_span,
            )
            .with_code(codes::TYPE_INVISIBLE_MEMBER),
        );
    }

    /// Emit T0031/T0032 when a bare-name reference resolves to a `private`
    /// top-level fn / property declared in another file. `decl_file` is the
    /// file of the declaration; `use_span` carries the access site's file.
    pub(crate) fn check_top_level_visibility(
        &mut self,
        name: &str,
        visibility: Visibility,
        decl_file: klio_span::FileId,
        use_span: Span,
    ) {
        if matches!(visibility, Visibility::Public | Visibility::Internal) {
            return;
        }
        // Top-level `protected` is illegal in Kotlin; until we surface a
        // dedicated diagnostic, treat it as `private` and gate by file.
        if use_span.file == decl_file {
            return;
        }
        self.diagnostics.emit(
            Diagnostic::error(
                format!("Cannot access `{name}`: it is private in its declaring file"),
                use_span,
            )
            .with_code(codes::TYPE_INVISIBLE_REFERENCE),
        );
    }

    /// Walk a class's supertype chain looking for a member by simple name.
    /// Returns the declared `Type` plus the user-class name when the
    /// declared type names a user class (drives `expr_class` propagation
    /// through chains like `foo.bar.baz`).
    pub(crate) fn lookup_member_through_chain(
        &self,
        class: &str,
        name: &str,
    ) -> Option<(Type, Option<String>)> {
        let mut seen: HashSet<String> = HashSet::new();
        let mut frontier: Vec<String> = vec![class.to_string()];
        let mut steps = 0;
        while let Some(c) = frontier.pop() {
            if steps > 64 {
                break;
            }
            steps += 1;
            if !seen.insert(c.clone()) {
                continue;
            }
            let Some(info) = self.classes.get(&c) else {
                continue;
            };
            if let Some(ty) = info.members.get(name) {
                let cn = info.member_class.get(name).cloned();
                return Some((ty.clone(), cn));
            }
            for s in &info.supertypes {
                frontier.push(s.clone());
            }
        }
        None
    }

    /// §17.5.9: a bare member reference inside nested DSL lambdas must
    /// resolve against the innermost implicit receiver whenever any
    /// closer receiver shares a dsl marker with the receiver that
    /// actually owns the member. Emits T0113 at `member_span` otherwise.
    pub(crate) fn enforce_dsl_scope_for_member(&mut self, name: &str, member_span: Span) {
        let stack = self.dsl_receiver_stack.clone();
        if stack.len() < 2 {
            return;
        }
        let last_idx = stack.len() - 1;
        let mut resolved: Option<usize> = None;
        for (i, (cls, _)) in stack.iter().enumerate() {
            if self.lookup_member_through_chain(cls, name).is_some() {
                resolved = Some(i);
            }
        }
        let Some(idx) = resolved else { return };
        if idx == last_idx {
            return;
        }
        let (resolved_cls, resolved_markers) = stack[idx].clone();
        if resolved_markers.is_empty() {
            return;
        }
        let mut inner_cls: Option<String> = None;
        for (cls, markers) in &stack[idx + 1..] {
            if markers.iter().any(|m| resolved_markers.contains(m)) {
                inner_cls = Some(cls.clone());
                break;
            }
        }
        let Some(inner) = inner_cls else { return };
        self.diagnostics.emit(
            Diagnostic::error(
                format!(
                    "member `{name}` of `{resolved_cls}` is shadowed by a closer DSL receiver of type `{inner}`"
                ),
                member_span,
            )
            .with_code(codes::TYPE_DSL_SCOPE_VIOLATION),
        );
    }

    /// §17.5.9: `this@Outer.b` is rejected when a closer implicit
    /// receiver shares a marker with `Outer` and also exposes `b`.
    pub(crate) fn enforce_dsl_scope_for_qualified_this(
        &mut self,
        qualifier: &str,
        member_name: &str,
        member_span: Span,
    ) {
        let stack = self.dsl_receiver_stack.clone();
        if stack.len() < 2 {
            return;
        }
        let Some(idx) = stack.iter().position(|(c, _)| c == qualifier) else {
            return;
        };
        if idx == stack.len() - 1 {
            return;
        }
        let (resolved_cls, resolved_markers) = stack[idx].clone();
        if resolved_markers.is_empty() {
            return;
        }
        if self
            .lookup_member_through_chain(&resolved_cls, member_name)
            .is_none()
        {
            return;
        }
        let mut inner_cls: Option<String> = None;
        for (cls, markers) in &stack[idx + 1..] {
            if markers.iter().any(|m| resolved_markers.contains(m)) {
                inner_cls = Some(cls.clone());
                break;
            }
        }
        let Some(inner) = inner_cls else { return };
        self.diagnostics.emit(
            Diagnostic::error(
                format!(
                    "member `{member_name}` of `{resolved_cls}` is shadowed by a closer DSL receiver of type `{inner}`"
                ),
                member_span,
            )
            .with_code(codes::TYPE_DSL_SCOPE_VIOLATION),
        );
    }

    /// `a name b` (`is_infix == true`) must resolve to a function declared
    /// with the `infix` modifier. Walks top-level fns, the lhs's class
    /// members, and extension functions visible on the lhs's class chain;
    /// emits T0029 when no candidate has the modifier set.
    pub(crate) fn check_infix_modifier(&mut self, callee: &Expr, args: &[Expr], call_span: Span) {
        let Expr::Path { segments, .. } = callee else {
            return;
        };
        if segments.len() != 1 {
            return;
        }
        let name = &segments[0].name;
        let mut found = false;
        let mut any = false;
        if let Some(sigs) = self.fns.get(name) {
            for s in sigs {
                any = true;
                if s.is_infix {
                    found = true;
                }
            }
        }
        if !found && let Some(lhs) = args.first() {
            let lhs_class = self.expr_class.get(&lhs.span()).cloned();
            if let Some(cn) = lhs_class {
                let mut seen: HashSet<String> = HashSet::new();
                let mut frontier: Vec<String> = vec![cn.clone()];
                let mut steps = 0;
                while let Some(c) = frontier.pop() {
                    if steps > 64 {
                        break;
                    }
                    steps += 1;
                    if !seen.insert(c.clone()) {
                        continue;
                    }
                    if let Some(info) = self.classes.get(&c) {
                        if let Some(flags) = info.member_flags.get(name) {
                            any = true;
                            if flags.is_infix {
                                found = true;
                                break;
                            }
                        }
                        for s in &info.supertypes {
                            frontier.push(s.clone());
                        }
                    }
                }
                if !found {
                    let mut keys: Vec<String> = vec![cn.clone()];
                    let mut seen2: HashSet<String> = HashSet::new();
                    seen2.insert(cn.clone());
                    let mut f2: Vec<String> = vec![cn.clone()];
                    let mut steps2 = 0;
                    while let Some(c) = f2.pop() {
                        if steps2 > 64 {
                            break;
                        }
                        steps2 += 1;
                        if let Some(info) = self.classes.get(&c) {
                            for s in &info.supertypes {
                                if seen2.insert(s.clone()) {
                                    keys.push(s.clone());
                                    f2.push(s.clone());
                                }
                            }
                        }
                    }
                    keys.push("Any".to_string());
                    for key in &keys {
                        if let Some(list) = self.extensions.get(key) {
                            for ext in list {
                                if ext.name == *name {
                                    any = true;
                                    if ext.sig.is_infix {
                                        found = true;
                                        break;
                                    }
                                }
                            }
                        }
                        if found {
                            break;
                        }
                    }
                }
            }
        }
        if any && !found {
            self.diagnostics.emit(
                Diagnostic::error(
                    format!("`{name}` is not declared with the `infix` modifier"),
                    call_span,
                )
                .with_code(codes::TYPE_INFIX_MODIFIER_REQUIRED),
            );
        }
    }

    /// Spec §11.8: walk every (f, g) declared in the same scope at the
    /// same c-level partition. The phantom call site is fully-specified
    /// (every parameter supplied, no defaults used), so we only consider
    /// pairs of equal arity. If neither dominates the other on the
    /// pairwise MSC test and the case-3 tiebreakers also fail to pick a
    /// winner, the pair is a compile-time conflict.
    pub(crate) fn check_conflicting_overloads(&mut self) {
        let mut pairs: Vec<OverloadPair> = Vec::new();
        let classes_snapshot = self.classes.clone();
        for (name, sigs) in &self.fns {
            if sigs.len() < 2 {
                continue;
            }
            for i in 0..sigs.len() {
                for j in (i + 1)..sigs.len() {
                    let (a, b) = (&sigs[i], &sigs[j]);
                    if a.params.len() != b.params.len() {
                        continue;
                    }
                    let n = a.params.len();
                    let a_ge_b = at_least_as_applicable(a, b, n, &classes_snapshot);
                    let b_ge_a = at_least_as_applicable(b, a, n, &classes_snapshot);
                    if !(a_ge_b && b_ge_a) {
                        continue;
                    }
                    // Case 3 tiebreakers: non-parameterized, fewer defaults,
                    // no-vararg.
                    if (a.type_param_count == 0) != (b.type_param_count == 0) {
                        continue;
                    }
                    let a_defaults = a.has_default.iter().filter(|h| **h).count();
                    let b_defaults = b.has_default.iter().filter(|h| **h).count();
                    if a_defaults != b_defaults {
                        continue;
                    }
                    let a_va = a.is_vararg.iter().any(|v| *v);
                    let b_va = b.is_vararg.iter().any(|v| *v);
                    if a_va != b_va {
                        continue;
                    }
                    if let (Some(sa), Some(sb)) = (a.decl_span, b.decl_span) {
                        pairs.push((
                            sa,
                            sb,
                            name.clone(),
                            a.param_names.clone(),
                            b.param_names.clone(),
                        ));
                    }
                }
            }
        }
        for (sa, sb, name, _ap, _bp) in pairs {
            self.diagnostics.emit(
                Diagnostic::error(format!("Conflicting overloads for `{name}`"), sa)
                    .with_code(codes::TYPE_CONFLICTING_OVERLOADS),
            );
            let _ = sb;
        }
    }

    /// Spec §7.1.2: a compound assignment `A op= B` is ambiguous when the
    /// LHS receiver's class declares *both* the `op` binary operator
    /// (`plus` / `minus` / `times` / `div` / `rem`) and the matching
    /// `opAssign` form (`plusAssign` / …). Emits T0079.
    pub(crate) fn check_compound_assign_ambiguity(
        &mut self,
        target: &Expr,
        op: AssignOp,
        span: Span,
    ) {
        let (op_name, assign_name): (&str, &str) = match op {
            AssignOp::Add => ("plus", "plusAssign"),
            AssignOp::Sub => ("minus", "minusAssign"),
            AssignOp::Mul => ("times", "timesAssign"),
            AssignOp::Div => ("div", "divAssign"),
            AssignOp::Rem => ("rem", "remAssign"),
            AssignOp::Assign => return,
        };
        let class_name = match target {
            Expr::Path { segments, .. } if segments.len() == 1 => self
                .lookup(&segments[0].name)
                .and_then(|b| b.class_name.clone()),
            Expr::Member { receiver, .. } | Expr::Index { receiver, .. } => {
                self.expr_class.get(&receiver.span()).cloned()
            }
            _ => self.expr_class.get(&target.span()).cloned(),
        };
        let Some(class_name) = class_name else { return };
        let Some(info) = self.classes.get(&class_name) else {
            return;
        };
        let has_op = info.members.contains_key(op_name);
        let has_assign = info.members.contains_key(assign_name);
        if has_op && has_assign {
            self.diagnostics.emit(
                Diagnostic::error(
                    format!(
                        "Compound assignment `{op_name}=` is ambiguous: `{class_name}` declares both `{op_name}` and `{assign_name}`",
                    ),
                    span,
                )
                .with_code(codes::TYPE_ASSIGN_OPERATOR_AMBIGUITY),
            );
        }
    }

    /// Spec §11.2.2: `super<Q>.f(...)` requires `Q` to be an immediate
    /// supertype of the enclosing class. Emits T0073 otherwise.
    pub(crate) fn check_super_qualifier(&mut self, qualifier: &TypeRef, super_span: Span) {
        let Some(enclosing) = self.class_stack.last().cloned() else {
            return;
        };
        let Some(info) = self.classes.get(&enclosing).cloned() else {
            return;
        };
        let q_name = qualifier.name.name.as_str();
        if !info.supertypes.iter().any(|s| s == q_name) {
            self.diagnostics.emit(
                Diagnostic::error(
                    format!(
                        "`super<{q_name}>` is not allowed: `{q_name}` is not an immediate supertype of `{enclosing}`",
                    ),
                    super_span,
                )
                .with_code(codes::TYPE_SUPER_QUALIFIER_NOT_SUPERTYPE),
            );
        }
    }

    /// Spec §11.2.2 basic super-form: walk the enclosing class's direct
    /// supertypes and emit T0093 when two or more contribute a member
    /// named `name`. The diagnostic encourages disambiguation via
    /// `super<TypeName>.name(...)`.
    pub(crate) fn check_ambiguous_super(&mut self, name: &str, super_span: Span) {
        let Some(enclosing) = self.class_stack.last().cloned() else {
            return;
        };
        let Some(info) = self.classes.get(&enclosing).cloned() else {
            return;
        };
        let mut contributors: Vec<String> = Vec::new();
        for s in &info.supertypes {
            if self.lookup_member_through_chain(s, name).is_some() {
                contributors.push(s.clone());
            }
        }
        if contributors.len() >= 2 {
            self.diagnostics.emit(
                Diagnostic::error(
                    format!(
                        "`super.{name}` is ambiguous: members named `{name}` exist in {}. Use `super<TypeName>.{name}(...)` to disambiguate.",
                        contributors.join(" and ")
                    ),
                    super_span,
                )
                .with_code(codes::TYPE_AMBIGUOUS_SUPER),
            );
        }
    }
}

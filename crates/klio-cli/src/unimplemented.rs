//! Ahead-of-time "missing implementation" check.
//!
//! Many silent-`Unit` runtime bugs trace to the same shape: an upstream
//! `expect` declaration (or a bodyless `external`) that klio loads but for
//! which no `actual` Kotlin body and no host intrinsic exist. The call
//! resolves, runs nothing, and returns `Unit` — there is no diagnostic.
//!
//! This check loads the program together with every pack it imports and the
//! embedded stdlib, walks all declarations, and reports each `expect`
//! function / property that has neither a body-carrying counterpart (a
//! Kotlin `actual`) nor a registered klio intrinsic backing its FQN. It is
//! the static analogue of the runtime failure mode.

use std::collections::{BTreeMap, HashSet};

use crate::pack_cache::{RequestedFeatures, load_installed_packs, merged_host_bindings};
use crate::{ExitCode, Lexer, Parser, PathBuf, SourceMap};

/// One unimplemented `expect` declaration awaiting an actual / intrinsic.
struct Missing {
    /// `fun` or `val`/`var`.
    kind: &'static str,
    /// Best-effort fully qualified display name (`pkg.Owner.name`).
    display: String,
    file: String,
    line: u32,
}

/// Strip generic args and package qualifier from a type/owner name:
/// `kotlin.collections.List<T>` -> `List`.
fn simple_name(n: &str) -> String {
    let base = n.split('<').next().unwrap_or(n);
    base.rsplit('.').next().unwrap_or(base).trim().to_string()
}

/// The owner used to key a declaration: an extension's receiver type if
/// present, else the lexically enclosing class/object (`None` = top level).
fn fn_owner(f: &klio_ast::Function, enclosing: Option<&str>) -> Option<String> {
    f.receiver_type
        .as_ref()
        .map(|t| simple_name(&t.name.name))
        .or_else(|| enclosing.map(str::to_string))
}

fn prop_owner(p: &klio_ast::Property, enclosing: Option<&str>) -> Option<String> {
    p.receiver_type
        .as_ref()
        .map(|t| simple_name(&t.name.name))
        .or_else(|| enclosing.map(str::to_string))
}

/// `owner#name` (owner empty for a top-level entity) — the key used to
/// decide whether a body-carrying counterpart exists for an `expect`.
fn impl_key(owner: Option<&str>, name: &str) -> String {
    format!("{}#{name}", owner.unwrap_or(""))
}

#[derive(Default)]
struct Scan {
    /// Keys (`owner#name`) that have a body somewhere — a Kotlin `actual`
    /// (or a plain definition) the `expect` can bind to.
    implemented: HashSet<String>,
    /// `expect`s discovered, paired with their owner + package context.
    expects: Vec<ExpectDecl>,
}

struct ExpectDecl {
    kind: &'static str,
    pkg: String,
    owner: Option<String>,
    name: String,
    span: klio_span::Span,
}

impl Scan {
    fn walk(
        &mut self,
        decls: &[klio_ast::Decl],
        pkg: &str,
        enclosing: Option<&str>,
        in_abstract_owner: bool,
    ) {
        for d in decls {
            match d {
                klio_ast::Decl::Function(f) => {
                    let owner = fn_owner(f, enclosing);
                    if f.body.is_some() || f.is_actual {
                        self.implemented
                            .insert(impl_key(owner.as_deref(), &f.name.name));
                    }
                    // An `expect` (never a body) with no actual/intrinsic is
                    // the target. Abstract members and interface methods are
                    // overridden, not implemented here — skip them.
                    if f.is_expect && !f.is_abstract && !in_abstract_owner {
                        self.expects.push(ExpectDecl {
                            kind: "fun",
                            pkg: pkg.to_string(),
                            owner,
                            name: f.name.name.clone(),
                            span: f.span,
                        });
                    }
                }
                klio_ast::Decl::Property(p) => {
                    let owner = prop_owner(p, enclosing);
                    let has_body =
                        p.init.is_some() || p.delegate.is_some() || p.getter.is_some();
                    if has_body {
                        self.implemented
                            .insert(impl_key(owner.as_deref(), &p.name.name));
                    }
                    if p.is_expect && !p.is_abstract && !in_abstract_owner {
                        self.expects.push(ExpectDecl {
                            kind: "val",
                            pkg: pkg.to_string(),
                            owner,
                            name: p.name.name.clone(),
                            span: p.span,
                        });
                    }
                }
                klio_ast::Decl::Class(c) => {
                    // Members of an interface / abstract class are dispatched
                    // through overrides, so an absent body there is expected.
                    let abstract_owner = c.is_interface || c.is_abstract;
                    self.walk(&c.members, pkg, Some(&c.name.name), abstract_owner);
                }
                klio_ast::Decl::Object(o) => {
                    self.walk(&o.members, pkg, Some(&o.name.name), false);
                }
                klio_ast::Decl::TypeAlias(_) => {}
            }
        }
    }
}

/// Member names the interpreter resolves directly in `Vm::call_member`
/// (hardcoded arms), not through the binding table — so an `expect` for one
/// is already served and must not be reported. Mirrors the `("name", arity)`
/// arms in `klio-interp-ir`'s `host_call_member.rs`; kept here as an explicit
/// list since those arms are not otherwise enumerable.
const INTERP_BUILTIN_MEMBERS: &[&str] = &[
    // Reified enum reflection, resolved in `call_func_typed` (not a binding).
    "enumValues",
    "enumValueOf",
    "asList",
    "constrainOnce",
    "containsValue",
    "distinct",
    "distinctBy",
    "drop",
    "dropWhile",
    "equals",
    "filter",
    "filterIndexed",
    "filterNot",
    "flatMap",
    "hashCode",
    "map",
    "mapIndexed",
    "notNull",
    "observable",
    "onEach",
    "sorted",
    "sortedBy",
    "sortedByDescending",
    "sortedDescending",
    "sortedWith",
    "take",
    "takeWhile",
    "toList",
    "toMutableList",
    "toSet",
    "toString",
    "toTypedArray",
];

/// Candidate intrinsic FQNs for an `expect` — generous so a real binding
/// under any plausible package/owner spelling counts as implemented.
fn candidate_fqns(pkg: &str, owner: Option<&str>, name: &str) -> Vec<String> {
    const PREFIXES: &[&str] = &[
        "kotlin",
        "kotlin.collections",
        "kotlin.text",
        "kotlin.comparisons",
        "kotlin.math",
        "kotlin.io",
        "kotlin.io.encoding",
        "kotlin.ranges",
        "kotlin.sequences",
    ];
    let mut prefixes: Vec<String> = vec![pkg.to_string()];
    prefixes.extend(PREFIXES.iter().map(|s| (*s).to_string()));
    let mut out = Vec::new();
    for p in &prefixes {
        if let Some(o) = owner {
            out.push(format!("{p}.{o}.{name}"));
        } else {
            out.push(format!("{p}.{name}"));
        }
    }
    // A bare `pkg.name` and `owner.name` fallback for unusual keyings.
    if let Some(o) = owner {
        out.push(format!("{o}.{name}"));
    }
    out
}

pub(crate) fn run_check_unimplemented(
    files: &[PathBuf],
    features: &RequestedFeatures,
) -> ExitCode {
    if files.is_empty() {
        eprintln!("usage: klio check --unimplemented <file.kt> [...]");
        return ExitCode::from(2);
    }
    let mut map = SourceMap::new();
    let mut user_asts: Vec<klio_ast::KotlinFile> = Vec::with_capacity(files.len());
    for path in files {
        let Ok(src) = std::fs::read_to_string(path) else {
            eprintln!("error: cannot read {}", path.display());
            return ExitCode::from(2);
        };
        let id = map.add(path, src.clone());
        let lexed = Lexer::new(id, &src).tokenize();
        let (ast, _diags) = Parser::new(id, &src, &lexed.tokens).parse_file();
        user_asts.push(ast);
    }
    let (pack_asts, _bindings) = load_installed_packs(&user_asts, &mut map, features);

    let mut scan = Scan::default();
    for f in pack_asts.iter().chain(user_asts.iter()) {
        let pkg = f
            .package
            .as_ref()
            .map(|h| {
                h.path
                    .iter()
                    .map(|i| i.name.as_str())
                    .collect::<Vec<_>>()
                    .join(".")
            })
            .unwrap_or_default();
        scan.walk(&f.decls, &pkg, None, false);
    }

    let bindings = merged_host_bindings();
    // Index every registered intrinsic by (owner, name) and by top-level
    // name. Intrinsics are keyed `pkg.Owner.name` (member / extension) or
    // `pkg.name` (top-level); matching against the real key set catches a
    // binding under any package spelling, far more reliably than guessing.
    let mut intrinsic_owner_name: HashSet<(String, String)> = HashSet::new();
    let mut intrinsic_top_name: HashSet<String> = HashSet::new();
    for (fqn, _) in bindings.entries() {
        let segs: Vec<&str> = fqn.rsplit('.').collect();
        let Some(name) = segs.first() else { continue };
        match segs.get(1) {
            // A capitalised preceding segment is a type owner; a
            // lowercase one is a package component (top-level fn).
            Some(prev) if prev.chars().next().is_some_and(char::is_uppercase) => {
                intrinsic_owner_name.insert(((*prev).to_string(), (*name).to_string()));
            }
            _ => {
                intrinsic_top_name.insert((*name).to_string());
            }
        }
    }
    let mut missing: Vec<Missing> = Vec::new();
    let mut seen: HashSet<String> = HashSet::new();
    for e in &scan.expects {
        // A Kotlin `actual` / body for this owner+name implements it.
        if scan
            .implemented
            .contains(&impl_key(e.owner.as_deref(), &e.name))
        {
            continue;
        }
        // A registered host intrinsic under any candidate FQN implements it.
        if candidate_fqns(&e.pkg, e.owner.as_deref(), &e.name)
            .iter()
            .any(|fqn| bindings.resolve(fqn).is_some())
        {
            continue;
        }
        // …or one indexed by (owner, name). A top-level intrinsic of the
        // same name also serves an extension (`kotlin.math.absoluteValue`
        // backs the `Double.absoluteValue` property), so accept that too.
        if let Some(o) = &e.owner {
            if intrinsic_owner_name.contains(&(o.clone(), e.name.clone())) {
                continue;
            }
        }
        if intrinsic_top_name.contains(&e.name) {
            continue;
        }
        // …or a core interpreter builtin serves it directly.
        if INTERP_BUILTIN_MEMBERS.contains(&e.name.as_str()) {
            continue;
        }
        let display = [e.pkg.as_str(), e.owner.as_deref().unwrap_or("")]
            .into_iter()
            .filter(|s| !s.is_empty())
            .chain(std::iter::once(e.name.as_str()))
            .collect::<Vec<_>>()
            .join(".");
        // Collapse overload sets / duplicate expects to one line.
        if !seen.insert(display.clone()) {
            continue;
        }
        let sf = map.get(e.span.file);
        let file = sf.path.display().to_string();
        let line = sf.line_col(e.span.start).0;
        missing.push(Missing {
            kind: e.kind,
            display,
            file,
            line,
        });
    }

    if missing.is_empty() {
        println!("no unimplemented expect declarations reachable from the program");
        return ExitCode::SUCCESS;
    }

    missing.sort_by(|a, b| a.display.cmp(&b.display));
    let mut by_pkg: BTreeMap<String, Vec<&Missing>> = BTreeMap::new();
    for m in &missing {
        let pkg = m.display.rsplit_once('.').map_or("", |(p, _)| p).to_string();
        by_pkg.entry(pkg).or_default().push(m);
    }
    println!(
        "{} expect declaration(s) have no actual or intrinsic (would return Unit at runtime):\n",
        missing.len()
    );
    for (pkg, items) in &by_pkg {
        println!("  {pkg}");
        for m in items {
            println!("    {} {}  ({}:{})", m.kind, m.display, m.file, m.line);
        }
    }
    ExitCode::from(1)
}

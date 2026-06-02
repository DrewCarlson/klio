use crate::{PathBuf, SourceMap};

/// Build a single `HostBindings` table that the loader passes to
/// every pack: starts with `klio-stdlib`'s defaults and unions in
/// the bindings each `klio-kotlinx-*` crate ships. A pack's
/// `host_symbol` keys resolve against this merged table, so a
/// `kotlinx.atomicfu.AtomicInt.compareAndSet` binding wins exactly
/// when the user has the matching pack loaded.
/// Consume the **embedded** stdlib pack's `SOURCES` section (the
/// curated upstream commonMain + klio actuals — today `kotlin.time`).
///
/// The embedded stdlib pack's `SYMBOLS` / `BINDINGS` are already
/// statically linked into the interpreter (the cache loop deliberately
/// skips any on-disk `stdlib*` pack so they are not double-loaded);
/// those sections are intentionally NOT touched here. This step only
/// parses the Kotlin `SOURCES` and pushes the resulting ASTs into the
/// module + registers their packages, so a program importing a package
/// these sources provide resolves against real upstream Kotlin.
///
/// Gated on the user's imports: the curated set is loaded only when a
/// user import matches one of the packages those sources declare
/// (prefix match — `import kotlin.time.*` /
/// `import kotlin.time.Duration` both trigger `kotlin.time`). Programs
/// that never import such a package pay nothing and see no change to
/// the statically-linked stdlib surface.
fn load_embedded_stdlib_sources(
    user_import_prefixes: &std::collections::HashSet<String>,
    source_map: &mut SourceMap,
    out_asts: &mut Vec<klio_ast::KotlinFile>,
    out_bindings: &mut klio_stdlib::HostBindings,
) {
    use klio_pack::schema::decode;
    use klio_pack::{PackReader, section_names};

    let bytes = klio_stdlib_pack::stdlib_pack_bytes();
    let Ok(pack) = PackReader::from_bytes(bytes.into_owned()) else {
        return;
    };
    let Ok(Some(payload)) = pack.read_section(section_names::SOURCES) else {
        return;
    };
    let Ok(bundle) = decode::<klio_pack::schema::SourceBundle>(&payload) else {
        return;
    };
    if bundle.files.is_empty() {
        return;
    }

    // Parse each source once, recording its package header. The
    // curated set is an interdependent unit (Duration <-> DurationUnit
    // <-> TimeSource <-> the klio actuals), so it is all-or-nothing:
    // load every file iff some user import matches any package the set
    // declares.
    let mut parsed: Vec<(String, klio_ast::KotlinFile)> = Vec::with_capacity(bundle.files.len());
    for sf in &bundle.files {
        // Consumption deferral: sources that PARSE but whose interpreted
        // declarations would shadow — and currently conflict with —
        // klio's host intrinsics (comparator combinators, the Regex/text
        // surface). The intrinsics serve these APIs until the source
        // bodies interoperate. See klio_stdlib::CONSUMPTION_DEFERRED_SOURCES.
        if klio_stdlib::is_consumption_deferred_source(&sf.rel_path) {
            continue;
        }
        if std::env::var_os("KLIO_PACK_DIAG").is_some()
            && (sf.rel_path.contains("Maps.kt") || sf.rel_path.contains("Sets.kt"))
        {
            eprintln!("[embed source] {}", sf.rel_path);
        }
        let text = String::from_utf8_lossy(&sf.bytes).into_owned();
        let fid = source_map.add(&sf.rel_path, text);
        let src = source_map.get(fid).source.clone();
        let lexed = klio_lexer::Lexer::new(fid, &src).tokenize();
        if lexed.diagnostics.has_errors() {
            if std::env::var_os("KLIO_PACK_DIAG").is_some() {
                eprintln!(
                    "[embed lex err] {}: {} diags",
                    sf.rel_path,
                    lexed.diagnostics.diagnostics().len()
                );
            }
            continue;
        }
        let (ast, diags) = klio_parser::Parser::new(fid, &src, &lexed.tokens).parse_file();
        if diags.has_errors() {
            if std::env::var_os("KLIO_PACK_DIAG").is_some() {
                for d in diags.diagnostics() {
                    eprintln!(
                        "[embed parse err] {}:{:?}: {}",
                        sf.rel_path, d.primary.span, d.message
                    );
                }
            }
            continue;
        }
        let pkg = ast
            .package
            .as_ref()
            .map(|p| {
                p.path
                    .iter()
                    .map(|i| i.name.as_str())
                    .collect::<Vec<_>>()
                    .join(".")
            })
            .unwrap_or_default();
        parsed.push((pkg, ast));
    }

    // Always load files in implicitly-imported packages
    // (kotlin.collections, kotlin.ranges, ...) — per spec §10.1
    // these are visible in every source file without an explicit
    // import, so their builders/extensions must be available to user
    // code unconditionally. Other curated sources stay all-or-nothing
    // and gated on a matching user import.
    let any_non_implicit = parsed
        .iter()
        .any(|(pkg, _)| !pkg.is_empty() && !klio_stdlib::is_implicitly_imported_package(pkg));
    let imported_match = parsed.iter().any(|(pkg, _)| {
        !pkg.is_empty()
            && user_import_prefixes.iter().any(|imp| {
                imp == pkg
                    || imp.starts_with(&format!("{pkg}."))
                    || pkg.starts_with(&format!("{imp}."))
            })
    });
    let load_gated = imported_match || !any_non_implicit;

    for (pkg, ast) in parsed {
        let is_implicit = !pkg.is_empty() && klio_stdlib::is_implicitly_imported_package(&pkg);
        if !is_implicit && !load_gated {
            continue;
        }
        if !pkg.is_empty() {
            klio_stdlib::register_known_package(pkg);
        }
        out_asts.push(ast);
    }

    // The curated sources' klio `actual`s call a couple of `internal`
    // platform helpers (`kotlin.time.__klio_time_systemMillis` /
    // `__klio_time_monotonicNanos`) whose Kotlin bodies are inert
    // stubs. Register their Rust host bindings into the installed
    // overlay so they shadow the stub bodies at dispatch — exactly the
    // mechanism a kotlinx pack's BINDINGS use for its `__kxdt_*`
    // helpers. These come from the statically-linked stdlib defaults;
    // we do NOT re-load the embedded pack's SYMBOLS/BINDINGS sections.
    let merged = merged_host_bindings();
    for fqn in [
        "kotlin.time.__klio_time_systemMillis",
        "kotlin.time.__klio_time_monotonicNanos",
        "kotlin.coroutines.__klio_co_newSlot",
        "kotlin.coroutines.__klio_co_park",
        "kotlin.coroutines.__klio_co_resume",
        "kotlin.coroutines.__klio_co_runRoot",
    ] {
        if let Some(f) = merged.resolve(fqn) {
            out_bindings.register(fqn, f);
        }
    }
}

struct PackCandidate {
    pack: klio_pack::PackReader,
    manifest: klio_pack::schema::PackManifest,
}

/// Load one resolved pack candidate: register its packages, parse its
/// sources (or fall back to the frozen AST bundle), and wire up its
/// bindings. Imports discovered in the pack's files are appended to
/// `new_imports` so the fixpoint loop can pull in transitive packs.
fn load_pack_candidate(
    c: &PackCandidate,
    lib_id: &str,
    merged: &klio_stdlib::HostBindings,
    source_map: &mut SourceMap,
    out_asts: &mut Vec<klio_ast::KotlinFile>,
    out_bindings: &mut klio_stdlib::HostBindings,
    new_imports: &mut Vec<String>,
) {
    use klio_pack::schema::{AstBundle, BindingManifest, decode};
    use klio_pack::section_names;

    let manifest = &c.manifest;
    let pack = &c.pack;
    // Teach the resolver every package this pack ships +
    // declares implicit, so user `import kotlinx.*` lines
    // resolve instead of tripping the "only kotlin.* is known"
    // gate. Pack manifests carry implicit packages; each AST
    // file's `package` header covers the rest.
    klio_stdlib::register_known_package(manifest.library_id.clone());
    for p in &manifest.implicit_packages {
        klio_stdlib::register_known_package(p.clone());
    }
    // Re-parse the pack's Kotlin sources through the shared
    // SourceMap rather than decoding the frozen `ast` section.
    // Re-parsing (a) assigns every pack file a fresh, unique
    // FileId so its spans never collide with user files and the
    // diagnostic renderer can show pack source, and (b) is
    // immune to AST-schema drift — a pack built against an older
    // klio still loads because we parse with the current
    // grammar. Falls back to the frozen `ast` bundle only when
    // the `sources` section is absent.
    let mut loaded_from_sources = false;
    if let Ok(Some(payload)) = pack.read_section(section_names::SOURCES)
        && let Ok(bundle) = decode::<klio_pack::schema::SourceBundle>(&payload)
    {
        for sf in &bundle.files {
            // See load_embedded_stdlib_sources / klio_stdlib::
            // CONSUMPTION_DEFERRED_SOURCES: these parse but their
            // interpreted bodies conflict with klio's intrinsics
            // until integrated; not consumed yet.
            if klio_stdlib::is_consumption_deferred_source(&sf.rel_path) {
                continue;
            }
            let text = String::from_utf8_lossy(&sf.bytes).into_owned();
            let fid = source_map.add(&sf.rel_path, text);
            let src = source_map.get(fid).source.clone();
            let lexed = klio_lexer::Lexer::new(fid, &src).tokenize();
            if lexed.diagnostics.has_errors() {
                continue;
            }
            let (ast, diags) = klio_parser::Parser::new(fid, &src, &lexed.tokens).parse_file();
            if diags.has_errors() {
                continue;
            }
            if let Some(pkg) = &ast.package {
                let path = pkg
                    .path
                    .iter()
                    .map(|i| i.name.as_str())
                    .collect::<Vec<_>>()
                    .join(".");
                if !path.is_empty() {
                    klio_stdlib::register_known_package(path);
                }
            }
            for imp in &ast.imports {
                new_imports.push(
                    imp.path
                        .iter()
                        .map(|i| i.name.as_str())
                        .collect::<Vec<_>>()
                        .join("."),
                );
            }
            out_asts.push(ast);
            loaded_from_sources = true;
        }
    }
    if !loaded_from_sources
        && let Ok(Some(payload)) = pack.read_section(section_names::AST)
        && let Ok(ast_bundle) = decode::<AstBundle>(&payload)
    {
        for f in ast_bundle.files {
            if let Some(pkg) = &f.kotlin_file.package {
                let path = pkg
                    .path
                    .iter()
                    .map(|i| i.name.as_str())
                    .collect::<Vec<_>>()
                    .join(".");
                if !path.is_empty() {
                    klio_stdlib::register_known_package(path);
                }
            }
            for imp in &f.kotlin_file.imports {
                new_imports.push(
                    imp.path
                        .iter()
                        .map(|i| i.name.as_str())
                        .collect::<Vec<_>>()
                        .join("."),
                );
            }
            out_asts.push(f.kotlin_file);
        }
    }
    if let Ok(Some(payload)) = pack.read_section(section_names::BINDINGS)
        && let Ok(bm) = decode::<BindingManifest>(&payload)
    {
        for b in bm.bindings {
            if let Some(f) = merged.resolve(&b.host_symbol) {
                // HostBindings keys are `'static`; leak the
                // FQN string so the entry lives for the rest
                // of the process. Pack-load is a one-shot at
                // startup, so this is bounded and small.
                let leaked: &'static str = Box::leak(b.fqn.clone().into_boxed_str());
                out_bindings.register(leaked, f);
            }
        }
    }
    // Also bring in any merged binding whose FQN sits under the
    // loaded pack's library_id but isn't explicitly listed in
    // the pack manifest. Newer Rust-side bindings (e.g. host
    // entries added after the pack was last built) take effect
    // without forcing a pack rebuild.
    let lib_prefix = format!("{lib_id}.");
    for (fqn, f) in merged.entries() {
        if fqn.starts_with(&lib_prefix) {
            out_bindings.register(fqn, f);
        }
    }
}

/// Read every `.klio-pack` file in the cache directory (skipping the
/// embedded stdlib) and decode its manifest, yielding the set of
/// candidate packs the fixpoint loader picks from.
fn collect_pack_candidates(entries: std::fs::ReadDir) -> Vec<PackCandidate> {
    use klio_pack::schema::{PackManifest, decode};
    use klio_pack::{PackReader, section_names};
    let mut candidates: Vec<PackCandidate> = Vec::new();
    for e in entries.flatten() {
        let p = e.path();
        if p.extension().is_none_or(|x| x != "klio-pack") {
            continue;
        }
        if p.file_name()
            .and_then(|n| n.to_str())
            .is_some_and(|n| n.starts_with("stdlib"))
        {
            continue;
        }
        let Ok(bytes) = std::fs::read(&p) else {
            continue;
        };
        let Ok(pack) = PackReader::from_bytes(bytes) else {
            continue;
        };
        let manifest: PackManifest = match pack
            .read_section(section_names::MANIFEST)
            .ok()
            .flatten()
            .as_deref()
            .and_then(|payload| decode(payload).ok())
        {
            Some(m) => m,
            None => continue,
        };
        candidates.push(PackCandidate { pack, manifest });
    }
    candidates
}

/// Walk the local pack cache, parse each pack's AST bundle, and
/// build a `HostBindings` populated with the Rust-side bindings each
/// pack declares. The caller prepends `pack_asts` to the user's AST
/// list before lowering so pack declarations (`AtomicInt`, `Buffer`,
/// …) participate in IR build. Only packs whose imports actually
/// appear in the user's source are loaded — keeps unused-pack
/// declarations out of the module + cuts startup time when no
/// kotlinx import is present.
pub(crate) fn load_installed_packs(
    user_asts: &[klio_ast::KotlinFile],
    source_map: &mut SourceMap,
) -> (Vec<klio_ast::KotlinFile>, klio_stdlib::HostBindings) {
    let mut out_asts: Vec<klio_ast::KotlinFile> = Vec::new();
    let mut out_bindings = klio_stdlib::HostBindings::new();
    let user_import_prefixes: std::collections::HashSet<String> = user_asts
        .iter()
        .flat_map(|f| {
            f.imports.iter().map(|imp| {
                imp.path
                    .iter()
                    .map(|i| i.name.as_str())
                    .collect::<Vec<_>>()
                    .join(".")
            })
        })
        .collect();
    // The embedded stdlib's curated kotlin.time SOURCES are consumed
    // *after* the pack-cache walk, so a loaded pack that itself
    // imports kotlin.time (kotlinx-datetime 0.8.0's
    // `kotlinx.datetime.Instant` is a typealias to
    // `kotlin.time.Instant`) also triggers the load — gating on the
    // user program's imports alone would miss it.
    let Ok(cache) = klio_cache_dir() else {
        load_embedded_stdlib_sources(
            &user_import_prefixes,
            source_map,
            &mut out_asts,
            &mut out_bindings,
        );
        return (out_asts, out_bindings);
    };
    let Ok(entries) = std::fs::read_dir(&cache) else {
        load_embedded_stdlib_sources(
            &user_import_prefixes,
            source_map,
            &mut out_asts,
            &mut out_bindings,
        );
        return (out_asts, out_bindings);
    };
    let merged = merged_host_bindings();
    // Collect every candidate pack on disk once. Loading is then a
    // fixed-point loop over this list: each pass loads packs whose
    // `library_id` matches a currently-known import prefix, and the
    // pass's freshly-loaded ASTs contribute their own imports to
    // the prefix set for the next pass. This lets a pack that
    // transitively depends on another pack (e.g. coroutines on
    // atomicfu) pull its dependency in even when the user program
    // imports only the outer library.
    let candidates = collect_pack_candidates(entries);
    let mut known_prefixes = user_import_prefixes.clone();
    let mut loaded_lib_ids: std::collections::HashSet<String> = std::collections::HashSet::new();
    loop {
        let mut progressed = false;
        let mut new_imports: Vec<String> = Vec::new();
        for c in &candidates {
            let lib_id = &c.manifest.library_id;
            if loaded_lib_ids.contains(lib_id) {
                continue;
            }
            let wanted = known_prefixes.iter().any(|imp| {
                imp == lib_id
                    || imp.starts_with(&format!("{lib_id}."))
                    || lib_id.starts_with(&format!("{imp}."))
            });
            if !wanted {
                continue;
            }
            loaded_lib_ids.insert(lib_id.clone());
            progressed = true;
            load_pack_candidate(
                c,
                lib_id,
                &merged,
                source_map,
                &mut out_asts,
                &mut out_bindings,
                &mut new_imports,
            );
        }
        if !progressed {
            break;
        }
        for imp in new_imports {
            if !imp.is_empty() {
                known_prefixes.insert(imp);
            }
        }
    }
    load_embedded_stdlib_sources(
        &known_prefixes,
        source_map,
        &mut out_asts,
        &mut out_bindings,
    );
    (out_asts, out_bindings)
}

pub(crate) fn merged_host_bindings() -> klio_stdlib::HostBindings {
    let mut out = klio_stdlib::HostBindings::with_stdlib_defaults();
    merge_into(&mut out, &klio_kotlinx_atomicfu::host_bindings());
    merge_into(&mut out, &klio_kotlinx_io::host_bindings());
    merge_into(&mut out, &klio_kotlinx_datetime::host_bindings());
    merge_into(&mut out, &klio_kotlinx_coroutines::host_bindings());
    merge_into(&mut out, &klio_kotlinx_serialization::host_bindings());
    // ktor-client is opt-in (pack must be installed to take effect)
    // but its host functions are always available in the registry so
    // the pack's bindings resolve when installed.
    merge_into(&mut out, &klio_ktor_client::host_bindings());
    out
}

fn merge_into(dst: &mut klio_stdlib::HostBindings, src: &klio_stdlib::HostBindings) {
    for (k, f) in src.entries() {
        dst.register(k, f);
    }
}

fn klio_cache_dir() -> Result<PathBuf, String> {
    let home = std::env::var_os("HOME").ok_or("HOME env var unset")?;
    Ok(PathBuf::from(home).join(".klio").join("packs"))
}

pub(crate) fn read_pack_manifest(
    path: &std::path::Path,
) -> Result<klio_pack::schema::PackManifest, String> {
    use klio_pack::schema::{PackManifest, decode};
    use klio_pack::{PackReader, section_names};
    let bytes = std::fs::read(path).map_err(|e| format!("read {}: {e}", path.display()))?;
    let pack = PackReader::from_bytes(bytes).map_err(|e| e.to_string())?;
    let payload = pack
        .read_section(section_names::MANIFEST)
        .map_err(|e| e.to_string())?
        .ok_or_else(|| format!("{}: missing manifest section", path.display()))?;
    let m: PackManifest = decode(&payload).map_err(|e| e.to_string())?;
    Ok(m)
}

pub(crate) fn install_pack_into_cache(src: &std::path::Path) -> Result<PathBuf, String> {
    let manifest = read_pack_manifest(src)?;
    let cache = klio_cache_dir()?;
    std::fs::create_dir_all(&cache).map_err(|e| e.to_string())?;
    let dest = cache.join(format!(
        "{}-{}.klio-pack",
        manifest.library_id, manifest.library_version
    ));
    std::fs::copy(src, &dest).map_err(|e| format!("copy: {e}"))?;
    let _ = rebuild_cache_index(&cache);
    Ok(dest)
}

#[derive(serde::Serialize, serde::Deserialize, Debug)]
struct CacheIndexEntry {
    library_id: String,
    version: String,
    abi_version: u32,
    path: String,
    dependencies: Vec<String>,
}

const CACHE_INDEX_NAME: &str = "index.json";

/// Walk every pack file in the cache, read each manifest, and write a
/// sidecar `index.json` so subsequent startups can skip the per-pack
/// header read. Best-effort: failures here are logged but do not
/// break the install flow.
fn rebuild_cache_index(cache: &std::path::Path) -> Result<(), String> {
    let Ok(entries) = std::fs::read_dir(cache) else {
        return Ok(());
    };
    let mut out: Vec<CacheIndexEntry> = Vec::new();
    for e in entries.flatten() {
        let p = e.path();
        if p.extension().is_none_or(|x| x != "klio-pack") {
            continue;
        }
        let Ok(m) = read_pack_manifest(&p) else {
            continue;
        };
        out.push(CacheIndexEntry {
            library_id: m.library_id,
            version: m.library_version,
            abi_version: m.abi_version,
            path: p.to_string_lossy().into_owned(),
            dependencies: m
                .dependencies
                .iter()
                .map(|d| d.library_id.clone())
                .collect(),
        });
    }
    out.sort_by(|a, b| a.library_id.cmp(&b.library_id));
    let bytes = serde_json::to_vec_pretty(&out).map_err(|e| e.to_string())?;
    let idx_path = cache.join(CACHE_INDEX_NAME);
    std::fs::write(&idx_path, bytes).map_err(|e| e.to_string())?;
    Ok(())
}

pub(crate) fn list_cache_packs() -> Result<(), String> {
    let cache = klio_cache_dir()?;
    let Ok(entries) = std::fs::read_dir(&cache) else {
        eprintln!("(no packs installed at {})", cache.display());
        return Ok(());
    };
    let mut paths: Vec<PathBuf> = entries
        .flatten()
        .map(|e| e.path())
        .filter(|p| p.extension().is_some_and(|x| x == "klio-pack"))
        .collect();
    paths.sort();
    for path in paths {
        match read_pack_manifest(&path) {
            Ok(m) => {
                let deps = if m.dependencies.is_empty() {
                    "—".to_string()
                } else {
                    m.dependencies
                        .iter()
                        .map(|d| format!("{}{}", d.library_id, format_min(&d.min_version)))
                        .collect::<Vec<_>>()
                        .join(", ")
                };
                println!(
                    "{:<32}  {:<10}  abi {}  deps {}",
                    m.library_id, m.library_version, m.abi_version, deps,
                );
            }
            Err(e) => {
                println!("{}: ! {}", path.display(), e);
            }
        }
    }
    Ok(())
}

fn format_min(min: &str) -> String {
    if min.is_empty() {
        String::new()
    } else {
        format!(" (>={min})")
    }
}

pub(crate) fn remove_cache_pack(
    library_id: &str,
    version: Option<&str>,
) -> Result<PathBuf, String> {
    let cache = klio_cache_dir()?;
    let entries = std::fs::read_dir(&cache).map_err(|e| e.to_string())?;
    for e in entries.flatten() {
        let p = e.path();
        let Ok(manifest) = read_pack_manifest(&p) else {
            continue;
        };
        if manifest.library_id != library_id {
            continue;
        }
        if let Some(v) = version
            && manifest.library_version != v
        {
            continue;
        }
        std::fs::remove_file(&p).map_err(|e| e.to_string())?;
        let _ = rebuild_cache_index(&cache);
        return Ok(p);
    }
    Err(format!("no pack matching {library_id} found in cache"))
}

pub(crate) fn inspect_pack(path: &std::path::Path) -> Result<(), String> {
    use klio_pack::schema::{BindingManifest, PackManifest, SymbolIndex, decode};
    use klio_pack::{PackReader, section_names};
    let bytes = std::fs::read(path).map_err(|e| format!("read {}: {e}", path.display()))?;
    let reader = PackReader::from_bytes(bytes).map_err(|e| e.to_string())?;
    println!("file:    {}", path.display());
    println!("format:  v{}", reader.format_version());
    let hash = reader.pack_hash();
    print!("hash:    ");
    for b in &hash[..16] {
        print!("{b:02x}");
    }
    println!("…");
    println!("sections:");
    for e in reader.sections() {
        println!(
            "  - {:<10} stored={:>8} bytes  uncompressed={:>8} bytes  {:?}",
            e.name, e.stored_len, e.uncompressed_len, e.compression,
        );
    }
    if let Some(payload) = reader
        .read_section(section_names::MANIFEST)
        .map_err(|e| e.to_string())?
    {
        let m: PackManifest = decode(&payload).map_err(|e| e.to_string())?;
        println!(
            "manifest: library={} version={} abi={} implicit={:?}",
            m.library_id, m.library_version, m.abi_version, m.implicit_packages,
        );
    }
    if let Some(payload) = reader
        .read_section(section_names::SYMBOLS)
        .map_err(|e| e.to_string())?
    {
        let s: SymbolIndex = decode(&payload).map_err(|e| e.to_string())?;
        println!("symbols:  {} entries", s.entries.len());
    }
    if let Some(payload) = reader
        .read_section(section_names::BINDINGS)
        .map_err(|e| e.to_string())?
    {
        let b: BindingManifest = decode(&payload).map_err(|e| e.to_string())?;
        println!("bindings: {} entries", b.bindings.len());
    }
    Ok(())
}

pub(crate) fn verify_pack(
    path: &std::path::Path,
    smoke: Option<&std::path::Path>,
) -> Result<(), String> {
    use klio_pack::schema::{BindingManifest, PackManifest, SymbolIndex, decode};
    use klio_pack::{PackReader, section_names};
    let bytes = std::fs::read(path).map_err(|e| format!("read {}: {e}", path.display()))?;
    let reader = PackReader::from_bytes(bytes).map_err(|e| e.to_string())?;
    // Required sections.
    for name in [
        section_names::MANIFEST,
        section_names::SYMBOLS,
        section_names::BINDINGS,
    ] {
        let payload = reader
            .read_section(name)
            .map_err(|e| e.to_string())?
            .ok_or_else(|| format!("missing required section `{name}`"))?;
        match name {
            section_names::MANIFEST => {
                let _: PackManifest = decode(&payload).map_err(|e| e.to_string())?;
            }
            section_names::SYMBOLS => {
                let _: SymbolIndex = decode(&payload).map_err(|e| e.to_string())?;
            }
            section_names::BINDINGS => {
                let _: BindingManifest = decode(&payload).map_err(|e| e.to_string())?;
            }
            _ => {}
        }
    }
    if let Some(_file) = smoke {
        eprintln!("note: pack smoke-run was removed during the IR cutover.");
    }
    Ok(())
}

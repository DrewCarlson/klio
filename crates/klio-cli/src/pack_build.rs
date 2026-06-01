use crate::*;

use crate::pack_cache::{
    install_pack_into_cache, inspect_pack, list_cache_packs, merged_host_bindings,
    read_pack_manifest, remove_cache_pack, verify_pack,
};

pub(crate) fn run_pack(cmd: PackCmd) -> ExitCode {
    match cmd {
        PackCmd::Build { dir, out } => match build_library_pack(&dir, out.as_deref()) {
            Ok(path) => {
                eprintln!("wrote {}", path.display());
                ExitCode::SUCCESS
            }
            Err(e) => {
                eprintln!("error: {e}");
                ExitCode::from(2)
            }
        },
        PackCmd::Stdlib { out, bindings_only, compress_symbols } => {
            if !bindings_only {
                eprintln!("--bindings-only is the only supported mode in the MVP");
                return ExitCode::from(2);
            }
            match build_stdlib_pack(compress_symbols) {
                Ok(bytes) => match write_pack(&out, &bytes) {
                    Ok(()) => {
                        eprintln!("wrote {} ({} bytes)", out.display(), bytes.len());
                        ExitCode::SUCCESS
                    }
                    Err(e) => {
                        eprintln!("error: {e}");
                        ExitCode::from(2)
                    }
                },
                Err(e) => {
                    eprintln!("pack build failed: {e}");
                    ExitCode::from(2)
                }
            }
        }
        PackCmd::Install { pack } => match install_pack_into_cache(&pack) {
            Ok(dest) => {
                eprintln!("installed {}", dest.display());
                ExitCode::SUCCESS
            }
            Err(e) => {
                eprintln!("error: {e}");
                ExitCode::from(2)
            }
        },
        PackCmd::List => match list_cache_packs() {
            Ok(()) => ExitCode::SUCCESS,
            Err(e) => {
                eprintln!("error: {e}");
                ExitCode::from(2)
            }
        },
        PackCmd::Remove { library_id, version } => {
            match remove_cache_pack(&library_id, version.as_deref()) {
                Ok(p) => {
                    eprintln!("removed {}", p.display());
                    ExitCode::SUCCESS
                }
                Err(e) => {
                    eprintln!("error: {e}");
                    ExitCode::from(2)
                }
            }
        }
        PackCmd::Inspect { pack } => match inspect_pack(&pack) {
            Ok(()) => ExitCode::SUCCESS,
            Err(e) => {
                eprintln!("error: {e}");
                ExitCode::from(2)
            }
        },
        PackCmd::Verify { pack, smoke } => match verify_pack(&pack, smoke.as_deref()) {
            Ok(()) => ExitCode::SUCCESS,
            Err(e) => {
                eprintln!("verify failed: {e}");
                ExitCode::from(1)
            }
        },
        PackCmd::Migrate { input, out } => {
            let target = out.unwrap_or_else(|| input.clone());
            match migrate_pack(&input, &target) {
                Ok(()) => {
                    eprintln!("migrated {} -> {}", input.display(), target.display());
                    ExitCode::SUCCESS
                }
                Err(e) => {
                    eprintln!("error: {e}");
                    ExitCode::from(2)
                }
            }
        }
        PackCmd::Publish { pack, registry } => match publish_to_registry(&pack, registry.as_deref()) {
            Ok(dest) => {
                eprintln!("published {}", dest.display());
                ExitCode::SUCCESS
            }
            Err(e) => {
                eprintln!("error: {e}");
                ExitCode::from(2)
            }
        },
        PackCmd::Search { query, registry } => match search_registry(&query, registry.as_deref()) {
            Ok(()) => ExitCode::SUCCESS,
            Err(e) => {
                eprintln!("error: {e}");
                ExitCode::from(2)
            }
        },
        PackCmd::Fetch { library_id, version, registry } => {
            match fetch_from_registry(&library_id, version.as_deref(), registry.as_deref()) {
                Ok(dest) => {
                    eprintln!("fetched {}", dest.display());
                    ExitCode::SUCCESS
                }
                Err(e) => {
                    eprintln!("error: {e}");
                    ExitCode::from(2)
                }
            }
        }
        PackCmd::TrainDict { inputs, out, max_size } => match train_zstd_dict(&inputs, &out, max_size) {
            Ok(()) => {
                eprintln!("trained dict {}", out.display());
                ExitCode::SUCCESS
            }
            Err(e) => {
                eprintln!("error: {e}");
                ExitCode::from(2)
            }
        },
        PackCmd::New { dir, id } => match scaffold_library(&dir, id.as_deref()) {
            Ok(()) => {
                eprintln!("scaffolded {}", dir.display());
                ExitCode::SUCCESS
            }
            Err(e) => {
                eprintln!("error: {e}");
                ExitCode::from(2)
            }
        },
    }
}

/// Re-encode a pack against the currently-supported FORMAT_VERSION.
///
/// Today the writer only knows how to emit one version, so a
/// successful migrate is a no-op round-trip that validates the
/// input pack and rewrites it deterministically. The function is
/// in place ahead of v2 so callers and CI flows can be wired up
/// before the schema change lands.
fn migrate_pack(input: &std::path::Path, output: &std::path::Path) -> Result<(), String> {
    use klio_pack::{Compression, PackReader, PackWriter};
    let reader = PackReader::from_path(input).map_err(|e| e.to_string())?;
    let mut writer = PackWriter::new();
    for entry in reader.sections() {
        let payload = reader
            .read_section(&entry.name)
            .map_err(|e| e.to_string())?
            .expect("section listed in directory must decode");
        let comp = match entry.compression {
            Compression::None => Compression::None,
            Compression::Zstd => Compression::Zstd,
            // Dictionary-compressed sections are decoded by the
            // reader using the inline zstd_dict section, and
            // re-emitted as plain Zstd by the migrate path —
            // re-training a dictionary is the user's call.
            Compression::ZstdDict => Compression::Zstd,
        };
        writer.add_section(entry.name.clone(), payload.into_owned(), comp);
    }
    let bytes = writer.finish().map_err(|e| e.to_string())?;
    if let Some(parent) = output.parent() {
        std::fs::create_dir_all(parent).map_err(|e| e.to_string())?;
    }
    std::fs::write(output, bytes).map_err(|e| e.to_string())?;
    Ok(())
}

// ---------------------------------------------------------------------
// Local-filesystem registry
// ---------------------------------------------------------------------

fn registry_dir(override_path: Option<&std::path::Path>) -> Result<PathBuf, String> {
    if let Some(p) = override_path {
        return Ok(p.to_path_buf());
    }
    let home = std::env::var_os("HOME").ok_or("HOME env var unset")?;
    Ok(PathBuf::from(home).join(".klio").join("registry"))
}

#[derive(serde::Serialize, serde::Deserialize, Debug)]
struct RegistryEntry {
    library_id: String,
    version: String,
    abi_version: u32,
    relative_path: String,
}

fn registry_index_path(root: &std::path::Path) -> PathBuf {
    root.join("index.json")
}

fn read_registry_index(root: &std::path::Path) -> Result<Vec<RegistryEntry>, String> {
    let path = registry_index_path(root);
    let Ok(bytes) = std::fs::read(&path) else {
        return Ok(Vec::new());
    };
    serde_json::from_slice(&bytes).map_err(|e| e.to_string())
}

fn write_registry_index(root: &std::path::Path, entries: &[RegistryEntry]) -> Result<(), String> {
    let bytes = serde_json::to_vec_pretty(entries).map_err(|e| e.to_string())?;
    std::fs::write(registry_index_path(root), bytes).map_err(|e| e.to_string())
}

fn publish_to_registry(
    pack: &std::path::Path,
    registry_override: Option<&std::path::Path>,
) -> Result<PathBuf, String> {
    let manifest = read_pack_manifest(pack)?;
    let root = registry_dir(registry_override)?;
    let lib_dir = root.join(&manifest.library_id).join(&manifest.library_version);
    std::fs::create_dir_all(&lib_dir).map_err(|e| e.to_string())?;
    let dest = lib_dir.join(format!(
        "{}-{}.klio-pack",
        manifest.library_id, manifest.library_version
    ));
    std::fs::copy(pack, &dest).map_err(|e| format!("copy: {e}"))?;

    let relative = dest
        .strip_prefix(&root)
        .map(|p| p.to_string_lossy().into_owned())
        .unwrap_or_else(|_| dest.to_string_lossy().into_owned());
    let mut index = read_registry_index(&root)?;
    index.retain(|e| !(e.library_id == manifest.library_id && e.version == manifest.library_version));
    index.push(RegistryEntry {
        library_id: manifest.library_id,
        version: manifest.library_version,
        abi_version: manifest.abi_version,
        relative_path: relative,
    });
    index.sort_by(|a, b| (a.library_id.as_str(), a.version.as_str()).cmp(&(b.library_id.as_str(), b.version.as_str())));
    write_registry_index(&root, &index)?;
    Ok(dest)
}

fn search_registry(query: &str, registry_override: Option<&std::path::Path>) -> Result<(), String> {
    let root = registry_dir(registry_override)?;
    let entries = read_registry_index(&root)?;
    let lq = query.to_lowercase();
    let matches: Vec<&RegistryEntry> = entries
        .iter()
        .filter(|e| e.library_id.to_lowercase().contains(&lq))
        .collect();
    if matches.is_empty() {
        eprintln!("no packs matching `{query}` in {}", root.display());
        return Ok(());
    }
    for e in matches {
        println!(
            "{:<32}  {:<12}  abi {}  {}",
            e.library_id, e.version, e.abi_version, e.relative_path
        );
    }
    Ok(())
}

fn fetch_from_registry(
    library_id: &str,
    version: Option<&str>,
    registry_override: Option<&std::path::Path>,
) -> Result<PathBuf, String> {
    let root = registry_dir(registry_override)?;
    let entries = read_registry_index(&root)?;
    let candidate = entries
        .iter()
        .filter(|e| e.library_id == library_id)
        .filter(|e| version.map_or(true, |v| e.version == v))
        .max_by(|a, b| a.version.cmp(&b.version))
        .ok_or_else(|| format!("no registry entry for `{library_id}`"))?;
    let src = root.join(&candidate.relative_path);
    if !src.exists() {
        return Err(format!("registry entry points at missing file {}", src.display()));
    }
    install_pack_into_cache(&src)
}

/// Train a zstd dictionary from the AST + sources sections of the
/// supplied packs. Uses `zstd::dict::from_continuous` over the
/// concatenated section bytes; dictionary size is bounded so the
/// emitted file fits comfortably as a pack section.
fn train_zstd_dict(
    inputs: &[std::path::PathBuf],
    out: &std::path::Path,
    max_size: usize,
) -> Result<(), String> {
    if inputs.is_empty() {
        return Err("at least one input pack required".into());
    }
    let mut samples: Vec<Vec<u8>> = Vec::new();
    for path in inputs {
        let pack = klio_pack::PackReader::from_path(path).map_err(|e| e.to_string())?;
        for name in [
            klio_pack::section_names::SOURCES,
            klio_pack::section_names::AST,
            klio_pack::section_names::SYMBOLS,
        ] {
            if let Some(bytes) = pack.read_section(name).map_err(|e| e.to_string())? {
                samples.push(bytes.into_owned());
            }
        }
    }
    if samples.is_empty() {
        return Err("no AST/sources/symbols sections found in inputs".into());
    }
    let dict = zstd::dict::from_samples(&samples, max_size)
        .map_err(|e| format!("zstd dict training failed: {e}"))?;
    if let Some(parent) = out.parent() {
        std::fs::create_dir_all(parent).map_err(|e| e.to_string())?;
    }
    std::fs::write(out, &dict).map_err(|e| e.to_string())?;
    eprintln!("dict size: {} bytes", dict.len());
    Ok(())
}

fn scaffold_library(dir: &std::path::Path, id_override: Option<&str>) -> Result<(), String> {
    if dir.exists() {
        return Err(format!("{} already exists", dir.display()));
    }
    let id = id_override
        .map(|s| s.to_string())
        .or_else(|| {
            dir.file_name()
                .and_then(|n| n.to_str())
                .map(|s| s.to_string())
        })
        .ok_or_else(|| "could not derive library id from path".to_string())?;
    let src_dir = dir.join("src").join("main").join("kotlin");
    std::fs::create_dir_all(&src_dir).map_err(|e| e.to_string())?;
    let klio_toml = format!(
        "[library]\nid = \"{id}\"\nversion = \"0.1.0\"\nabi = 1\nimplicit_packages = []\nsource_roots = [\"src/main/kotlin\"]\n\n[[deps]]\nid = \"stdlib\"\n\n# Map FQN to host_symbol for any native binding the host registers.\n# Omit the table when the library is pure Kotlin.\n# [bindings]\n# \"{id}.example.hello\" = \"{id}.example.hello\"\n",
    );
    std::fs::write(dir.join("klio.toml"), klio_toml).map_err(|e| e.to_string())?;
    let sample_path = src_dir.join("Sample.kt");
    let pkg = sanitize_package(&id);
    let sample = format!("package {pkg}\n\nfun greet(name: String): String = \"hello, $name\"\n");
    std::fs::write(&sample_path, sample).map_err(|e| e.to_string())?;
    let readme = format!(
        "# {id}\n\nA klio pack scaffold.\n\nBuild:\n\n    klio pack build .\n\nInstall:\n\n    klio pack install target/packs/{id}.klio-pack\n\nUse from a program:\n\n    import {pkg}.greet\n    fun main() {{ println(greet(\"world\")) }}\n"
    );
    std::fs::write(dir.join("README.md"), readme).map_err(|e| e.to_string())?;
    Ok(())
}

fn sanitize_package(id: &str) -> String {
    id.chars()
        .map(|c| if c.is_ascii_alphanumeric() || c == '.' { c } else { '_' })
        .collect()
}

fn build_stdlib_pack(compress_symbols: bool) -> Result<Vec<u8>, String> {
    klio_stdlib::build_stdlib_pack(compress_symbols).map_err(|e| e.to_string())
}

/// Parse every source file at pack-build time. Files that fail to lex
/// or parse are dropped from the returned bundle; the loader falls
/// back to the `sources` section to re-parse them later. Spans inside
/// the bundle carry SourceMap FileIds allocated during the build,
/// which the loader rebases when it ingests the AST.
fn build_ast_bundle(files: &[klio_pack::schema::SourceFile]) -> klio_pack::schema::AstBundle {
    use klio_pack::schema::{AstBundle, AstFile};
    let mut out = AstBundle::default();
    let mut map = SourceMap::new();
    for f in files {
        let id = map.add(&f.rel_path, String::from_utf8_lossy(&f.bytes).into_owned());
        let src = map.get(id).source.clone();
        let lexed = klio_lexer::Lexer::new(id, &src).tokenize();
        if lexed.diagnostics.has_errors() {
            continue;
        }
        let (ast, diags) = klio_parser::Parser::new(id, &src, &lexed.tokens).parse_file();
        if diags.has_errors() {
            continue;
        }
        out.files.push(AstFile { rel_path: f.rel_path.clone(), kotlin_file: ast });
    }
    out
}

/// Run typecheck over the parsed AST bundle and produce the
/// per-expression type map. Best-effort: any file whose typecheck
/// reports errors is skipped silently so the resulting bundle covers
/// only the green parts. Loader code merges these entries into the
/// interpreter's `expr_types` map directly, skipping a second
/// resolve + typecheck pass at install time.
fn build_typeck_bundle(asts: &[klio_ast::KotlinFile]) -> klio_pack::schema::TypeckBundle {
    let mut out = klio_pack::schema::TypeckBundle::default();
    if asts.is_empty() {
        return out;
    }
    let r = klio_resolver::resolve_module(asts);
    let tc = klio_typeck::typecheck_module(asts, &r);
    if tc.diagnostics.has_errors() {
        return out;
    }
    let mut entries: Vec<(klio_span::Span, klio_types::Type)> = tc.types.into_iter().collect();
    entries.sort_by_key(|(s, _)| (s.file.0, s.start, s.end));
    out.entries = entries;
    out
}

#[derive(serde::Deserialize, Debug)]
struct LibraryToml {
    library: LibraryHeader,
    #[serde(default)]
    deps: Vec<DepEntry>,
    /// Map of FQN -> host_symbol. Each entry is registered as a
    /// `BindingKind::Function` with the FQN as both the key and the
    /// host symbol when the value omits the colon-shaped explicit
    /// form.
    #[serde(default)]
    bindings: std::collections::BTreeMap<String, BindingValue>,
    /// Optional `[[source]]` tables giving per-root include/exclude
    /// control on top of the plain `source_roots` strings. Processed
    /// after `source_roots`; see `SourceRoot`.
    #[serde(default)]
    source: Vec<SourceRoot>,
}

/// One source root with optional include/exclude filtering, used by
/// the `[[source]]` manifest table.
///
/// `include`/`exclude` patterns are matched against the
/// slash-normalized path of each `.kt` file relative to the root
/// directory. Supported pattern forms:
/// - exact: `pat == rel` (e.g. `Buffer.kt`, `internal/-Utf8.kt`);
/// - directory prefix: `pat` ending with `/` matches the directory
///   itself and everything beneath it (e.g. `files/`);
/// - suffix glob: `pat` starting with `*` matches any path ending
///   with the remainder (e.g. `*.kt`, `*Windows.kt`);
/// - prefix glob: `pat` ending with `*` matches any path starting
///   with the leading part (e.g. `internal/*`).
///
/// Selection: a file is included if `include` is empty or it matches
/// any `include` pattern; it is then dropped if it matches any
/// `exclude` pattern. Excludes always override includes.
#[derive(serde::Deserialize, Debug)]
pub(crate) struct SourceRoot {
    pub(crate) root: String,
    #[serde(default)]
    pub(crate) include: Vec<String>,
    #[serde(default)]
    pub(crate) exclude: Vec<String>,
}

/// Match `rel` (a slash-normalized path relative to a source root)
/// against a single pattern. See `SourceRoot` for the supported
/// forms.
pub(crate) fn pat_match(rel: &str, pat: &str) -> bool {
    if let Some(prefix) = pat.strip_suffix('/') {
        // Directory prefix: the directory itself or anything under it.
        return rel == prefix || rel.starts_with(pat);
    }
    if let Some(suffix) = pat.strip_prefix('*') {
        // Suffix glob.
        return rel.ends_with(suffix);
    }
    if let Some(prefix) = pat.strip_suffix('*') {
        // Prefix glob.
        return rel.starts_with(prefix);
    }
    // Exact match.
    rel == pat
}

/// Walk every root in `roots` for `.kt` files, applying each root's
/// include/exclude rules, and return the collected source files
/// sorted by crate-dir-relative path. `dir` is the directory holding
/// `klio.toml`. With empty include/exclude this collects exactly the
/// files (and `rel_path`s) the old inline walk did, so the no-filter
/// path stays byte-identical.
pub(crate) fn collect_pack_sources(
    dir: &std::path::Path,
    roots: &[SourceRoot],
) -> Result<Vec<klio_pack::schema::SourceFile>, String> {
    use klio_pack::schema::SourceFile;
    let mut files: Vec<SourceFile> = Vec::new();
    let mut seen: std::collections::HashSet<String> = std::collections::HashSet::new();
    for sr in roots {
        let root_path = dir.join(&sr.root);
        if !root_path.is_dir() {
            continue;
        }
        for entry in walkdir::WalkDir::new(&root_path).sort_by_file_name() {
            let entry = entry.map_err(|e| format!("walk {}: {e}", root_path.display()))?;
            if !entry.file_type().is_file() {
                continue;
            }
            let p = entry.path();
            if !p.extension().map(|e| e == "kt").unwrap_or(false) {
                continue;
            }
            let rel_to_root = p
                .strip_prefix(&root_path)
                .unwrap_or(p)
                .to_string_lossy()
                .replace('\\', "/");
            let included = sr.include.is_empty()
                || sr.include.iter().any(|pat| pat_match(&rel_to_root, pat));
            if !included {
                continue;
            }
            if sr.exclude.iter().any(|pat| pat_match(&rel_to_root, pat)) {
                continue;
            }
            let rel = p
                .strip_prefix(dir)
                .unwrap_or(p)
                .to_string_lossy()
                .into_owned();
            if !seen.insert(rel.clone()) {
                continue;
            }
            let bytes = std::fs::read(p).map_err(|e| format!("read {}: {e}", p.display()))?;
            files.push(SourceFile { rel_path: rel, bytes });
        }
    }
    files.sort_by(|a, b| a.rel_path.cmp(&b.rel_path));
    Ok(files)
}

#[derive(serde::Deserialize, Debug)]
struct LibraryHeader {
    id: String,
    version: String,
    #[serde(default = "default_abi")]
    abi: u32,
    #[serde(default)]
    implicit_packages: Vec<String>,
    /// Optional list of glob-like relative paths (under the library
    /// root) the builder walks for `.kt` source files. Defaults to
    /// `["src"]`.
    #[serde(default)]
    source_roots: Vec<String>,
    /// When true, every host_symbol in `merged_host_bindings`
    /// whose FQN starts with one of the prefixes in
    /// `binding_auto_prefixes` (or with `<id>.` when the prefix
    /// list is empty) is included in the emitted binding
    /// manifest. Lets a crate ship its bindings purely in Rust
    /// and skip the duplicate `[bindings]` table.
    #[serde(default)]
    auto_bindings: bool,
    #[serde(default)]
    binding_auto_prefixes: Vec<String>,
}

fn default_abi() -> u32 {
    1
}

#[derive(serde::Deserialize, Debug)]
struct DepEntry {
    id: String,
    #[serde(default)]
    min_version: String,
}

#[derive(serde::Deserialize, Debug)]
#[serde(untagged)]
enum BindingValue {
    Symbol(String),
    Detailed {
        host_symbol: String,
        #[serde(default)]
        kind: Option<String>,
        #[serde(default = "default_true")]
        overrides_interpreter: bool,
        #[serde(default)]
        platform_actual: bool,
    },
}

fn default_true() -> bool {
    true
}

fn build_library_pack(
    dir: &std::path::Path,
    out: Option<&std::path::Path>,
) -> Result<PathBuf, String> {
    use klio_pack::schema::{
        encode, Binding, BindingKind, BindingManifest, PackDependency, PackManifest, Purity,
        SourceBundle,
    };
    use klio_pack::{section_names, Compression, PackWriter};

    let toml_path = dir.join("klio.toml");
    let toml_str = std::fs::read_to_string(&toml_path)
        .map_err(|e| format!("read {}: {e}", toml_path.display()))?;
    let mut cfg: LibraryToml = toml::from_str(&toml_str)
        .map_err(|e| format!("parse {}: {e}", toml_path.display()))?;

    // Source files. The plain `source_roots` strings become
    // unfiltered roots; the `[[source]]` tables follow with their
    // include/exclude rules. The walk itself is shared so the
    // no-filter path collects exactly the files it did before.
    let plain_roots = if cfg.library.source_roots.is_empty() && cfg.source.is_empty() {
        vec!["src".to_string()]
    } else {
        cfg.library.source_roots.clone()
    };
    let mut effective: Vec<SourceRoot> = plain_roots
        .into_iter()
        .map(|root| SourceRoot { root, include: Vec::new(), exclude: Vec::new() })
        .collect();
    for s in cfg.source.drain(..) {
        effective.push(s);
    }

    let files = collect_pack_sources(dir, &effective)?;

    // Manifest.
    let manifest = PackManifest {
        library_id: cfg.library.id.clone(),
        library_version: cfg.library.version.clone(),
        abi_version: cfg.library.abi,
        implicit_packages: cfg.library.implicit_packages.clone(),
        dependencies: cfg
            .deps
            .into_iter()
            .map(|d| PackDependency { library_id: d.id, min_version: d.min_version })
            .collect(),
    };
    let manifest_bytes = encode(&manifest).map_err(|e| e.to_string())?;

    // Bindings.
    let mut bindings: Vec<Binding> = Vec::new();
    for (fqn, value) in cfg.bindings {
        let (host_symbol, overrides_interpreter, _kind, platform_actual) = match value {
            BindingValue::Symbol(s) => (s, true, None, false),
            BindingValue::Detailed {
                host_symbol,
                kind,
                overrides_interpreter,
                platform_actual,
            } => (host_symbol, overrides_interpreter, kind, platform_actual),
        };
        bindings.push(Binding {
            fqn,
            kind: BindingKind::Function,
            host_symbol,
            overrides_interpreter,
            purity: Purity::Effectful,
            min_arity: 0,
            max_arity: u8::MAX,
            platform_actual,
        });
    }
    // Auto-emit: pull every entry from `merged_host_bindings`
    // whose FQN matches a configured prefix. Drops the klio.toml
    // [bindings] duplication for the common case where the host
    // crate already lists every binding.
    if cfg.library.auto_bindings {
        let prefixes: Vec<String> = if cfg.library.binding_auto_prefixes.is_empty() {
            vec![format!("{}.", cfg.library.id)]
        } else {
            cfg.library
                .binding_auto_prefixes
                .iter()
                .map(|p| if p.ends_with('.') { p.clone() } else { format!("{p}.") })
                .collect()
        };
        let host = merged_host_bindings();
        let known: std::collections::HashSet<String> =
            bindings.iter().map(|b| b.fqn.clone()).collect();
        for (host_symbol, _) in host.entries() {
            if !prefixes.iter().any(|p| host_symbol.starts_with(p)) {
                continue;
            }
            if known.contains(host_symbol) {
                continue;
            }
            bindings.push(Binding {
                fqn: host_symbol.to_string(),
                kind: BindingKind::Function,
                host_symbol: host_symbol.to_string(),
                overrides_interpreter: true,
                purity: Purity::Effectful,
                min_arity: 0,
                max_arity: u8::MAX,
                platform_actual: false,
            });
        }
    }
    bindings.sort_by(|a, b| a.fqn.cmp(&b.fqn));
    let bindings_bytes = encode(&BindingManifest { bindings }).map_err(|e| e.to_string())?;

    // Sources (zstd-compressed; common case is many KB of Kotlin text).
    let sources_bytes = encode(&SourceBundle { files: files.clone() }).map_err(|e| e.to_string())?;

    // Frozen AST: try to parse every source file at pack-build time
    // and ship the resulting `KotlinFile` tree alongside the raw
    // bytes. Files that fail to lex / parse are skipped and the
    // loader falls back to the source-bundle path for them.
    let ast_bundle = build_ast_bundle(&files);
    let ast_bytes = encode(&ast_bundle).map_err(|e| e.to_string())?;

    // Frozen typeck: typecheck the bundle and ship the per-Span
    // type map. Empty when typecheck reports errors; the loader
    // re-typechecks at install time in that case.
    let asts: Vec<klio_ast::KotlinFile> =
        ast_bundle.files.iter().map(|f| f.kotlin_file.clone()).collect();
    let typeck_bundle = build_typeck_bundle(&asts);
    let typeck_bytes = encode(&typeck_bundle).map_err(|e| e.to_string())?;

    let mut writer = PackWriter::new();
    writer.add_raw(section_names::MANIFEST, manifest_bytes);
    writer.add_raw(section_names::BINDINGS, bindings_bytes);
    writer.add_section(section_names::SOURCES, sources_bytes, Compression::Zstd);
    writer.add_section(section_names::AST, ast_bytes, Compression::Zstd);
    writer.add_section(section_names::TYPECK, typeck_bytes, Compression::Zstd);
    let pack_bytes = writer.finish().map_err(|e| e.to_string())?;

    let out_path = match out {
        Some(p) => p.to_path_buf(),
        None => PathBuf::from(format!("target/packs/{}.klio-pack", cfg.library.id)),
    };
    if let Some(parent) = out_path.parent() {
        std::fs::create_dir_all(parent).map_err(|e| e.to_string())?;
    }
    std::fs::write(&out_path, &pack_bytes).map_err(|e| e.to_string())?;
    Ok(out_path)
}

fn write_pack(out: &std::path::Path, bytes: &[u8]) -> std::io::Result<()> {
    if let Some(parent) = out.parent() {
        std::fs::create_dir_all(parent)?;
    }
    std::fs::write(out, bytes)
}

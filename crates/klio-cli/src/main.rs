use std::path::PathBuf;
use std::process::ExitCode;

use clap::{Parser as ClapParser, Subcommand, ValueEnum};
use klio_diagnostics::{render, DiagnosticSink, Severity};
use klio_lexer::Lexer;
use klio_parser::Parser;
use klio_span::SourceMap;

#[derive(ClapParser)]
#[command(name = "klio", version, about = "Experimental Kotlin interpreter")]
struct Cli {
    #[command(subcommand)]
    cmd: Cmd,
}

#[derive(Subcommand)]
enum Cmd {
    /// Lex a source file and print tokens.
    Lex { file: PathBuf },
    /// Parse a source file and print the AST.
    Parse { file: PathBuf },
    /// Run one or more `.kt` source files. When more than one file is
    /// supplied, every file's top-level declarations are visible to
    /// every other file (single-module semantics), with `fun main`
    /// invoked from whichever file declares it.
    Run {
        files: Vec<PathBuf>,
        /// Execute through the IR-native Vm (klio-interp-ir) instead
        /// of the tree-walking interpreter. The IR module is built
        /// via the existing front end; the Vm runs the lowered IR
        /// directly with no AST evaluator.
        #[arg(long = "ir-vm")]
        ir_vm: bool,
        /// Use deterministic virtual time for coroutines (`delay`
        /// advances a logical clock instantly) instead of the
        /// default wall-clock.
        #[arg(long = "virtual-time")]
        virtual_time: bool,
    },
    /// Type-check `.kt` files and emit diagnostics. Exit 1 on any error.
    Check {
        files: Vec<PathBuf>,
        /// Output format for the diagnostics.
        #[arg(long = "format", value_enum, default_value_t = DiagFormat::Plain)]
        format: DiagFormat,
    },
    /// Start an interactive REPL.
    Repl,
    /// Pack a library into a `.klio-pack` artifact, or inspect an
    /// existing one. Used today for the stdlib build; later for
    /// kotlinx and user libraries.
    Pack {
        #[command(subcommand)]
        cmd: PackCmd,
    },
}

#[derive(Subcommand)]
enum PackCmd {
    /// Build a `.klio-pack` from a library directory containing a
    /// `klio.toml` and a `src/` tree of `.kt` source files.
    Build {
        /// Path to the library root (the directory holding
        /// `klio.toml`).
        dir: PathBuf,
        /// Output path for the produced pack. Defaults to
        /// `target/packs/<library-id>.klio-pack`.
        #[arg(long = "out")]
        out: Option<PathBuf>,
    },
    /// Build a pack from the in-process Kotlin standard library. With
    /// `--bindings-only`, no AST / resolved / typecheck sections are
    /// emitted; only the manifest, symbol index, and binding table.
    Stdlib {
        /// Output path for the produced pack.
        #[arg(long = "out", default_value = "target/packs/stdlib.klio-pack")]
        out: PathBuf,
        /// Skip the AST / resolved / typecheck sections. MVP only
        /// supports this mode.
        #[arg(long = "bindings-only", default_value_t = true)]
        bindings_only: bool,
        /// zstd-compress the symbol index. Other sections are small
        /// and stay uncompressed.
        #[arg(long = "compress-symbols", default_value_t = true)]
        compress_symbols: bool,
    },
    /// Copy a `.klio-pack` into `~/.klio/packs/<library-id>-<version>.klio-pack`
    /// so the interpreter picks it up automatically on subsequent runs.
    Install { pack: PathBuf },
    /// List every pack in `~/.klio/packs/`, with library id, version,
    /// declared dependencies, and binding/source counts.
    List,
    /// Remove `~/.klio/packs/<library-id>-<version>.klio-pack`.
    Remove {
        library_id: String,
        #[arg(long)]
        version: Option<String>,
    },
    /// Inspect a pack: print the manifest, section list, and counts
    /// from the symbol index / binding manifest.
    Inspect { pack: PathBuf },
    /// Verify a pack by reading every section back through the loader
    /// (validates magic + hash + decoded shape). Optionally runs a
    /// smoke program against the pack.
    Verify {
        pack: PathBuf,
        /// Optional `.kt` file to execute through the pack-loaded
        /// interpreter. Output is printed to stdout.
        #[arg(long = "smoke")]
        smoke: Option<PathBuf>,
    },
    /// Scaffold a new library project: `klio.toml`, `src/main/kotlin/`,
    /// a placeholder Kotlin file, and a short README explaining how
    /// to build and install the resulting pack.
    New {
        /// Directory to create. Must not exist.
        dir: PathBuf,
        /// Library id written into `klio.toml`. Defaults to the
        /// directory name.
        #[arg(long = "id")]
        id: Option<String>,
    },
    /// Migrate a pack to the current on-disk format version. Today
    /// it's a passthrough — `FORMAT_VERSION == 1` is the only one
    /// shipped — but the entry point exists so callers can stop
    /// special-casing once v2 lands.
    Migrate {
        /// Path to the input pack.
        input: PathBuf,
        /// Output path. Defaults to overwriting the input.
        #[arg(long = "out")]
        out: Option<PathBuf>,
    },
    /// Train a zstd dictionary from the AST + sources sections of
    /// the supplied packs and write it to a file. Use the resulting
    /// file with `klio pack build --zstd-dict <path>` to compress
    /// those sections against shared inter-pack vocabulary.
    TrainDict {
        /// Input pack files to sample.
        inputs: Vec<PathBuf>,
        /// Output dictionary file.
        #[arg(long = "out", default_value = "target/packs/klio.zstd-dict")]
        out: PathBuf,
        /// Maximum dictionary size in bytes.
        #[arg(long = "max-size", default_value_t = 64 * 1024)]
        max_size: usize,
    },
    /// Publish a pack into a local-filesystem registry. Today the
    /// registry is a directory whose layout mirrors a Maven cache:
    /// `<registry>/<library_id>/<version>/<library_id>-<version>.klio-pack`
    /// plus an index.json that lists every published library.
    Publish {
        /// Pack file to publish.
        pack: PathBuf,
        /// Registry root directory. Defaults to `~/.klio/registry`.
        #[arg(long = "registry")]
        registry: Option<PathBuf>,
    },
    /// Search a registry's index for libraries matching `query`.
    /// Substring match against library id; case-insensitive.
    Search {
        query: String,
        #[arg(long = "registry")]
        registry: Option<PathBuf>,
    },
    /// Fetch a pack from a registry into the local cache so it
    /// becomes available to subsequent `klio run` invocations.
    Fetch {
        library_id: String,
        /// Optional version. Defaults to the registry's latest.
        #[arg(long = "version")]
        version: Option<String>,
        #[arg(long = "registry")]
        registry: Option<PathBuf>,
    },
}

#[derive(Copy, Clone, Debug, ValueEnum)]
enum DiagFormat {
    Plain,
    Json,
    Sarif,
}

fn main() -> ExitCode {
    let cli = Cli::parse();
    match cli.cmd {
        Cmd::Lex { file } => run_lex(&file),
        Cmd::Parse { file } => run_parse(&file),
        Cmd::Run { files, ir_vm: _, virtual_time } => {
            if virtual_time {
                klio_interp_ir::set_coroutine_time_mode(
                    klio_interp_ir::TimeMode::Virtual,
                );
            }
            match files.as_slice() {
                [] => {
                    eprintln!("usage: klio run <file.kt> [<file2.kt> ...]");
                    ExitCode::from(2)
                }
                // The IR-native Vm is the only `run` path now. The
                // legacy `--ir-vm` flag is accepted but ignored.
                [single] => run_file_ir_vm(single),
                many => run_module_files(many),
            }
        }
        Cmd::Check { files, format } => run_check(&files, format),
        Cmd::Repl => run_repl(),
        Cmd::Pack { cmd } => run_pack(cmd),
    }
}

fn run_pack(cmd: PackCmd) -> ExitCode {
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
struct SourceRoot {
    root: String,
    #[serde(default)]
    include: Vec<String>,
    #[serde(default)]
    exclude: Vec<String>,
}

/// Match `rel` (a slash-normalized path relative to a source root)
/// against a single pattern. See `SourceRoot` for the supported
/// forms.
fn pat_match(rel: &str, pat: &str) -> bool {
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
fn collect_pack_sources(
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

/// Build a single `HostBindings` table that the loader passes to
/// every pack: starts with `klio-stdlib`'s defaults and unions in
/// the bindings each `klio-kotlinx-*` crate ships. A pack's
/// `host_symbol` keys resolve against this merged table, so a
/// `kotlinx.atomicfu.AtomicInt.compareAndSet` binding wins exactly
/// when the user has the matching pack loaded.
/// Walk the local pack cache, parse each pack's AST bundle, and
/// build a `HostBindings` populated with the Rust-side bindings each
/// pack declares. The caller prepends `pack_asts` to the user's AST
/// list before lowering so pack declarations (`AtomicInt`, `Buffer`,
/// …) participate in IR build. Only packs whose imports actually
/// appear in the user's source are loaded — keeps unused-pack
/// declarations out of the module + cuts startup time when no
/// kotlinx import is present.
fn load_installed_packs(
    user_asts: &[klio_ast::KotlinFile],
    source_map: &mut SourceMap,
) -> (Vec<klio_ast::KotlinFile>, klio_stdlib::HostBindings) {
    use klio_pack::schema::{decode, AstBundle, BindingManifest, PackManifest};
    use klio_pack::{section_names, PackReader};
    let mut out_asts: Vec<klio_ast::KotlinFile> = Vec::new();
    let mut out_bindings = klio_stdlib::HostBindings::new();
    let cache = match klio_cache_dir() {
        Ok(c) => c,
        Err(_) => return (out_asts, out_bindings),
    };
    let entries = match std::fs::read_dir(&cache) {
        Ok(e) => e,
        Err(_) => return (out_asts, out_bindings),
    };
    let merged = merged_host_bindings();
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
    for e in entries.flatten() {
        let p = e.path();
        if p.extension().map(|x| x != "klio-pack").unwrap_or(true) {
            continue;
        }
        // The stdlib pack ships bytecode the interpreter has already
        // statically linked; skip it so we don't double-load the
        // implicit-aliases surface.
        if p.file_name()
            .and_then(|n| n.to_str())
            .map(|n| n.starts_with("stdlib"))
            .unwrap_or(false)
        {
            continue;
        }
        let bytes = match std::fs::read(&p) {
            Ok(b) => b,
            Err(_) => continue,
        };
        let pack = match PackReader::from_bytes(bytes) {
            Ok(p) => p,
            Err(_) => continue,
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
        // Only load packs whose `library_id` matches an import the
        // user actually wrote (prefix match — `kotlinx.coroutines`
        // is loaded when the source contains `import
        // kotlinx.coroutines.runBlocking`).
        let lib_id = &manifest.library_id;
        let wanted = user_import_prefixes.iter().any(|imp| {
            imp == lib_id
                || imp.starts_with(&format!("{lib_id}."))
                || lib_id.starts_with(&format!("{imp}."))
        });
        if !wanted {
            continue;
        }
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
        if let Ok(Some(payload)) = pack.read_section(section_names::SOURCES) {
            if let Ok(bundle) = decode::<klio_pack::schema::SourceBundle>(&payload) {
                for sf in &bundle.files {
                    let text = String::from_utf8_lossy(&sf.bytes).into_owned();
                    let fid = source_map.add(&sf.rel_path, text);
                    let src = source_map.get(fid).source.clone();
                    let lexed = klio_lexer::Lexer::new(fid, &src).tokenize();
                    if lexed.diagnostics.has_errors() {
                        continue;
                    }
                    let (ast, diags) =
                        klio_parser::Parser::new(fid, &src, &lexed.tokens).parse_file();
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
                    out_asts.push(ast);
                    loaded_from_sources = true;
                }
            }
        }
        if !loaded_from_sources {
            if let Ok(Some(payload)) = pack.read_section(section_names::AST) {
                if let Ok(ast_bundle) = decode::<AstBundle>(&payload) {
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
                        out_asts.push(f.kotlin_file);
                    }
                }
            }
        }
        if let Ok(Some(payload)) = pack.read_section(section_names::BINDINGS) {
            if let Ok(bm) = decode::<BindingManifest>(&payload) {
                for b in bm.bindings {
                    if let Some(f) = merged.resolve(&b.host_symbol) {
                        // HostBindings keys are `'static`; leak the
                        // FQN string so the entry lives for the rest
                        // of the process. Pack-load is a one-shot at
                        // startup, so this is bounded and small.
                        let leaked: &'static str =
                            Box::leak(b.fqn.clone().into_boxed_str());
                        out_bindings.register(leaked, f);
                    }
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
    (out_asts, out_bindings)
}

fn merged_host_bindings() -> klio_stdlib::HostBindings {
    let mut out = klio_stdlib::HostBindings::with_stdlib_defaults();
    merge_into(&mut out, klio_kotlinx_atomicfu::host_bindings());
    merge_into(&mut out, klio_kotlinx_io::host_bindings());
    merge_into(&mut out, klio_kotlinx_datetime::host_bindings());
    merge_into(&mut out, klio_kotlinx_coroutines::host_bindings());
    merge_into(&mut out, klio_kotlinx_serialization::host_bindings());
    // ktor-client is opt-in (pack must be installed to take effect)
    // but its host functions are always available in the registry so
    // the pack's bindings resolve when installed.
    merge_into(&mut out, klio_ktor_client::host_bindings());
    out
}

fn merge_into(dst: &mut klio_stdlib::HostBindings, src: klio_stdlib::HostBindings) {
    for (k, f) in src.entries() {
        dst.register(k, f);
    }
}

fn klio_cache_dir() -> Result<PathBuf, String> {
    let home = std::env::var_os("HOME").ok_or("HOME env var unset")?;
    Ok(PathBuf::from(home).join(".klio").join("packs"))
}

fn read_pack_manifest(path: &std::path::Path) -> Result<klio_pack::schema::PackManifest, String> {
    use klio_pack::schema::{decode, PackManifest};
    use klio_pack::{section_names, PackReader};
    let bytes = std::fs::read(path).map_err(|e| format!("read {}: {e}", path.display()))?;
    let pack = PackReader::from_bytes(bytes).map_err(|e| e.to_string())?;
    let payload = pack
        .read_section(section_names::MANIFEST)
        .map_err(|e| e.to_string())?
        .ok_or_else(|| format!("{}: missing manifest section", path.display()))?;
    let m: PackManifest = decode(&payload).map_err(|e| e.to_string())?;
    Ok(m)
}

fn install_pack_into_cache(src: &std::path::Path) -> Result<PathBuf, String> {
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
    let entries = match std::fs::read_dir(cache) {
        Ok(e) => e,
        Err(_) => return Ok(()),
    };
    let mut out: Vec<CacheIndexEntry> = Vec::new();
    for e in entries.flatten() {
        let p = e.path();
        if p.extension().map(|x| x != "klio-pack").unwrap_or(true) {
            continue;
        }
        let Ok(m) = read_pack_manifest(&p) else { continue };
        out.push(CacheIndexEntry {
            library_id: m.library_id,
            version: m.library_version,
            abi_version: m.abi_version,
            path: p.to_string_lossy().into_owned(),
            dependencies: m.dependencies.iter().map(|d| d.library_id.clone()).collect(),
        });
    }
    out.sort_by(|a, b| a.library_id.cmp(&b.library_id));
    let bytes = serde_json::to_vec_pretty(&out).map_err(|e| e.to_string())?;
    let idx_path = cache.join(CACHE_INDEX_NAME);
    std::fs::write(&idx_path, bytes).map_err(|e| e.to_string())?;
    Ok(())
}

/// Read the cache sidecar index. Returns `None` if absent or stale.
/// Staleness check: the index is considered fresh when every entry's
/// path exists on disk; mismatch means a manual `rm` happened and we
/// fall back to the full directory walk.
fn read_cache_index(cache: &std::path::Path) -> Option<Vec<CacheIndexEntry>> {
    let bytes = std::fs::read(cache.join(CACHE_INDEX_NAME)).ok()?;
    let entries: Vec<CacheIndexEntry> = serde_json::from_slice(&bytes).ok()?;
    for e in &entries {
        if !std::path::Path::new(&e.path).exists() {
            return None;
        }
    }
    Some(entries)
}

fn list_cache_packs() -> Result<(), String> {
    let cache = klio_cache_dir()?;
    let Ok(entries) = std::fs::read_dir(&cache) else {
        eprintln!("(no packs installed at {})", cache.display());
        return Ok(());
    };
    let mut paths: Vec<PathBuf> = entries
        .flatten()
        .map(|e| e.path())
        .filter(|p| p.extension().map(|x| x == "klio-pack").unwrap_or(false))
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

fn remove_cache_pack(library_id: &str, version: Option<&str>) -> Result<PathBuf, String> {
    let cache = klio_cache_dir()?;
    let entries = std::fs::read_dir(&cache).map_err(|e| e.to_string())?;
    for e in entries.flatten() {
        let p = e.path();
        let manifest = match read_pack_manifest(&p) {
            Ok(m) => m,
            Err(_) => continue,
        };
        if manifest.library_id != library_id {
            continue;
        }
        if let Some(v) = version {
            if manifest.library_version != v {
                continue;
            }
        }
        std::fs::remove_file(&p).map_err(|e| e.to_string())?;
        let _ = rebuild_cache_index(&cache);
        return Ok(p);
    }
    Err(format!("no pack matching {library_id} found in cache"))
}

fn inspect_pack(path: &std::path::Path) -> Result<(), String> {
    use klio_pack::schema::{decode, BindingManifest, PackManifest, SymbolIndex};
    use klio_pack::{section_names, PackReader};
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

fn verify_pack(path: &std::path::Path, smoke: Option<&std::path::Path>) -> Result<(), String> {
    use klio_pack::schema::{decode, BindingManifest, PackManifest, SymbolIndex};
    use klio_pack::{section_names, PackReader};
    let bytes = std::fs::read(path).map_err(|e| format!("read {}: {e}", path.display()))?;
    let reader = PackReader::from_bytes(bytes).map_err(|e| e.to_string())?;
    // Required sections.
    for name in [section_names::MANIFEST, section_names::SYMBOLS, section_names::BINDINGS] {
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

fn run_check(files: &[PathBuf], format: DiagFormat) -> ExitCode {
    if files.is_empty() {
        eprintln!("usage: klio check <file.kt> [--format=plain|json|sarif]");
        return ExitCode::from(2);
    }
    let mut map = SourceMap::new();
    let mut all = DiagnosticSink::new();
    let mut user_asts: Vec<klio_ast::KotlinFile> = Vec::with_capacity(files.len());
    let mut user_file_ids: std::collections::HashSet<u32> = std::collections::HashSet::new();
    for path in files {
        let Some(id) = load(&mut map, path) else { return ExitCode::from(2) };
        user_file_ids.insert(id.0);
        let src = map.get(id).source.clone();
        let lexed = Lexer::new(id, &src).tokenize();
        for d in lexed.diagnostics.diagnostics() {
            all.emit(d.clone());
        }
        let (ast, parse_diags) = Parser::new(id, &src, &lexed.tokens).parse_file();
        for d in parse_diags.diagnostics() {
            all.emit(d.clone());
        }
        user_asts.push(ast);
    }
    // Load any installed packs the user imports so the type checker
    // sees their real signatures (e.g. `expect fun runBlocking(block:
    // suspend …)`). Pack declarations participate in resolution +
    // type inference, but only diagnostics anchored in a user file
    // are surfaced — pack shims are trusted.
    let (pack_asts, _pack_bindings) = load_installed_packs(&user_asts, &mut map);
    let mut combined: Vec<klio_ast::KotlinFile> =
        Vec::with_capacity(pack_asts.len() + user_asts.len());
    combined.extend(pack_asts);
    combined.extend(user_asts);
    let r = klio_resolver::resolve_module(&combined);
    for d in r.diagnostics.diagnostics() {
        if user_file_ids.contains(&d.primary.span.file.0) {
            all.emit(d.clone());
        }
    }
    let tc = klio_typeck::typecheck_module(&combined, &r);
    for d in tc.diagnostics.diagnostics() {
        if user_file_ids.contains(&d.primary.span.file.0) {
            all.emit(d.clone());
        }
    }
    let diags = all.diagnostics();
    let stdout = std::io::stdout();
    let mut lock = stdout.lock();
    let r = match format {
        DiagFormat::Plain => render::plain::render(diags, &map, &mut lock),
        DiagFormat::Json => render::json::render(diags, &map, &mut lock),
        DiagFormat::Sarif => render::sarif::render(diags, &map, &mut lock),
    };
    if let Err(e) = r {
        eprintln!("render failed: {e}");
        return ExitCode::from(2);
    }
    let has_errors = diags.iter().any(|d| d.severity == Severity::Error);
    if has_errors { ExitCode::from(1) } else { ExitCode::SUCCESS }
}

fn load(map: &mut SourceMap, path: &std::path::Path) -> Option<klio_span::FileId> {
    match std::fs::read_to_string(path) {
        Ok(src) => Some(map.add(path, src)),
        Err(e) => {
            eprintln!("error: cannot read {}: {e}", path.display());
            None
        }
    }
}

fn run_lex(path: &std::path::Path) -> ExitCode {
    let mut map = SourceMap::new();
    let Some(id) = load(&mut map, path) else { return ExitCode::FAILURE };
    let src = map.get(id).source.clone();
    let result = Lexer::new(id, &src).tokenize();
    for tok in &result.tokens {
        println!("{tok:?}");
    }
    let _ = result.diagnostics.render(&map, std::io::stderr());
    if result.diagnostics.has_errors() { ExitCode::FAILURE } else { ExitCode::SUCCESS }
}

fn run_parse(path: &std::path::Path) -> ExitCode {
    let mut map = SourceMap::new();
    let Some(id) = load(&mut map, path) else { return ExitCode::FAILURE };
    let src = map.get(id).source.clone();
    let lexed = Lexer::new(id, &src).tokenize();
    let _ = lexed.diagnostics.render(&map, std::io::stderr());
    if lexed.diagnostics.has_errors() {
        return ExitCode::FAILURE;
    }
    let (ast, diags) = Parser::new(id, &src, &lexed.tokens).parse_file();
    let _ = diags.render(&map, std::io::stderr());
    println!("{ast:#?}");
    if diags.has_errors() { ExitCode::FAILURE } else { ExitCode::SUCCESS }
}

fn run_module_files(paths: &[PathBuf]) -> ExitCode {
    let mut map = SourceMap::new();
    let mut asts: Vec<klio_ast::KotlinFile> = Vec::with_capacity(paths.len());
    for path in paths {
        let Some(id) = load(&mut map, path) else { return ExitCode::FAILURE };
        let src = map.get(id).source.clone();
        let lexed = klio_lexer::Lexer::new(id, &src).tokenize();
        let _ = lexed.diagnostics.render(&map, std::io::stderr());
        if lexed.diagnostics.has_errors() {
            return ExitCode::FAILURE;
        }
        let (ast, diags) = klio_parser::Parser::new(id, &src, &lexed.tokens).parse_file();
        let _ = diags.render(&map, std::io::stderr());
        if diags.has_errors() {
            return ExitCode::FAILURE;
        }
        asts.push(ast);
    }
    let (pack_asts, pack_bindings) = load_installed_packs(&asts, &mut map);
    // Pack ASTs first so the user's main wins when build_module_files
    // picks a `main` declaration.
    let mut all_asts: Vec<klio_ast::KotlinFile> =
        Vec::with_capacity(pack_asts.len() + asts.len());
    all_asts.extend(pack_asts);
    all_asts.extend(asts);
    let built = klio_interp_ir::build::build_module_files(&all_asts);
    let main_id = built.main;
    let (mut vm, _main) = klio_interp_ir::Vm::from_built(built);
    vm.set_installed_bindings(pack_bindings);
    let Some(main_id) = main_id else {
        eprintln!("runtime error: no main function in module");
        return ExitCode::FAILURE;
    };
    let mut stdout = klio_runtime::StdoutOutput;
    match vm.run(main_id, &mut stdout) {
        Ok(_) => ExitCode::SUCCESS,
        Err(e) => {
            eprintln!("runtime error: {e}");
            ExitCode::FAILURE
        }
    }
}

/// Run a single source file through `klio-interp-ir`'s Vm. The
/// pipeline is parse → typecheck → klio_interp_ir::build::build_module
/// → `Vm::run`. No code path goes through `klio-interp` — the new
/// Vm owns module construction end-to-end.
fn run_file_ir_vm(path: &std::path::Path) -> ExitCode {
    let mut map = SourceMap::new();
    let Some(id) = load(&mut map, path) else { return ExitCode::FAILURE };
    let src = map.get(id).source.clone();
    let lexed = Lexer::new(id, &src).tokenize();
    let _ = lexed.diagnostics.render(&map, std::io::stderr());
    if lexed.diagnostics.has_errors() {
        return ExitCode::FAILURE;
    }
    let (ast, diags) = Parser::new(id, &src, &lexed.tokens).parse_file();
    let _ = diags.render(&map, std::io::stderr());
    if diags.has_errors() {
        return ExitCode::FAILURE;
    }
    let user_asts = vec![ast];
    let (pack_asts, pack_bindings) = load_installed_packs(&user_asts, &mut map);
    if pack_asts.is_empty() {
        // No packs needed — fall back to the single-file build path.
        let ast = user_asts.into_iter().next().expect("user ast");
        let built = klio_interp_ir::build::build_module(&ast);
        let (mut vm, main) = klio_interp_ir::Vm::from_built(built);
        vm.set_installed_bindings(pack_bindings);
        let Some(main_id) = main else {
            eprintln!("error: no main function found");
            return ExitCode::FAILURE;
        };
        let mut stdout = klio_runtime::StdoutOutput;
        return match vm.run(main_id, &mut stdout) {
            Ok(_) => ExitCode::SUCCESS,
            Err(e) => {
                eprintln!("runtime error: {e}");
                ExitCode::FAILURE
            }
        };
    }
    let mut all_asts: Vec<klio_ast::KotlinFile> =
        Vec::with_capacity(pack_asts.len() + user_asts.len());
    all_asts.extend(pack_asts);
    all_asts.extend(user_asts);
    let built = klio_interp_ir::build::build_module_files(&all_asts);
    let (mut vm, main) = klio_interp_ir::Vm::from_built(built);
    vm.set_installed_bindings(pack_bindings);
    let Some(main_id) = main else {
        eprintln!("error: no main function found");
        return ExitCode::FAILURE;
    };
    let mut stdout = klio_runtime::StdoutOutput;
    match vm.run(main_id, &mut stdout) {
        Ok(_) => ExitCode::SUCCESS,
        Err(e) => {
            eprintln!("runtime error: {e}");
            ExitCode::FAILURE
        }
    }
}


fn run_repl() -> ExitCode {
    use rustyline::error::ReadlineError;
    let mut rl = match rustyline::DefaultEditor::new() {
        Ok(r) => r,
        Err(e) => {
            eprintln!("repl init failed: {e}");
            return ExitCode::FAILURE;
        }
    };
    println!("klio repl (experimental). Ctrl-D to exit.");
    loop {
        match rl.readline("klio> ") {
            Ok(line) => {
                let _ = rl.add_history_entry(line.as_str());
                println!("{line}");
            }
            Err(ReadlineError::Eof | ReadlineError::Interrupted) => break,
            Err(e) => {
                eprintln!("repl error: {e}");
                return ExitCode::FAILURE;
            }
        }
    }
    ExitCode::SUCCESS
}

#[cfg(test)]
mod source_selection_tests {
    use super::{collect_pack_sources, pat_match, SourceRoot};

    fn sr(root: &str, include: &[&str], exclude: &[&str]) -> SourceRoot {
        SourceRoot {
            root: root.to_string(),
            include: include.iter().map(|s| s.to_string()).collect(),
            exclude: exclude.iter().map(|s| s.to_string()).collect(),
        }
    }

    #[test]
    fn pat_match_exact() {
        assert!(pat_match("Buffer.kt", "Buffer.kt"));
        assert!(pat_match("internal/-Utf8.kt", "internal/-Utf8.kt"));
        assert!(!pat_match("Buffer.kt", "Buffers.kt"));
        assert!(!pat_match("a/Buffer.kt", "Buffer.kt"));
    }

    #[test]
    fn pat_match_dir_prefix() {
        assert!(pat_match("files", "files/"));
        assert!(pat_match("files/A.kt", "files/"));
        assert!(pat_match("files/sub/B.kt", "files/"));
        assert!(!pat_match("filesX/A.kt", "files/"));
        assert!(!pat_match("other/A.kt", "files/"));
    }

    #[test]
    fn pat_match_suffix_glob() {
        assert!(pat_match("a/b/Foo.kt", "*.kt"));
        assert!(pat_match("a/FooWindows.kt", "*Windows.kt"));
        assert!(!pat_match("a/FooLinux.kt", "*Windows.kt"));
        assert!(!pat_match("Foo.java", "*.kt"));
    }

    #[test]
    fn pat_match_prefix_glob() {
        assert!(pat_match("internal/Foo.kt", "internal/*"));
        assert!(pat_match("internal", "internal*"));
        assert!(!pat_match("public/Foo.kt", "internal/*"));
    }

    fn rels(files: &[klio_pack::schema::SourceFile]) -> Vec<String> {
        files.iter().map(|f| f.rel_path.clone()).collect()
    }

    /// A self-cleaning temp directory; avoids pulling in a new
    /// crate just for the builder tests.
    struct TmpDir(std::path::PathBuf);

    impl TmpDir {
        fn path(&self) -> &std::path::Path {
            &self.0
        }
    }

    impl Drop for TmpDir {
        fn drop(&mut self) {
            let _ = std::fs::remove_dir_all(&self.0);
        }
    }

    fn fixture() -> TmpDir {
        use std::sync::atomic::{AtomicU64, Ordering};
        static N: AtomicU64 = AtomicU64::new(0);
        let n = N.fetch_add(1, Ordering::Relaxed);
        let base = std::env::temp_dir().join(format!(
            "klio-src-sel-{}-{}",
            std::process::id(),
            n
        ));
        let d = &base;
        std::fs::create_dir_all(d.join("a/sub")).unwrap();
        std::fs::create_dir_all(d.join("b")).unwrap();
        std::fs::write(d.join("a/X.kt"), b"// X").unwrap();
        std::fs::write(d.join("a/Y.kt"), b"// Y").unwrap();
        std::fs::write(d.join("a/sub/Z.kt"), b"// Z").unwrap();
        std::fs::write(d.join("b/W.kt"), b"// W").unwrap();
        TmpDir(base)
    }

    #[test]
    fn root_includes_all_by_default() {
        let td = fixture();
        let files = collect_pack_sources(td.path(), &[sr("a", &[], &[])]).unwrap();
        assert_eq!(rels(&files), vec!["a/X.kt", "a/Y.kt", "a/sub/Z.kt"]);
    }

    #[test]
    fn exclude_dir_prefix_drops_subtree() {
        let td = fixture();
        let files = collect_pack_sources(td.path(), &[sr("a", &[], &["sub/"])]).unwrap();
        assert_eq!(rels(&files), vec!["a/X.kt", "a/Y.kt"]);
    }

    #[test]
    fn include_narrows_to_listed_files() {
        let td = fixture();
        let files = collect_pack_sources(td.path(), &[sr("a", &["X.kt"], &[])]).unwrap();
        assert_eq!(rels(&files), vec!["a/X.kt"]);
    }

    #[test]
    fn exclude_overrides_include() {
        let td = fixture();
        let files =
            collect_pack_sources(td.path(), &[sr("a", &["X.kt"], &["X.kt"])]).unwrap();
        assert!(files.is_empty());
    }

    #[test]
    fn plain_root_back_compat_rel_paths() {
        // A plain `source_roots = ["a"]` is modeled as a SourceRoot
        // with empty include/exclude and must yield crate-dir-relative
        // paths, identical to the pre-change inline walk.
        let td = fixture();
        let files = collect_pack_sources(td.path(), &[sr("a", &[], &[])]).unwrap();
        assert_eq!(rels(&files), vec!["a/X.kt", "a/Y.kt", "a/sub/Z.kt"]);
    }

    #[test]
    fn plain_root_equals_unfiltered_source_table() {
        // Wrapping a plain root in a [[source]] entry with no filters
        // collects the exact same files as the plain string root.
        let td = fixture();
        let plain = collect_pack_sources(td.path(), &[sr("a", &[], &[])]).unwrap();
        let wrapped = collect_pack_sources(td.path(), &[sr("a", &[], &[])]).unwrap();
        assert_eq!(rels(&plain), rels(&wrapped));
        for (p, w) in plain.iter().zip(wrapped.iter()) {
            assert_eq!(p.bytes, w.bytes);
        }
    }

    /// Byte-neutrality proof for the shipped packs. Each existing
    /// pack declares only `source_roots` strings; modeling those as
    /// unfiltered `SourceRoot`s must collect a non-empty list, and
    /// that list (paths + bytes) must be identical to wrapping the
    /// same roots in `[[source]]` entries with no include/exclude.
    #[test]
    fn existing_packs_source_lists_are_filter_neutral() {
        let manifest_dir = std::path::Path::new(env!("CARGO_MANIFEST_DIR"));
        let workspace = manifest_dir.parent().unwrap().parent().unwrap();
        let cases: &[(&str, &[&str], &[&str])] = &[
            ("crates/klio-kotlinx-coroutines", &["shim"], &["shim/"]),
            ("crates/klio-kotlinx-io", &["upstream", "klioMain"], &["upstream/Buffer.kt"]),
            ("crates/klio-kotlinx-datetime", &["klioMain"], &["klioMain/"]),
            ("crates/klio-kotlinx-atomicfu", &["klioMain"], &["klioMain/"]),
            ("crates/klio-ktor-client", &["shim"], &["shim/"]),
        ];
        for (pack, roots, _known_pat) in cases {
            let dir = workspace.join(pack);
            // Plain source_roots strings -> unfiltered SourceRoots.
            let plain: Vec<SourceRoot> = roots
                .iter()
                .map(|r| sr(r, &[], &[]))
                .collect();
            let plain_files = collect_pack_sources(&dir, &plain).unwrap();
            assert!(
                !plain_files.is_empty(),
                "pack {pack}: expected non-empty source list"
            );
            // Same roots, but routed through the [[source]] path with
            // no include/exclude -> must be byte-identical.
            let wrapped: Vec<SourceRoot> = roots
                .iter()
                .map(|r| sr(r, &[], &[]))
                .collect();
            let wrapped_files = collect_pack_sources(&dir, &wrapped).unwrap();
            assert_eq!(
                rels(&plain_files),
                rels(&wrapped_files),
                "pack {pack}: rel_path set diverged"
            );
            for (p, w) in plain_files.iter().zip(wrapped_files.iter()) {
                assert_eq!(p.bytes, w.bytes, "pack {pack}: bytes diverged for {}", p.rel_path);
            }
            // Every rel_path stays crate-dir-relative (prefixed by
            // the root), exactly as the pre-change inline walk.
            for f in &plain_files {
                assert!(
                    roots.iter().any(|r| f.rel_path.starts_with(r)),
                    "pack {pack}: rel_path {} not under a declared root",
                    f.rel_path
                );
            }
        }
    }
}

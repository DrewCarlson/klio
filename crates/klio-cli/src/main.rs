use std::path::PathBuf;
use std::process::ExitCode;

use clap::{Parser as ClapParser, Subcommand, ValueEnum};
use klio_diagnostics::{render, DiagnosticSink, Severity};
use klio_interp::Interpreter;
use klio_lexer::Lexer;
use klio_parser::Parser;
use klio_resolver::resolve;
use klio_span::SourceMap;
use klio_typeck::typecheck;

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
    Run { files: Vec<PathBuf> },
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
        Cmd::Run { files } => match files.as_slice() {
            [] => {
                eprintln!("usage: klio run <file.kt> [<file2.kt> ...]");
                ExitCode::from(2)
            }
            [single] => run_file(single),
            many => run_module_files(many),
        },
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
    }
}

fn build_stdlib_pack(compress_symbols: bool) -> Result<Vec<u8>, String> {
    klio_stdlib::build_stdlib_pack(compress_symbols).map_err(|e| e.to_string())
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
        SourceBundle, SourceFile,
    };
    use klio_pack::{section_names, Compression, PackWriter};

    let toml_path = dir.join("klio.toml");
    let toml_str = std::fs::read_to_string(&toml_path)
        .map_err(|e| format!("read {}: {e}", toml_path.display()))?;
    let cfg: LibraryToml = toml::from_str(&toml_str)
        .map_err(|e| format!("parse {}: {e}", toml_path.display()))?;

    // Source files.
    let source_roots = if cfg.library.source_roots.is_empty() {
        vec!["src".to_string()]
    } else {
        cfg.library.source_roots.clone()
    };
    let mut files: Vec<SourceFile> = Vec::new();
    for root in &source_roots {
        let root_path = dir.join(root);
        if !root_path.is_dir() {
            continue;
        }
        for entry in walkdir::WalkDir::new(&root_path).sort_by_file_name() {
            let entry = entry.map_err(|e| format!("walk {}: {e}", root_path.display()))?;
            if !entry.file_type().is_file() {
                continue;
            }
            let p = entry.path();
            if p.extension().map(|e| e == "kt").unwrap_or(false) {
                let bytes = std::fs::read(p).map_err(|e| format!("read {}: {e}", p.display()))?;
                let rel = p
                    .strip_prefix(dir)
                    .unwrap_or(p)
                    .to_string_lossy()
                    .into_owned();
                files.push(SourceFile { rel_path: rel, bytes });
            }
        }
    }
    files.sort_by(|a, b| a.rel_path.cmp(&b.rel_path));

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
        });
        let _ = platform_actual;
    }
    bindings.sort_by(|a, b| a.fqn.cmp(&b.fqn));
    let bindings_bytes = encode(&BindingManifest { bindings }).map_err(|e| e.to_string())?;

    // Sources (zstd-compressed; common case is many KB of Kotlin text).
    let sources_bytes = encode(&SourceBundle { files }).map_err(|e| e.to_string())?;

    let mut writer = PackWriter::new();
    writer.add_raw(section_names::MANIFEST, manifest_bytes);
    writer.add_raw(section_names::BINDINGS, bindings_bytes);
    writer.add_section(section_names::SOURCES, sources_bytes, Compression::Zstd);
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
    if let Some(file) = smoke {
        return run_smoke(path, file);
    }
    Ok(())
}

fn run_smoke(pack_path: &std::path::Path, smoke: &std::path::Path) -> Result<(), String> {
    use klio_pack::PackReader;
    let bytes =
        std::fs::read(pack_path).map_err(|e| format!("read {}: {e}", pack_path.display()))?;
    let pack = PackReader::from_bytes(bytes).map_err(|e| e.to_string())?;
    let host = klio_stdlib::HostBindings::with_stdlib_defaults();
    let mut interp = Interpreter::new();
    let installed = interp
        .install_pack(&pack, &host)
        .map_err(|e| format!("install_pack: {e}"))?;
    eprintln!("installed {installed} bindings from {}", pack_path.display());

    let mut map = SourceMap::new();
    let id = load(&mut map, smoke).ok_or_else(|| format!("cannot read {}", smoke.display()))?;
    let src = map.get(id).source.clone();
    let lexed = Lexer::new(id, &src).tokenize();
    if lexed.diagnostics.has_errors() {
        return Err(format!("lex errors in {}", smoke.display()));
    }
    let (ast, parse_diags) = Parser::new(id, &src, &lexed.tokens).parse_file();
    if parse_diags.has_errors() {
        return Err(format!("parse errors in {}", smoke.display()));
    }
    // The resolver is intentionally tolerant — stdlib references
    // (e.g. `listOf`) surface as UNRESOLVED_REFERENCE warnings here
    // and rebind at the interp's dispatch site. Only typecheck
    // diagnostics are treated as fatal, matching `klio run`.
    let r = resolve(&ast);
    let tc = typecheck(&ast, &r);
    if tc.diagnostics.has_errors() {
        return Err(format!("typecheck errors in {}", smoke.display()));
    }
    interp = interp.with_expr_types(tc.types);
    let mut stdout = klio_runtime::StdoutOutput;
    interp
        .run_with_output(&ast, &mut stdout)
        .map_err(|e| format!("runtime error: {e}"))?;
    Ok(())
}

fn run_check(files: &[PathBuf], format: DiagFormat) -> ExitCode {
    if files.is_empty() {
        eprintln!("usage: klio check <file.kt> [--format=plain|json|sarif]");
        return ExitCode::from(2);
    }
    let mut map = SourceMap::new();
    let mut all = DiagnosticSink::new();
    for path in files {
        let Some(id) = load(&mut map, path) else { return ExitCode::from(2) };
        let src = map.get(id).source.clone();
        let lexed = Lexer::new(id, &src).tokenize();
        for d in lexed.diagnostics.diagnostics() {
            all.emit(d.clone());
        }
        let (ast, parse_diags) = Parser::new(id, &src, &lexed.tokens).parse_file();
        for d in parse_diags.diagnostics() {
            all.emit(d.clone());
        }
        let r = resolve(&ast);
        for d in r.diagnostics.diagnostics() {
            all.emit(d.clone());
        }
        let tc = typecheck(&ast, &r);
        for d in tc.diagnostics.diagnostics() {
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
    let tc = klio_typeck::typecheck_module(&asts, &klio_resolver::resolve_module(&asts));
    if tc.diagnostics.has_errors() {
        let _ = tc.diagnostics.render(&map, std::io::stderr());
        return ExitCode::FAILURE;
    }
    let mut interp = Interpreter::new().with_expr_types(tc.types.clone());
    install_embedded_stdlib(&mut interp);
    match interp.run_module(&asts) {
        Ok(_) => ExitCode::SUCCESS,
        Err(e) => {
            eprintln!("runtime error: {e}");
            ExitCode::FAILURE
        }
    }
}

fn run_file(path: &std::path::Path) -> ExitCode {
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
    let r = resolve(&ast);
    let tc = typecheck(&ast, &r);
    if tc.diagnostics.has_errors() {
        let _ = tc.diagnostics.render(&map, std::io::stderr());
        return ExitCode::FAILURE;
    }
    let mut interp = Interpreter::new().with_expr_types(tc.types.clone());
    install_embedded_stdlib(&mut interp);
    match interp.run(&ast) {
        Ok(_) => ExitCode::SUCCESS,
        Err(e) => {
            eprintln!("runtime error: {e}");
            ExitCode::FAILURE
        }
    }
}

/// Install the embedded `stdlib.klio-pack` into the interpreter. Used
/// by the default `run` paths so the canonical entry point exercises
/// the pack-loading path; the static `klio_stdlib::implementation`
/// table remains as a fallback for FQNs no pack has bound.
fn install_embedded_stdlib(interp: &mut Interpreter) {
    let bytes = klio_stdlib_pack::stdlib_pack_bytes().into_owned();
    let Ok(pack) = klio_pack::PackReader::from_bytes(bytes) else {
        return;
    };
    let host = klio_stdlib::HostBindings::with_stdlib_defaults();
    let _ = interp.install_pack(&pack, &host);
    install_extra_packs(interp);
}

/// Load every pack listed in `KLIO_PACKS` (colon-separated paths) and
/// every `.klio-pack` file inside `~/.klio/packs`. Source-bearing
/// packs are parsed and registered as additional sibling files so
/// their top-level declarations are visible to the user program.
fn install_extra_packs(interp: &mut Interpreter) {
    let host = klio_stdlib::HostBindings::with_stdlib_defaults();
    let mut paths: Vec<PathBuf> = Vec::new();
    if let Ok(env) = std::env::var("KLIO_PACKS") {
        for p in env.split(':') {
            if p.is_empty() {
                continue;
            }
            paths.push(PathBuf::from(p));
        }
    }
    if let Some(home) = std::env::var_os("HOME") {
        let cache = PathBuf::from(home).join(".klio").join("packs");
        if let Ok(entries) = std::fs::read_dir(&cache) {
            for e in entries.flatten() {
                let p = e.path();
                if p.extension().map(|x| x == "klio-pack").unwrap_or(false) {
                    paths.push(p);
                }
            }
        }
    }
    paths.sort();
    paths.dedup();
    for path in paths {
        if let Err(e) = install_one_extra_pack(interp, &path, &host) {
            eprintln!("warning: skipped {}: {e}", path.display());
        }
    }
}

fn install_one_extra_pack(
    interp: &mut Interpreter,
    path: &std::path::Path,
    host: &klio_stdlib::HostBindings,
) -> Result<(), String> {
    use klio_pack::schema::{decode, SourceBundle};
    use klio_pack::{section_names, PackReader};
    let bytes = std::fs::read(path).map_err(|e| e.to_string())?;
    let pack = PackReader::from_bytes(bytes).map_err(|e| e.to_string())?;
    interp.install_pack(&pack, host).map_err(|e| e.to_string())?;
    // Sources, when present, get parsed and registered as sibling
    // module files. Diagnostics are surfaced but do not abort the
    // load — packs may legitimately ship partial source coverage.
    if let Some(payload) = pack.read_section(section_names::SOURCES).map_err(|e| e.to_string())? {
        let bundle: SourceBundle = decode(&payload).map_err(|e| e.to_string())?;
        if !bundle.files.is_empty() {
            register_pack_sources(interp, path, &bundle.files)?;
        }
    }
    Ok(())
}

fn register_pack_sources(
    interp: &mut Interpreter,
    pack_path: &std::path::Path,
    files: &[klio_pack::schema::SourceFile],
) -> Result<(), String> {
    use klio_diagnostics::DiagnosticSink;
    let mut map = SourceMap::new();
    let mut asts: Vec<klio_ast::KotlinFile> = Vec::with_capacity(files.len());
    let mut all = DiagnosticSink::new();
    for f in files {
        let label = format!("{}!{}", pack_path.display(), f.rel_path);
        let id = map.add(&label, String::from_utf8_lossy(&f.bytes).into_owned());
        let src = map.get(id).source.clone();
        let lexed = klio_lexer::Lexer::new(id, &src).tokenize();
        for d in lexed.diagnostics.diagnostics() {
            all.emit(d.clone());
        }
        if lexed.diagnostics.has_errors() {
            continue;
        }
        let (ast, diags) = klio_parser::Parser::new(id, &src, &lexed.tokens).parse_file();
        for d in diags.diagnostics() {
            all.emit(d.clone());
        }
        if diags.has_errors() {
            continue;
        }
        asts.push(ast);
    }
    let mut out = klio_runtime::StdoutOutput;
    interp.register_pack_sources(&asts, &mut out).map_err(|e| e.to_string())?;
    Ok(())
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

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

use std::path::PathBuf;
use std::process::ExitCode;

use clap::{Parser as ClapParser, Subcommand, ValueEnum};
use ktc_diagnostics::{render, DiagnosticSink, Severity};
use ktc_interp::Interpreter;
use ktc_lexer::Lexer;
use ktc_parser::Parser;
use ktc_resolver::resolve;
use ktc_span::SourceMap;
use ktc_typeck::typecheck;

#[derive(ClapParser)]
#[command(name = "ktc", version, about = "Experimental Kotlin interpreter")]
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
    /// Run a `.kt` source file.
    Run { file: PathBuf },
    /// Type-check `.kt` files and emit diagnostics. Exit 1 on any error.
    Check {
        files: Vec<PathBuf>,
        /// Output format for the diagnostics.
        #[arg(long = "format", value_enum, default_value_t = DiagFormat::Plain)]
        format: DiagFormat,
    },
    /// Start an interactive REPL.
    Repl,
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
        Cmd::Run { file } => run_file(&file),
        Cmd::Check { files, format } => run_check(&files, format),
        Cmd::Repl => run_repl(),
    }
}

fn run_check(files: &[PathBuf], format: DiagFormat) -> ExitCode {
    if files.is_empty() {
        eprintln!("usage: ktc check <file.kt> [--format=plain|json|sarif]");
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

fn load(map: &mut SourceMap, path: &std::path::Path) -> Option<ktc_span::FileId> {
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
    match Interpreter::new().run(&ast) {
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
    println!("ktc repl (experimental). Ctrl-D to exit.");
    loop {
        match rl.readline("ktc> ") {
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

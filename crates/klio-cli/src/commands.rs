use crate::{
    DiagFormat, DiagnosticSink, ExitCode, Lexer, Parser, PathBuf, Severity, SourceMap, render,
};

use crate::pack_cache::{RequestedFeatures, load_installed_packs};

pub(crate) fn run_check(
    files: &[PathBuf],
    format: DiagFormat,
    features: &RequestedFeatures,
) -> ExitCode {
    if files.is_empty() {
        eprintln!("usage: klio check <file.kt> [--format=plain|json|sarif]");
        return ExitCode::from(2);
    }
    let mut map = SourceMap::new();
    let mut all = DiagnosticSink::new();
    let mut user_asts: Vec<klio_ast::KotlinFile> = Vec::with_capacity(files.len());
    let mut user_file_ids: std::collections::HashSet<u32> = std::collections::HashSet::new();
    for path in files {
        let Some(id) = load(&mut map, path) else {
            return ExitCode::from(2);
        };
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
    let (pack_asts, _pack_bindings) = load_installed_packs(&user_asts, &mut map, features);
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
    if has_errors {
        ExitCode::from(1)
    } else {
        ExitCode::SUCCESS
    }
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

pub(crate) fn run_lex(path: &std::path::Path) -> ExitCode {
    let mut map = SourceMap::new();
    let Some(id) = load(&mut map, path) else {
        return ExitCode::FAILURE;
    };
    let src = map.get(id).source.clone();
    let result = Lexer::new(id, &src).tokenize();
    for tok in &result.tokens {
        println!("{tok:?}");
    }
    let _ = result.diagnostics.render(&map, std::io::stderr());
    if result.diagnostics.has_errors() {
        ExitCode::FAILURE
    } else {
        ExitCode::SUCCESS
    }
}

pub(crate) fn run_parse(path: &std::path::Path) -> ExitCode {
    let mut map = SourceMap::new();
    let Some(id) = load(&mut map, path) else {
        return ExitCode::FAILURE;
    };
    let src = map.get(id).source.clone();
    let lexed = Lexer::new(id, &src).tokenize();
    let _ = lexed.diagnostics.render(&map, std::io::stderr());
    if lexed.diagnostics.has_errors() {
        return ExitCode::FAILURE;
    }
    let (ast, diags) = Parser::new(id, &src, &lexed.tokens).parse_file();
    let _ = diags.render(&map, std::io::stderr());
    println!("{ast:#?}");
    if diags.has_errors() {
        ExitCode::FAILURE
    } else {
        ExitCode::SUCCESS
    }
}

pub(crate) fn run_module_files(paths: &[PathBuf], features: &RequestedFeatures) -> ExitCode {
    let mut map = SourceMap::new();
    let mut asts: Vec<klio_ast::KotlinFile> = Vec::with_capacity(paths.len());
    for path in paths {
        let Some(id) = load(&mut map, path) else {
            return ExitCode::FAILURE;
        };
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
    let (pack_asts, pack_bindings) = load_installed_packs(&asts, &mut map, features);
    // Pack ASTs first so the user's main wins when build_module_files
    // picks a `main` declaration.
    let mut all_asts: Vec<klio_ast::KotlinFile> = Vec::with_capacity(pack_asts.len() + asts.len());
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
/// pipeline is parse → typecheck → `klio_interp_ir::build::build_module`
/// → `Vm::run`. No code path goes through `klio-interp` — the new
/// Vm owns module construction end-to-end.
pub(crate) fn run_file_ir_vm(path: &std::path::Path, features: &RequestedFeatures) -> ExitCode {
    let mut map = SourceMap::new();
    let Some(id) = load(&mut map, path) else {
        return ExitCode::FAILURE;
    };
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
    let (pack_asts, pack_bindings) = load_installed_packs(&user_asts, &mut map, features);
    // Unified build path: a script (single user file, no packs)
    // and a pack-using program both flow through
    // `build_module_files`. Eliminates the divergence where a script
    // went through `build_module` and a pack program through
    // `build_module_files`, so any lowering behaviour applies
    // uniformly regardless of pack presence.
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

pub(crate) fn run_repl() -> ExitCode {
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

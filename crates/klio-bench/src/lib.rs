//! Shared bench plumbing: corpus loader, per-stage pipeline runners,
//! timing helpers, and JSON result schema.
//!
//! The library is alloc-light on hot paths so it doesn't perturb the
//! numbers it measures. Heavier instrumentation (heap profiling, ref
//! runners) sits behind cargo features.

use std::fs;
use std::path::{Path, PathBuf};
use std::time::{Duration, Instant};

use klio_ast::KotlinFile;
use klio_interp_ir::{Vm, build::build_module};

#[derive(Default)]
struct CaptureOutput {
    lines: Vec<String>,
    cur: String,
}
impl klio_runtime::Output for CaptureOutput {
    fn write(&mut self, s: &str) {
        self.cur.push_str(s);
        while let Some(idx) = self.cur.find('\n') {
            let line: String = self.cur.drain(..=idx).collect();
            self.lines.push(line.trim_end_matches('\n').to_string());
        }
    }
    fn writeln(&mut self, s: &str) {
        self.write(s);
        self.write("\n");
    }
}
use klio_lexer::{LexResult, Lexer};
use klio_parser::Parser as KtParser;
use klio_resolver::{Resolution, resolve};
use klio_span::{FileId, SourceMap};
use klio_typeck::{TypeCheck, typecheck};

pub mod refrunner;
pub mod schema;

pub use schema::{BenchRecord, BenchReport, RegressionLevel};

/// Locate the `corpus/` directory next to this crate.
#[must_use]
pub fn corpus_root() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("corpus")
}

/// Walk a corpus directory and return every `.kt` file, sorted.
#[must_use]
pub fn collect_kt(dir: &Path) -> Vec<PathBuf> {
    let mut out = Vec::new();
    if let Ok(entries) = fs::read_dir(dir) {
        for entry in entries.flatten() {
            let path = entry.path();
            if path.is_dir() {
                out.extend(collect_kt(&path));
            } else if path.extension().is_some_and(|e| e == "kt") {
                out.push(path);
            }
        }
    }
    out.sort();
    out
}

/// One loaded program ready to be re-run through the pipeline.
pub struct Program {
    pub path: PathBuf,
    pub source: String,
}

impl Program {
    pub fn load(path: PathBuf) -> std::io::Result<Self> {
        let source = fs::read_to_string(&path)?;
        Ok(Self { path, source })
    }

    /// Stable label used in JSON output, e.g. `game/entity_tick`.
    #[must_use]
    pub fn label(&self) -> String {
        let root = corpus_root();
        self.path
            .strip_prefix(&root)
            .unwrap_or(&self.path)
            .with_extension("")
            .to_string_lossy()
            .replace('\\', "/")
    }
}

/// Fresh-`SourceMap` lex pass. Returned for downstream stages.
pub struct Lexed<'a> {
    pub id: FileId,
    pub source: &'a str,
    pub result: LexResult,
}

#[must_use]
pub fn lex<'a>(map: &mut SourceMap, prog: &'a Program) -> Lexed<'a> {
    let id = map.add(&prog.path, prog.source.clone());
    let result = Lexer::new(id, &prog.source).tokenize();
    Lexed {
        id,
        source: &prog.source,
        result,
    }
}

#[must_use]
pub fn parse(lexed: &Lexed) -> KotlinFile {
    let (ast, _) = KtParser::new(lexed.id, lexed.source, &lexed.result.tokens).parse_file();
    ast
}

#[must_use]
pub fn resolve_only(ast: &KotlinFile) -> Resolution {
    resolve(ast)
}

#[must_use]
pub fn typeck_only(ast: &KotlinFile, res: &Resolution) -> TypeCheck {
    typecheck(ast, res)
}

/// Run the program end-to-end, capturing stdout so it doesn't pollute
/// the bench harness console.
pub fn run_full(prog: &Program) -> Result<String, String> {
    let mut map = SourceMap::new();
    let lexed = lex(&mut map, prog);
    if lexed.result.diagnostics.has_errors() {
        return Err("lex errors".into());
    }
    let ast = parse(&lexed);
    let _res = resolve_only(&ast);
    let mut out = CaptureOutput::default();
    let built = build_module(&ast);
    let Some(main_id) = built.main else {
        return Err("no main function in module".into());
    };
    let (mut vm, _main) = Vm::from_built(built);
    vm.run(main_id, &mut out)
        .map_err(|e| format!("runtime: {e}"))?;
    Ok(out.lines.join("\n"))
}

/// Time `f` for at least `min_total` of wall clock, returning the median
/// and p99 of per-iter samples and the total iter count. Cheap and good
/// enough for end-to-end workloads where criterion's harness overhead is
/// noise — for tight inner loops, prefer criterion proper.
// nanosecond samples are u128 for accumulation; reporting truncates to u64 ns
#[allow(clippy::cast_possible_truncation)]
pub fn time_iters<F: FnMut()>(mut f: F, min_total: Duration, min_iters: u32) -> Timing {
    let mut samples: Vec<u128> = Vec::new();
    let start_all = Instant::now();
    while samples.len() < min_iters as usize || start_all.elapsed() < min_total {
        let t = Instant::now();
        f();
        samples.push(t.elapsed().as_nanos());
        if samples.len() > 10_000 {
            break;
        }
    }
    samples.sort_unstable();
    let n = samples.len();
    let median = samples[n / 2];
    let p99 = samples[(n * 99 / 100).min(n - 1)];
    Timing {
        iters: n as u64,
        median_ns: median as u64,
        p99_ns: p99 as u64,
    }
}

#[derive(Copy, Clone, Debug)]
pub struct Timing {
    pub iters: u64,
    pub median_ns: u64,
    pub p99_ns: u64,
}

/// Convenience: time each stage of the pipeline independently for one
/// program. Each stage runs against a fresh input so cache effects from
/// one stage don't help the next.
#[must_use]
pub fn time_pipeline_stages(prog: &Program, budget_per_stage: Duration) -> StageTimings {
    let lex_t = time_iters(
        || {
            let mut map = SourceMap::new();
            let _ = lex(&mut map, prog);
        },
        budget_per_stage,
        5,
    );
    let parse_t = time_iters(
        || {
            let mut map = SourceMap::new();
            let lexed = lex(&mut map, prog);
            let _ = parse(&lexed);
        },
        budget_per_stage,
        5,
    );
    let resolve_t = time_iters(
        || {
            let mut map = SourceMap::new();
            let lexed = lex(&mut map, prog);
            let ast = parse(&lexed);
            let _ = resolve_only(&ast);
        },
        budget_per_stage,
        5,
    );
    let typeck_t = time_iters(
        || {
            let mut map = SourceMap::new();
            let lexed = lex(&mut map, prog);
            let ast = parse(&lexed);
            let res = resolve_only(&ast);
            let _ = typeck_only(&ast, &res);
        },
        budget_per_stage,
        5,
    );
    let interp_t = time_iters(
        || {
            let _ = run_full(prog);
        },
        budget_per_stage,
        3,
    );
    StageTimings {
        lex: lex_t,
        parse: parse_t,
        resolve: resolve_t,
        typeck: typeck_t,
        e2e: interp_t,
    }
}

pub struct StageTimings {
    pub lex: Timing,
    pub parse: Timing,
    pub resolve: Timing,
    pub typeck: Timing,
    pub e2e: Timing,
}

/// Crude allocator-agnostic "memory footprint" sample for a workload.
/// Times a closure that runs the program once and returns the total
/// time. We deliberately do NOT shell out to ps here — dhat (behind the
/// feature flag) is the authoritative memory channel.
#[must_use]
// elapsed nanos is u128; one workload run fits in u64 ns
#[allow(clippy::cast_possible_truncation)]
pub fn quick_run_ns<F: FnOnce()>(f: F) -> u64 {
    let t = Instant::now();
    f();
    t.elapsed().as_nanos() as u64
}

#[cfg(test)]
mod tests {
    use super::*;
    use klio_runtime::Value;

    /// Pinned size of `Value`. A bump here means a variant grew or a new
    /// variant inflated the discriminant — investigate before bumping.
    #[test]
    fn value_size_is_pinned() {
        let sz = std::mem::size_of::<Value>();
        assert!(
            sz <= 64,
            "Value grew to {sz} bytes; tree-walker cost scales with this, audit before raising the cap"
        );
    }

    #[test]
    fn collect_kt_finds_corpus() {
        let files = collect_kt(&corpus_root());
        assert!(!files.is_empty(), "corpus/ should have at least one .kt");
    }
}

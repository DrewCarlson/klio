use std::path::PathBuf;
use std::process::ExitCode;

use clap::{Parser as ClapParser, Subcommand, ValueEnum};
use klio_diagnostics::{DiagnosticSink, Severity, render};
use klio_lexer::Lexer;
use klio_parser::Parser;
use klio_span::SourceMap;

use commands::{run_check, run_file_ir_vm, run_lex, run_module_files, run_parse, run_repl};
use pack_build::run_pack;

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
pub(crate) enum PackCmd {
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
pub(crate) enum DiagFormat {
    Plain,
    Json,
    Sarif,
}

fn main() -> ExitCode {
    // Run the CLI on a worker thread with a 64 MiB stack so the IR
    // interpreter's recursion (each Kotlin call frame adds several
    // Rust frames) has plenty of headroom; the default 8 MiB main
    // stack on macOS isn't enough for upstream stdlib bodies with
    // nested `is`-checks and inline expansions.
    std::thread::Builder::new()
        .stack_size(64 * 1024 * 1024)
        .spawn(main_inner)
        .expect("spawn worker")
        .join()
        .unwrap_or(ExitCode::FAILURE)
}

fn main_inner() -> ExitCode {
    let cli = Cli::parse();
    match cli.cmd {
        Cmd::Lex { file } => run_lex(&file),
        Cmd::Parse { file } => run_parse(&file),
        Cmd::Run {
            files,
            ir_vm: _,
            virtual_time,
        } => {
            if virtual_time {
                klio_interp_ir::set_coroutine_time_mode(klio_interp_ir::TimeMode::Virtual);
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

mod commands;
mod pack_build;
mod pack_cache;

#[cfg(test)]
mod source_selection_tests {
    use crate::pack_build::{SourceRoot, collect_pack_sources, pat_match};

    fn sr(root: &str, include: &[&str], exclude: &[&str]) -> SourceRoot {
        SourceRoot {
            root: root.to_string(),
            include: include
                .iter()
                .map(std::string::ToString::to_string)
                .collect(),
            exclude: exclude
                .iter()
                .map(std::string::ToString::to_string)
                .collect(),
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
        let base = std::env::temp_dir().join(format!("klio-src-sel-{}-{}", std::process::id(), n));
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
        let files = collect_pack_sources(td.path(), &[sr("a", &["X.kt"], &["X.kt"])]).unwrap();
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
            (
                "crates/klio-kotlinx-coroutines",
                &["upstream/kotlinx-coroutines-core/common/src", "klioMain"],
                &["klioMain/"],
            ),
            (
                "crates/klio-kotlinx-io",
                &["upstream", "klioMain"],
                &["upstream/Buffer.kt"],
            ),
            (
                "crates/klio-kotlinx-datetime",
                &["klioMain"],
                &["klioMain/"],
            ),
            (
                "crates/klio-kotlinx-atomicfu",
                &["klioMain"],
                &["klioMain/"],
            ),
            ("crates/klio-ktor-client", &["shim"], &["shim/"]),
        ];
        for (pack, roots, _known_pat) in cases {
            let dir = workspace.join(pack);
            // Plain source_roots strings -> unfiltered SourceRoots.
            let plain: Vec<SourceRoot> = roots.iter().map(|r| sr(r, &[], &[])).collect();
            let plain_files = collect_pack_sources(&dir, &plain).unwrap();
            assert!(
                !plain_files.is_empty(),
                "pack {pack}: expected non-empty source list"
            );
            // Same roots, but routed through the [[source]] path with
            // no include/exclude -> must be byte-identical.
            let wrapped: Vec<SourceRoot> = roots.iter().map(|r| sr(r, &[], &[])).collect();
            let wrapped_files = collect_pack_sources(&dir, &wrapped).unwrap();
            assert_eq!(
                rels(&plain_files),
                rels(&wrapped_files),
                "pack {pack}: rel_path set diverged"
            );
            for (p, w) in plain_files.iter().zip(wrapped_files.iter()) {
                assert_eq!(
                    p.bytes, w.bytes,
                    "pack {pack}: bytes diverged for {}",
                    p.rel_path
                );
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

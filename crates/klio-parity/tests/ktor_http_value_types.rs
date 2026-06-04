//! Upstream ktor `io.ktor.http` value types consumed verbatim, driven
//! through the real shipping path (build + install the ktor pack, run with
//! the `klio` binary). Exercises `ContentDisposition.parse` /
//! `withParameter`, `ContentType.parse` + `toString`, and `parseHeaderValue`
//! over multi-parameter header strings — the header/content-type layer whose
//! consumption depends on two interpreter fixes:
//!
//!  - a trailing-lambda call (`parse(value) { v, p -> … }`) binding the 2-arg
//!    inline `HeaderValueWithParameters.parse` rather than the 1-arg member
//!    (which would drop the lambda and recurse), and
//!  - `HeaderValueWithParameters.toString()`'s `apply { … parameters … }`
//!    block reading the enclosing `this.parameters` property, not the
//!    same-file top-level `fun parameters(builder)`.

use std::path::{Path, PathBuf};
use std::process::Command;

fn ws_root() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .parent()
        .and_then(|p| p.parent())
        .map(PathBuf::from)
        .expect("workspace root")
}

fn klio_bin() -> PathBuf {
    ws_root().join("target/release/klio")
}

/// Build + install the ktor pack. Idempotent.
fn install_ktor_pack() {
    let bin = klio_bin();
    assert!(
        bin.exists(),
        "target/release/klio missing — run `cargo build -p klio-cli --release` first"
    );
    let dir = ws_root().join("crates").join("klio-ktor-client");
    let out = std::env::temp_dir().join("klio-ktor-http-value-types.klio-pack");
    let b = Command::new(&bin)
        .args(["pack", "build"])
        .arg(&dir)
        .arg("--out")
        .arg(&out)
        .output()
        .expect("spawn klio pack build");
    assert!(
        b.status.success(),
        "pack build failed: {}",
        String::from_utf8_lossy(&b.stderr)
    );
    let i = Command::new(&bin)
        .args(["pack", "install"])
        .arg(&out)
        .output()
        .expect("spawn klio pack install");
    assert!(
        i.status.success(),
        "pack install failed: {}",
        String::from_utf8_lossy(&i.stderr)
    );
}

fn run(file: &Path) -> String {
    let o = Command::new(klio_bin())
        .arg("run")
        .arg(file)
        .output()
        .expect("spawn klio run");
    assert!(
        o.status.success(),
        "klio run failed: {}",
        String::from_utf8_lossy(&o.stderr)
    );
    String::from_utf8(o.stdout).expect("utf8 stdout")
}

#[test]
fn ktor_header_value_types_from_upstream() {
    install_ktor_pack();

    let src = r#"
import io.ktor.http.*

fun main() {
    val cd = ContentDisposition.parse("attachment; filename=\"report.pdf\"; name=upload")
    println("${cd.disposition}|${cd.name}|${cd.parameter(ContentDisposition.Parameters.FileName)}")
    println(ContentDisposition.Attachment.withParameter("filename", "a b.txt"))

    val ct = ContentType.parse("text/plain; charset=utf-8")
    println("${ct.contentType}/${ct.contentSubtype}|${ct.charset()}")
    println(ContentType("application", "json", listOf(HeaderValueParam("q", "0.5"))))

    val parts = parseHeaderValue("a/b; q=0.8; level=1, c/d")
    println("${parts.size}|${parts[0].value}|${parts[0].params.size}")
}
"#;

    let dir = std::env::temp_dir().join("klio_ktor_http_value_types");
    std::fs::create_dir_all(&dir).unwrap();
    let file = dir.join("prog.kt");
    std::fs::write(&file, src).unwrap();

    let got = run(&file);
    assert_eq!(
        got,
        "attachment|upload|report.pdf\n\
         attachment; filename=\"a b.txt\"\n\
         text/plain|UTF-8\n\
         application/json; q=0.5\n\
         2|a/b|2\n",
        "ktor header value-type output drifted"
    );
}

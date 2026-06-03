//! kotlinx.io.files through the real shipping path: build + install the
//! io pack and run a filesystem program with the actual `klio` binary
//! (whose `~/.klio/packs` loader + host `std::fs` bindings are what users
//! get). Exercises Path math, SystemFileSystem create/write/read/append/
//! metadata/delete, and readLine over a file source.

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

fn install_io_pack() {
    let bin = klio_bin();
    assert!(
        bin.exists(),
        "target/release/klio missing — run `cargo build -p klio-cli --release` first"
    );
    let dir = ws_root().join("crates/klio-kotlinx-io");
    let out = std::env::temp_dir().join("klio-kotlinx-io-smoke.klio-pack");
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

fn run_via_binary(file: &Path) -> String {
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
    String::from_utf8_lossy(&o.stdout).into_owned()
}

#[test]
fn files_read_write_metadata_delete() {
    install_io_pack();
    let src = r#"
import kotlinx.io.*
import kotlinx.io.files.*
fun main() {
    val base = "/tmp/klio_files_smoke_rwmd"
    SystemFileSystem.createDirectories(Path(base))
    val f = Path("$base/hello.txt")
    SystemFileSystem.sink(f).buffered().use { it.writeString("hello world\n") }
    println(SystemFileSystem.exists(f))
    val m = SystemFileSystem.metadataOrNull(f)
    println("file=${m?.isRegularFile} size=${m?.size}")
    println(SystemFileSystem.source(f).buffered().use { it.readString() }.trim())
    println(SystemFileSystem.source(f).buffered().use { it.readLine() })
    SystemFileSystem.sink(f, true).buffered().use { it.writeString("line2\n") }
    println(SystemFileSystem.source(f).buffered().use { it.readString() }.trim())
    println("name=${f.name} abs=${f.isAbsolute} dir=${SystemFileSystem.metadataOrNull(Path(base))?.isDirectory}")
    SystemFileSystem.delete(f)
    println(SystemFileSystem.exists(f))
    SystemFileSystem.delete(Path(base))
}
"#;
    let dir = std::env::temp_dir().join("klio_io_files_smoke");
    std::fs::create_dir_all(&dir).unwrap();
    let file = dir.join("files_smoke.kt");
    std::fs::write(&file, src).unwrap();
    let got = run_via_binary(&file);
    assert_eq!(
        got,
        "true\n\
         file=true size=12\n\
         hello world\n\
         hello world\n\
         hello world\nline2\n\
         name=hello.txt abs=true dir=true\n\
         false\n",
    );
}

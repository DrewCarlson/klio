//! Inline stdlib builders (`buildString`/`buildList`/`buildSet`/`buildMap`)
//! invoked from a pack's *own* source, through the real shipping path
//! (build + install a pack, drive it with the `klio` binary).
//!
//! A pack consumer sees the stdlib's two builder overloads
//! (`buildString(block)` / `buildString(capacity, block)`) only as forward
//! stubs at lower time, so an arity-aware bind to the bodied source func is
//! unavailable. Without the implicit-alias route to the host intrinsic the
//! bare-name path picks the 1-arg overload's body and invokes the `capacity`
//! argument as the builder lambda. This locks in the capacity-overload form
//! resolving to the intrinsic actual.

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

fn write(path: &Path, body: &str) {
    std::fs::create_dir_all(path.parent().unwrap()).unwrap();
    std::fs::write(path, body).unwrap();
}

fn install_builder_pack() {
    let bin = klio_bin();
    assert!(bin.exists(), "build the release binary first");
    let dir = std::env::temp_dir().join("klio_builder_pack_src");
    let _ = std::fs::remove_dir_all(&dir);
    write(
        &dir.join("klio.toml"),
        r#"
[library]
id = "com.bld"
version = "1.0.0"
abi = 1
source_roots = ["src"]

[[deps]]
id = "stdlib"
"#,
    );
    // Every builder is called in its `(capacity, block)` overload form —
    // the shape that mis-bound before the fix. `escape` mirrors ktor's
    // `escapeHTML`: a `when` over chars inside a capacity-sized
    // `buildString` whose block appends multi-char replacements.
    write(
        &dir.join("src/core/com/bld/Builders.kt"),
        r#"package com.bld

fun escape(s: String): String = buildString(s.length) {
    for (c in s) {
        when (c) {
            '&' -> append("&amp;")
            '<' -> append("&lt;")
            '>' -> append("&gt;")
            else -> append(c)
        }
    }
}

fun nums(): List<Int> = buildList(3) { add(1); add(2); add(3) }

fun uniq(): Set<Int> = buildSet(4) { add(7); add(7); add(9) }

fun pairs(): Map<String, Int> = buildMap(2) { put("a", 1); put("b", 2) }
"#,
    );

    let out = std::env::temp_dir().join("klio_builder_pack.klio-pack");
    let b = Command::new(&bin)
        .args(["pack", "build"])
        .arg(&dir)
        .arg("--out")
        .arg(&out)
        .output()
        .expect("pack build");
    assert!(
        b.status.success(),
        "pack build: {}",
        String::from_utf8_lossy(&b.stderr)
    );
    let i = Command::new(&bin)
        .args(["pack", "install"])
        .arg(&out)
        .output()
        .expect("pack install");
    assert!(
        i.status.success(),
        "pack install: {}",
        String::from_utf8_lossy(&i.stderr)
    );
}

#[test]
fn inline_builders_from_pack_source() {
    install_builder_pack();

    let dir = std::env::temp_dir().join("klio_builder_pack_run");
    std::fs::create_dir_all(&dir).unwrap();
    let file = dir.join("prog.kt");
    std::fs::write(
        &file,
        r#"import com.bld.*
fun main() {
    println(escape("a<b>c&d"))
    println(nums())
    println(uniq())
    println(pairs())
}
"#,
    )
    .unwrap();

    let o = Command::new(klio_bin())
        .arg("run")
        .arg(&file)
        .output()
        .expect("klio run");
    assert!(
        o.status.success(),
        "klio run failed: {}",
        String::from_utf8_lossy(&o.stderr)
    );
    assert_eq!(
        String::from_utf8_lossy(&o.stdout),
        "a&lt;b&gt;c&amp;d\n[1, 2, 3]\n[7, 9]\n{a=1, b=2}\n",
        "inline builder output drifted; stderr: {}",
        String::from_utf8_lossy(&o.stderr)
    );
}

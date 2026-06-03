//! Cargo-style pack features through the real shipping path: build +
//! install a synthetic two-feature pack and drive it with the actual
//! `klio` binary. Verifies that the core loads by default, a
//! feature-gated package is unavailable until its feature is enabled
//! with `--feature <pack>/<name>`, that `requires`/`deps` expand, and
//! that an unmet feature produces an actionable hint.

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

/// Build + install a synthetic pack `klio.featuretest` with a core
/// package plus a `client` feature and a dependent `client-extra`
/// feature (which `requires` client).
fn install_feature_pack() {
    let bin = klio_bin();
    assert!(bin.exists(), "build the release binary first");
    let dir = std::env::temp_dir().join("klio_feature_pack_src");
    let _ = std::fs::remove_dir_all(&dir);
    write(
        &dir.join("klio.toml"),
        r#"
[library]
id = "com.ft"
version = "1.0.0"
abi = 1
source_roots = ["src"]

[features]
default = []
client = { sources = ["src/client"] }
client-extra = { sources = ["src/extra"], requires = ["client"] }
"#,
    );
    write(
        &dir.join("src/core/com/ft/core/Core.kt"),
        "package com.ft.core\nobject Core { val tag: String = \"core\" }\n",
    );
    write(
        &dir.join("src/client/com/ft/client/Client.kt"),
        "package com.ft.client\nobject Client { val tag: String = \"client\" }\n",
    );
    write(
        &dir.join("src/extra/com/ft/extra/Extra.kt"),
        "package com.ft.extra\nobject Extra { val tag: String = \"extra\" }\n",
    );

    let out = std::env::temp_dir().join("klio_feature_pack.klio-pack");
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

struct Run {
    code: i32,
    stdout: String,
    stderr: String,
}

fn run(tag: &str, src: &str, features: &[&str]) -> Run {
    // Unique file per scenario so nothing clobbers another's program.
    let dir = std::env::temp_dir().join(format!("klio_feature_pack_run_{tag}"));
    std::fs::create_dir_all(&dir).unwrap();
    let file = dir.join("prog.kt");
    std::fs::write(&file, src).unwrap();
    let mut cmd = Command::new(klio_bin());
    cmd.arg("run").arg(&file);
    for f in features {
        cmd.args(["--feature", f]);
    }
    let o = cmd.output().expect("klio run");
    Run {
        code: o.status.code().unwrap_or(-1),
        stdout: String::from_utf8_lossy(&o.stdout).into_owned(),
        stderr: String::from_utf8_lossy(&o.stderr).into_owned(),
    }
}

// One sequential test: these share the global `~/.klio/packs` cache, so
// keeping them in a single function avoids cross-test races.
#[test]
fn pack_feature_selection() {
    install_feature_pack();

    // Core loads by default — no feature needed.
    let core = run("core", "import com.ft.core.Core\nfun main() { println(Core.tag) }", &[]);
    assert_eq!(core.code, 0, "core stderr: {}", core.stderr);
    assert_eq!(core.stdout, "core\n");

    // A gated package is unavailable until its feature is enabled, and
    // the failure carries an actionable hint.
    let gated = run(
        "gated",
        "import com.ft.client.Client\nfun main() { println(Client.tag) }",
        &[],
    );
    assert_ne!(gated.code, 0, "gated should fail without the feature");
    assert!(
        gated.stderr.contains("--feature com.ft/client"),
        "missing feature hint; stderr: {}",
        gated.stderr
    );

    // Enabling the feature makes the gated package resolve.
    let enabled = run(
        "enabled",
        "import com.ft.client.Client\nfun main() { println(Client.tag) }",
        &["com.ft/client"],
    );
    assert_eq!(enabled.code, 0, "enabled stderr: {}", enabled.stderr);
    assert_eq!(enabled.stdout, "client\n");

    // `requires` expands: enabling only `client-extra` transitively
    // activates `client`, so both gated packages resolve.
    let req = run(
        "requires",
        "import com.ft.client.Client\nimport com.ft.extra.Extra\nfun main() { println(Client.tag + Extra.tag) }",
        &["com.ft/client-extra"],
    );
    assert_eq!(req.code, 0, "requires stderr: {}", req.stderr);
    assert_eq!(req.stdout, "clientextra\n");
}

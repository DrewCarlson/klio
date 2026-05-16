fn main() {
    // `cfg(loom)` is a hand-set RUSTFLAGS cfg (the loom convention),
    // not a Cargo feature; register it so the unexpected-cfg lint
    // stays quiet on normal builds.
    println!("cargo::rustc-check-cfg=cfg(loom)");
}

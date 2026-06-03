//! kotlinx.atomicfu atomic-array surface. The array types' bare simple
//! names (`AtomicIntArray` etc.) used to ambiguate with the unimplemented
//! `kotlin.concurrent.atomics` `expect` classes the stdlib pack carried,
//! so a user import failed at runtime; the stdlib pack no longer bundles
//! those array `expect`s.

use std::io::Write;
use std::path::PathBuf;

fn write_src(name: &str, src: &str) -> PathBuf {
    let dir = std::env::temp_dir().join("klio_atomicfu_arrays");
    std::fs::create_dir_all(&dir).expect("mkdir");
    let file = dir.join(format!("{name}.kt"));
    let mut f = std::fs::File::create(&file).expect("create kt");
    f.write_all(src.as_bytes()).expect("write");
    file
}

fn assert_klio(name: &str, src: &str, expected: &str) {
    let file = write_src(name, src);
    let got = klio_parity::run_with_packs(&file)
        .unwrap_or_else(|e| panic!("klio run failed for `{name}`: {e}"));
    assert_eq!(got, expected, "klio output for `{name}` did not match");
}

#[test]
fn atomic_int_array_get_set_and_size() {
    let src = r#"
import kotlinx.atomicfu.AtomicIntArray
fun main() {
    val a = AtomicIntArray(3)
    a[0].value = 42
    a[2].value = 7
    println("${a[0].value},${a[1].value},${a[2].value},${a.size}")
}
"#;
    assert_klio("atomic_int_array", src, "42,0,7,3\n");
}

#[test]
fn atomic_array_of_nulls() {
    let src = r#"
import kotlinx.atomicfu.atomicArrayOfNulls
fun main() {
    val a = atomicArrayOfNulls<String>(4)
    a[0].value = "x"
    println("${a[0].value},${a[1].value},${a.size}")
}
"#;
    assert_klio("atomic_array_of_nulls", src, "x,null,4\n");
}

#[test]
fn locks_run_uncontended() {
    let src = r#"
import kotlinx.atomicfu.locks.reentrantLock
import kotlinx.atomicfu.locks.withLock
import kotlinx.atomicfu.locks.SynchronizedObject
import kotlinx.atomicfu.locks.synchronized
import kotlinx.atomicfu.locks.SynchronousMutex
fun main() {
    val lock = reentrantLock()
    println(lock.withLock { 42 })
    println(synchronized(SynchronizedObject()) { "ok" })
    println(SynchronousMutex().withLock { "done" })
}
"#;
    assert_klio("atomicfu_locks", src, "42\nok\ndone\n");
}

#[test]
fn scalar_atomic_still_works() {
    let src = r#"
import kotlinx.atomicfu.atomic
fun main() {
    val a = atomic(0)
    a.value = 7
    println(a.compareAndSet(7, 9))
    println(a.value)
}
"#;
    assert_klio("scalar_atomic", src, "true\n9\n");
}

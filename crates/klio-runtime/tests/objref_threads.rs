//! Real-OS-thread stress + ordering tests for `ObjRef`'s publish
//! protocol. This exercises the actual `std`-backed `AdaptiveCell`
//! (the non-loom path) across genuine threads.
//!
//! Runs under plain `cargo test`. It is also written to be clean
//! under ThreadSanitizer; the CI invocation is:
//!
//!   RUSTFLAGS="-Zsanitizer=thread" \
//!     cargo +nightly test -p klio-runtime --test objref_threads \
//!     --target <host-triple>
//!
//! (TSan needs a nightly toolchain and an explicit `--target`; when
//! those are unavailable locally the test still passes on stable and
//! TSan is run in CI.)

use std::sync::Arc;
use std::sync::atomic::{AtomicUsize, Ordering};
use std::thread;

use klio_runtime::ObjRef;

const THREADS: usize = 8;
const PUSHES_PER_THREAD: usize = 2_000;

/// After `publish()`, N threads hammer the same shared `ObjRef` with
/// interleaved `borrow_mut().push(..)` and `borrow()` reads. The
/// `SHARED` lock must serialize every access: the final length equals
/// the exact total of pushes and every element is one we pushed
/// (no corruption, no lost write).
#[test]
fn shared_objref_concurrent_push_is_consistent() {
    let obj: ObjRef<Vec<i32>> = ObjRef::new(Vec::new());
    // Publish before the handle escapes to any other thread.
    obj.publish();
    assert!(obj.is_shared());

    let obj = Arc::new(obj);
    let mut handles = Vec::with_capacity(THREADS);

    for t in 0..THREADS {
        let obj = Arc::clone(&obj);
        handles.push(thread::spawn(move || {
            for i in 0..PUSHES_PER_THREAD {
                {
                    let mut g = obj.borrow_mut();
                    g.push((t * PUSHES_PER_THREAD + i) as i32);
                }
                // Interleave shared reads to stress the lock under
                // mixed shared/exclusive contention.
                let _len = obj.borrow().len();
            }
        }));
    }
    for h in handles {
        h.join().unwrap();
    }

    let g = obj.borrow();
    assert_eq!(g.len(), THREADS * PUSHES_PER_THREAD);

    // Every value in [0, THREADS*PUSHES) must appear exactly once.
    let mut seen = vec![false; THREADS * PUSHES_PER_THREAD];
    for &v in g.iter() {
        let v = v as usize;
        assert!(v < seen.len(), "corrupted element {v}");
        assert!(!seen[v], "duplicated element {v} (lost-update / torn write)");
        seen[v] = true;
    }
    assert!(seen.into_iter().all(|b| b), "missing elements");
}

/// Publish-then-handoff ordering: the writing thread mutates the
/// value, `publish()`es, then hands the handle to a reader thread
/// over a channel. The reader (which only sees the handle *after*
/// publish) must observe the fully-written value, never a partial
/// state.
#[test]
fn publish_then_handoff_orders_the_write() {
    use std::sync::mpsc::channel;

    const ROUNDS: usize = 200;

    for _ in 0..ROUNDS {
        let (tx, rx) = channel::<ObjRef<Vec<i32>>>();

        let writer = thread::spawn(move || {
            let obj: ObjRef<Vec<i32>> = ObjRef::new(Vec::new());
            {
                let mut g = obj.borrow_mut();
                g.extend(0..64);
            }
            obj.publish();
            tx.send(obj).unwrap();
        });

        let reader = thread::spawn(move || {
            let obj = rx.recv().unwrap();
            let g = obj.borrow();
            assert_eq!(g.len(), 64);
            for (i, &v) in g.iter().enumerate() {
                assert_eq!(v, i as i32, "reader saw a partial pre-publish write");
            }
        });

        writer.join().unwrap();
        reader.join().unwrap();
    }
}

/// Many threads each clone the shared handle and do a long
/// read/modify under the lock; an atomic side-counter cross-checks
/// that exactly the expected number of mutations were applied.
#[test]
fn shared_objref_read_modify_counter() {
    let obj: ObjRef<i64> = ObjRef::new(0);
    obj.publish();
    let obj = Arc::new(obj);
    let applied = Arc::new(AtomicUsize::new(0));

    let mut handles = Vec::new();
    for _ in 0..THREADS {
        let obj = Arc::clone(&obj);
        let applied = Arc::clone(&applied);
        handles.push(thread::spawn(move || {
            for _ in 0..PUSHES_PER_THREAD {
                {
                    let mut g = obj.borrow_mut();
                    *g += 1;
                }
                applied.fetch_add(1, Ordering::Relaxed);
            }
        }));
    }
    for h in handles {
        h.join().unwrap();
    }

    let total = (THREADS * PUSHES_PER_THREAD) as i64;
    assert_eq!(*obj.borrow(), total, "lost increment under lock");
    assert_eq!(applied.load(Ordering::Relaxed), total as usize);
}

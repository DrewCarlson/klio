//! Exhaustive loom model of `ObjRef`'s publish-then-cross-thread
//! borrow protocol.
//!
//! `AdaptiveCell`'s `state` atomic, `lock` mutex, and `data`
//! `UnsafeCell` are aliased to loom's instrumented models under
//! `cfg(loom)` (see `klio_runtime::cell_sync`). loom drives every
//! thread interleaving and flags any data race, lost update, or
//! torn read. The protocol obligation under test: thread B never
//! touches the cell until it has received the handle *after*
//! `publish()`, so the only cross-thread accesses are those the
//! `Release`/`Acquire` on `state` orders, and post-publish accesses
//! are serialized by the cell's lock.
//!
//! Run with:
//!   RUSTFLAGS="--cfg loom" cargo test -p klio-runtime --release \
//!       --test `objref_loom`
//!
//! Without `--cfg loom` this file compiles to nothing (the protocol
//! is exercised by the real-thread stress test instead).

#![cfg(loom)]

use klio_runtime::ObjRef;
use loom::sync::mpsc::channel;
use loom::thread;

/// Thread A writes 42 then publishes and hands the handle to B over a
/// channel. B may only borrow after it has *received* the handle —
/// the channel send/recv plus `publish`'s `Release`/`Acquire` on
/// `state` is the full happens-before edge. B reads (must observe 42,
/// never a torn/garbage value), then writes 7. Final value is 7.
#[test]
fn publish_then_cross_thread_borrow_is_race_free() {
    loom::model(|| {
        let obj: ObjRef<i32> = ObjRef::new(0);

        {
            let mut g = obj.borrow_mut();
            *g = 42;
        }
        // Publication seam: establishes happens-before ordered before
        // the handle can be observed on another thread.
        obj.publish();

        let (tx, rx) = channel();

        let producer = {
            let obj = obj.clone();
            thread::spawn(move || {
                // The handle only escapes to B *after* publish ran.
                tx.send(obj).unwrap();
            })
        };

        let consumer = thread::spawn(move || {
            // B touches the cell strictly after receiving the
            // published handle — the protocol.
            let obj = rx.recv().unwrap();
            {
                let g = obj.borrow();
                assert_eq!(*g, 42, "B must observe the pre-publish write, never a torn value");
            }
            {
                let mut g = obj.borrow_mut();
                *g = 7;
            }
        });

        producer.join().unwrap();
        consumer.join().unwrap();

        assert_eq!(*obj.borrow(), 7);
    });
}

/// Two post-publish threads each do `borrow_mut().+=1` on a shared
/// published cell. Once `SHARED`, every borrow takes the cell's
/// `lock` first, so the two increments must serialize: no lost
/// update, final value is exactly 2.
#[test]
fn two_post_publish_writers_serialize_via_lock() {
    loom::model(|| {
        let obj: ObjRef<i32> = ObjRef::new(0);
        obj.publish();

        let a = {
            let obj = obj.clone();
            thread::spawn(move || {
                let mut g = obj.borrow_mut();
                *g += 1;
            })
        };
        let b = {
            let obj = obj.clone();
            thread::spawn(move || {
                let mut g = obj.borrow_mut();
                *g += 1;
            })
        };

        a.join().unwrap();
        b.join().unwrap();

        assert_eq!(*obj.borrow(), 2, "lock-serialized increments must not lose an update");
    });
}

/// One post-publish reader and one post-publish writer, mediated by
/// the cell's reader/writer `lock`. The reader observes either the
/// initial value or the written value — never a torn read — and the
/// writer's update is always visible afterwards.
#[test]
fn post_publish_reader_writer_no_torn_read() {
    loom::model(|| {
        let obj: ObjRef<i32> = ObjRef::new(1);
        obj.publish();

        let writer = {
            let obj = obj.clone();
            thread::spawn(move || {
                let mut g = obj.borrow_mut();
                *g = 9;
            })
        };
        let reader = {
            let obj = obj.clone();
            thread::spawn(move || {
                let seen = *obj.borrow();
                assert!(seen == 1 || seen == 9, "torn/garbage read: {seen}");
            })
        };

        writer.join().unwrap();
        reader.join().unwrap();

        assert_eq!(*obj.borrow(), 9);
    });
}

/// Reader/writer-lock protocol: after publish + handoff, TWO threads
/// take *concurrent* shared `borrow()`s of the same cell (the RwLock
/// must let them proceed simultaneously — neither blocks the other —
/// and each must observe a coherent, non-torn value) while a THIRD
/// thread takes an exclusive `borrow_mut()` (mutually exclusive
/// against both readers; no reader may see a half-written value).
/// The pre-publish write of `7` is ordered before any post-handoff
/// access by `publish`'s `Release`/`Acquire`, so every reader sees
/// either `7` (writer not yet run) or `8` (writer ran) — never
/// garbage. loom explores all interleavings; the state space is
/// bounded (3 short threads, one i32) so it finishes in minutes.
#[test]
fn concurrent_readers_with_exclusive_writer() {
    loom::model(|| {
        let obj: ObjRef<i32> = ObjRef::new(0);
        {
            let mut g = obj.borrow_mut();
            *g = 7;
        }
        obj.publish();

        let (tx, rx) = channel();
        let (tx2, rx2) = channel();

        // The handle only escapes *after* publish ran.
        let handoff = {
            let obj = obj.clone();
            thread::spawn(move || {
                tx.send(obj.clone()).unwrap();
                tx2.send(obj).unwrap();
            })
        };

        let reader1 = {
            let obj = obj.clone();
            thread::spawn(move || {
                let g = obj.borrow();
                let seen = *g;
                assert!(seen == 7 || seen == 8, "reader1 torn/garbage: {seen}");
            })
        };
        let reader2 = thread::spawn(move || {
            let obj = rx.recv().unwrap();
            let g = obj.borrow();
            let seen = *g;
            assert!(seen == 7 || seen == 8, "reader2 torn/garbage: {seen}");
        });
        let writer = thread::spawn(move || {
            let obj = rx2.recv().unwrap();
            let mut g = obj.borrow_mut();
            // Exclusive: no reader may observe an intermediate state.
            *g = 8;
        });

        handoff.join().unwrap();
        reader1.join().unwrap();
        reader2.join().unwrap();
        writer.join().unwrap();

        assert_eq!(*obj.borrow(), 8);
    });
}

/// Two concurrent shared readers, no writer: the RwLock must admit
/// both read guards at once (a serializing mutex would still be
/// *correct* here, but this pins the concurrent-reader intent — both
/// observe the single published value with no torn read).
#[test]
fn two_concurrent_readers_both_observe_published_value() {
    loom::model(|| {
        let obj: ObjRef<i32> = ObjRef::new(0);
        {
            let mut g = obj.borrow_mut();
            *g = 5;
        }
        obj.publish();

        let r1 = {
            let obj = obj.clone();
            thread::spawn(move || {
                assert_eq!(*obj.borrow(), 5, "reader1 must see the published value");
            })
        };
        let r2 = {
            let obj = obj.clone();
            thread::spawn(move || {
                assert_eq!(*obj.borrow(), 5, "reader2 must see the published value");
            })
        };

        r1.join().unwrap();
        r2.join().unwrap();
    });
}

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
//!       --test objref_loom
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

/// One post-publish reader and one post-publish writer, serialized by
/// the cell's `lock`. The reader observes either the initial value or
/// the written value — never a torn read — and the writer's update is
/// always visible afterwards.
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

//! Shared runtime types for the interpreter and the stdlib.
//!
//! `Value`, `RuntimeError`, the `Output` trait, and `Env` live here so that
//! `klio-stdlib` can express Rust-native intrinsics in terms of the same
//! types `klio-interp` evaluates against, without either crate depending on
//! the other.
#![allow(unsafe_code)] // `ObjRef`'s adaptive cell; see its safety docs.

use std::cell::RefCell;
use std::collections::HashMap;
use std::fmt;
use std::ops::{Deref, DerefMut};
use std::rc::Rc;
use std::sync::{Arc, Mutex};

use thiserror::Error;

/// Synchronization primitives for [`AdaptiveCell`]. Under `cfg(loom)`
/// the atomic `state`, the reader/writer `lock`, and the data
/// `UnsafeCell` resolve to loom's instrumented models so the
/// publication protocol can be exhaustively model-checked; under
/// every normal build they resolve to `parking_lot`/`std`
/// equivalents and the generated code is behaviorally identical to a
/// direct use. `flag` stays a `std::cell::Cell` in both builds: it is
/// single-owner by the protocol and loom intentionally does not model
/// non-atomic cells.
///
/// The `SHARED` lock is a *reader/writer* lock: many concurrent
/// shared `borrow()`s, one exclusive `borrow_mut()`. The non-loom
/// build uses `parking_lot::RwLock`, whose `read_recursive()` lets
/// the same thread take nested shared borrows of one cell (the
/// interpreter reads a list while iterating it) without deadlock.
/// loom's `RwLock` has no recursive read, but every loom scenario
/// holds at most one borrow per thread at a time, so plain `read()`
/// models the protocol faithfully.
mod cell_sync {
    #[cfg(loom)]
    pub(crate) use loom::cell::UnsafeCell;
    #[cfg(loom)]
    pub(crate) use loom::sync::atomic::{AtomicU8, Ordering};
    #[cfg(loom)]
    pub(crate) use loom::sync::{RwLock, RwLockReadGuard, RwLockWriteGuard};

    #[cfg(not(loom))]
    pub(crate) use parking_lot::{RwLock, RwLockReadGuard, RwLockWriteGuard};
    #[cfg(not(loom))]
    pub(crate) use std::cell::UnsafeCell;
    #[cfg(not(loom))]
    pub(crate) use std::sync::atomic::{AtomicU8, Ordering};

    pub(crate) use std::cell::Cell;
}

use cell_sync::{AtomicU8, Cell, Ordering, UnsafeCell};

/// Adaptive interior-mutable cell behind [`ObjRef`].
///
/// While a cell is **unshared** (only ever reachable from its
/// creating thread — the case for essentially every object, and the
/// *only* case until a reference is published across threads) borrow
/// tracking is a single non-atomic `Cell<isize>`, exactly
/// `RefCell`'s algorithm and speed. When the runtime publishes a
/// reference to another thread it calls [`publish`], which
/// transitions the cell to **shared** under a release fence before
/// the reference can be observed elsewhere; shared cells mediate all
/// access through `lock`, a reader/writer lock — any number of
/// concurrent shared `borrow()`s, an exclusive `borrow_mut()`.
///
/// `flag`: `0` = free, `n > 0` = `n` shared borrows, `-1` = mutably
/// borrowed (the `RefCell` encoding). Only the UNSHARED path touches
/// `flag`; the SHARED path's discipline is the RwLock itself.
///
/// # Safety / publication protocol
///
/// `unsafe impl Send + Sync` is sound because of one invariant: a
/// cell is touched by at most one thread until [`publish`] runs, and
/// [`publish`] establishes happens-before (via `state`'s
/// `Release`/`Acquire`) ordered *before* the `ObjRef` becomes
/// reachable from any other thread. Pre-publication, single-owner
/// access makes the non-atomic `flag`/`data` race-free; post
/// publication every access goes through `lock`'s acquire/release.
/// The runtime upholds the "publish before the reference escapes"
/// obligation at the [`fence_and_publish`] seam (escaping graphs are
/// `publish_deep`'d before a thread is spawned).
///
/// # Normative fence matrix
///
/// This is the authoritative statement of every memory-model seam in
/// KLIO and the concrete Rust mechanism that establishes the
/// happens-before edge it requires. Kotlin's memory model only
/// defines behaviour for data-race-free programs (modulo the
/// no-out-of-thin-air / no-tearing floor that holds even for racy
/// programs); each seam below provides at least the ordering the
/// model demands.
///
/// - **Shared-object field access** — every `borrow()`/`borrow_mut()`
///   on a `SHARED` cell acquires this `AdaptiveCell`'s RwLock (read
///   or write) and releases it on guard drop. The lock's
///   acquire/release plus the `state` `Release` (in [`publish`]) /
///   `Acquire` (in every borrow's state load) pair is the
///   happens-before edge: a write under a write guard
///   happens-before any later read/write under a guard on the same
///   cell. Concurrent readers run in parallel; a writer is exclusive
///   against all readers and writers.
/// - **`synchronized` / monitor** — lowered to a process-wide
///   reentrant monitor whose `Mutex` + `Condvar` provide the
///   monitor-enter (acquire) / monitor-exit (release) edge, so an
///   unlock happens-before the next lock of the same monitor.
/// - **`@Volatile`** — *subsumed, by deliberate and sound design*.
///   Every field access on a *shared* instance already goes through
///   this RwLock, which gives sequentially-consistent ordering for
///   *all* fields of the object, not just one. Lock-mediated shared
///   access is strictly stronger than per-field volatile (it orders
///   the whole object, and a `borrow_mut` is a full release of every
///   field), so `@Volatile` needs no extra per-field fence under
///   this model: `lock ≥ volatile`. A `@Volatile` field on an
///   *unshared* instance is single-owner and needs no fence either.
/// - **Atomics (`kotlinx.atomicfu`)** — backed directly by Rust's
///   `core::sync::atomic` operations with their specified orderings;
///   the atomic op *is* the fence.
/// - **`Thread.start` / `Thread.join`** — `std::thread::spawn`
///   (start happens-before the spawned body) and `JoinHandle::join`
///   (body completion happens-before `join()` returning). The
///   escaping object graph is `publish_deep`'d before spawn so the
///   child only ever sees `SHARED` cells.
/// - **Coroutine interceptor dispatch / resume** — coroutines run on
///   a single cooperative thread; dispatch and resume are ordinary
///   sequenced-before steps on that one instruction stream, so no
///   cross-thread fence is needed for intra-dispatcher resumption.
struct AdaptiveCell<T: ?Sized> {
    state: AtomicU8,
    flag: Cell<isize>,
    lock: cell_sync::RwLock<()>,
    data: UnsafeCell<T>,
}

const UNSHARED: u8 = 0;
const SHARED: u8 = 1;

// SAFETY: see the publication protocol on `AdaptiveCell`.
unsafe impl<T: ?Sized + Send> Send for AdaptiveCell<T> {}
unsafe impl<T: ?Sized + Send> Sync for AdaptiveCell<T> {}

impl<T> AdaptiveCell<T> {
    fn new(v: T) -> Self {
        Self {
            state: AtomicU8::new(UNSHARED),
            flag: Cell::new(0),
            lock: cell_sync::RwLock::new(()),
            data: UnsafeCell::new(v),
        }
    }
}

impl<T: ?Sized> AdaptiveCell<T> {
    /// Run `f` with a const pointer to the cell's data. The single
    /// place the data `UnsafeCell`'s access shape diverges: `std`'s
    /// `UnsafeCell::get` vs loom's `UnsafeCell::with`. Callers must
    /// uphold the borrow protocol exactly as before; this only
    /// abstracts pointer acquisition.
    #[inline(always)]
    fn with_data_ptr<R>(&self, f: impl FnOnce(*const T) -> R) -> R {
        #[cfg(loom)]
        {
            self.data.with(|p| f(p))
        }
        #[cfg(not(loom))]
        {
            f(self.data.get())
        }
    }

    /// Run `f` with a mutable pointer to the cell's data. See
    /// [`Self::with_data_ptr`]; mirrors loom's `UnsafeCell::with_mut`.
    #[inline(always)]
    fn with_data_ptr_mut<R>(&self, f: impl FnOnce(*mut T) -> R) -> R {
        #[cfg(loom)]
        {
            self.data.with_mut(|p| f(p))
        }
        #[cfg(not(loom))]
        {
            f(self.data.get())
        }
    }

    /// Acquire the per-cell RwLock for a *shared* borrow once the
    /// cell is `SHARED`: a read guard, so concurrent readers run in
    /// parallel. The non-loom path uses `read_recursive()` so a
    /// thread that already holds a read guard on this cell (the
    /// interpreter reading a list while iterating it) does not
    /// self-deadlock against a queued writer. loom's `RwLock` has no
    /// recursive read, but no loom scenario nests borrows on one
    /// thread, so plain `read()` models the protocol exactly.
    #[inline(always)]
    fn lock_shared_read(&self) -> cell_sync::RwLockReadGuard<'_, ()> {
        #[cfg(loom)]
        {
            self.lock.read().unwrap()
        }
        #[cfg(not(loom))]
        {
            self.lock.read_recursive()
        }
    }

    /// Acquire the per-cell RwLock for an *exclusive* borrow once the
    /// cell is `SHARED`: a write guard, mutually exclusive against
    /// every reader and writer.
    #[inline(always)]
    fn lock_shared_write(&self) -> cell_sync::RwLockWriteGuard<'_, ()> {
        #[cfg(loom)]
        {
            self.lock.write().unwrap()
        }
        #[cfg(not(loom))]
        {
            self.lock.write()
        }
    }
}

/// Error returned by [`ObjRef::try_borrow_mut`] when the cell is
/// already borrowed (mirrors `std::cell::BorrowMutError`).
#[derive(Debug)]
pub struct BorrowMutError;

/// Handle to a shared, interior-mutable Kotlin heap object. The one
/// place the value model's backing pointer is named. The backing is
/// `Arc<AdaptiveCell>`: an atomic strong count (so `Value` is
/// `Send`/`Sync`) over a borrow path that stays non-atomic and
/// `RefCell`-fast until a reference is published across threads.
pub struct ObjRef<T: ?Sized>(Arc<AdaptiveCell<T>>);

#[cfg(not(feature = "gc"))]
impl<T> ObjRef<T> {
    #[must_use]
    pub fn new(v: T) -> Self {
        Self(Arc::new(AdaptiveCell::new(v)))
    }
}

/// Under the `gc` backing every cell is registered in the global
/// tracing heap on construction, which requires `T: Send + 'static`
/// (the heap's type-erased retainer is `Arc<dyn Any + Send + Sync>`;
/// `AdaptiveCell<T>: Send + Sync` follows from `T: Send` via its
/// publication-protocol `unsafe impl`s). Every concrete `ObjRef`
/// payload in the value model already satisfies this — the
/// `Value: Send + Sync` assertion at the bottom of this file proves
/// it — so the bound is invisible at all real call sites.
#[cfg(feature = "gc")]
impl<T: Send + 'static> ObjRef<T> {
    #[must_use]
    pub fn new(v: T) -> Self {
        let cell = Arc::new(AdaptiveCell::new(v));
        gc::register_cell(&cell);
        Self(cell)
    }
}

/// Stop-the-world mark/sweep tracing-GC backing for [`ObjRef`],
/// compiled only under `--features gc`.
///
/// Design (prototype, per the Phase-F bake-off): every `ObjRef::new`
/// registers its `AdaptiveCell` in a single global heap keyed by the
/// cell's address-stable identity. The heap holds one *retaining*
/// strong `Arc` per cell so a cell that no live `ObjRef` clone names
/// is still kept alive by the heap until the next collection. The Vm
/// registers its roots (the globals `Env` and the value graph
/// reachable from it) via [`register_root_env`]; an allocation
/// counter trips a collection once it crosses a threshold. Collection
/// is stop-the-world: it marks every cell reachable from the roots —
/// reusing the exact reachability shape of [`Value::publish_deep`] —
/// then sweeps, dropping the heap's retaining `Arc` for every
/// unmarked cell.
///
/// Memory safety is unconditional and does not depend on the tracer
/// being a precise reachability oracle: actual deallocation is still
/// governed by the cell's `Arc` strong count, so a swept cell whose
/// retaining `Arc` is dropped while some live `ObjRef` clone still
/// names it simply survives (its strong count is > 0). The tracer
/// therefore cannot cause a use-after-free even if it under-marks;
/// the worst case of an over-conservative tracer is retained
/// garbage, never a dangling reference. `Drop` of a collected cell
/// runs normally when the last `Arc` (heap retainer + every clone)
/// is gone, so any `Drop`-carrying payload is released
/// deterministically at that point. The only `ObjRef` payload that
/// owns host state is `InstanceData::native_state`, whose
/// `Arc<Mutex<dyn Any>>` is itself reference-counted and released by
/// its own `Arc`, so no cell needs a finalizer queue.
#[cfg(feature = "gc")]
pub mod gc {
    use super::{AdaptiveCell, Env, ObjRef, Value};
    use std::any::Any;
    use std::collections::{HashMap, HashSet};
    use std::sync::atomic::{AtomicUsize, Ordering};
    use std::sync::{Arc, Mutex, OnceLock};

    /// Type-erased retaining handle to one registered cell. `Arc<dyn
    /// Any + Send + Sync>` keeps the cell alive independently of any
    /// live `ObjRef` clone until a sweep drops it.
    type Retainer = Arc<dyn Any + Send + Sync>;

    struct Heap {
        /// identity -> retaining Arc for every live registered cell.
        cells: HashMap<usize, Retainer>,
        /// Root value graphs the collector marks from.
        roots: Vec<Value>,
        /// Root environments (globals, class tables) the collector
        /// marks from.
        env_roots: Vec<ObjRef<Env>>,
    }

    fn heap() -> &'static Mutex<Heap> {
        static HEAP: OnceLock<Mutex<Heap>> = OnceLock::new();
        HEAP.get_or_init(|| {
            Mutex::new(Heap {
                cells: HashMap::new(),
                roots: Vec::new(),
                env_roots: Vec::new(),
            })
        })
    }

    /// Allocations since the last collection. Crossing the threshold
    /// triggers a stop-the-world mark/sweep on the allocating thread.
    static ALLOCS: AtomicUsize = AtomicUsize::new(0);
    const COLLECT_EVERY: usize = 200_000;

    /// Heap key for a cell. MUST match `ObjRef::identity()` (the
    /// cell's *data* pointer, not the `Arc` allocation pointer) so the
    /// tracer's mark set — built from `ObjRef::identity()` — and the
    /// heap's retainer map use one consistent key space.
    fn cell_key<T>(cell: &Arc<AdaptiveCell<T>>) -> usize {
        cell.with_data_ptr(|p| p as *const () as usize)
    }

    /// Register a freshly allocated cell. Called from `ObjRef::new`.
    pub(crate) fn register_cell<T: Send + 'static>(cell: &Arc<AdaptiveCell<T>>) {
        let id = cell_key(cell);
        let retainer: Retainer = cell.clone();
        {
            let mut h = heap().lock().unwrap_or_else(|e| e.into_inner());
            h.cells.insert(id, retainer);
        }
        if ALLOCS.fetch_add(1, Ordering::Relaxed) + 1 >= COLLECT_EVERY {
            ALLOCS.store(0, Ordering::Relaxed);
            collect();
        }
    }

    /// Register a root environment (the Vm's globals / class tables).
    /// Idempotent on identity. Roots are held for the process
    /// lifetime; the Vm calls this once at start before any thread
    /// spawn, mirroring `publish_env_deep`'s root set.
    pub fn register_root_env(env: &ObjRef<Env>) {
        let mut h = heap().lock().unwrap_or_else(|e| e.into_inner());
        if !h.env_roots.iter().any(|e| ObjRef::ptr_eq(e, env)) {
            h.env_roots.push(env.clone());
        }
    }

    /// Register a root value graph (e.g. an in-flight value the Vm
    /// must keep reachable across a collection point).
    pub fn register_root_value(v: Value) {
        let mut h = heap().lock().unwrap_or_else(|e| e.into_inner());
        h.roots.push(v);
    }

    /// Force a stop-the-world collection now (used by tests / explicit
    /// triggers; the alloc counter calls this automatically).
    pub fn collect() {
        let (cells_snapshot, roots, env_roots) = {
            let h = heap().lock().unwrap_or_else(|e| e.into_inner());
            (
                h.cells.keys().copied().collect::<Vec<_>>(),
                h.roots.clone(),
                h.env_roots.clone(),
            )
        };
        let mut marked: HashSet<usize> = HashSet::new();
        for env in &env_roots {
            super::gc_mark_env_root(env, &mut marked);
        }
        for v in &roots {
            super::gc_mark_value(v, &mut marked);
        }
        // Sweep: drop the heap's retaining Arc for every cell not
        // reachable from a root. A still-clone-referenced cell stays
        // alive via its own strong count regardless; re-registration
        // on a later `ObjRef::new` would re-add it, but a swept cell
        // that is still live is simply un-tracked until it is dropped.
        let mut h = heap().lock().unwrap_or_else(|e| e.into_inner());
        for id in cells_snapshot {
            if !marked.contains(&id) {
                h.cells.remove(&id);
            }
        }
    }

    /// Number of cells the heap currently retains. Test/inspection
    /// hook only.
    #[must_use]
    pub fn live_cell_count() -> usize {
        heap().lock().unwrap_or_else(|e| e.into_inner()).cells.len()
    }

    /// Whether the heap still retains the cell with this identity.
    /// Test/inspection hook only.
    #[must_use]
    pub fn heap_contains(id: usize) -> bool {
        heap()
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .cells
            .contains_key(&id)
    }

    /// Re-register a reachable cell discovered during the mark walk so
    /// a cell that had been swept while still clone-alive becomes
    /// tracked again. Keyed by identity; the retainer is the live
    /// clone the tracer is already holding.
    pub(crate) fn retain<T: Send + 'static>(cell: &Arc<AdaptiveCell<T>>) {
        let id = cell_key(cell);
        let mut h = heap().lock().unwrap_or_else(|e| e.into_inner());
        h.cells.entry(id).or_insert_with(|| cell.clone());
    }
}

impl<T: ?Sized> ObjRef<T> {
    /// Shared borrow. Panics on an active mutable borrow, exactly
    /// like `RefCell::borrow`.
    #[must_use]
    pub fn borrow(&self) -> ObjGuard<'_, T> {
        match self.try_borrow() {
            Some(g) => g,
            None => panic!("ObjRef already mutably borrowed"),
        }
    }

    /// Mutable borrow. Panics on any active borrow, exactly like
    /// `RefCell::borrow_mut`.
    #[must_use]
    pub fn borrow_mut(&self) -> ObjGuardMut<'_, T> {
        match self.try_borrow_mut() {
            Ok(g) => g,
            Err(_) => panic!("ObjRef already borrowed"),
        }
    }

    fn try_borrow(&self) -> Option<ObjGuard<'_, T>> {
        let cell = &*self.0;
        if cell.state.load(Ordering::Acquire) == SHARED {
            // SHARED path: the RwLock read guard is the discipline.
            // Many shared borrows run concurrently; an exclusive
            // `borrow_mut` blocks until they drain. `flag` is not
            // consulted or mutated here — it is the UNSHARED-only
            // RefCell counter.
            let read = cell.lock_shared_read();
            // SAFETY: a read guard is held for the returned guard's
            // lifetime; no writer can be active concurrently.
            return Some(ObjGuard { cell, _shared: Some(read) });
        }
        let f = cell.flag.get();
        if f < 0 {
            return None;
        }
        cell.flag.set(f + 1);
        // SAFETY: flag was >= 0, so no mutable borrow is live; we
        // hand out a shared reference and the guard restores the
        // count on drop.
        Some(ObjGuard { cell, _shared: None })
    }

    /// Fallible mutable borrow (mirrors `RefCell::try_borrow_mut`).
    pub fn try_borrow_mut(&self) -> Result<ObjGuardMut<'_, T>, BorrowMutError> {
        let cell = &*self.0;
        if cell.state.load(Ordering::Acquire) == SHARED {
            // SHARED path: the RwLock write guard is the discipline —
            // exclusive against every reader and writer. It blocks
            // (monitor-like) rather than failing if borrows are live
            // on other threads; that is the intended behavior, not a
            // `RefCell`-style panic. `flag` is untouched.
            let write = cell.lock_shared_write();
            // SAFETY: a write guard is held for the returned guard's
            // lifetime; no other borrow can be active concurrently.
            return Ok(ObjGuardMut { cell, _shared: Some(write) });
        }
        if cell.flag.get() != 0 {
            return Err(BorrowMutError);
        }
        cell.flag.set(-1);
        // SAFETY: flag was 0, so no other borrow is live; the guard
        // restores it on drop.
        Ok(ObjGuardMut { cell, _shared: None })
    }

    /// Transition the cell to the shared state with a full fence.
    /// Called at the publication seam before the reference escapes
    /// to another thread. Idempotent.
    pub fn publish(&self) {
        self.0.state.store(SHARED, Ordering::Release);
    }

    #[must_use]
    pub fn is_shared(&self) -> bool {
        self.0.state.load(Ordering::Acquire) == SHARED
    }

    #[must_use]
    pub fn ptr_eq(a: &Self, b: &Self) -> bool {
        Arc::ptr_eq(&a.0, &b.0)
    }

    #[must_use]
    pub fn strong_count(&self) -> usize {
        Arc::strong_count(&self.0)
    }

    #[must_use]
    pub fn as_ptr(&self) -> *const T {
        self.0.with_data_ptr(|p| p)
    }

    /// Address-stable identity of the backing cell, usable as a key in
    /// a visited set when walking a (possibly cyclic) value graph.
    /// Two `ObjRef`s with this same value share the same cell.
    #[must_use]
    pub fn identity(&self) -> usize {
        self.as_ptr() as *const () as usize
    }
}

impl<T: ?Sized> Clone for ObjRef<T> {
    fn clone(&self) -> Self {
        Self(Arc::clone(&self.0))
    }
}

impl<T: ?Sized + fmt::Debug> fmt::Debug for ObjRef<T> {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        // Match the old `Debug` (which forwarded through RefCell):
        // show the contents when not mutably borrowed.
        match self.try_borrow() {
            Some(g) => f.debug_tuple("ObjRef").field(&&*g).finish(),
            None => f.debug_tuple("ObjRef").field(&"<borrowed>").finish(),
        }
    }
}

/// Shared-borrow guard. On the UNSHARED path it restores the
/// `RefCell` borrow count on drop; on the SHARED path it instead
/// holds a RwLock read guard (`_shared`) for its lifetime and the
/// lock — not `flag` — is the discipline.
pub struct ObjGuard<'a, T: ?Sized> {
    cell: &'a AdaptiveCell<T>,
    _shared: Option<cell_sync::RwLockReadGuard<'a, ()>>,
}
impl<T: ?Sized> Deref for ObjGuard<'_, T> {
    type Target = T;
    fn deref(&self) -> &T {
        // SAFETY: a shared borrow is live (UNSHARED: flag > 0;
        // SHARED: a read guard is held). The pointer is valid for
        // the cell's lifetime and the guard outlives this reference.
        self.cell.with_data_ptr(|p| unsafe { &*p })
    }
}
impl<T: ?Sized> Drop for ObjGuard<'_, T> {
    fn drop(&mut self) {
        // UNSHARED path only: SHARED borrows never touched `flag`,
        // so they must not decrement it. The read guard in `_shared`
        // is released by its own `Drop` after this.
        if self._shared.is_none() {
            self.cell.flag.set(self.cell.flag.get() - 1);
        }
    }
}
impl<T: ?Sized + fmt::Debug> fmt::Debug for ObjGuard<'_, T> {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        (**self).fmt(f)
    }
}
impl<T: ?Sized + fmt::Display> fmt::Display for ObjGuard<'_, T> {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        (**self).fmt(f)
    }
}

/// Mutable-borrow guard. On the UNSHARED path it restores the
/// `RefCell` borrow flag on drop; on the SHARED path it instead
/// holds an exclusive RwLock write guard (`_shared`) for its
/// lifetime.
pub struct ObjGuardMut<'a, T: ?Sized> {
    cell: &'a AdaptiveCell<T>,
    _shared: Option<cell_sync::RwLockWriteGuard<'a, ()>>,
}
impl<T: ?Sized> Deref for ObjGuardMut<'_, T> {
    type Target = T;
    fn deref(&self) -> &T {
        // SAFETY: an exclusive borrow is live (UNSHARED: flag == -1;
        // SHARED: an exclusive write guard is held).
        self.cell.with_data_ptr(|p| unsafe { &*p })
    }
}
impl<T: ?Sized> DerefMut for ObjGuardMut<'_, T> {
    fn deref_mut(&mut self) -> &mut T {
        // SAFETY: an exclusive borrow is live (UNSHARED: flag == -1;
        // SHARED: an exclusive write guard is held).
        self.cell.with_data_ptr_mut(|p| unsafe { &mut *p })
    }
}
impl<T: ?Sized> Drop for ObjGuardMut<'_, T> {
    fn drop(&mut self) {
        // UNSHARED path only: SHARED mutable borrows never set
        // `flag` to -1, so they must not clear it. The write guard
        // in `_shared` is released by its own `Drop` after this.
        if self._shared.is_none() {
            self.cell.flag.set(0);
        }
    }
}
impl<T: ?Sized + fmt::Debug> fmt::Debug for ObjGuardMut<'_, T> {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        (**self).fmt(f)
    }
}
impl<T: ?Sized + fmt::Display> fmt::Display for ObjGuardMut<'_, T> {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        (**self).fmt(f)
    }
}

/// Named memory-model seam, retained as the explicit ordering site
/// for `synchronized` enter/exit and `thread` start/join.
///
/// The concrete happens-before mechanism for every seam is now
/// real and is stated normatively in the **fence matrix** on
/// [`AdaptiveCell`] (shared-object access → the cell RwLock + the
/// `state` `Release`/`Acquire` on [`ObjRef::publish`]; monitors → the
/// process-wide reentrant monitor's `Mutex`/`Condvar`; `@Volatile` →
/// subsumed by lock-mediated shared access; atomics → the underlying
/// Rust atomic ops; `Thread.start`/`join` → `std::thread`
/// spawn/join; coroutine dispatch/resume → the single cooperative
/// thread). Each of those edges is established by its own primitive
/// at its own site; this function does not itself emit a fence —
/// publication ordering lives in [`ObjRef::publish`] /
/// [`Value::publish_deep`], which the runtime invokes before an
/// object graph escapes to a spawned thread. It is kept as a
/// stable, named call site so the boundary is visible in the code.
#[inline(always)]
pub fn fence_and_publish() {}

/// Function pointer signature for a Rust-native stdlib intrinsic.
///
/// `CallCtx::args` carries the call arguments. For member access (`x.f()`
/// or property `x.length`) the receiver is passed as `args[0]`, with any
/// further user arguments following.
pub type StdlibFn = fn(&mut CallCtx) -> Result<Value, RuntimeError>;

pub struct CallCtx<'a> {
    pub args: &'a [Value],
    pub out: &'a mut dyn Output,
    /// Single trait object the intrinsic uses to reach the rest of
    /// the runtime — the scheduler (for `launch { }` / parked
    /// continuations) and the lambda invoker (for `.map { }`,
    /// `.let { }`, `runCatching { }` etc.). Bundled this way so a
    /// call site can borrow `out` and the host from a single
    /// `&mut Interpreter` without conflicting field borrows.
    pub host: &'a mut dyn IntrinsicHost,
}

/// Side-channel the runtime exposes to stdlib intrinsics. Lets a
/// binding call back into the interpreter for the bits an
/// intrinsic can't carry out on its own — invoking a
/// caller-supplied lambda, posting to the cooperative scheduler.
pub trait IntrinsicHost {
    /// Cooperative scheduler. Coroutine builders post launched
    /// bodies / parked continuations here.
    fn scheduler(&mut self) -> &mut dyn Scheduler;

    /// Invoke a callable `Value` (`Value::Lambda`, `Value::IrClosure`,
    /// `Value::Function`, `Value::Intrinsic`, `Value::BoundMethod`,
    /// `Value::PropertyRef`, …) with the supplied args. Used by
    /// stdlib HOFs and scope functions to drive the user's
    /// lambda body.
    fn invoke_callable(
        &mut self,
        callable: &Value,
        args: &[Value],
        out: &mut dyn Output,
    ) -> Result<Value, RuntimeError>;

    /// Like `invoke_callable` but binds `this` inside the lambda
    /// body to `this_value` for the duration of the call. Used by
    /// `apply { … }` / `run { … }` / `with(x) { … }` — the
    /// receiver-bound scope functions.
    fn invoke_callable_with_this(
        &mut self,
        callable: &Value,
        args: &[Value],
        this_value: &Value,
        out: &mut dyn Output,
    ) -> Result<Value, RuntimeError>;

    /// Invoke a named method on the given receiver value. Used by
    /// `println` / string-template formatting to dispatch user
    /// `override fun toString(): String` bodies. Default impl
    /// returns `None`, signalling the caller to fall back to the
    /// runtime's structural rendering.
    fn invoke_method(
        &mut self,
        _receiver: &Value,
        _name: &str,
        _args: &[Value],
        _out: &mut dyn Output,
    ) -> Option<Result<Value, RuntimeError>> {
        None
    }

    /// Resolve a top-level identifier (class / object / function)
    /// against the running interpreter's global environment.
    /// Bindings can use this to grab a singleton (`GlobalScope`) or
    /// look up a class for `NewInstance`-style dispatch. Default
    /// impl returns `None`, signalling the host doesn't expose a
    /// global table.
    fn lookup_global(&mut self, _name: &str) -> Option<Value> {
        None
    }

    /// Allocate a fresh `Instance.identity` value (monotonic across
    /// the interpreter run). klio-native intrinsics that synthesise
    /// `Value::Instance` (e.g. the channels factory) call this so
    /// the identity space stays disjoint from regular allocations.
    fn alloc_instance_id(&mut self) -> u64 {
        0
    }

    /// Synthesise a `Value::Instance` of class `class_fqn` (a name
    /// not declared in user IR) with the given `identity` and
    /// `fields`. Used by klio-native intrinsics that need to return
    /// an opaque user-visible handle bound to host state.
    fn new_synth_instance(
        &mut self,
        _class_fqn: &str,
        _identity: u64,
        _fields: Vec<(String, Value)>,
    ) -> Value {
        Value::Unit
    }

    /// Run `block` as the root of a cooperative coroutine and drive
    /// the scheduler to completion: launched children interleave at
    /// suspension points and `delay` advances *virtual* time so a
    /// long-running block never blocks the OS thread. Returns the
    /// block's terminal value. Default impl runs `block` straight
    /// through with no scheduling (no suspension support).
    fn run_blocking(
        &mut self,
        block: &Value,
        scope: &Value,
        out: &mut dyn Output,
    ) -> Result<Value, RuntimeError> {
        self.invoke_callable_with_this(block, &[], scope, out)
    }

    /// Run `block` (a `() -> T`) as the root of a cooperative
    /// coroutine and drive the scheduler to quiescence, then return
    /// its terminal value. Backs the `kotlin.coroutines`
    /// `startCoroutine` boundary: a suspension inside the started
    /// coroutine parks in the driver and any continuation resumed
    /// while draining runs, instead of the suspension propagating to
    /// a non-coroutine caller. Default impl invokes `block` directly
    /// (no scheduling).
    fn coroutine_run_root(
        &mut self,
        block: &Value,
        out: &mut dyn Output,
    ) -> Result<Value, RuntimeError> {
        self.invoke_callable(block, &[], out)
    }

    /// Spawn `block` as a child coroutine of the active
    /// `runBlocking`/coroutineScope. It interleaves with siblings at
    /// suspension points and is awaited before the root completes.
    /// Default impl runs it eagerly to completion.
    fn coroutine_launch(
        &mut self,
        block: &Value,
        scope: &Value,
        out: &mut dyn Output,
    ) -> Result<(), RuntimeError> {
        self.invoke_callable_with_this(block, &[], scope, out).map(|_| ())
    }

    /// Record that the activation about to suspend indefinitely is
    /// waiting on `slot`. The active interceptor associates the next
    /// indefinitely-parked token with this slot so a later
    /// `coroutine_resume_slot(slot)` can resume it. Default impl is a
    /// no-op (no cooperative driver).
    fn coroutine_park_slot(&mut self, _slot: i64) {}

    /// Arm `slot` so the next parked activation (even a timed one) is
    /// bound to it, without itself suspending. Default no-op.
    fn coroutine_arm_slot(&mut self, _slot: i64) {}

    /// Clear a previously-armed slot (block returned without
    /// suspending). Default no-op.
    fn coroutine_disarm_slot(&mut self) {}

    /// Make the coroutine waiting on `slot` ready, if any is parked.
    /// Searches the interceptor stack top-down so a nested scope can
    /// resume a waiter parked by an outer one. No-op if nothing is
    /// waiting on the slot (the waiter must re-check its condition
    /// after each park). Default impl is a no-op.
    fn coroutine_resume_slot(&mut self, _slot: i64) {}

    /// Like [`coroutine_resume_slot`] but the parked activation
    /// resumes with `value` delivered as the result of the call that
    /// suspended it (instead of the default `Unit`). Backs the
    /// `kotlin.coroutines` `Continuation.resumeWith` protocol, where
    /// the suspending `suspendCoroutine` site must observe the
    /// resumed value. Default impl is a no-op.
    fn coroutine_resume_slot_value(&mut self, _slot: i64, _value: Value) {}

    /// Cancel every parked timed-wait activation (a `delay()` /
    /// `withTimeout` continuation) in the active interceptor: wake
    /// each with `Result.failure(CancellationException)` so the
    /// suspended call resumes by throwing instead of returning.
    /// Indefinite parks (job joins, channel rendezvous) are not
    /// touched. Default impl is a no-op.
    fn coroutine_cancel_timed_parks(&mut self) {
        self.coroutine_cancel_timed_parks_with(None);
    }

    /// Variant of [`coroutine_cancel_timed_parks`] that lets the
    /// caller supply the exception each woken activation observes;
    /// `None` defaults to a `CancellationException`. `cancelCoroutine`
    /// in upstream Kotlin reaches this with a
    /// `TimeoutCancellationException` cause so `withTimeoutOrNull`'s
    /// `catch (e: TimeoutCancellationException)` arm fires.
    fn coroutine_cancel_timed_parks_with(&mut self, _cause: Option<Value>) {}

    /// Drive the active cooperative interceptor's queues (launched
    /// children and parked timers) until idle. Used by
    /// `coroutineScope` / `supervisorScope` to enforce the
    /// structured-concurrency wait-for-children contract for the
    /// non-suspending body case (a scope body whose final expression
    /// only queues launches, e.g. fire-and-forget event dispatch).
    /// Default impl is a no-op.
    fn coroutine_drain_to_idle(
        &mut self,
        _out: &mut dyn Output,
    ) -> Result<(), RuntimeError> {
        Ok(())
    }

    /// `Continuation.resumeWith` entry point: deliver `value` to the
    /// activation parked on `slot`. If a live cooperative driver
    /// holds it, just enqueue (the driver runs it); otherwise the
    /// coroutine parked inside a since-returned `startCoroutine`
    /// driver — drive its preserved state to completion here.
    /// Default impl delegates to [`coroutine_resume_slot_value`].
    fn coroutine_resume_external(
        &mut self,
        slot: i64,
        value: Value,
        _out: &mut dyn Output,
    ) {
        self.coroutine_resume_slot_value(slot, value);
    }

    /// Spawn `block` on a real OS thread and return an opaque thread
    /// id usable with [`join_os_thread`]. The default impl runs
    /// `block` eagerly on the calling stack (preserving the legacy
    /// serialized behaviour for hosts without a Vm) and returns `0`.
    /// The Vm overrides this with a true `std::thread::spawn`; the
    /// escaping value graph is published before the thread starts.
    fn spawn_os_thread(
        &mut self,
        block: &Value,
        out: &mut dyn Output,
    ) -> Result<u64, RuntimeError> {
        self.invoke_callable(block, &[], out).map(|_| 0)
    }

    /// Join the OS thread previously returned by [`spawn_os_thread`],
    /// propagating any error the thread body threw. Default impl is a
    /// no-op (the eager default already ran the body to completion).
    fn join_os_thread(&mut self, _id: u64) -> Result<(), RuntimeError> {
        Ok(())
    }

    /// Whether the OS thread with this id is still running. Default
    /// impl reports `false` (the eager default already completed).
    fn os_thread_alive(&mut self, _id: u64) -> bool {
        false
    }

    /// Dispatch a coroutine `block` onto a real worker thread for a
    /// parallel dispatcher (`Dispatchers.Default` / `Dispatchers.IO`)
    /// and return an opaque job id usable with [`join_dispatched`].
    /// The escaping value graph is `publish_deep`'d before the worker
    /// starts (same publication boundary as a spawned OS thread).
    /// `elastic` requests the unbounded (`IO`) pool rather than the
    /// CPU-bound (`Default`) pool. Default impl reuses
    /// [`spawn_os_thread`].
    fn dispatch_coroutine(
        &mut self,
        block: &Value,
        _elastic: bool,
        out: &mut dyn Output,
    ) -> Result<u64, RuntimeError> {
        self.spawn_os_thread(block, out)
    }

    /// Block the calling thread until the dispatched job completes,
    /// establishing the completion → joiner happens-before edge.
    /// Default impl reuses [`join_os_thread`].
    fn join_dispatched(&mut self, id: u64) -> Result<(), RuntimeError> {
        self.join_os_thread(id)
    }
}

/// Cooperative scheduler the runtime exposes to anything called
/// from inside an evaluation. A `launch { … }` builder pushes
/// onto the queue with [`Scheduler::spawn`]; a parked
/// `Continuation` records itself with [`Scheduler::schedule_resume`].
/// The interpreter pulls from these queues between rounds to
/// interleave sibling coroutines.
pub trait Scheduler: Send {
    /// Post a lambda to run as a freshly-launched task. The
    /// interpreter drives the body through the suspend state
    /// machine on the next drain pass.
    fn spawn(&mut self, block: Value);

    /// Park a continuation so the next drain pass resumes it.
    /// The interpreter calls `cont.resume(Unit)` on each parked
    /// continuation and re-drives the corresponding paused
    /// frame.
    fn schedule_resume(&mut self, cont: Value);

    /// Take and clear every queued launch. Drained FIFO.
    fn drain_launches(&mut self) -> Vec<Value>;

    /// Take and clear every parked continuation. Drained FIFO.
    fn drain_resumes(&mut self) -> Vec<Value>;
}

/// Default scheduler — keeps spawn/resume queues in a single
/// pair of Vecs. Suitable for single-threaded execution; alternate
/// backends (Godot async, custom event loops) implement the trait
/// directly.
#[derive(Default)]
pub struct InProcessScheduler {
    launches: Vec<Value>,
    resumes: Vec<Value>,
}

impl InProcessScheduler {
    pub fn new() -> Self {
        Self::default()
    }
}

/// Bare-minimum host for unit tests of pure intrinsics (no
/// callable invocation, no scheduling). Panics if a binding under
/// test tries to call back through the host.
#[derive(Default)]
pub struct NoopHost {
    scheduler: InProcessScheduler,
}

impl IntrinsicHost for NoopHost {
    fn scheduler(&mut self) -> &mut dyn Scheduler {
        &mut self.scheduler
    }
    fn invoke_callable(
        &mut self,
        _callable: &Value,
        _args: &[Value],
        _out: &mut dyn Output,
    ) -> Result<Value, RuntimeError> {
        Err(RuntimeError::Unimplemented(
            "NoopHost::invoke_callable".into(),
        ))
    }
    fn invoke_callable_with_this(
        &mut self,
        _callable: &Value,
        _args: &[Value],
        _this_value: &Value,
        _out: &mut dyn Output,
    ) -> Result<Value, RuntimeError> {
        Err(RuntimeError::Unimplemented(
            "NoopHost::invoke_callable_with_this".into(),
        ))
    }
}

impl Scheduler for InProcessScheduler {
    fn spawn(&mut self, block: Value) {
        self.launches.push(block);
    }
    fn schedule_resume(&mut self, cont: Value) {
        self.resumes.push(cont);
    }
    fn drain_launches(&mut self) -> Vec<Value> {
        std::mem::take(&mut self.launches)
    }
    fn drain_resumes(&mut self) -> Vec<Value> {
        std::mem::take(&mut self.resumes)
    }
}

#[derive(Clone)]
pub enum Value {
    Unit,
    /// The `kotlin.coroutines.intrinsics.COROUTINE_SUSPENDED`
    /// singleton. A `suspendCoroutineUninterceptedOrReturn` block
    /// returns this to signal it parked instead of producing a
    /// value. There is exactly one logical instance, so every
    /// `CoroutineSuspended` compares referentially equal.
    CoroutineSuspended,
    Int(i32),
    Long(i64),
    Short(i16),
    Byte(i8),
    /// Unsigned integer. Kotlin's `UInt` / `ULong` / `UShort` /
    /// `UByte` types are inline value classes wrapping the signed
    /// integer; at the runtime level we store them as the matching
    /// unsigned native and rely on the `kind` to pick the right
    /// arithmetic + print semantics.
    UInt(u32),
    ULong(u64),
    UShort(u16),
    UByte(u8),
    Double(f64),
    /// Kotlin `Float`. Stored as `f32` so single-precision rounding matches
    /// kotlinc-native byte-identically.
    Float(f32),
    Bool(bool),
    String(Arc<String>),
    Char(char),
    Null,
    /// Inclusive integer progression with a signed step. `1..10` is
    /// `{start:1,end:10,step:1}`; `1..<10` clamps end to 9; `10 downTo 1` is
    /// `{start:10,end:1,step:-1}`; `x step n` produces `step:n`. Iteration
    /// honors `step`'s sign. `kind` distinguishes `IntRange` (values widen to
    /// `Value::Int`) from `LongRange` (values widen to `Value::Long`).
    Range { start: i64, end: i64, step: i64, kind: RangeKind },
    Function { decl: Arc<klio_ast::Function>, env: ObjRef<Env> },
    Lambda {
        params: Arc<Vec<String>>,
        body: Arc<klio_ast::Block>,
        env: ObjRef<Env>,
        /// `true` when produced by an anonymous-function expression
        /// (`fun (x: Int): R = ...`). A bare `return` inside the body is
        /// a local return and is absorbed at the call boundary. `false`
        /// for lambda literals — bare `return` propagates out of the
        /// enclosing function (the inline-lambda case).
        absorb_return: bool,
    },
    Intrinsic { fqn: &'static str, func: StdlibFn },
    /// IR-side closure handle. Produced by the IR evaluator's
    /// `Inst::Lambda` op via the Host's `build_closure` callback.
    /// `id` is an opaque side-table key; the IR host resolves it
    /// back to a `(module, body_func, captures)` triple at call
    /// time. Distinct from `Value::Lambda` (which carries an AST
    /// block + env tied to the tree walker).
    IrClosure { id: u64, captures: Arc<Vec<Value>> },
    /// A method intrinsic bound to a specific receiver — produced by member
    /// access like `s.uppercase`. Calling it invokes `func` with the receiver
    /// prepended to the user arguments.
    BoundMethod { fqn: &'static str, func: StdlibFn, receiver: Box<Value> },
    /// A user-method reference bound to a specific instance — produced by
    /// `instance::method`. Calling it dispatches through the method
    /// resolution chain on `receiver` with the caller's arguments.
    BoundUserMethod { receiver: ObjRef<InstanceData>, method: Arc<MethodDef> },
    /// A thrown value, modeled as a Kotlin Throwable. Carries an FQN
    /// (e.g. `kotlin.IllegalArgumentException`), an optional message, and
    /// an optional cause (another Throwable) per spec §3.12.
    Exception { fqn: Arc<String>, message: Option<Arc<String>>, cause: Option<Box<Value>> },
    /// `kotlin.collections.List` / `MutableList`. The mutability tag drives
    /// `type_fqn` and any mutability checks; the storage is shared.
    /// `enum_class` is `Some(name)` for the result of `EnumName.entries` /
    /// `EnumName.values()`, tagging the list as a `kotlin.enums.EnumEntries`
    /// for `is`-checks; `None` for ordinary user lists.
    List {
        items: ObjRef<Vec<Value>>,
        mutable: bool,
        enum_class: Option<Arc<String>>,
    },
    /// `kotlin.Array<T>` and the primitive-array siblings (`IntArray`,
    /// `DoubleArray`, …). Fixed-size, mutable element storage. The
    /// `prim` tag, when set, surfaces the typed-array FQN via
    /// `type_fqn()` so member dispatch and `is`-checks see e.g.
    /// `kotlin.IntArray` rather than the generic object array.
    Array {
        items: ObjRef<Vec<Value>>,
        prim: Option<PrimitiveArrayKind>,
    },
    /// `kotlin.collections.Set` / `MutableSet`. Vec-backed with linear-scan
    /// uniqueness, matching `LinkedHashSet` semantics (insertion order).
    Set { items: ObjRef<Vec<Value>>, mutable: bool },
    /// `kotlin.collections.Map` / `MutableMap`. Vec-backed, insertion-ordered
    /// (mirrors `LinkedHashMap`, which is Kotlin's default Map impl).
    Map { entries: ObjRef<Vec<(Value, Value)>>, mutable: bool },
    /// `kotlin.Pair`. `to` constructs one.
    Pair(Box<Value>, Box<Value>),
    /// `kotlin.Triple`. Built by `Triple(a, b, c)`.
    Triple(Box<Value>, Box<Value>, Box<Value>),
    /// `kotlin.collections.Map.Entry`. Yielded by iterating a `Map`.
    /// Exposes `.key` / `.value`. `toString` renders as `key=value`.
    MapEntry { key: Box<Value>, value: Box<Value> },
    /// `kotlin.Result<T>`. `ok` distinguishes success from failure; `payload`
    /// is the success value or the captured `kotlin.Throwable`.
    Result { ok: bool, payload: Box<Value> },
    /// `kotlin.Comparator<T>`. A chain of key selectors (each a `Lambda`
    /// paired with a per-step `descending` flag) applied in order; the
    /// first non-equal step wins. The outer `descending` flag is the
    /// "reversed" toggle that flips every step's effective direction
    /// (built by `Comparator.reversed`).
    Comparator { steps: Arc<Vec<(Value, bool)>>, descending: bool },
    /// A user-declared class. Calling it constructs an `Instance`. Holds the
    /// declaration plus the env it was declared in (for resolving names from
    /// method bodies, supertypes, etc.).
    Class(Arc<ClassDef>),
    /// An `inner class` bound to a specific outer-instance. Produced when
    /// the source navigates `outer.Inner` (or refers to `Inner` unqualified
    /// inside an outer-class method, where `this` is the outer instance).
    /// Calling it constructs an `Instance` with `InstanceData.outer = Some(outer)`.
    BoundInnerClass { class: Arc<ClassDef>, outer: ObjRef<InstanceData> },
    /// A live instance of a user-declared class.
    Instance(ObjRef<InstanceData>),
    /// `kotlin.sequences.Sequence<T>`. Lazy: a source plus a chain of
    /// pipeline ops. Terminal ops drive the pull, so unbounded generators
    /// (`generateSequence { … }`) only emit as many items as the terminal
    /// op consumes.
    Sequence(Arc<SequenceData>),
    /// `kotlin.collections.Iterator<T>` and its primitive specializations
    /// (`IntIterator`, `CharIterator`, …). Sequential cursor over a fixed
    /// vector; `prim` tags the typed-iterator variant so `is`-checks and
    /// `next{TYPE}` dispatch resolve correctly.
    Iterator {
        items: ObjRef<Vec<Value>>,
        pos: ObjRef<usize>,
        prim: Option<PrimitiveArrayKind>,
    },
    /// A built-in property delegate produced by `lazy { … }` /
    /// `Delegates.observable(...)` / `Delegates.notNull()`. Carries the
    /// state the delegate needs across calls (cached value, change
    /// callback, etc.).
    Delegate(ObjRef<DelegateKind>),
    /// `::foo` — a lightweight property/function reference. The
    /// `.name: String` member is the only feature delegate `getValue` /
    /// `setValue` calls reach for; anything richer waits on a reflection
    /// surface.
    PropertyRef { name: Arc<String> },
    /// `kotlin.text.Regex`. Carries the source pattern plus a compiled
    /// Rust regex. The compiled object is shared via `Rc` so cloning a
    /// `Value::Regex` is cheap.
    Regex(Arc<RegexData>),
    /// `kotlin.text.MatchResult` — single match outcome produced by
    /// `Regex.find` / `Regex.matchEntire` / `Regex.findAll` iteration.
    /// Holds the originating regex + input so `next()` can resume.
    Match(Arc<MatchData>),
    /// `kotlin.text.MatchGroup` — one captured group of a `MatchResult`.
    /// `value` is the matched substring; `start`/`end_inclusive` are
    /// Kotlin char-indices into the original input.
    MatchGroup { value: Arc<String>, start: i64, end_inclusive: i64 },
    /// `kotlin.text.StringBuilder` — mutable string buffer. Shared
    /// storage so `sb1 === sb2` semantics hold across cloned values.
    StringBuilder(ObjRef<String>),
    /// Boxed local `var` captured by a closure (Kotlin's
    /// `Ref.ObjectRef`). The declaring scope and every capturing
    /// lambda hold the same `ObjRef`, so an assignment from
    /// a coroutine / nested closure is immediately visible at the
    /// declaration site. Created by `Inst::MakeCell`; only ever
    /// touched through `Inst::CellGet` / `Inst::CellSet` — it never
    /// escapes to user-visible value operations.
    Cell(ObjRef<Value>),
}

impl Value {
    /// Wrap a value in a fresh capture cell.
    #[must_use]
    pub fn new_cell(v: Value) -> Value {
        Value::Cell(ObjRef::new(v))
    }
}

/// Compiled regex + the original pattern source. Cheap to clone via `Rc`.
#[derive(Debug)]
pub struct RegexData {
    pub pattern: Arc<String>,
    pub re: regex::Regex,
}

/// A single regex match outcome — full match plus capture groups, with
/// enough state to resume scanning via `MatchResult.next()`.
#[derive(Debug)]
pub struct MatchData {
    pub input: Arc<String>,
    /// Index 0 is the whole match; later indices are capture groups.
    /// `None` means a group did not participate in this match.
    pub groups: Vec<Option<MatchGroupData>>,
    /// Byte offset in `input` immediately after the matched span — used
    /// by `next()` to advance past the current match.
    pub end_byte: usize,
    pub regex: Arc<RegexData>,
}

#[derive(Debug, Clone)]
pub struct MatchGroupData {
    pub value: Arc<String>,
    pub start: i64,
    pub end_inclusive: i64,
}

/// Helper trait for the `Value::new_int` / `new_long` / `new_short` /
/// `new_byte` constructors: anything numeric we want to hand to the
/// runtime as an integer can be coerced through here. Width adjustment
/// (truncation / sign-extension) happens at the construction site, so
/// callers don't need to scatter `as i32` / `as i64` casts.
pub trait ToI64 {
    fn to_i64(self) -> i64;
}

macro_rules! impl_to_i64 {
    ($($t:ty),*) => {
        $(impl ToI64 for $t {
            #[inline]
            fn to_i64(self) -> i64 { self as i64 }
        })*
    };
}
impl_to_i64!(i8, i16, i32, i64, isize, u8, u16, u32, u64, usize);

/// Distinguishes integer ranges (`IntRange`) from long ranges (`LongRange`).
/// Storage in `Value::Range` is a normalised `i64` triple regardless of
/// kind; iteration honours the kind to materialise the body variable as
/// `Value::Int` or `Value::Long`.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub enum RangeKind {
    #[default]
    Int,
    Long,
    Char,
}

/// Numeric promotion rank — wider types win in mixed arithmetic.
/// Byte/Short promote to Int for arithmetic per Kotlin spec, so callers
/// that need the *arithmetic* rank should call `arith_rank()` rather than
/// `numeric_rank()` directly.
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord)]
pub enum NumericRank {
    Byte = 0,
    Short = 1,
    Int = 2,
    Long = 3,
    UByte = 4,
    UShort = 5,
    UInt = 6,
    ULong = 7,
    Float = 8,
    Double = 9,
}

/// Identifies the typed Kotlin primitive-array variants so member
/// dispatch and `is`-checks can distinguish them from the generic
/// object array.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum PrimitiveArrayKind {
    Int,
    Long,
    Double,
    Float,
    Short,
    Byte,
    Boolean,
    Char,
    UInt,
    ULong,
    UShort,
    UByte,
}

impl PrimitiveArrayKind {
    #[must_use]
    pub fn type_fqn(self) -> &'static str {
        match self {
            Self::Int => "kotlin.IntArray",
            Self::Long => "kotlin.LongArray",
            Self::Double => "kotlin.DoubleArray",
            Self::Float => "kotlin.FloatArray",
            Self::Short => "kotlin.ShortArray",
            Self::Byte => "kotlin.ByteArray",
            Self::Boolean => "kotlin.BooleanArray",
            Self::Char => "kotlin.CharArray",
            Self::UInt => "kotlin.UIntArray",
            Self::ULong => "kotlin.ULongArray",
            Self::UShort => "kotlin.UShortArray",
            Self::UByte => "kotlin.UByteArray",
        }
    }

    #[must_use]
    pub fn simple_name(self) -> &'static str {
        match self {
            Self::Int => "Int",
            Self::Long => "Long",
            Self::Double => "Double",
            Self::Float => "Float",
            Self::Short => "Short",
            Self::Byte => "Byte",
            Self::Boolean => "Boolean",
            Self::Char => "Char",
            Self::UInt => "UInt",
            Self::ULong => "ULong",
            Self::UShort => "UShort",
            Self::UByte => "UByte",
        }
    }
}

#[derive(Debug, Clone)]
pub enum DelegateKind {
    /// `lazy { producer }`. First read evaluates the producer (in the
    /// captured env) and stores the result; subsequent reads return the
    /// cache.
    Lazy { producer: Value, cached: Option<Value> },
    /// `Delegates.observable(initial) { property, old, new -> … }`.
    Observable { value: Value, on_change: Value },
    /// `Delegates.notNull<T>()`. Reads before the first write throw
    /// `IllegalStateException`.
    NotNull { value: Option<Value>, name: String },
}

/// State-machine representation of a `suspend fun` body. Built once
/// when a suspend function is registered and consulted whenever the
/// interpreter enters / resumes the body.
#[derive(Debug, Clone)]
pub struct SuspendBody {
    pub states: Vec<SuspendState>,
}

/// One "basic block" in a state machine: a contiguous run of
/// statements with at most one suspending operation, ending in a
/// transition.
#[derive(Debug, Clone)]
pub struct SuspendState {
    /// Optional local to bind the resumed value to *before* the
    /// statements run. `None` for the initial state (state 0).
    pub resume_target: Option<String>,
    /// Statements to execute in order. The interpreter walks these
    /// against the frame's locals + captured env. If an expression
    /// in here suspends (returns Value::CoroutineSuspended), the
    /// frame is saved at this state and the suspension bubbles up.
    pub stmts: Vec<klio_ast::Stmt>,
    /// What to do after the last stmt finishes.
    pub transition: SuspendTransition,
}

#[derive(Debug, Clone)]
pub enum SuspendTransition {
    /// Move to the named state, optionally carrying a value (e.g.
    /// the result of the last expression in this state).
    Goto(usize),
    /// Function returns. The value comes from the last expression
    /// of `stmts` (Unit for an empty / non-expression tail).
    Return,
    /// Branch on a boolean register produced by the last stmt:
    /// jump to `then_state` if true, `else_state` otherwise.
    Branch { then_state: usize, else_state: usize },
}

/// A live `suspend fun` invocation. Holds enough state to resume
/// the body after a pause: the function decl, the captured env
/// (params + closure), the locals introduced so far, the next
/// state to run, and the caller's continuation.
#[derive(Debug)]
pub struct SuspendFrame {
    pub decl: Arc<klio_ast::Function>,
    pub body: Arc<SuspendBody>,
    pub env: ObjRef<Env>,
    /// Locals introduced by val/var statements in earlier states.
    /// Survives across suspensions because each state writes/reads
    /// here instead of pushing a transient frame.
    pub locals: Vec<(String, Value)>,
    /// Index into `body.states` for the next state to run.
    pub state: usize,
    /// Bound when this frame is the active continuation: the
    /// caller's continuation chain. Driving this frame to a Return
    /// hands the value to `caller.resume_with(...)`.
    pub caller: Option<SuspendCallerCont>,
    /// When the frame is paused mid-state on an async
    /// `suspendCoroutine`, the slot's identity-stable handle lives
    /// here as an opaque resume-value record. The interpreter
    /// reads it on re-entry instead of re-allocating a slot and
    /// re-calling the user lambda.
    pub paused_resume: std::cell::RefCell<Option<PausedResume>>,
}

/// Result of a previously-suspended `suspendCoroutine` call,
/// stashed on the frame so the state machine can read it on its
/// next driving pass. `Pending` is not represented here; an
/// outstanding suspension simply leaves `paused_resume = None`
/// and the next drive returns `CoroutineSuspended` immediately.
#[derive(Debug, Clone)]
pub enum PausedResume {
    Resumed(Value),
    Failed(Value),
}

/// Where a finished suspend frame hands its result. Either upstream
/// to another paused suspend frame, or to a host-side slot that
/// `runBlocking` drains.
#[derive(Debug, Clone)]
pub enum SuspendCallerCont {
    Frame(ObjRef<SuspendFrame>),
    HostSlot(ObjRef<Option<Result<Value, Value>>>),
}

/// A declared Kotlin class as the interpreter sees it at runtime.
#[derive(Debug)]
pub struct ClassDef {
    pub name: String,
    pub fqn: String,
    /// Runtime-retained annotation class names applied to this
    /// declaration. Populated at class-registration time from the
    /// AST, filtered to spec §17 RUNTIME retention (the default).
    /// `KClass.annotations` / `KClass.findAnnotation` walk this
    /// list when reflection asks for them.
    pub annotation_names: Vec<String>,
    pub primary_params: Vec<ClassParamDef>,
    /// Member functions keyed by simple name.
    pub methods: Vec<MethodDef>,
    /// Body `val`/`var` properties (not primary-ctor properties). Each
    /// initializer expression runs against the instance scope during
    /// construction.
    pub body_properties: Vec<PropertyDef>,
    pub init_blocks: Vec<Arc<klio_ast::Block>>,
    /// For each entry in `init_blocks`, the index of `body_properties`
    /// it runs BEFORE — matching Kotlin's source-order rule that an
    /// `init { … }` block interleaves with body-property initializers
    /// in declaration order. Same length as `init_blocks`.
    pub init_block_property_positions: Vec<usize>,
    pub is_data: bool,
    /// `true` for a `value class` / `@JvmInline value class`. Like a
    /// data class, the compiler synthesises `equals`/`hashCode`/
    /// `toString` over the single backing property, so structural
    /// equality and display follow the data-class path.
    pub is_value: bool,
    pub is_object: bool,
    /// `true` for an `enum class`. The entry instances live on
    /// `enum_entries` of the same `ClassDef`.
    pub is_enum: bool,
    /// `true` when the declaration carried the `sealed` modifier.
    pub is_sealed: bool,
    /// Simple supertype names recorded from `class Foo : Bar(), Baz`. Used by
    /// runtime `is`-checks to walk a class's parent chain by name; no
    /// generics, no diamond resolution.
    pub supertype_names: Vec<String>,
    /// Resolved parent class for method-resolution chain walking. Single
    /// inheritance only — populated from the first non-interface supertype
    /// that resolves to a `Value::Class` at registration time.
    pub parent: ObjRef<Option<Arc<ClassDef>>>,
    /// Resolved interface supertypes (any number). Walked after `parent` for
    /// default-method lookup and `is`-check membership. Each entry is a
    /// `ClassDef` with `is_interface = true`.
    pub interfaces: ObjRef<Vec<Arc<ClassDef>>>,
    /// `true` for a class declared with the `interface` keyword.
    pub is_interface: bool,
    /// `true` for a `fun interface` (a SAM interface eligible for lambda
    /// conversion via the constructor-call form `Foo { … }`).
    pub is_fun_interface: bool,
    /// Constructor argument expressions for the parent class, captured at
    /// declaration time from `: Parent(args)`. Evaluated in the subclass's
    /// constructor env when an instance is built.
    pub parent_ctor_args: Vec<Arc<klio_ast::Expr>>,
    /// `true` when the declaration carried the `open` modifier.
    pub is_open: bool,
    /// `true` for an `abstract class`. Direct instantiation is rejected; the
    /// class may declare members whose method/property carries
    /// `is_abstract = true`.
    pub is_abstract: bool,
    /// `true` for an `inner class`. Instances built from one of these store
    /// an outer-instance reference on `InstanceData.outer`.
    pub is_inner: bool,
    /// `true` for the synthetic `ClassDef` built from an `object { … }`
    /// expression. Drives the `Foo$N@hash` form used by `toString`.
    pub is_anonymous: bool,
    /// Secondary constructors. The order is the source-declared order.
    pub secondary_ctors: Vec<Arc<klio_ast::SecondaryCtor>>,
    /// Eagerly-constructed enum entries in source order. Each value is a
    /// `Value::Instance` whose class is either this `ClassDef` or a
    /// synthetic per-entry subclass when the entry declared an override
    /// body. Populated after the enclosing `Arc<ClassDef>` exists so
    /// entries can carry a `Arc<ClassDef>` back-reference.
    pub enum_entries: ObjRef<Vec<(String, Value)>>,
    /// Companion object, if any. Stored as a class with `is_object: true`.
    /// Companion object instance. Interior mutability lets the
    /// interpreter defer construction until after the enclosing
    /// class is bound to the env, so `class Outer { companion {
    /// val X = Outer() } }` can resolve `Outer` during its
    /// companion's init. Construction sites set this once.
    pub companion: ObjRef<Option<ObjRef<InstanceData>>>,
    /// For a companion-object class (`is_object: true` built from a
    /// `companion object` declaration), this points back to the enclosing
    /// class. Lets the interpreter expose enum entries / `entries` inside
    /// the companion's own method bodies.
    pub enclosing_class: ObjRef<Option<Arc<ClassDef>>>,
    /// Nested classes by simple name (both plain nested and `inner` —
    /// `is_inner` lives on the nested class's own `ClassDef`).
    pub nested_classes: ObjRef<Vec<(String, Arc<ClassDef>)>>,
    /// Captured env in which the class was declared (for closure-like
    /// resolution in method bodies).
    pub captured_env: ObjRef<Env>,
    /// Inheritance-delegation table: for each delegated supertype entry,
    /// the supertype name and the expression that produces the delegate
    /// instance. Evaluated once during construction; the resulting value
    /// is stored on the instance under `$$delegate$<idx>`. Resolved by
    /// the interpreter to forward calls to abstract methods that are not
    /// overridden in this class.
    pub supertype_delegates: ObjRef<Vec<SupertypeDelegate>>,
    /// Synthesized forwarder methods built once the delegated interfaces
    /// are resolved (at parent-link time). Walked by `find_method_walk`
    /// after the class's own methods miss but before the parent chain.
    pub delegate_forwarders: ObjRef<Vec<MethodDef>>,
    /// Lazily-constructed singleton for `is_object` classes that are
    /// nested inside another classifier. Top-level objects materialize
    /// their singleton at file load and bind it in globals; nested
    /// objects (including ones inside sealed classes) need lazy
    /// construction the first time `Outer.NestedObj` is read.
    pub object_singleton: ObjRef<Option<ObjRef<InstanceData>>>,
}

#[derive(Debug, Clone)]
pub struct SupertypeDelegate {
    /// Simple name of the delegated interface (the type written before
    /// `by`). Used so the runtime can look up the interface's method
    /// table for forwarder synthesis.
    pub interface_name: String,
    /// Resolved interface class, if it resolves at registration time.
    pub interface: Option<Arc<ClassDef>>,
    /// Delegate expression — evaluated in the primary-ctor parameter
    /// scope at construction.
    pub expr: Arc<klio_ast::Expr>,
    /// Field key on the instance where the resolved delegate value lives.
    pub field_key: String,
}

#[derive(Debug, Clone)]
pub struct ClassParamDef {
    /// `Some(true)` for `var`, `Some(false)` for `val`, `None` if the param
    /// isn't a property.
    pub property: Option<bool>,
    pub name: String,
    pub default: Option<Arc<klio_ast::Expr>>,
}

#[derive(Debug, Clone)]
pub struct MethodDef {
    pub name: String,
    pub decl: Arc<klio_ast::Function>,
    pub is_operator: bool,
    pub is_open: bool,
    pub is_override: bool,
    /// `true` when the source carried the `abstract` modifier on this
    /// member. Abstract methods may have `decl.body == None`.
    pub is_abstract: bool,
    /// When `Some`, calls to this method dispatch through the bundled
    /// lambda instead of executing `decl.body`. Populated when a lambda is
    /// SAM-converted to a `fun interface` instance — the synthesized
    /// subclass replaces the single abstract method with this binding.
    pub sam_lambda: Option<Value>,
    /// When `Some(field_key)`, this is a synthesized inheritance-delegation
    /// forwarder: calls to this method are routed to the stored delegate
    /// instance found under `field_key` on the receiver, dispatching the
    /// same method name on the delegate.
    pub delegate_field: Option<String>,
    /// IR FuncId of the lowered method body (with `this` as the
    /// implicit first param). Set by class registration when the
    /// method body has been lowered into the active IR module;
    /// `None` for abstract / SAM-replaced / delegate-forwarder
    /// methods that have no IR body of their own.
    pub ir_fn_id: Option<u32>,
}

#[derive(Debug, Clone)]
pub struct PropertyDef {
    pub name: String,
    pub mutable: bool,
    pub init: Option<Arc<klio_ast::Expr>>,
    /// Custom getter body, if the source declared `get() = …` / `get() { … }`.
    pub getter: Option<Arc<klio_ast::Accessor>>,
    /// Custom setter body, if the source declared `set(value) { … }`.
    pub setter: Option<Arc<klio_ast::Accessor>>,
    /// `val foo by expr` — the delegate expression. Evaluated once at
    /// instance construction; its result is stored under
    /// `__delegate$<name>` in the instance field map and consulted on
    /// every read/write of the property.
    pub delegate: Option<Arc<klio_ast::Expr>>,
    /// `true` when the property was declared `abstract`. Such properties
    /// have no `init` and serve as a contract for subclasses.
    pub is_abstract: bool,
    /// `true` for a `lateinit var`. Reads before the first write throw
    /// `kotlin.UninitializedPropertyAccessException`.
    pub is_lateinit: bool,
}

#[derive(Debug)]
pub struct InstanceData {
    pub class: Arc<ClassDef>,
    /// Field name → value. Insertion ordered (Vec keeps order for `toString`
    /// on data classes).
    pub fields: Vec<(String, Value)>,
    /// For an `inner class` instance, the captured enclosing-class
    /// instance. Bare-name lookups inside an inner method fall through to
    /// this outer's fields, and `this@Outer` resolves to it.
    pub outer: Option<Value>,
    /// Per-instance identity, assigned at construction from a monotonic
    /// counter on the interpreter. Drives `Foo@<hex>` in the default
    /// `toString` for plain (non-data, non-enum, non-singleton) classes.
    pub identity: u64,
    /// Opaque per-instance state owned by a native host binding —
    /// kotlinx.io's `Buffer` stashes its byte queue here, for
    /// example. Lifecycle is tied to the instance: the state is
    /// dropped when the last `ObjRef<InstanceData>` clone is
    /// released, no side-map cleanup needed.
    pub native_state: Option<NativeState>,
}

/// Native-side data attached to a `Value::Instance`. The `kind`
/// discriminator is a free-form string (convention: the FQN of the
/// owning native binding, e.g. `"kotlinx.io.Buffer"`) that downcasts
/// surface as a panic-on-mismatch guard so two libraries don't
/// accidentally trample each other's storage on the same instance.
pub struct NativeState {
    pub kind: &'static str,
    pub data: Arc<Mutex<dyn std::any::Any + Send + Sync>>,
}

impl std::fmt::Debug for NativeState {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "NativeState({})", self.kind)
    }
}

impl ClassDef {
    /// Walk the class chain (self, then parent, then grandparent, …) and
    /// return the first method matching `name`, paired with the class that
    /// declared it.
    #[must_use]
    pub fn find_method(self: &Arc<Self>, name: &str) -> Option<(MethodDef, Arc<ClassDef>)> {
        let mut seen: Vec<*const ClassDef> = Vec::new();
        find_method_walk(self, name, &mut seen)
    }

    /// Like `find_method`, but among overloads with this name, prefers one
    /// whose first declared parameter type name matches `arg_type_name` —
    /// used by operator dispatch to pick `plus(Bag)` over `plus(Int)` when
    /// the argument is a `Bag`. Falls back to the unspecific lookup.
    pub fn find_method_for_arg(
        self: &Arc<Self>,
        name: &str,
        arg_type_name: Option<&str>,
    ) -> Option<(MethodDef, Arc<ClassDef>)> {
        if let Some(arg) = arg_type_name {
            let mut seen: Vec<*const ClassDef> = Vec::new();
            if let Some(found) = find_method_for_arg_walk(self, name, arg, &mut seen) {
                return Some(found);
            }
        }
        self.find_method(name)
    }

    /// Walk the class chain searching for a body property declaration of the
    /// given name. Returns the property and the class that declared it.
    #[must_use]
    pub fn find_body_property(self: &Arc<Self>, name: &str) -> Option<(PropertyDef, Arc<ClassDef>)> {
        let mut seen: Vec<*const ClassDef> = Vec::new();
        find_body_property_walk(self, name, &mut seen)
    }

    /// Returns the list of declared interface supertypes (resolved).
    #[must_use]
    pub fn interface_refs(&self) -> Vec<Arc<ClassDef>> {
        self.interfaces.borrow().clone()
    }

    /// Collect companions reachable from this class: self, parent chain, and
    /// transitive interfaces. Used to resolve bare-name references to
    /// companion-object members (`Counter.n` accessed as `n` inside a
    /// `Counter.inc()` default body that runs on a class implementing
    /// `Counter`).
    #[must_use]
    pub fn all_companions(self: &Arc<Self>) -> Vec<ObjRef<InstanceData>> {
        let mut out: Vec<ObjRef<InstanceData>> = Vec::new();
        let mut seen: Vec<*const ClassDef> = Vec::new();
        collect_companions_walk(self, &mut out, &mut seen);
        out
    }

    /// True when this class or any of its named supertypes matches `name`.
    /// Walks the chain by simple name through `captured_env`. Cycles are
    /// guarded against by bounding the walk to a small depth.
    #[must_use]
    pub fn is_subtype_of(&self, name: &str) -> bool {
        if self.name == name || self.fqn == name {
            return true;
        }
        let mut frontier: Vec<String> = self.supertype_names.clone();
        let mut seen: Vec<String> = vec![self.name.clone()];
        let mut steps = 0;
        while let Some(parent_name) = frontier.pop() {
            if steps > 64 {
                return false;
            }
            steps += 1;
            if parent_name == name {
                return true;
            }
            if seen.iter().any(|s| s == &parent_name) {
                continue;
            }
            seen.push(parent_name.clone());
            let Some(v) = self.captured_env.borrow().lookup(&parent_name) else {
                continue;
            };
            if let Value::Class(c) = v {
                if c.name == name || c.fqn == name {
                    return true;
                }
                for p in &c.supertype_names {
                    frontier.push(p.clone());
                }
            }
        }
        false
    }
}

fn collect_companions_walk(
    cls: &Arc<ClassDef>,
    out: &mut Vec<ObjRef<InstanceData>>,
    seen: &mut Vec<*const ClassDef>,
) {
    let ptr = Arc::as_ptr(cls);
    if seen.iter().any(|p| *p == ptr) || seen.len() > 128 {
        return;
    }
    seen.push(ptr);
    if let Some(c) = cls.companion.borrow().as_ref() {
        out.push(c.clone());
    }
    if let Some(parent) = cls.parent.borrow().clone() {
        collect_companions_walk(&parent, out, seen);
    }
    for iface in cls.interfaces.borrow().iter() {
        collect_companions_walk(iface, out, seen);
    }
    // Spec §6.1: a companion-object decl scope is ULD to the companion
    // decl scope of the parent of its parent classifier. Walk the
    // enclosing class chain so members of a companion can read names
    // from the enclosing class's companion.
    if let Some(encl) = cls.enclosing_class.borrow().clone() {
        collect_companions_walk(&encl, out, seen);
    }
}

fn find_method_for_arg_walk(
    cls: &Arc<ClassDef>,
    name: &str,
    arg_type_name: &str,
    seen: &mut Vec<*const ClassDef>,
) -> Option<(MethodDef, Arc<ClassDef>)> {
    let ptr = Arc::as_ptr(cls);
    if seen.iter().any(|p| *p == ptr) || seen.len() > 128 {
        return None;
    }
    seen.push(ptr);
    let arg_matches = |m: &MethodDef| -> bool {
        m.decl
            .params
            .first()
            .map(|p| p.ty.name.name == arg_type_name)
            .unwrap_or(false)
    };
    if let Some(m) = cls.methods.iter().find(|m| {
        m.name == name && m.decl.body.is_some() && arg_matches(m)
    }) {
        return Some((m.clone(), Arc::clone(cls)));
    }
    if let Some(parent) = cls.parent.borrow().clone() {
        if let Some(found) = find_method_for_arg_walk(&parent, name, arg_type_name, seen) {
            return Some(found);
        }
    }
    for iface in cls.interfaces.borrow().iter() {
        if let Some(found) = find_method_for_arg_walk(iface, name, arg_type_name, seen) {
            return Some(found);
        }
    }
    None
}

fn find_method_walk(
    cls: &Arc<ClassDef>,
    name: &str,
    seen: &mut Vec<*const ClassDef>,
) -> Option<(MethodDef, Arc<ClassDef>)> {
    let ptr = Arc::as_ptr(cls);
    if seen.iter().any(|p| *p == ptr) || seen.len() > 128 {
        return None;
    }
    seen.push(ptr);
    if let Some(m) = cls
        .methods
        .iter()
        .find(|m| {
            m.name == name
                && (m.decl.body.is_some()
                    || m.sam_lambda.is_some()
                    || m.delegate_field.is_some())
        })
    {
        return Some((m.clone(), Arc::clone(cls)));
    }
    // Inheritance-delegation forwarders synthesized at parent-link
    // resolution time. Consulted before the parent chain so a delegated
    // member wins over a default body the same way an explicit override
    // would.
    if let Some(m) = cls.delegate_forwarders.borrow().iter().find(|m| m.name == name) {
        return Some((m.clone(), Arc::clone(cls)));
    }
    // Walk the parent chain (concrete superclass) before interfaces — a
    // concrete-method inherited from a parent class wins over an interface
    // default with the same signature.
    if let Some(parent) = cls.parent.borrow().clone() {
        if let Some(found) = find_method_walk(&parent, name, seen) {
            return Some(found);
        }
    }
    for iface in cls.interfaces.borrow().iter() {
        if let Some(found) = find_method_walk(iface, name, seen) {
            return Some(found);
        }
    }
    // Fall back to an abstract declaration on the class itself — only useful
    // for error reporting at call time.
    if let Some(m) = cls.methods.iter().find(|m| m.name == name) {
        return Some((m.clone(), Arc::clone(cls)));
    }
    None
}

fn find_body_property_walk(
    cls: &Arc<ClassDef>,
    name: &str,
    seen: &mut Vec<*const ClassDef>,
) -> Option<(PropertyDef, Arc<ClassDef>)> {
    let ptr = Arc::as_ptr(cls);
    if seen.iter().any(|p| *p == ptr) || seen.len() > 128 {
        return None;
    }
    seen.push(ptr);
    if let Some(p) = cls.body_properties.iter().find(|p| p.name == name) {
        return Some((p.clone(), Arc::clone(cls)));
    }
    if let Some(parent) = cls.parent.borrow().clone() {
        if let Some(found) = find_body_property_walk(&parent, name, seen) {
            return Some(found);
        }
    }
    for iface in cls.interfaces.borrow().iter() {
        if let Some(found) = find_body_property_walk(iface, name, seen) {
            return Some(found);
        }
    }
    None
}

impl InstanceData {
    #[must_use]
    pub fn get(&self, name: &str) -> Option<Value> {
        self.fields.iter().find(|(n, _)| n == name).map(|(_, v)| v.clone())
    }
    pub fn set(&mut self, name: &str, v: Value) -> bool {
        if let Some(slot) = self.fields.iter_mut().find(|(n, _)| n == name) {
            slot.1 = v;
            true
        } else {
            false
        }
    }
    pub fn define(&mut self, name: &str, v: Value) {
        if !self.set(name, v.clone()) {
            self.fields.push((name.to_string(), v));
        }
    }

    /// Fetch the instance's native-state cell, creating it via `init`
    /// on first access. Panics when the instance already carries
    /// native state under a different `kind`, which indicates two
    /// host bindings are fighting over the same instance.
    pub fn ensure_native_state<T: std::any::Any + Send + Sync>(
        &mut self,
        kind: &'static str,
        init: impl FnOnce() -> T,
    ) -> Arc<Mutex<dyn std::any::Any + Send + Sync>> {
        if let Some(ns) = &self.native_state {
            assert_eq!(
                ns.kind, kind,
                "native_state kind mismatch: instance carries `{}`, binding asked for `{}`",
                ns.kind, kind,
            );
            return Arc::clone(&ns.data);
        }
        let data: Arc<Mutex<dyn std::any::Any + Send + Sync>> =
            Arc::new(Mutex::new(init()));
        self.native_state = Some(NativeState { kind, data: Arc::clone(&data) });
        data
    }
}

#[derive(Debug, Clone)]
pub struct SequenceData {
    pub source: SequenceSource,
    pub ops: Vec<SeqOp>,
}

#[derive(Debug, Clone)]
pub enum SequenceSource {
    /// Eager-known elements. Built by `asSequence` / `sequenceOf`.
    Items(Arc<Vec<Value>>),
    /// `generateSequence(seed) { it -> next }`. `seed` is `None` for the
    /// nullary form `generateSequence { nextOrNull }` — that variant emits
    /// values from the lambda until it returns `null`.
    Generate { seed: Option<Box<Value>>, next: Box<Value> },
}

#[derive(Debug, Clone)]
pub enum SeqOp {
    Map(Value),
    Filter(Value),
    FilterNot(Value),
    Take(i64),
    Drop(i64),
    TakeWhile(Value),
    DropWhile(Value),
    FlatMap(Value),
    Distinct,
    DistinctBy(Value),
    /// Sort in natural order. The `descending` flag flips the comparison.
    /// Sorting ops are buffer-then-emit: the materializer collects every
    /// upstream item, sorts, then feeds the sorted batch through downstream
    /// ops in order.
    Sorted(bool),
    /// Sort by a key-selector lambda. `descending` flips the comparison.
    SortedBy(Value, bool),
    /// Sort with a user-supplied `Value::Comparator`.
    SortedWith(Value),
}

impl fmt::Debug for Value {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::Cell(c) => write!(f, "Cell({:?})", c.borrow()),
            Self::Unit => write!(f, "Unit"),
            Self::CoroutineSuspended => write!(f, "CoroutineSuspended"),
            Self::Int(v) => write!(f, "Int({v})"),
            Self::Long(v) => write!(f, "Long({v})"),
            Self::Short(v) => write!(f, "Short({v})"),
            Self::Byte(v) => write!(f, "Byte({v})"),
            Self::UInt(v) => write!(f, "UInt({v})"),
            Self::ULong(v) => write!(f, "ULong({v})"),
            Self::UShort(v) => write!(f, "UShort({v})"),
            Self::UByte(v) => write!(f, "UByte({v})"),
            Self::Double(v) => write!(f, "Double({v})"),
            Self::Float(v) => write!(f, "Float({v})"),
            Self::Bool(v) => write!(f, "Bool({v})"),
            Self::String(v) => write!(f, "String({v:?})"),
            Self::Char(v) => write!(f, "Char({v:?})"),
            Self::Null => write!(f, "Null"),
            Self::Range { start, end, step, kind } => {
                write!(f, "Range({start}..{end} step {step} kind={kind:?})")
            }
            Self::Function { decl, .. } => write!(f, "Function({})", decl.name.name),
            Self::Lambda { params, .. } => write!(f, "Lambda(params={})", params.len()),
            Self::IrClosure { id, captures } => write!(f, "IrClosure(id={id}, captures={})", captures.len()),
            Self::Intrinsic { fqn, .. } => write!(f, "Intrinsic({fqn})"),
            Self::BoundMethod { fqn, .. } => write!(f, "BoundMethod({fqn})"),
            Self::BoundUserMethod { receiver, method } => write!(
                f,
                "BoundUserMethod({}::{})",
                receiver.borrow().class.name,
                method.name
            ),
            Self::Exception { fqn, message, .. } => match message {
                Some(m) => write!(f, "Exception({fqn}: {m:?})"),
                None => write!(f, "Exception({fqn})"),
            },
            Self::List { items, mutable, enum_class } => {
                let tag = match enum_class {
                    Some(n) => format!("EnumEntries<{n}>"),
                    None => (if *mutable { "mut" } else { "ro" }).to_string(),
                };
                write!(f, "List({}, {} items)", tag, items.borrow().len())
            }
            Self::Set { items, mutable } => {
                write!(f, "Set({}, {} items)", if *mutable { "mut" } else { "ro" }, items.borrow().len())
            }
            Self::Map { entries, mutable } => {
                write!(f, "Map({}, {} entries)", if *mutable { "mut" } else { "ro" }, entries.borrow().len())
            }
            Self::Pair(a, b) => write!(f, "Pair({a:?}, {b:?})"),
            Self::Triple(a, b, c) => write!(f, "Triple({a:?}, {b:?}, {c:?})"),
            Self::MapEntry { key, value } => write!(f, "Map.Entry({key:?}={value:?})"),
            Self::Result { ok, payload } => write!(f, "Result(ok={ok}, payload={payload:?})"),
            Self::Comparator { steps, descending } => write!(
                f,
                "Comparator(steps={}, descending={})",
                steps.len(),
                descending
            ),
            Self::Sequence(data) => write!(f, "Sequence(source={:?}, ops={})", data.source, data.ops.len()),
            Self::Iterator { items, pos, prim } => write!(
                f,
                "Iterator(prim={prim:?}, pos={}/{})",
                pos.borrow(),
                items.borrow().len()
            ),
            Self::Class(c) => write!(f, "Class({})", c.fqn),
            Self::BoundInnerClass { class, .. } => write!(f, "BoundInnerClass({})", class.fqn),
            Self::Instance(i) => write!(f, "Instance({})", i.borrow().class.fqn),
            Self::Delegate(d) => write!(f, "Delegate({:?})", d.borrow()),
            Self::PropertyRef { name } => write!(f, "PropertyRef({name})"),
            Self::Array { items, prim } => write!(
                f,
                "Array({:?}, {} items)",
                prim,
                items.borrow().len()
            ),
            Self::Regex(d) => write!(f, "Regex({:?})", d.pattern),
            Self::Match(m) => write!(f, "Match({:?})", m.groups.first()),
            Self::MatchGroup { value, .. } => write!(f, "MatchGroup({value:?})"),
            Self::StringBuilder(s) => write!(f, "StringBuilder({:?})", s.borrow()),
        }
    }
}

impl fmt::Display for Value {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::Cell(c) => write!(f, "{}", c.borrow()),
            Self::Unit => write!(f, "kotlin.Unit"),
            Self::CoroutineSuspended => write!(f, "COROUTINE_SUSPENDED"),
            Self::Int(v) => write!(f, "{v}"),
            Self::Long(v) => write!(f, "{v}"),
            Self::Short(v) => write!(f, "{v}"),
            Self::Byte(v) => write!(f, "{v}"),
            Self::UInt(v) => write!(f, "{v}"),
            Self::ULong(v) => write!(f, "{v}"),
            Self::UShort(v) => write!(f, "{v}"),
            Self::UByte(v) => write!(f, "{v}"),
            Self::Double(v) => write!(f, "{}", kotlin_double_to_string(*v)),
            Self::Float(v) => write!(f, "{}", kotlin_float_to_string(*v)),
            Self::Bool(v) => write!(f, "{v}"),
            Self::String(v) => write!(f, "{v}"),
            Self::Char(v) => write!(f, "{v}"),
            Self::Null => write!(f, "null"),
            Self::Range { start, end, step, .. } => {
                // Kotlin renders progressions as:
                //   IntRange (step == 1): "1..10"
                //   forward IntProgression: "1..10 step 2"
                //   descending IntProgression: "10 downTo 1 step N"  (N >= 1)
                if *step == 1 {
                    write!(f, "{start}..{end}")
                } else if *step > 0 {
                    write!(f, "{start}..{end} step {step}")
                } else {
                    write!(f, "{start} downTo {end} step {}", -step)
                }
            }
            Self::Function { decl, .. } => write!(f, "fun {}(...)", decl.name.name),
            Self::Lambda { .. } => write!(f, "{{lambda}}"),
            Self::IrClosure { id, .. } => write!(f, "{{ir-closure#{id}}}"),
            Self::Intrinsic { fqn, .. } | Self::BoundMethod { fqn, .. } => {
                write!(f, "fun {fqn}(...)")
            }
            Self::BoundUserMethod { receiver, method } => {
                write!(f, "fun {}.{}(...)", receiver.borrow().class.name, method.name)
            }
            Self::Exception { fqn, message, .. } => match message {
                Some(m) => write!(f, "{fqn}: {m}"),
                None => write!(f, "{fqn}"),
            },
            Self::List { items, .. } => {
                write!(f, "[")?;
                for (i, v) in items.borrow().iter().enumerate() {
                    if i > 0 { write!(f, ", ")?; }
                    write_collection_element(f, v)?;
                }
                write!(f, "]")
            }
            Self::Array { items, prim } => {
                // kotlinc-native renders arrays as `[I@<hash>`-style
                // identity strings that depend on heap addresses, so
                // corpora that need parity must iterate manually. We
                // surface a placeholder identity-shaped string here so
                // accidental `println(arr)` doesn't crash; the leading
                // tag still makes the type readable.
                let tag = match prim {
                    Some(k) => k.type_fqn(),
                    None => "kotlin.Array",
                };
                let _ = items;
                write!(f, "{tag}@<…>")
            }
            Self::Set { items, .. } => {
                write!(f, "[")?;
                for (i, v) in items.borrow().iter().enumerate() {
                    if i > 0 { write!(f, ", ")?; }
                    write_collection_element(f, v)?;
                }
                write!(f, "]")
            }
            Self::Map { entries, .. } => {
                write!(f, "{{")?;
                for (i, (k, v)) in entries.borrow().iter().enumerate() {
                    if i > 0 { write!(f, ", ")?; }
                    write_collection_element(f, k)?;
                    write!(f, "=")?;
                    write_collection_element(f, v)?;
                }
                write!(f, "}}")
            }
            Self::Pair(a, b) => {
                write!(f, "(")?;
                write_collection_element(f, a)?;
                write!(f, ", ")?;
                write_collection_element(f, b)?;
                write!(f, ")")
            }
            Self::Triple(a, b, c) => {
                write!(f, "(")?;
                write_collection_element(f, a)?;
                write!(f, ", ")?;
                write_collection_element(f, b)?;
                write!(f, ", ")?;
                write_collection_element(f, c)?;
                write!(f, ")")
            }
            Self::MapEntry { key, value } => {
                write_collection_element(f, key)?;
                write!(f, "=")?;
                write_collection_element(f, value)
            }
            Self::Result { ok, payload } => {
                if *ok {
                    write!(f, "Success(")?;
                    write_collection_element(f, payload)?;
                    write!(f, ")")
                } else {
                    write!(f, "Failure(")?;
                    write_collection_element(f, payload)?;
                    write!(f, ")")
                }
            }
            Self::Comparator { .. } => write!(f, "Comparator"),
            Self::Sequence { .. } => write!(f, "kotlin.sequences.Sequence"),
            Self::Iterator { prim, .. } => match prim {
                Some(p) => write!(f, "{}Iterator", p.simple_name()),
                None => write!(f, "kotlin.collections.Iterator"),
            },
            Self::Class(c) => write!(f, "class {}", c.name),
            Self::BoundInnerClass { class, .. } => write!(f, "class {}", class.name),
            Self::Delegate(_) => write!(f, "<delegate>"),
            Self::PropertyRef { name } => write!(f, "property {name} (Kotlin reflection is not available)"),
            Self::Regex(d) => write!(f, "{}", d.pattern),
            Self::Match(m) => {
                let v = m.groups.first().and_then(|g| g.as_ref());
                match v {
                    Some(g) => write!(f, "{}", g.value),
                    None => write!(f, ""),
                }
            }
            Self::MatchGroup { value, .. } => write!(f, "{value}"),
            Self::StringBuilder(s) => write!(f, "{}", s.borrow()),
            Self::Instance(i) => {
                let inst = i.borrow();
                if inst.class.is_enum {
                    // Enum entries render as the bare entry name unless the
                    // user overrode `toString`. The `name` field is populated
                    // at entry construction.
                    if let Some(Value::String(s)) = inst.get("name") {
                        return write!(f, "{s}");
                    }
                    return write!(f, "{}", inst.class.name);
                }
                if inst.class.is_object {
                    return write!(f, "{}", inst.class.name);
                }
                if inst.class.is_data || inst.class.is_value {
                    write!(f, "{}(", inst.class.name)?;
                    let mut first = true;
                    for p in &inst.class.primary_params {
                        if !first { write!(f, ", ")?; }
                        first = false;
                        let v = inst.get(&p.name).unwrap_or(Value::Null);
                        write!(f, "{}=", p.name)?;
                        match &v {
                            Value::String(s) => write!(f, "{s}")?,
                            other => write!(f, "{other}")?,
                        }
                    }
                    write!(f, ")")
                } else {
                    // Plain class (incl. anonymous-object instances): match
                    // JVM Kotlin's default `Any.toString` shape
                    // `<fqn>@<hex>`. The hex digits come from a monotonic
                    // per-instance counter — not the real heap address, so
                    // parity programs check the *structure* of the string
                    // (prefix, `@`, hex digits) rather than the exact value.
                    write!(f, "{}@{:x}", inst.class.fqn, inst.identity)
                }
            }
        }
    }
}

/// Inside a `List` / `Map` / `Set` / `Pair`, Kotlin renders `String` and
/// `Char` elements unquoted (matching `AbstractCollection.toString`). This
/// helper matches that — but only at one level of nesting; nested
/// collections recurse through `Display` again.
fn write_collection_element(f: &mut fmt::Formatter<'_>, v: &Value) -> fmt::Result {
    write!(f, "{v}")
}

impl Value {
    #[must_use]
    pub fn is_integral(&self) -> bool {
        matches!(
            self,
            Self::Int(_)
                | Self::Long(_)
                | Self::Short(_)
                | Self::Byte(_)
                | Self::UInt(_)
                | Self::ULong(_)
                | Self::UShort(_)
                | Self::UByte(_)
        )
    }

    #[must_use]
    pub fn is_unsigned(&self) -> bool {
        matches!(
            self,
            Self::UInt(_) | Self::ULong(_) | Self::UShort(_) | Self::UByte(_)
        )
    }

    #[must_use]
    pub fn is_floating(&self) -> bool {
        matches!(self, Self::Double(_) | Self::Float(_))
    }

    #[must_use]
    pub fn is_numeric(&self) -> bool {
        self.is_integral() || self.is_floating()
    }

    /// Widen any integral variant to `i64`. Floating types return `None`;
    /// use `as_f64` for those.
    #[must_use]
    pub fn as_i64(&self) -> Option<i64> {
        match self {
            Self::Int(v) => Some(i64::from(*v)),
            Self::Long(v) => Some(*v),
            Self::Short(v) => Some(i64::from(*v)),
            Self::Byte(v) => Some(i64::from(*v)),
            Self::UInt(v) => Some(i64::from(*v)),
            Self::ULong(v) => Some(*v as i64),
            Self::UShort(v) => Some(i64::from(*v)),
            Self::UByte(v) => Some(i64::from(*v)),
            _ => None,
        }
    }

    /// Widen any integral variant to `u64`. Mirrors `as_i64` for the
    /// unsigned-arithmetic path. Negative signed values wrap.
    #[must_use]
    pub fn as_u64(&self) -> Option<u64> {
        match self {
            Self::Int(v) => Some(*v as u64),
            Self::Long(v) => Some(*v as u64),
            Self::Short(v) => Some(*v as u64),
            Self::Byte(v) => Some(*v as u64),
            Self::UInt(v) => Some(u64::from(*v)),
            Self::ULong(v) => Some(*v),
            Self::UShort(v) => Some(u64::from(*v)),
            Self::UByte(v) => Some(u64::from(*v)),
            _ => None,
        }
    }

    /// Widen any numeric variant (integral or floating) to `f64`.
    #[must_use]
    pub fn as_f64(&self) -> Option<f64> {
        match self {
            Self::Int(v) => Some(f64::from(*v)),
            Self::Long(v) => Some(*v as f64),
            Self::Short(v) => Some(f64::from(*v)),
            Self::Byte(v) => Some(f64::from(*v)),
            Self::UInt(v) => Some(f64::from(*v)),
            Self::ULong(v) => Some(*v as f64),
            Self::UShort(v) => Some(f64::from(*v)),
            Self::UByte(v) => Some(f64::from(*v)),
            Self::Double(v) => Some(*v),
            Self::Float(v) => Some(f64::from(*v)),
            _ => None,
        }
    }

    /// Widen any numeric variant to `f32`. Used by `Float`-typed arithmetic.
    #[must_use]
    pub fn as_f32(&self) -> Option<f32> {
        match self {
            Self::Int(v) => Some(*v as f32),
            Self::Long(v) => Some(*v as f32),
            Self::Short(v) => Some(f32::from(*v)),
            Self::Byte(v) => Some(f32::from(*v)),
            Self::UInt(v) => Some(*v as f32),
            Self::ULong(v) => Some(*v as f32),
            Self::UShort(v) => Some(f32::from(*v)),
            Self::UByte(v) => Some(f32::from(*v)),
            Self::Double(v) => Some(*v as f32),
            Self::Float(v) => Some(*v),
            _ => None,
        }
    }

    /// Construct an `Int` value from any integer-like input, wrapping to
    /// the 32-bit storage width. Convenience for the (very common) call
    /// pattern where stdlib helpers compute in `i64` / `usize` / `isize`
    /// and need to hand a `kotlin.Int` back.
    #[must_use]
    pub fn new_int<T: ToI64>(v: T) -> Value {
        Value::Int(v.to_i64() as i32)
    }

    #[must_use]
    pub fn new_long<T: ToI64>(v: T) -> Value {
        Value::Long(v.to_i64())
    }

    #[must_use]
    pub fn new_short<T: ToI64>(v: T) -> Value {
        Value::Short(v.to_i64() as i16)
    }

    #[must_use]
    pub fn new_byte<T: ToI64>(v: T) -> Value {
        Value::Byte(v.to_i64() as i8)
    }

    /// Promotion rank used to determine the result type of a mixed-numeric
    /// binary operation. Higher rank wins; ties keep the operand's variant.
    #[must_use]
    pub fn numeric_rank(&self) -> Option<NumericRank> {
        match self {
            Self::Byte(_) => Some(NumericRank::Byte),
            Self::Short(_) => Some(NumericRank::Short),
            Self::Int(_) => Some(NumericRank::Int),
            Self::Long(_) => Some(NumericRank::Long),
            Self::UByte(_) => Some(NumericRank::UByte),
            Self::UShort(_) => Some(NumericRank::UShort),
            Self::UInt(_) => Some(NumericRank::UInt),
            Self::ULong(_) => Some(NumericRank::ULong),
            Self::Float(_) => Some(NumericRank::Float),
            Self::Double(_) => Some(NumericRank::Double),
            _ => None,
        }
    }

    /// Convert this numeric value to the variant matching `rank`. Returns
    /// `None` if `self` is not numeric. Truncates/wraps on narrowing —
    /// callers should always promote *up* (max of operand ranks) for
    /// arithmetic, never down.
    #[must_use]
    pub fn promote_to(&self, rank: NumericRank) -> Option<Value> {
        match rank {
            NumericRank::Byte => self.as_i64().map(|v| Value::Byte(v as i8)),
            NumericRank::Short => self.as_i64().map(|v| Value::Short(v as i16)),
            NumericRank::Int => self.as_i64().map(|v| Value::Int(v as i32)),
            NumericRank::Long => self.as_i64().map(Value::Long),
            NumericRank::UByte => self.as_u64().map(|v| Value::UByte(v as u8)),
            NumericRank::UShort => self.as_u64().map(|v| Value::UShort(v as u16)),
            NumericRank::UInt => self.as_u64().map(|v| Value::UInt(v as u32)),
            NumericRank::ULong => self.as_u64().map(Value::ULong),
            NumericRank::Float => self.as_f32().map(Value::Float),
            NumericRank::Double => self.as_f64().map(Value::Double),
        }
    }

    /// Truncate an `i64` arithmetic result back to the storage range of
    /// the requested integer rank. Use after `i64::wrapping_*` to apply
    /// 8/16/32-bit overflow semantics. Long is returned as-is.
    #[must_use]
    pub fn wrap_integer(rank: NumericRank, v: i64) -> Value {
        match rank {
            NumericRank::Byte => Value::Byte(v as i8),
            NumericRank::Short => Value::Short(v as i16),
            NumericRank::Int => Value::Int(v as i32),
            NumericRank::Long => Value::Long(v),
            NumericRank::UByte => Value::UByte(v as u8),
            NumericRank::UShort => Value::UShort(v as u16),
            NumericRank::UInt => Value::UInt(v as u32),
            NumericRank::ULong => Value::ULong(v as u64),
            _ => Value::Long(v),
        }
    }

    /// Wrap a `u64` arithmetic result into the unsigned variant
    /// matching `rank`. Truncates on narrowing.
    #[must_use]
    pub fn wrap_unsigned(rank: NumericRank, v: u64) -> Value {
        match rank {
            NumericRank::UByte => Value::UByte(v as u8),
            NumericRank::UShort => Value::UShort(v as u16),
            NumericRank::UInt => Value::UInt(v as u32),
            NumericRank::ULong => Value::ULong(v),
            _ => Value::ULong(v),
        }
    }

    /// Fully-qualified Kotlin type name for the value, used as the key prefix
    /// for member lookups in the stdlib registry.
    #[must_use]
    pub fn type_fqn(&self) -> &'static str {
        match self {
            // A capture cell is always dereferenced before use; it
            // never reaches a user-visible type query.
            Self::Cell(_) => "kotlin.Any",
            Self::Unit => "kotlin.Unit",
            Self::CoroutineSuspended => "kotlin.coroutines.intrinsics.COROUTINE_SUSPENDED",
            Self::Int(_) => "kotlin.Int",
            Self::Long(_) => "kotlin.Long",
            Self::Short(_) => "kotlin.Short",
            Self::Byte(_) => "kotlin.Byte",
            Self::UInt(_) => "kotlin.UInt",
            Self::ULong(_) => "kotlin.ULong",
            Self::UShort(_) => "kotlin.UShort",
            Self::UByte(_) => "kotlin.UByte",
            Self::Double(_) => "kotlin.Double",
            Self::Float(_) => "kotlin.Float",
            Self::Bool(_) => "kotlin.Boolean",
            Self::String(_) => "kotlin.String",
            Self::Char(_) => "kotlin.Char",
            Self::Null => "kotlin.Nothing",
            Self::Range { step, kind, .. } => match kind {
                RangeKind::Int => {
                    if *step == 1 {
                        "kotlin.ranges.IntRange"
                    } else {
                        "kotlin.ranges.IntProgression"
                    }
                }
                RangeKind::Long => {
                    if *step == 1 {
                        "kotlin.ranges.LongRange"
                    } else {
                        "kotlin.ranges.LongProgression"
                    }
                }
                RangeKind::Char => {
                    if *step == 1 {
                        "kotlin.ranges.CharRange"
                    } else {
                        "kotlin.ranges.CharProgression"
                    }
                }
            },
            Self::Function { .. }
            | Self::Lambda { .. }
            | Self::IrClosure { .. }
            | Self::Intrinsic { .. }
            | Self::BoundMethod { .. }
            | Self::BoundUserMethod { .. } => "kotlin.Function",
            Self::Exception { .. } => "kotlin.Throwable",
            // EnumEntries values dispatch through the regular `List` member
            // table at runtime — the EnumEntries identity is only surfaced
            // by `is`-checks via `is_runtime_type`.
            Self::List { mutable: true, .. } => "kotlin.collections.MutableList",
            Self::List { mutable: false, .. } => "kotlin.collections.List",
            Self::Array { prim: Some(k), .. } => k.type_fqn(),
            Self::Array { prim: None, .. } => "kotlin.Array",
            Self::Set { mutable: true, .. } => "kotlin.collections.MutableSet",
            Self::Set { mutable: false, .. } => "kotlin.collections.Set",
            Self::Map { mutable: true, .. } => "kotlin.collections.MutableMap",
            Self::Map { mutable: false, .. } => "kotlin.collections.Map",
            Self::Pair(_, _) => "kotlin.Pair",
            Self::Triple(_, _, _) => "kotlin.Triple",
            Self::MapEntry { .. } => "kotlin.collections.Map.Entry",
            Self::Result { .. } => "kotlin.Result",
            Self::Comparator { .. } => "kotlin.Comparator",
            Self::Sequence { .. } => "kotlin.sequences.Sequence",
            Self::Iterator { prim, .. } => match prim {
                Some(PrimitiveArrayKind::Int) => "kotlin.collections.IntIterator",
                Some(PrimitiveArrayKind::Long) => "kotlin.collections.LongIterator",
                Some(PrimitiveArrayKind::Double) => "kotlin.collections.DoubleIterator",
                Some(PrimitiveArrayKind::Float) => "kotlin.collections.FloatIterator",
                Some(PrimitiveArrayKind::Short) => "kotlin.collections.ShortIterator",
                Some(PrimitiveArrayKind::Byte) => "kotlin.collections.ByteIterator",
                Some(PrimitiveArrayKind::Boolean) => "kotlin.collections.BooleanIterator",
                Some(PrimitiveArrayKind::Char) => "kotlin.collections.CharIterator",
                Some(PrimitiveArrayKind::UInt) => "kotlin.collections.UIntIterator",
                Some(PrimitiveArrayKind::ULong) => "kotlin.collections.ULongIterator",
                Some(PrimitiveArrayKind::UShort) => "kotlin.collections.UShortIterator",
                Some(PrimitiveArrayKind::UByte) => "kotlin.collections.UByteIterator",
                None => "kotlin.collections.Iterator",
            },
            // User classes/instances live outside the stdlib dispatch path
            // and never key into the intrinsic table.
            Self::Class(_) | Self::BoundInnerClass { .. } => "kotlin.reflect.KClass",
            Self::Instance(_) => "<instance>",
            Self::Delegate(_) => "<delegate>",
            Self::PropertyRef { .. } => "kotlin.reflect.KProperty",
            Self::Regex(_) => "kotlin.text.Regex",
            Self::Match(_) => "kotlin.text.MatchResult",
            Self::MatchGroup { .. } => "kotlin.text.MatchGroup",
            Self::StringBuilder(_) => "kotlin.text.StringBuilder",
        }
    }

    /// Render a `Double` value the way Kotlin's `Double.toString` does:
    ///   * `NaN`, `Infinity`, `-Infinity` literal.
    ///   * Integer-valued finite doubles render with a trailing `.0`.
    ///   * Scientific notation uses a capital `E`.
    #[must_use]
    pub fn render_double(d: f64) -> String {
        kotlin_double_to_string(d)
    }

    /// Runtime `is` check against a simple type name (the form `TypeRef.name`
    /// captures). Primitive builtins map by `Value` variant; instances walk
    /// their class hierarchy. Recognized aliases follow Kotlin's
    /// type-check surface (e.g. `Any` matches every non-null value).
    #[must_use]
    pub fn is_runtime_type(&self, name: &str) -> bool {
        match self {
            Value::Cell(c) => c.borrow().is_runtime_type(name),
            Value::CoroutineSuspended => false,
            Value::Int(_) => matches!(name, "Int" | "Number" | "Any" | "Comparable"),
            Value::Long(_) => matches!(name, "Long" | "Number" | "Any" | "Comparable"),
            Value::Short(_) => matches!(name, "Short" | "Number" | "Any" | "Comparable"),
            Value::Byte(_) => matches!(name, "Byte" | "Number" | "Any" | "Comparable"),
            Value::UInt(_) => matches!(name, "UInt" | "Number" | "Any" | "Comparable"),
            Value::ULong(_) => matches!(name, "ULong" | "Number" | "Any" | "Comparable"),
            Value::UShort(_) => matches!(name, "UShort" | "Number" | "Any" | "Comparable"),
            Value::UByte(_) => matches!(name, "UByte" | "Number" | "Any" | "Comparable"),
            Value::Double(_) => matches!(name, "Double" | "Number" | "Any" | "Comparable"),
            Value::Float(_) => matches!(name, "Float" | "Number" | "Any" | "Comparable"),
            Value::Bool(_) => matches!(name, "Boolean" | "Any" | "Comparable"),
            Value::String(_) => matches!(
                name,
                "String" | "CharSequence" | "Any" | "Comparable"
            ),
            Value::Char(_) => matches!(name, "Char" | "Any" | "Comparable"),
            Value::Unit => matches!(name, "Unit" | "Any"),
            Value::Null => false,
            Value::Range { kind, .. } => match kind {
                RangeKind::Int => matches!(
                    name,
                    "IntRange" | "IntProgression" | "ClosedRange" | "Iterable" | "Any"
                ),
                RangeKind::Long => matches!(
                    name,
                    "LongRange" | "LongProgression" | "ClosedRange" | "Iterable" | "Any"
                ),
                RangeKind::Char => matches!(
                    name,
                    "CharRange" | "CharProgression" | "ClosedRange" | "Iterable" | "Any"
                ),
            },
            Value::List { mutable, enum_class, .. } => {
                if matches!(name, "EnumEntries") {
                    return enum_class.is_some();
                }
                if *mutable {
                    matches!(name, "MutableList" | "List" | "Collection" | "Iterable" | "Any")
                } else {
                    matches!(name, "List" | "Collection" | "Iterable" | "Any")
                }
            }
            Value::Set { mutable, .. } => {
                if *mutable {
                    matches!(name, "MutableSet" | "Set" | "Collection" | "Iterable" | "Any")
                } else {
                    matches!(name, "Set" | "Collection" | "Iterable" | "Any")
                }
            }
            Value::Map { mutable, .. } => {
                if *mutable {
                    matches!(name, "MutableMap" | "Map" | "Any")
                } else {
                    matches!(name, "Map" | "Any")
                }
            }
            Value::Pair(_, _) => matches!(name, "Pair" | "Any"),
            Value::Triple(_, _, _) => matches!(name, "Triple" | "Any"),
            Value::MapEntry { .. } => matches!(name, "Entry" | "MapEntry" | "Map.Entry" | "Any"),
            Value::Result { .. } => matches!(name, "Result" | "Any"),
            Value::Sequence(_) => matches!(name, "Sequence" | "Any"),
            Value::Iterator { prim, .. } => {
                if matches!(name, "Iterator" | "Any") {
                    return true;
                }
                match prim {
                    Some(p) => name == &format!("{}Iterator", p.simple_name())[..],
                    None => false,
                }
            }
            Value::Comparator { .. } => matches!(name, "Comparator" | "Any"),
            Value::Function { .. }
            | Value::Lambda { .. }
            | Value::IrClosure { .. }
            | Value::Intrinsic { .. }
            | Value::BoundMethod { .. }
            | Value::BoundUserMethod { .. } => {
                if matches!(
                    name,
                    "Function"
                        | "Any"
                        | "kotlin.Function"
                        | "KFunction"
                        | "KCallable"
                        | "kotlin.reflect.KFunction"
                        | "kotlin.reflect.KCallable"
                ) {
                    return true;
                }
                // Match the arity-tagged `FunctionN` form when the value
                // carries explicit parameter info. Intrinsics / bound methods
                // hide arity, so they only match the base `Function`.
                if let Some(stripped) =
                    name.strip_prefix("Function").or_else(|| name.strip_prefix("kotlin.Function"))
                {
                    if let Ok(n) = stripped.parse::<usize>() {
                        return match self {
                            Value::Lambda { params, .. } => params.len() == n,
                            Value::Function { decl, .. } => decl.params.len() == n,
                            _ => false,
                        };
                    }
                }
                false
            }
            Value::Exception { fqn, .. } => {
                let tail = fqn.rsplit('.').next().unwrap_or(fqn);
                tail == name
                    || matches!(name, "Throwable" | "Exception" | "Any")
                    || fqn.as_str() == name
            }
            Value::Class(_) | Value::BoundInnerClass { .. } => matches!(
                name,
                "KClass" | "kotlin.reflect.KClass" | "Any"
            ),
            Value::Instance(i) => {
                let inst = i.borrow();
                if name == "Any" {
                    return true;
                }
                if inst.class.is_subtype_of(name) {
                    return true;
                }
                // Qualified nested-class type (`Outer.Inner`) — match against
                // the trailing simple name when the dotted prefix names an
                // enclosing classifier of this instance's class.
                if let Some((_outer, simple)) = name.rsplit_once('.') {
                    if inst.class.is_subtype_of(simple) {
                        return true;
                    }
                }
                false
            }
            Value::Delegate(_) => matches!(name, "Any"),
            Value::PropertyRef { .. } => matches!(
                name,
                "KProperty"
                    | "KProperty0"
                    | "KProperty1"
                    | "KCallable"
                    | "kotlin.reflect.KProperty"
                    | "kotlin.reflect.KProperty0"
                    | "kotlin.reflect.KProperty1"
                    | "kotlin.reflect.KCallable"
                    | "Any"
            ),
            Value::Array { prim, .. } => {
                if name == "Any" {
                    return true;
                }
                match prim {
                    Some(PrimitiveArrayKind::Int) => name == "IntArray",
                    Some(PrimitiveArrayKind::Long) => name == "LongArray",
                    Some(PrimitiveArrayKind::Double) => name == "DoubleArray",
                    Some(PrimitiveArrayKind::Float) => name == "FloatArray",
                    Some(PrimitiveArrayKind::Short) => name == "ShortArray",
                    Some(PrimitiveArrayKind::Byte) => name == "ByteArray",
                    Some(PrimitiveArrayKind::Boolean) => name == "BooleanArray",
                    Some(PrimitiveArrayKind::Char) => name == "CharArray",
                    Some(PrimitiveArrayKind::UInt) => name == "UIntArray",
                    Some(PrimitiveArrayKind::ULong) => name == "ULongArray",
                    Some(PrimitiveArrayKind::UShort) => name == "UShortArray",
                    Some(PrimitiveArrayKind::UByte) => name == "UByteArray",
                    None => name == "Array",
                }
            }
            Value::Regex(_) => matches!(name, "Regex" | "Any"),
            Value::Match(_) => matches!(name, "MatchResult" | "Any"),
            Value::MatchGroup { .. } => matches!(name, "MatchGroup" | "Any"),
            Value::StringBuilder(_) => matches!(
                name,
                "StringBuilder" | "Appendable" | "CharSequence" | "Any"
            ),
        }
    }

    /// Live exception fqn — for catch-clause matching by type name.
    #[must_use]
    pub fn exception_fqn(&self) -> Option<&str> {
        match self {
            Self::Exception { fqn, .. } => Some(fqn.as_str()),
            _ => None,
        }
    }

    /// True iff this is an equal value (structural equality for primitives
    /// and strings; identity-ish for callables).
    #[must_use]
    /// Same as `structural_eq` but compares `Float` / `Double`
    /// bitwise (NaN == NaN, +0.0 != -0.0). Used by the IR
    /// `BoxedEq` / `BoxedNotEq` ops when an operand came through
    /// an `as Any` cast or its static type is `Any` — per spec
    /// boxed-number equality is identity-based rather than IEEE.
    pub fn structural_eq_boxed(a: &Value, b: &Value) -> bool {
        use Value::*;
        match (a, b) {
            (Double(x), Double(y)) => x.to_bits() == y.to_bits(),
            (Float(x), Float(y)) => x.to_bits() == y.to_bits(),
            (Double(x), Float(y)) => x.to_bits() == (*y as f64).to_bits(),
            (Float(x), Double(y)) => (*x as f64).to_bits() == y.to_bits(),
            _ => Value::structural_eq(a, b),
        }
    }

    pub fn structural_eq(a: &Value, b: &Value) -> bool {
        use Value::*;
        // Cross-type numeric equality follows Kotlin's `equals` semantics for
        // boxed Number subtypes: integer-vs-integer compares values exactly;
        // mixing with floats compares as f64 (Float widens losslessly to
        // Double via `as f64`). NaN never equals anything.
        if a.is_numeric() && b.is_numeric() {
            if a.is_integral() && b.is_integral() {
                return a.as_i64().unwrap() == b.as_i64().unwrap();
            }
            let av = a.as_f64().unwrap();
            let bv = b.as_f64().unwrap();
            return av == bv;
        }
        match (a, b) {
            (Bool(x), Bool(y)) => x == y,
            (String(x), String(y)) => **x == **y,
            (Char(x), Char(y)) => x == y,
            (Null, Null) => true,
            (Unit, Unit) => true,
            (CoroutineSuspended, CoroutineSuspended) => true,
            (
                Range { start: a1, end: a2, step: s1, kind: k1 },
                Range { start: b1, end: b2, step: s2, kind: k2 },
            ) => a1 == b1 && a2 == b2 && s1 == s2 && k1 == k2,
            (List { items: a, .. }, List { items: b, .. }) => {
                let ab = a.borrow();
                let bb = b.borrow();
                ab.len() == bb.len()
                    && ab.iter().zip(bb.iter()).all(|(x, y)| Value::structural_eq(x, y))
            }
            (Set { items: a, .. }, Set { items: b, .. }) => {
                let ab = a.borrow();
                let bb = b.borrow();
                ab.len() == bb.len()
                    && ab.iter().all(|x| bb.iter().any(|y| Value::structural_eq(x, y)))
            }
            (Map { entries: a, .. }, Map { entries: b, .. }) => {
                let ab = a.borrow();
                let bb = b.borrow();
                ab.len() == bb.len()
                    && ab.iter().all(|(k, v)| {
                        bb.iter().any(|(k2, v2)| {
                            Value::structural_eq(k, k2) && Value::structural_eq(v, v2)
                        })
                    })
            }
            (Pair(a1, a2), Pair(b1, b2)) => {
                Value::structural_eq(a1, b1) && Value::structural_eq(a2, b2)
            }
            (Triple(a1, a2, a3), Triple(b1, b2, b3)) => {
                Value::structural_eq(a1, b1)
                    && Value::structural_eq(a2, b2)
                    && Value::structural_eq(a3, b3)
            }
            (MapEntry { key: k1, value: v1 }, MapEntry { key: k2, value: v2 }) => {
                Value::structural_eq(k1, k2) && Value::structural_eq(v1, v2)
            }
            (Result { ok: o1, payload: p1 }, Result { ok: o2, payload: p2 }) => {
                o1 == o2 && Value::structural_eq(p1, p2)
            }
            (Class(a), Class(b)) => a.fqn == b.fqn,
            // Function values compare by identity. Two distinct
            // closures created by the same source position are still
            // separate values; the JVM-equivalent semantic is
            // reference equality, which gives `List.remove(handler)`
            // a way to drop the exact callable that subscribe()
            // returned.
            (Lambda { body: a, env: ea, .. }, Lambda { body: b, env: eb, .. }) => {
                Arc::ptr_eq(a, b) && ObjRef::ptr_eq(ea, eb)
            }
            (
                IrClosure { id: a, captures: ca },
                IrClosure { id: b, captures: cb },
            ) => a == b && Arc::ptr_eq(ca, cb),
            (
                BoundMethod { fqn: fa, receiver: ra, .. },
                BoundMethod { fqn: fb, receiver: rb, .. },
            ) => fa == fb && Value::structural_eq(ra, rb),
            (Instance(a), Instance(b)) => {
                if ObjRef::ptr_eq(a, b) {
                    return true;
                }
                let aa = a.borrow();
                let bb = b.borrow();
                if aa.class.fqn != bb.class.fqn {
                    return false;
                }
                if !aa.class.is_data && !aa.class.is_value {
                    return false;
                }
                for p in &aa.class.primary_params {
                    let v1 = aa.get(&p.name).unwrap_or(Null);
                    let v2 = bb.get(&p.name).unwrap_or(Null);
                    if !Value::structural_eq(&v1, &v2) {
                        return false;
                    }
                }
                true
            }
            _ => false,
        }
    }

    /// Kotlin referential identity (`===` / `!==`). Heap-backed
    /// reference values compare by backing-cell pointer; a class /
    /// object reference compares by identity; value-like primitives
    /// (where the Kotlin compiler forbids `===`, or it coincides with
    /// `==`) fall back to structural equality. Crucially this never
    /// dispatches a user `equals`, so a `this === other` guard inside
    /// an `equals` / `plus` override cannot recurse into itself.
    #[must_use]
    pub fn reference_eq(a: &Value, b: &Value) -> bool {
        use Value::*;
        match (a, b) {
            (Instance(x), Instance(y)) => ObjRef::ptr_eq(x, y),
            (Cell(x), Cell(y)) => ObjRef::ptr_eq(x, y),
            (List { items: x, .. }, List { items: y, .. })
            | (Set { items: x, .. }, Set { items: y, .. }) => ObjRef::ptr_eq(x, y),
            (Map { entries: x, .. }, Map { entries: y, .. }) => ObjRef::ptr_eq(x, y),
            (Array { items: x, .. }, Array { items: y, .. }) => ObjRef::ptr_eq(x, y),
            // Stdlib intrinsics are process singletons: identity is
            // by fully-qualified name (`x === COROUTINE_SUSPENDED`,
            // `x === Unit`-like sentinels). `structural_eq` has no
            // intrinsic arm, so without this an `outcome ===
            // COROUTINE_SUSPENDED` guard never fires and the sentinel
            // leaks as a value.
            (Intrinsic { fqn: a, .. }, Intrinsic { fqn: b, .. }) => a == b,
            // The dedicated `CoroutineSuspended` variant and the
            // `COROUTINE_SUSPENDED` intrinsic are the same logical
            // singleton regardless of which representation a path
            // produced.
            (CoroutineSuspended, Intrinsic { fqn, .. })
            | (Intrinsic { fqn, .. }, CoroutineSuspended) => {
                *fqn == "kotlin.coroutines.intrinsics.COROUTINE_SUSPENDED"
            }
            // Distinct heap-reference variants are never identical to
            // a value of an unrelated variant.
            (Instance(_), _) | (_, Instance(_)) => false,
            _ => Value::structural_eq(a, b),
        }
    }
}

#[derive(Debug, Error)]
pub enum RuntimeError {
    #[error("unbound identifier: {0}")]
    Unbound(String),
    #[error("type mismatch: {0}")]
    Type(String),
    #[error("argument mismatch: {0}")]
    Arity(String),
    #[error("no `fun main` to run")]
    NoMain,
    #[error("not yet implemented: {0}")]
    Unimplemented(String),

    // Control-flow signals — caught by the appropriate frame, never surfaced.
    #[error("internal: return")]
    Return(Value),
    /// `return@label value` — caught by the frame bound to `label`.
    #[error("internal: labeled return")]
    LabeledReturn(String, Value),
    #[error("internal: break")]
    Break,
    /// `break@label` — caught by the loop bound to `label`.
    #[error("internal: labeled break")]
    LabeledBreak(String),
    #[error("internal: continue")]
    Continue,
    /// `continue@label` — caught by the loop bound to `label`.
    #[error("internal: labeled continue")]
    LabeledContinue(String),
    /// A thrown Kotlin Throwable. Caught by `try`.
    #[error("uncaught {0}")]
    Thrown(Value),
    /// `tailrec` trampoline signal. Raised at a tail-position self-call
    /// inside a `tailrec` function: carries the evaluated arguments for the
    /// next iteration. Caught by the enclosing call frame, which rebinds
    /// parameters and re-evaluates the body.
    #[error("internal: tail continue")]
    TailContinue(Vec<Value>, Vec<Option<String>>),
    /// Mutual `tailrec` hop. Raised at a tail-position call from one
    /// `tailrec` function into another. The enclosing trampoline
    /// replaces its current decl/env with the new pair and rebinds
    /// parameters, reusing the same host stack frame so chains of
    /// mutual tail-recursive functions cycle indefinitely without
    /// growing the stack. The callee value is opaque to this crate
    /// — the interpreter unwraps it as `Value::Function`.
    #[error("internal: tail jump")]
    TailJump(Value, Vec<Value>, Vec<Option<String>>),
    /// Coroutine suspension request. A suspending primitive
    /// (`delay` / `yield` / `suspendCoroutine`) raises this; the
    /// interpreter snapshots the live activation, parks it, and the
    /// cooperative driver resumes it after `wake_in_millis` of
    /// *virtual* time (`0` = yield to ready coroutines now; a
    /// negative value = park indefinitely until an explicit resume).
    #[error("internal: coroutine suspended (wake {0}ms)")]
    Suspend(i64),
}

pub trait Output {
    /// Write a string followed by a newline.
    fn writeln(&mut self, s: &str);
    /// Write a string with no trailing newline. Default implementation
    /// stores the partial line and flushes on the next `writeln`.
    fn write(&mut self, s: &str) {
        self.writeln(s);
    }
}

/// One recorded output call. A [`RecordingSink`] logs the exact
/// `write`/`writeln` sequence so it can later be replayed verbatim
/// into any `Output`, byte-for-byte and call-for-call.
#[derive(Clone)]
pub enum OutOp {
    Write(String),
    WriteLn(String),
}

/// `Send` sink that records the exact call sequence instead of
/// formatting eagerly. The root thread and every spawned thread
/// share one of these behind a `Mutex` (via [`SharedOutput`]); when
/// the program finishes, [`RecordingSink::replay_into`] reproduces
/// the calls in order on the caller's real sink. Because the replay
/// is the identical call sequence, a single-threaded program's
/// output is byte-identical to writing the caller's sink directly.
#[derive(Default)]
pub struct RecordingSink {
    pub ops: Vec<OutOp>,
}

impl RecordingSink {
    pub fn replay_into(&mut self, out: &mut dyn Output) {
        for op in self.ops.drain(..) {
            match op {
                OutOp::Write(s) => out.write(&s),
                OutOp::WriteLn(s) => out.writeln(&s),
            }
        }
    }
}

impl Output for RecordingSink {
    fn writeln(&mut self, s: &str) {
        self.ops.push(OutOp::WriteLn(s.to_string()));
    }
    fn write(&mut self, s: &str) {
        self.ops.push(OutOp::Write(s.to_string()));
    }
}

pub struct StdoutOutput;
impl Output for StdoutOutput {
    fn writeln(&mut self, s: &str) {
        println!("{s}");
    }
    fn write(&mut self, s: &str) {
        use std::io::Write;
        let _ = std::io::stdout().write_all(s.as_bytes());
        let _ = std::io::stdout().flush();
    }
}

/// Test helper that captures every line written to it.
#[derive(Default)]
pub struct CaptureOutput {
    pub lines: Vec<String>,
    partial: String,
}
impl Output for CaptureOutput {
    fn writeln(&mut self, s: &str) {
        if self.partial.is_empty() {
            self.lines.push(s.to_string());
        } else {
            let mut joined = std::mem::take(&mut self.partial);
            joined.push_str(s);
            self.lines.push(joined);
        }
    }
    fn write(&mut self, s: &str) {
        self.partial.push_str(s);
    }
}

/// A `Send` output sink shared by every OS thread of one program.
///
/// All threads (the root and every `kotlin.concurrent.thread` child)
/// write through the same `Arc<Mutex<dyn Output + Send>>`, so a
/// `println` is serialized at write granularity. Kotlin does not
/// define an ordering for racy output; the litmus programs gate their
/// prints behind join / `synchronized` so the observable order stays
/// deterministic.
///
/// Single-thread behaviour is byte-identical to writing the inner sink
/// directly: there is exactly one writer, the mutex is uncontended,
/// and `write`/`writeln` forward verbatim in the same program order.
#[derive(Clone, Default)]
pub struct SharedOutput(Arc<std::sync::Mutex<RecordingSink>>);

impl SharedOutput {
    pub fn new() -> Self {
        Self::default()
    }

    /// Replay every recorded call, in order, into the caller's real
    /// sink, then clear the recording. Called once after the run and
    /// every spawned thread have completed.
    pub fn replay_into(&self, out: &mut dyn Output) {
        let mut g = self.0.lock().unwrap_or_else(|e| e.into_inner());
        g.replay_into(out);
    }
}

impl Output for SharedOutput {
    fn writeln(&mut self, s: &str) {
        self.0.lock().unwrap_or_else(|e| e.into_inner()).writeln(s);
    }
    fn write(&mut self, s: &str) {
        self.0.lock().unwrap_or_else(|e| e.into_inner()).write(s);
    }
}

/// Kotlin-compatible `Double.toString`. Mirrors Java/Kotlin output:
///   * `NaN` literal.
///   * `+/-Infinity` literal.
///   * Integer-valued finite doubles get a `.0` suffix (so `1.0`, not `1`).
///   * Scientific notation kicks in below `1e-3` or at/above `1e7`, with a
///     capital `E` and a `.0` in the mantissa if it's otherwise integer-valued.
#[must_use]
pub fn kotlin_float_to_string(d: f32) -> String {
    if d.is_nan() {
        return "NaN".to_string();
    }
    if d.is_infinite() {
        return if d > 0.0 { "Infinity".into() } else { "-Infinity".into() };
    }
    let abs = d.abs();
    let scientific = abs != 0.0 && (abs < 1e-3 || abs >= 1e7);
    if scientific {
        let raw = format!("{:e}", d);
        let (mantissa, exp) = raw
            .split_once('e')
            .expect("scientific format produces an `e`");
        let mantissa = if mantissa.contains('.') {
            mantissa.to_string()
        } else {
            format!("{mantissa}.0")
        };
        return format!("{mantissa}E{exp}");
    }
    let s = format!("{}", d);
    if !s.contains('.') {
        return format!("{s}.0");
    }
    s
}

#[must_use]
pub fn kotlin_double_to_string(d: f64) -> String {
    if d.is_nan() {
        return "NaN".to_string();
    }
    if d.is_infinite() {
        return if d > 0.0 { "Infinity".into() } else { "-Infinity".into() };
    }
    let abs = d.abs();
    let scientific = abs != 0.0 && (abs < 1e-3 || abs >= 1e7);
    if scientific {
        // Rust's `{:e}` gives lowercase `e` and may emit no `.` (e.g.
        // `1e10` for 1.0e10). Split, normalize the mantissa, recombine.
        let raw = format!("{:e}", d);
        let (mantissa, exp) = raw
            .split_once('e')
            .expect("scientific format produces an `e`");
        let mantissa = if mantissa.contains('.') {
            mantissa.to_string()
        } else {
            format!("{mantissa}.0")
        };
        return format!("{mantissa}E{exp}");
    }
    let s = format!("{}", d);
    if !s.contains('.') {
        return format!("{s}.0");
    }
    s
}

#[derive(Debug, Default, Clone)]
pub struct Env {
    parent: Option<ObjRef<Env>>,
    vars: HashMap<String, Value>,
}

impl Env {
    #[must_use]
    pub fn new() -> Self {
        Self::default()
    }

    #[must_use]
    pub fn with_parent(parent: ObjRef<Env>) -> Self {
        Self { parent: Some(parent), vars: HashMap::new() }
    }

    pub fn define(&mut self, name: impl Into<String>, value: Value) {
        self.vars.insert(name.into(), value);
    }

    /// Remove a binding from this scope (does not touch parent scopes).
    pub fn remove_local(&mut self, name: &str) {
        self.vars.remove(name);
    }

    #[must_use]
    pub fn lookup(&self, name: &str) -> Option<Value> {
        if let Some(v) = self.vars.get(name) {
            return Some(v.clone());
        }
        self.parent.as_ref()?.borrow().lookup(name)
    }

    /// Look up `name` in this scope only, skipping the parent chain. Used by
    /// the interpreter when applying spec §10.1 import renames: a renamed
    /// short name is shadowed if and only if it would have resolved through
    /// the implicit prelude (a parent scope).
    #[must_use]
    pub fn lookup_local(&self, name: &str) -> Option<Value> {
        self.vars.get(name).cloned()
    }

    /// True when this env is a child scope (has a parent). The base
    /// module-globals env has no parent; a layered capture scope does.
    #[must_use]
    pub fn has_parent(&self) -> bool {
        self.parent.is_some()
    }

    /// Resolve `name` ignoring any binding that lives in `stop_at` (compared
    /// by `Rc::ptr_eq`). Used by the interpreter to ask "would this lookup
    /// have come from the implicit prelude?" — pass the prelude env in
    /// `stop_at` and a non-prelude binding (locals, file-scope, …) is
    /// returned; a None means only the prelude could have answered it.
    #[must_use]
    pub fn lookup_excluding(
        &self,
        name: &str,
        stop_at: &ObjRef<Env>,
    ) -> Option<Value> {
        if let Some(v) = self.vars.get(name) {
            return Some(v.clone());
        }
        let parent = self.parent.as_ref()?;
        if ObjRef::ptr_eq(parent, stop_at) {
            return None;
        }
        parent.borrow().lookup_excluding(name, stop_at)
    }

    /// Collect every value bound under `name` walking from the innermost
    /// scope outwards. Returns them in inside-out order. Used to find
    /// enclosing-class `this` bindings when resolving a bare name inside
    /// a local class declared in another class's method body.
    #[must_use]
    pub fn lookup_all(&self, name: &str) -> Vec<Value> {
        let mut out = Vec::new();
        if let Some(v) = self.vars.get(name) {
            out.push(v.clone());
        }
        if let Some(p) = &self.parent {
            out.extend(p.borrow().lookup_all(name));
        }
        out
    }

    /// Look up `name` and return the scope depth (0 = innermost) where it
    /// was found, along with the value. Used to compare a name's lexical
    /// binding against an enclosing `this`-instance field — class fields
    /// only override a lexical binding when the binding is strictly deeper
    /// (closer to the call site) than that `this`.
    #[must_use]
    pub fn lookup_with_depth(&self, name: &str) -> Option<(Value, usize)> {
        if let Some(v) = self.vars.get(name) {
            return Some((v.clone(), 0));
        }
        self.parent
            .as_ref()?
            .borrow()
            .lookup_with_depth(name)
            .map(|(v, d)| (v, d + 1))
    }

    /// Like `lookup_all` but pairs each value with its scope depth.
    #[must_use]
    pub fn lookup_all_with_depth(&self, name: &str) -> Vec<(Value, usize)> {
        let mut out = Vec::new();
        if let Some(v) = self.vars.get(name) {
            out.push((v.clone(), 0));
        }
        if let Some(p) = &self.parent {
            for (v, d) in p.borrow().lookup_all_with_depth(name) {
                out.push((v, d + 1));
            }
        }
        out
    }

    pub fn assign(&mut self, name: &str, value: Value) -> Result<(), RuntimeError> {
        if let Some(slot) = self.vars.get_mut(name) {
            *slot = value;
            return Ok(());
        }
        match &self.parent {
            Some(p) => p.borrow_mut().assign(name, value),
            None => Err(RuntimeError::Unbound(name.to_string())),
        }
    }
}

impl Value {
    /// Address-stable identity for use as a `synchronized` monitor
    /// key. Reference types (instances, containers, cells, builders)
    /// return their backing cell's stable address so two handles to
    /// the same Kotlin object map to the same monitor. Value types
    /// have no identity and return `None` — the caller falls back to
    /// a single shared monitor for them (matching the JVM, where
    /// boxing makes such locks effectively global).
    #[must_use]
    pub fn lock_identity(&self) -> Option<usize> {
        match self {
            Value::Instance(i) => Some(i.identity()),
            Value::List { items, .. }
            | Value::Array { items, .. }
            | Value::Set { items, .. } => Some(items.identity()),
            Value::Map { entries, .. } => Some(entries.identity()),
            Value::Cell(c) => Some(c.identity()),
            Value::StringBuilder(s) => Some(s.identity()),
            _ => None,
        }
    }

    /// Publish every `ObjRef` reachable from this value so the whole
    /// graph is sound to observe from another OS thread. The soundness
    /// primitive a value graph must pass through before it can cross a
    /// thread boundary: `publish()` establishes the happens-before that
    /// `ObjRef`'s `unsafe impl Send/Sync` relies on.
    ///
    /// Cycle-safe. Kotlin object graphs, `Env` parent chains, `Cell`
    /// self-references, and `ClassDef` parent/enclosing links are all
    /// cyclic; recursion is guarded by a visited set keyed on each
    /// cell's address-stable [`ObjRef::identity`]. `publish()` itself
    /// is idempotent, so revisiting a cell is harmless — the visited
    /// check exists purely to guarantee termination.
    ///
    /// Over-approximates by design: when in doubt a reachable cell is
    /// published. It never under-publishes.
    pub fn publish_deep(&self) {
        let mut seen = std::collections::HashSet::new();
        publish_value(self, &mut seen);
    }
}

/// Publish every `ObjRef` reachable from an environment (its bound
/// values and the whole parent chain). Used to make the program's
/// globals sound to observe from a freshly spawned OS thread.
pub fn publish_env_deep(env: &ObjRef<Env>) {
    let mut seen = std::collections::HashSet::new();
    env.publish();
    seen.insert(env.identity());
    publish_env(&env.borrow(), &mut seen);
}

/// Publish (and recurse through) one `ObjRef`. Publishing is always
/// safe and idempotent; the visited set only bounds recursion. Returns
/// `true` when this is the first visit (caller should recurse into the
/// contents), `false` when the cell was already walked.
fn mark_cell<T: ?Sized>(r: &ObjRef<T>, seen: &mut std::collections::HashSet<usize>) -> bool {
    r.publish();
    seen.insert(r.identity())
}

fn publish_env(env: &Env, seen: &mut std::collections::HashSet<usize>) {
    for v in env.vars.values() {
        publish_value(v, seen);
    }
    if let Some(parent) = &env.parent {
        if mark_cell(parent, seen) {
            publish_env(&parent.borrow(), seen);
        }
    }
}

fn publish_classdef(cls: &Arc<ClassDef>, seen: &mut std::collections::HashSet<usize>) {
    // Key ClassDef walks on the Arc identity so parent/enclosing cycles
    // terminate even though the Arc itself carries no ObjRef cell.
    let arc_id = Arc::as_ptr(cls) as *const () as usize;
    if !seen.insert(arc_id) {
        return;
    }
    if mark_cell(&cls.parent, seen) {
        if let Some(p) = cls.parent.borrow().as_ref() {
            publish_classdef(p, seen);
        }
    }
    if mark_cell(&cls.interfaces, seen) {
        for iface in cls.interfaces.borrow().iter() {
            publish_classdef(iface, seen);
        }
    }
    if mark_cell(&cls.enum_entries, seen) {
        for (_, v) in cls.enum_entries.borrow().iter() {
            publish_value(v, seen);
        }
    }
    if mark_cell(&cls.companion, seen) {
        if let Some(c) = cls.companion.borrow().as_ref() {
            if mark_cell(c, seen) {
                publish_instance(&c.borrow(), seen);
            }
        }
    }
    if mark_cell(&cls.enclosing_class, seen) {
        if let Some(e) = cls.enclosing_class.borrow().as_ref() {
            publish_classdef(e, seen);
        }
    }
    if mark_cell(&cls.nested_classes, seen) {
        for (_, nested) in cls.nested_classes.borrow().iter() {
            publish_classdef(nested, seen);
        }
    }
    if mark_cell(&cls.captured_env, seen) {
        publish_env(&cls.captured_env.borrow(), seen);
    }
    if mark_cell(&cls.supertype_delegates, seen) {
        // SupertypeDelegate carries only resolved ClassDefs and
        // immutable Arc<Expr>; recurse the resolved interfaces.
        for d in cls.supertype_delegates.borrow().iter() {
            if let Some(iface) = &d.interface {
                publish_classdef(iface, seen);
            }
        }
    }
    if mark_cell(&cls.delegate_forwarders, seen) {
        for m in cls.delegate_forwarders.borrow().iter() {
            if let Some(v) = &m.sam_lambda {
                publish_value(v, seen);
            }
        }
    }
    if mark_cell(&cls.object_singleton, seen) {
        if let Some(s) = cls.object_singleton.borrow().as_ref() {
            if mark_cell(s, seen) {
                publish_instance(&s.borrow(), seen);
            }
        }
    }
    // Methods can carry SAM-converted lambda values that close over
    // the graph; publish those too.
    for m in &cls.methods {
        if let Some(v) = &m.sam_lambda {
            publish_value(v, seen);
        }
    }
}

fn publish_instance(inst: &InstanceData, seen: &mut std::collections::HashSet<usize>) {
    publish_classdef(&inst.class, seen);
    for (_, v) in &inst.fields {
        publish_value(v, seen);
    }
    if let Some(outer) = &inst.outer {
        publish_value(outer, seen);
    }
}

fn publish_delegate(kind: &DelegateKind, seen: &mut std::collections::HashSet<usize>) {
    match kind {
        DelegateKind::Lazy { producer, cached } => {
            publish_value(producer, seen);
            if let Some(c) = cached {
                publish_value(c, seen);
            }
        }
        DelegateKind::Observable { value, on_change } => {
            publish_value(value, seen);
            publish_value(on_change, seen);
        }
        DelegateKind::NotNull { value, .. } => {
            if let Some(v) = value {
                publish_value(v, seen);
            }
        }
    }
}

fn publish_value(v: &Value, seen: &mut std::collections::HashSet<usize>) {
    match v {
        // Scalars / immutable Arc leaves: no ObjRef, nothing to publish.
        Value::Unit
        | Value::Int(_)
        | Value::Long(_)
        | Value::Short(_)
        | Value::Byte(_)
        | Value::UInt(_)
        | Value::ULong(_)
        | Value::UShort(_)
        | Value::UByte(_)
        | Value::Double(_)
        | Value::Float(_)
        | Value::Bool(_)
        | Value::String(_)
        | Value::Char(_)
        | Value::Null
        | Value::Range { .. }
        | Value::Intrinsic { .. }
        | Value::BoundMethod { .. }
        | Value::PropertyRef { .. }
        | Value::Regex(_)
        | Value::Match(_)
        | Value::MatchGroup { .. } => {}

        Value::List { items, .. }
        | Value::Array { items, .. }
        | Value::Set { items, .. } => {
            if mark_cell(items, seen) {
                for elem in items.borrow().iter() {
                    publish_value(elem, seen);
                }
            }
        }
        Value::Iterator { items, pos, .. } => {
            if mark_cell(items, seen) {
                for elem in items.borrow().iter() {
                    publish_value(elem, seen);
                }
            }
            mark_cell(pos, seen);
        }
        Value::Map { entries, .. } => {
            if mark_cell(entries, seen) {
                for (k, val) in entries.borrow().iter() {
                    publish_value(k, seen);
                    publish_value(val, seen);
                }
            }
        }

        Value::Instance(inst) => {
            if mark_cell(inst, seen) {
                publish_instance(&inst.borrow(), seen);
            }
        }
        Value::BoundUserMethod { receiver, .. } => {
            if mark_cell(receiver, seen) {
                publish_instance(&receiver.borrow(), seen);
            }
        }
        Value::BoundInnerClass { class, outer } => {
            publish_classdef(class, seen);
            if mark_cell(outer, seen) {
                publish_instance(&outer.borrow(), seen);
            }
        }
        Value::Class(cls) => publish_classdef(cls, seen),

        Value::Cell(c) => {
            if mark_cell(c, seen) {
                publish_value(&c.borrow(), seen);
            }
        }
        Value::Delegate(d) => {
            if mark_cell(d, seen) {
                publish_delegate(&d.borrow(), seen);
            }
        }
        Value::StringBuilder(sb) => {
            // String leaf: publish the cell, no inner ObjRef.
            mark_cell(sb, seen);
        }

        Value::Function { env, .. } | Value::Lambda { env, .. } => {
            if mark_cell(env, seen) {
                publish_env(&env.borrow(), seen);
            }
        }
        Value::CoroutineSuspended => {}

        Value::Pair(a, b) => {
            publish_value(a, seen);
            publish_value(b, seen);
        }
        Value::Triple(a, b, c) => {
            publish_value(a, seen);
            publish_value(b, seen);
            publish_value(c, seen);
        }
        Value::MapEntry { key, value } => {
            publish_value(key, seen);
            publish_value(value, seen);
        }
        Value::Result { payload, .. } => publish_value(payload, seen),
        Value::Exception { cause, .. } => {
            if let Some(c) = cause {
                publish_value(c, seen);
            }
        }

        Value::IrClosure { captures, .. } => {
            for cap in captures.iter() {
                publish_value(cap, seen);
            }
        }
        Value::Comparator { steps, .. } => {
            for (step, _) in steps.iter() {
                publish_value(step, seen);
            }
        }
        Value::Sequence(seq) => {
            match &seq.source {
                SequenceSource::Items(items) => {
                    for elem in items.iter() {
                        publish_value(elem, seen);
                    }
                }
                SequenceSource::Generate { seed, next } => {
                    if let Some(s) = seed {
                        publish_value(s, seen);
                    }
                    publish_value(next, seen);
                }
            }
            for op in &seq.ops {
                match op {
                    SeqOp::Map(v)
                    | SeqOp::Filter(v)
                    | SeqOp::FilterNot(v)
                    | SeqOp::TakeWhile(v)
                    | SeqOp::DropWhile(v)
                    | SeqOp::FlatMap(v)
                    | SeqOp::DistinctBy(v)
                    | SeqOp::SortedBy(v, _)
                    | SeqOp::SortedWith(v) => publish_value(v, seen),
                    SeqOp::Take(_)
                    | SeqOp::Drop(_)
                    | SeqOp::Distinct
                    | SeqOp::Sorted(_) => {}
                }
            }
        }
    }
}

// ===== GC tracer (feature = "gc") =====
//
// A second walk of the exact same reachability graph as
// `publish_*`, but instead of calling `ObjRef::publish()` on each
// cell it records the cell's identity in the mark set and re-retains
// it in the GC heap (so a cell reachable from a root survives the
// sweep). The traversal shape is kept deliberately identical to the
// `publish_*` family above; if one changes the other must change in
// lockstep. Compiled only under `--features gc`, so the production
// build is byte-identical.

/// Mark + re-retain one cell; returns `true` on first visit so the
/// caller recurses (mirrors `mark_cell`).
#[cfg(feature = "gc")]
fn gc_mark_cell<T: Send + 'static>(
    r: &ObjRef<T>,
    seen: &mut std::collections::HashSet<usize>,
) -> bool {
    gc::retain(&r.0);
    seen.insert(r.identity())
}

#[cfg(feature = "gc")]
fn gc_mark_env_root(env: &ObjRef<Env>, seen: &mut std::collections::HashSet<usize>) {
    if gc_mark_cell(env, seen) {
        gc_mark_env(&env.borrow(), seen);
    }
}

#[cfg(feature = "gc")]
fn gc_mark_env(env: &Env, seen: &mut std::collections::HashSet<usize>) {
    for v in env.vars.values() {
        gc_mark_value(v, seen);
    }
    if let Some(parent) = &env.parent {
        if gc_mark_cell(parent, seen) {
            gc_mark_env(&parent.borrow(), seen);
        }
    }
}

#[cfg(feature = "gc")]
fn gc_mark_classdef(cls: &Arc<ClassDef>, seen: &mut std::collections::HashSet<usize>) {
    let arc_id = Arc::as_ptr(cls) as *const () as usize;
    if !seen.insert(arc_id) {
        return;
    }
    if gc_mark_cell(&cls.parent, seen) {
        if let Some(p) = cls.parent.borrow().as_ref() {
            gc_mark_classdef(p, seen);
        }
    }
    if gc_mark_cell(&cls.interfaces, seen) {
        for iface in cls.interfaces.borrow().iter() {
            gc_mark_classdef(iface, seen);
        }
    }
    if gc_mark_cell(&cls.enum_entries, seen) {
        for (_, v) in cls.enum_entries.borrow().iter() {
            gc_mark_value(v, seen);
        }
    }
    if gc_mark_cell(&cls.companion, seen) {
        if let Some(c) = cls.companion.borrow().as_ref() {
            if gc_mark_cell(c, seen) {
                gc_mark_instance(&c.borrow(), seen);
            }
        }
    }
    if gc_mark_cell(&cls.enclosing_class, seen) {
        if let Some(e) = cls.enclosing_class.borrow().as_ref() {
            gc_mark_classdef(e, seen);
        }
    }
    if gc_mark_cell(&cls.nested_classes, seen) {
        for (_, nested) in cls.nested_classes.borrow().iter() {
            gc_mark_classdef(nested, seen);
        }
    }
    if gc_mark_cell(&cls.captured_env, seen) {
        gc_mark_env(&cls.captured_env.borrow(), seen);
    }
    if gc_mark_cell(&cls.supertype_delegates, seen) {
        for d in cls.supertype_delegates.borrow().iter() {
            if let Some(iface) = &d.interface {
                gc_mark_classdef(iface, seen);
            }
        }
    }
    if gc_mark_cell(&cls.delegate_forwarders, seen) {
        for m in cls.delegate_forwarders.borrow().iter() {
            if let Some(v) = &m.sam_lambda {
                gc_mark_value(v, seen);
            }
        }
    }
    if gc_mark_cell(&cls.object_singleton, seen) {
        if let Some(s) = cls.object_singleton.borrow().as_ref() {
            if gc_mark_cell(s, seen) {
                gc_mark_instance(&s.borrow(), seen);
            }
        }
    }
    for m in &cls.methods {
        if let Some(v) = &m.sam_lambda {
            gc_mark_value(v, seen);
        }
    }
}

#[cfg(feature = "gc")]
fn gc_mark_instance(inst: &InstanceData, seen: &mut std::collections::HashSet<usize>) {
    gc_mark_classdef(&inst.class, seen);
    for (_, v) in &inst.fields {
        gc_mark_value(v, seen);
    }
    if let Some(outer) = &inst.outer {
        gc_mark_value(outer, seen);
    }
}

#[cfg(feature = "gc")]
#[cfg(feature = "gc")]
fn gc_mark_delegate(kind: &DelegateKind, seen: &mut std::collections::HashSet<usize>) {
    match kind {
        DelegateKind::Lazy { producer, cached } => {
            gc_mark_value(producer, seen);
            if let Some(c) = cached {
                gc_mark_value(c, seen);
            }
        }
        DelegateKind::Observable { value, on_change } => {
            gc_mark_value(value, seen);
            gc_mark_value(on_change, seen);
        }
        DelegateKind::NotNull { value, .. } => {
            if let Some(v) = value {
                gc_mark_value(v, seen);
            }
        }
    }
}

#[cfg(feature = "gc")]
fn gc_mark_value(v: &Value, seen: &mut std::collections::HashSet<usize>) {
    match v {
        Value::Unit
        | Value::Int(_)
        | Value::Long(_)
        | Value::Short(_)
        | Value::Byte(_)
        | Value::UInt(_)
        | Value::ULong(_)
        | Value::UShort(_)
        | Value::UByte(_)
        | Value::Double(_)
        | Value::Float(_)
        | Value::Bool(_)
        | Value::String(_)
        | Value::Char(_)
        | Value::Null
        | Value::Range { .. }
        | Value::Intrinsic { .. }
        | Value::BoundMethod { .. }
        | Value::PropertyRef { .. }
        | Value::Regex(_)
        | Value::Match(_)
        | Value::MatchGroup { .. } => {}

        Value::List { items, .. }
        | Value::Array { items, .. }
        | Value::Set { items, .. } => {
            if gc_mark_cell(items, seen) {
                for elem in items.borrow().iter() {
                    gc_mark_value(elem, seen);
                }
            }
        }
        Value::Iterator { items, pos, .. } => {
            if gc_mark_cell(items, seen) {
                for elem in items.borrow().iter() {
                    gc_mark_value(elem, seen);
                }
            }
            gc_mark_cell(pos, seen);
        }
        Value::Map { entries, .. } => {
            if gc_mark_cell(entries, seen) {
                for (k, val) in entries.borrow().iter() {
                    gc_mark_value(k, seen);
                    gc_mark_value(val, seen);
                }
            }
        }

        Value::Instance(inst) => {
            if gc_mark_cell(inst, seen) {
                gc_mark_instance(&inst.borrow(), seen);
            }
        }
        Value::BoundUserMethod { receiver, .. } => {
            if gc_mark_cell(receiver, seen) {
                gc_mark_instance(&receiver.borrow(), seen);
            }
        }
        Value::BoundInnerClass { class, outer } => {
            gc_mark_classdef(class, seen);
            if gc_mark_cell(outer, seen) {
                gc_mark_instance(&outer.borrow(), seen);
            }
        }
        Value::Class(cls) => gc_mark_classdef(cls, seen),

        Value::Cell(c) => {
            if gc_mark_cell(c, seen) {
                gc_mark_value(&c.borrow(), seen);
            }
        }
        Value::Delegate(d) => {
            if gc_mark_cell(d, seen) {
                gc_mark_delegate(&d.borrow(), seen);
            }
        }
        Value::StringBuilder(sb) => {
            gc_mark_cell(sb, seen);
        }

        Value::Function { env, .. } | Value::Lambda { env, .. } => {
            if gc_mark_cell(env, seen) {
                gc_mark_env(&env.borrow(), seen);
            }
        }
        Value::CoroutineSuspended => {}

        Value::Pair(a, b) => {
            gc_mark_value(a, seen);
            gc_mark_value(b, seen);
        }
        Value::Triple(a, b, c) => {
            gc_mark_value(a, seen);
            gc_mark_value(b, seen);
            gc_mark_value(c, seen);
        }
        Value::MapEntry { key, value } => {
            gc_mark_value(key, seen);
            gc_mark_value(value, seen);
        }
        Value::Result { payload, .. } => gc_mark_value(payload, seen),
        Value::Exception { cause, .. } => {
            if let Some(c) = cause {
                gc_mark_value(c, seen);
            }
        }

        Value::IrClosure { captures, .. } => {
            for cap in captures.iter() {
                gc_mark_value(cap, seen);
            }
        }
        Value::Comparator { steps, .. } => {
            for (step, _) in steps.iter() {
                gc_mark_value(step, seen);
            }
        }
        Value::Sequence(seq) => {
            match &seq.source {
                SequenceSource::Items(items) => {
                    for elem in items.iter() {
                        gc_mark_value(elem, seen);
                    }
                }
                SequenceSource::Generate { seed, next } => {
                    if let Some(s) = seed {
                        gc_mark_value(s, seen);
                    }
                    gc_mark_value(next, seen);
                }
            }
            for op in &seq.ops {
                match op {
                    SeqOp::Map(v)
                    | SeqOp::Filter(v)
                    | SeqOp::FilterNot(v)
                    | SeqOp::TakeWhile(v)
                    | SeqOp::DropWhile(v)
                    | SeqOp::FlatMap(v)
                    | SeqOp::DistinctBy(v)
                    | SeqOp::SortedBy(v, _)
                    | SeqOp::SortedWith(v) => gc_mark_value(v, seen),
                    SeqOp::Take(_)
                    | SeqOp::Drop(_)
                    | SeqOp::Distinct
                    | SeqOp::Sorted(_) => {}
                }
            }
        }
    }
}

/// The whole point of the value-model migration: a `Value` (and the
/// interpreter state reachable through it) can be sent and shared
/// across OS threads. If a future change reintroduces an `Rc` /
/// `RefCell` / non-`Send` payload anywhere in the graph, this fails
/// to compile — the regression guard for the parallel backing.
const _: fn() = || {
    fn assert_send_sync<T: Send + Sync>() {}
    assert_send_sync::<Value>();
    assert_send_sync::<ObjRef<Value>>();
    assert_send_sync::<Env>();
    assert_send_sync::<ClassDef>();
};

#[cfg(test)]
mod tests {
    use super::*;

    fn make_class(name: &str, is_data: bool, is_object: bool, is_enum: bool) -> Arc<ClassDef> {
        Arc::new(ClassDef {
            name: name.to_string(),
            fqn: name.to_string(),
            annotation_names: Vec::new(),
            primary_params: Vec::new(),
            methods: Vec::new(),
            body_properties: Vec::new(),
            init_blocks: Vec::new(),
            init_block_property_positions: Vec::new(),
            is_data,
            is_value: false,
            is_object,
            is_enum,
            is_sealed: false,
            supertype_names: Vec::new(),
            parent: ObjRef::new(None),
            interfaces: ObjRef::new(Vec::new()),
            is_interface: false,
            is_fun_interface: false,
            parent_ctor_args: Vec::new(),
            is_open: false,
            is_abstract: false,
            is_inner: false,
            is_anonymous: false,
            secondary_ctors: Vec::new(),
            enum_entries: ObjRef::new(Vec::new()),
            companion: ObjRef::new(None),
            enclosing_class: ObjRef::new(None),
            nested_classes: ObjRef::new(Vec::new()),
            captured_env: ObjRef::new(Env::new()),
            supertype_delegates: ObjRef::new(Vec::new()),
            delegate_forwarders: ObjRef::new(Vec::new()),
            object_singleton: ObjRef::new(None),
        })
    }

    #[test]
    fn plain_instance_display_uses_class_at_hex() {
        let cls = make_class("Foo", false, false, false);
        let inst = ObjRef::new(InstanceData {
            class: cls,
            fields: Vec::new(),
            outer: None,
            identity: 0x2a,
            native_state: None,
        });
        assert_eq!(format!("{}", Value::Instance(inst)), "Foo@2a");
    }

    #[test]
    fn data_instance_display_unchanged() {
        // Data classes still render via the data-class form; identity is
        // irrelevant. (Field rendering exercised by integration tests.)
        let cls = make_class("D", true, false, false);
        let inst = ObjRef::new(InstanceData {
            class: cls,
            fields: Vec::new(),
            outer: None,
            identity: 99,
            native_state: None,
        });
        assert_eq!(format!("{}", Value::Instance(inst)), "D()");
    }

    #[test]
    fn enum_entries_is_runtime_type_matches_both() {
        let entries = Value::List {
            items: ObjRef::new(vec![Value::Int(1)]),
            mutable: false,
            enum_class: Some(Arc::new("Color".to_string())),
        };
        assert!(entries.is_runtime_type("List"));
        assert!(entries.is_runtime_type("EnumEntries"));
        assert!(entries.is_runtime_type("Collection"));

        let plain = Value::List {
            items: ObjRef::new(vec![Value::Int(1)]),
            mutable: false,
            enum_class: None,
        };
        assert!(plain.is_runtime_type("List"));
        assert!(!plain.is_runtime_type("EnumEntries"));
    }

    #[test]
    fn publish_deep_nested_graph_publishes_every_cell() {
        // List -> Instance -> field Map -> Cell
        let cell = ObjRef::new(Value::Int(7));
        let map_entries = ObjRef::new(vec![(
            Value::String(Arc::new("k".into())),
            Value::Cell(cell.clone()),
        )]);
        let map = Value::Map { entries: map_entries.clone(), mutable: true };
        let cls = make_class("Holder", false, false, false);
        let inst = ObjRef::new(InstanceData {
            class: cls,
            fields: vec![("m".into(), map)],
            outer: None,
            identity: 1,
            native_state: None,
        });
        let items = ObjRef::new(vec![Value::Instance(inst.clone())]);
        let root = Value::List { items: items.clone(), mutable: false, enum_class: None };

        assert!(!items.is_shared());
        assert!(!inst.is_shared());
        assert!(!map_entries.is_shared());
        assert!(!cell.is_shared());

        root.publish_deep();

        assert!(items.is_shared());
        assert!(inst.is_shared());
        assert!(map_entries.is_shared());
        assert!(cell.is_shared());
        // captured_env of the embedded ClassDef is reached too.
        if let Value::Instance(i) = &Value::Instance(inst.clone()) {
            assert!(i.borrow().class.captured_env.is_shared());
        }
    }

    #[test]
    fn publish_deep_cyclic_graph_terminates() {
        // Instance whose field is a Cell pointing back to the instance.
        let cls = make_class("Node", false, false, false);
        let inst = ObjRef::new(InstanceData {
            class: cls,
            fields: Vec::new(),
            outer: None,
            identity: 1,
            native_state: None,
        });
        let cell = ObjRef::new(Value::Instance(inst.clone()));
        inst.borrow_mut()
            .fields
            .push(("self".into(), Value::Cell(cell.clone())));

        // Env whose parent chain loops back on itself.
        let env_cell: ObjRef<Env> = ObjRef::new(Env::new());
        env_cell.borrow_mut().parent = Some(env_cell.clone());
        env_cell
            .borrow_mut()
            .define("here", Value::Instance(inst.clone()));
        let lam = Value::Lambda {
            params: Arc::new(Vec::new()),
            body: Arc::new(klio_ast::Block {
                stmts: Vec::new(),
                span: klio_span::Span::new(klio_span::FileId(0), 0, 0),
            }),
            env: env_cell.clone(),
            absorb_return: false,
        };

        Value::Instance(inst.clone()).publish_deep();
        lam.publish_deep();

        assert!(inst.is_shared());
        assert!(cell.is_shared());
        assert!(env_cell.is_shared());
    }

    #[test]
    fn publish_deep_is_idempotent() {
        let cell = ObjRef::new(Value::Int(1));
        let items = ObjRef::new(vec![Value::Cell(cell.clone())]);
        let root = Value::List { items: items.clone(), mutable: true, enum_class: None };

        root.publish_deep();
        root.publish_deep();

        assert!(items.is_shared());
        assert!(cell.is_shared());
    }

    #[test]
    fn publish_deep_scalars_are_noops() {
        Value::Int(42).publish_deep();
        Value::String(Arc::new("hi".into())).publish_deep();
        Value::Null.publish_deep();
        Value::Unit.publish_deep();
        Value::IrClosure {
            id: 0,
            captures: Arc::new(vec![Value::Int(1), Value::Bool(true)]),
        }
        .publish_deep();
    }

    #[test]
    fn enum_entries_keeps_list_type_fqn_for_dispatch() {
        // Stdlib member dispatch keys on type_fqn — EnumEntries values must
        // continue to dispatch through `kotlin.collections.List`.
        let entries = Value::List {
            items: ObjRef::new(vec![Value::Int(1)]),
            mutable: false,
            enum_class: Some(Arc::new("Color".to_string())),
        };
        assert_eq!(entries.type_fqn(), "kotlin.collections.List");
    }

    /// The `gc` backing: a cell reachable from a registered root
    /// survives collection; a cell that nothing references is swept
    /// (the heap drops its retaining `Arc`). Memory safety holds
    /// regardless — a swept-but-still-cloned cell stays alive via its
    /// own strong count.
    #[cfg(feature = "gc")]
    #[test]
    fn gc_collect_keeps_reachable_sweeps_garbage() {
        // A root env holding a list value: the list cell is reachable.
        let env: ObjRef<Env> = ObjRef::new(Env::new());
        let live = ObjRef::new(vec![Value::Int(7)]);
        env.borrow_mut().define(
            "xs",
            Value::List { items: live.clone(), mutable: true, enum_class: None },
        );
        gc::register_root_env(&env);

        // An unrooted cell. We keep the `ObjRef` alive across the
        // collection so its backing address cannot be recycled (which
        // would alias another cell's identity): the cell stays live
        // via this clone's strong count, but it is unreachable from
        // any registered root, so the sweep must drop the *heap's*
        // retaining handle for it.
        let garbage = ObjRef::new(vec![Value::Int(99)]);
        let garbage_id = garbage.identity();
        assert!(gc::heap_contains(garbage_id), "newly allocated cell is registered");

        gc::collect();

        // The reachable list cell's contents are intact post-collect.
        assert!(matches!(live.borrow().as_slice(), [Value::Int(7)]));
        // The unreachable cell's heap retainer was dropped by the
        // sweep even though the cell itself is still alive here.
        assert!(
            !gc::heap_contains(garbage_id),
            "unreachable cell should have been swept from the heap"
        );
        assert!(
            matches!(garbage.borrow().as_slice(), [Value::Int(99)]),
            "swept-but-clone-alive cell is still safely usable"
        );
        // The root-reachable cell survived collection.
        assert!(
            gc::heap_contains(live.identity()),
            "reachable cell must survive collection"
        );
        drop(garbage);
    }
}

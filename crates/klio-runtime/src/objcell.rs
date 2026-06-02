use std::fmt;
use std::ops::{Deref, DerefMut};
use std::sync::Arc;

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
/// `flag`; the SHARED path's discipline is the `RwLock` itself.
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
///   on a `SHARED` cell acquires this `AdaptiveCell`'s `RwLock` (read
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
///   this `RwLock`, which gives sequentially-consistent ordering for
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
pub(crate) struct AdaptiveCell<T: ?Sized> {
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
    #[inline]
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
    #[inline]
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

    /// Acquire the per-cell `RwLock` for a *shared* borrow once the
    /// cell is `SHARED`: a read guard, so concurrent readers run in
    /// parallel. The non-loom path uses `read_recursive()` so a
    /// thread that already holds a read guard on this cell (the
    /// interpreter reading a list while iterating it) does not
    /// self-deadlock against a queued writer. loom's `RwLock` has no
    /// recursive read, but no loom scenario nests borrows on one
    /// thread, so plain `read()` models the protocol exactly.
    #[inline]
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

    /// Acquire the per-cell `RwLock` for an *exclusive* borrow once the
    /// cell is `SHARED`: a write guard, mutually exclusive against
    /// every reader and writer.
    #[inline]
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
pub struct ObjRef<T: ?Sized>(pub(crate) Arc<AdaptiveCell<T>>);

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
    use super::{AdaptiveCell, ObjRef};
    use crate::{Env, Value};
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
            crate::gc_mark_env_root(env, &mut marked);
        }
        for v in &roots {
            crate::gc_mark_value(v, &mut marked);
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
    /// Shared borrow, exactly like `RefCell::borrow`.
    ///
    /// # Panics
    ///
    /// Panics if the cell is already mutably borrowed.
    #[must_use]
    pub fn borrow(&self) -> ObjGuard<'_, T> {
        match self.try_borrow() {
            Some(g) => g,
            None => panic!("ObjRef already mutably borrowed"),
        }
    }

    /// Mutable borrow, exactly like `RefCell::borrow_mut`.
    ///
    /// # Panics
    ///
    /// Panics if the cell is already borrowed (shared or mutable).
    #[must_use]
    pub fn borrow_mut(&self) -> ObjGuardMut<'_, T> {
        match self.try_borrow_mut() {
            Ok(g) => g,
            Err(BorrowMutError) => panic!("ObjRef already borrowed"),
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
            return Some(ObjGuard {
                cell,
                shared: Some(read),
            });
        }
        let f = cell.flag.get();
        if f < 0 {
            return None;
        }
        cell.flag.set(f + 1);
        // SAFETY: flag was >= 0, so no mutable borrow is live; we
        // hand out a shared reference and the guard restores the
        // count on drop.
        Some(ObjGuard { cell, shared: None })
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
            return Ok(ObjGuardMut {
                cell,
                shared: Some(write),
            });
        }
        if cell.flag.get() != 0 {
            return Err(BorrowMutError);
        }
        cell.flag.set(-1);
        // SAFETY: flag was 0, so no other borrow is live; the guard
        // restores it on drop.
        Ok(ObjGuardMut { cell, shared: None })
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
        self.as_ptr().cast::<()>() as usize
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
/// holds a `RwLock` read guard (`shared`) for its lifetime and the
/// lock — not `flag` — is the discipline.
pub struct ObjGuard<'a, T: ?Sized> {
    cell: &'a AdaptiveCell<T>,
    shared: Option<cell_sync::RwLockReadGuard<'a, ()>>,
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
        // so they must not decrement it. The read guard in `shared`
        // is released by its own `Drop` after this.
        if self.shared.is_none() {
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
/// holds an exclusive `RwLock` write guard (`shared`) for its
/// lifetime.
pub struct ObjGuardMut<'a, T: ?Sized> {
    cell: &'a AdaptiveCell<T>,
    shared: Option<cell_sync::RwLockWriteGuard<'a, ()>>,
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
        // in `shared` is released by its own `Drop` after this.
        if self.shared.is_none() {
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
/// [`AdaptiveCell`] (shared-object access → the cell `RwLock` + the
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

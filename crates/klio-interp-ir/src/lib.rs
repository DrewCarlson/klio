//! IR-native interpreter.
//!
//! This crate executes a frozen `klio_ir::Module` end-to-end with no
//! AST evaluator, no callback into `klio-interp`, and no `IrHost`
//! shim that synthesises AST. The IR cutover plan replaces the tree
//! walker by growing this crate's `Vm` until every Kotlin shape we
//! support has a Vm-native execution path.
//!
//! The crate intentionally does not depend on `klio-interp`. Module
//! construction goes through `klio_ir::lower` directly; the driver
//! (`klio-cli`) parses + type-checks via the shared front-end crates
//! and hands the resulting AST to this crate's `build_module`. Until
//! W12 the legacy `klio` binary keeps the tree walker available as a
//! reference; the new Vm runs alongside under `--ir-vm`.

use std::cell::RefCell;
use std::sync::atomic::{AtomicU64, Ordering as AtomicOrdering};
use std::sync::{Arc, Mutex};

pub use klio_runtime::Output;

/// Runtime-lowered method bodies for anonymous-object / local
/// classes, keyed by `(class, method)`: the owning module, the body's
/// `FuncId`, and the captured-name/value pairs to bind on call.
type AnonMethods = klio_runtime::ObjRef<
    std::collections::HashMap<
        (String, String),
        (
            Arc<klio_ir::Module>,
            klio_ir::FuncId,
            Vec<(String, klio_runtime::Value)>,
        ),
    >,
>;

pub mod build;

mod vm {
    pub(crate) mod coroutines;
    pub(crate) mod host_call_func;
    pub(crate) mod host_call_member;
    pub(crate) mod host_call_value;
    pub(crate) mod host_classes;
    pub(crate) mod host_fields;
    pub(crate) mod host_globals;
    pub(crate) mod host_impl;
    pub(crate) mod host_instances;
    pub(crate) mod intrinsic_host;
    pub(crate) mod run;
    pub(crate) mod vmhost;
}

/// Build-time-immutable program metadata. Produced once by
/// `build::build_module` and shared O(1) by `Arc` with every OS
/// thread the program spawns (`kotlin.concurrent.thread`). Nothing
/// here is mutated after construction, so sharing it across threads
/// needs no synchronization.
pub struct ProgramImage {
    /// Top-level property name → 0-arg initializer `FuncId`. Mirrors
    /// `Vm::top_level_props` so a `VmHost` can drive a property's
    /// initializer on demand when it is read before the in-order
    /// startup pass reaches it.
    top_level_prop_inits: std::collections::HashMap<String, klio_ir::FuncId>,
    body_prop_inits: std::collections::HashMap<(String, String), klio_ir::FuncId>,
    instance_prop_getters: std::collections::HashMap<(String, String), klio_ir::FuncId>,
    instance_prop_setters: std::collections::HashMap<(String, String), klio_ir::FuncId>,
    parent_ctor_args: std::collections::HashMap<String, Vec<klio_ir::FuncId>>,
    init_blocks: std::collections::HashMap<String, Vec<klio_ir::FuncId>>,
    extension_props: std::collections::HashMap<(String, String), klio_ir::FuncId>,
    extension_prop_setters: std::collections::HashMap<(String, String), klio_ir::FuncId>,
    secondary_ctors: std::collections::HashMap<String, Vec<build::SecondaryCtorEntry>>,
    class_delegates: std::collections::HashMap<String, Vec<(String, klio_ir::FuncId)>>,
    func_defaults: std::collections::HashMap<klio_ir::FuncId, Vec<Option<klio_ir::FuncId>>>,
    installed_bindings: Arc<klio_stdlib::HostBindings>,
}

/// Lambda/closure side-table shared across every OS thread of one
/// program. Indices (`Value::IrClosure { id }`) are append-stable —
/// `push` only ever extends — so a `Mutex<Vec<_>>` keeps cross-thread
/// closure creation sound while every existing id stays valid.
#[derive(Clone)]
pub struct SharedClosures(Arc<Mutex<Vec<ClosureInfo>>>);

impl SharedClosures {
    fn new() -> Self {
        Self(Arc::new(Mutex::new(Vec::new())))
    }
    fn get(&self, id: usize) -> Option<ClosureInfo> {
        self.0
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
            .get(id)
            .cloned()
    }
    /// Append `info`, returning its stable id.
    fn push(&self, info: ClosureInfo) -> u64 {
        let mut g = self
            .0
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner);
        let id = g.len() as u64;
        g.push(info);
        id
    }
}

/// Bounded concurrency gate for the parallel coroutine dispatchers.
///
/// `Dispatchers.Default`/`IO` realize parallelism by spawning a real
/// OS thread per dispatched coroutine body (reusing the proven
/// `spawn_os_thread` publication + cross-thread join machinery). A
/// raw thread-per-coroutine would let 1000 `async`s create 1000 live
/// threads; this counting semaphore caps how many dispatched bodies
/// run *concurrently*. A worker thread is still spawned per job
/// (cheap to create, parks immediately on the gate), but only `cap`
/// of them execute their Kotlin body at once — the rest block on the
/// `Condvar` until a permit frees. `Default`'s cap tracks
/// `available_parallelism()` (CPU-bound); `IO`'s is a large fixed cap
/// (blocking-offload, elastic in practice).
struct DispatchGate {
    inner: Mutex<usize>,
    cv: std::sync::Condvar,
}

impl DispatchGate {
    fn new(cap: usize) -> Self {
        Self {
            inner: Mutex::new(cap.max(1)),
            cv: std::sync::Condvar::new(),
        }
    }
    /// Block until a permit is free, then take it.
    fn acquire(&self) {
        let mut avail = self
            .inner
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner);
        while *avail == 0 {
            avail = self
                .cv
                .wait(avail)
                .unwrap_or_else(std::sync::PoisonError::into_inner);
        }
        *avail -= 1;
    }
    /// Return a permit and wake one waiter.
    fn release(&self) {
        let mut avail = self
            .inner
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner);
        *avail += 1;
        self.cv.notify_one();
    }
}

/// Process-global Default-dispatcher gate, sized to the host's
/// hardware parallelism. CPU-bound coroutine bodies dispatched on
/// `Dispatchers.Default` contend for these permits so the machine
/// runs at most ~one busy body per core.
fn default_gate() -> &'static DispatchGate {
    static GATE: std::sync::OnceLock<DispatchGate> = std::sync::OnceLock::new();
    GATE.get_or_init(|| {
        let cap = std::thread::available_parallelism().map_or(4, std::num::NonZero::get);
        DispatchGate::new(cap)
    })
}

/// Process-global IO-dispatcher gate. `Dispatchers.IO` is for
/// blocking offload, so its cap is large (an effectively-elastic
/// pool) rather than CPU-bound.
fn io_gate() -> &'static DispatchGate {
    static GATE: std::sync::OnceLock<DispatchGate> = std::sync::OnceLock::new();
    GATE.get_or_init(|| DispatchGate::new(64))
}

/// One Vm instance executes a single program against the IR module
/// produced by the front end.
pub struct Vm {
    module: Arc<klio_ir::Module>,
    globals: klio_runtime::ObjRef<klio_runtime::Env>,
    scheduler: Box<dyn klio_runtime::Scheduler>,
    /// Process-wide monotonic instance-id source. Shared (atomically)
    /// across every OS thread so ids stay unique program-wide.
    instance_id_counter: Arc<AtomicU64>,
    /// Per-class runtime metadata produced by `build::build_module`.
    /// Shared by handle with spawned threads.
    classes: klio_runtime::ObjRef<std::collections::HashMap<String, Arc<klio_runtime::ClassDef>>>,
    /// Top-level property initialiser `FuncIds`. Run at `Vm::run` start
    /// so globals see the initial values.
    top_level_props: Vec<(String, klio_ir::FuncId)>,
    /// Enum-entry ctor-arg thunks to evaluate at startup.
    enum_entry_arg_inits: Vec<(String, String, Vec<klio_ir::FuncId>)>,
    /// Default outer instance to attach to locally-registered
    /// classes. Shared by handle with spawned threads.
    class_default_outer:
        klio_runtime::ObjRef<std::collections::HashMap<String, klio_runtime::Value>>,
    /// Runtime-lowered method bodies for anonymous-object / local
    /// classes. Shared by handle with spawned threads.
    anon_methods: AnonMethods,
    /// Closure side-table, shared (mutex) across threads so a thread
    /// body can create lambdas without invalidating existing ids.
    closures: SharedClosures,
    /// Build-time-immutable program metadata, shared O(1) by `Arc`
    /// with every spawned OS thread.
    prog: Arc<ProgramImage>,
    /// Shared serialized stdout sink. The root and every spawned
    /// thread write through this so concurrent `println` is
    /// serialized; single-threaded ordering is byte-identical.
    out_sink: klio_runtime::SharedOutput,
    /// Host-side registry of live spawned-thread join handles, keyed
    /// by the opaque id handed back to `Thread.join`.
    threads: Arc<Mutex<std::collections::HashMap<u64, ThreadEntry>>>,
}

/// One spawned OS thread tracked by the host. The `JoinHandle`
/// yields the thread body's terminal result (an error string carries
/// a thrown Kotlin Throwable rendered for the joiner).
struct ThreadEntry {
    handle: Option<std::thread::JoinHandle<Result<(), klio_runtime::RuntimeError>>>,
}

/// `Send` capture of the shared program state for a new OS thread.
/// Built by [`Vm::spawn_child`] on the parent, moved into the
/// `std::thread::spawn` closure, then turned back into a [`Vm`] with
/// [`SendableVmSeed::materialize`] on the new thread. Every field is
/// an owned shared handle (`Arc` / `ObjRef` / atomic), so the seed
/// outlives the spawning call and carries no borrow.
pub struct SendableVmSeed {
    module: Arc<klio_ir::Module>,
    globals: klio_runtime::ObjRef<klio_runtime::Env>,
    instance_id_counter: Arc<AtomicU64>,
    classes: klio_runtime::ObjRef<std::collections::HashMap<String, Arc<klio_runtime::ClassDef>>>,
    prog: Arc<ProgramImage>,
    anon_methods: AnonMethods,
    class_default_outer:
        klio_runtime::ObjRef<std::collections::HashMap<String, klio_runtime::Value>>,
    closures: SharedClosures,
    out_sink: klio_runtime::SharedOutput,
    threads: Arc<Mutex<std::collections::HashMap<u64, ThreadEntry>>>,
}

impl SendableVmSeed {
    /// Materialize a child `Vm` on the current (new) OS thread. The
    /// child shares the parent's program image, globals, classes,
    /// closure table, id counter, and stdout sink; it gets its own
    /// fresh cooperative scheduler (coroutine state is `thread_local`
    /// already).
    #[must_use]
    pub fn materialize(self) -> Vm {
        Vm {
            module: self.module,
            globals: self.globals,
            scheduler: Box::new(klio_runtime::InProcessScheduler::new()),
            instance_id_counter: self.instance_id_counter,
            classes: self.classes,
            top_level_props: Vec::new(),
            enum_entry_arg_inits: Vec::new(),
            class_default_outer: self.class_default_outer,
            anon_methods: self.anon_methods,
            closures: self.closures,
            prog: self.prog,
            out_sink: self.out_sink,
            threads: self.threads,
        }
    }
}

const _: fn() = || {
    fn assert_send<T: Send>() {}
    assert_send::<Vm>();
    assert_send::<SendableVmSeed>();
};

#[derive(Clone)]
struct ClosureInfo {
    body_func: klio_ir::FuncId,
    n_params: usize,
    /// Capture names, in the same order as the runtime captures
    /// vec. Lets the Vm's `read_lambda_capture` host method map a
    /// name back to the captured value index.
    capture_names: Vec<String>,
    /// Live capture values. Stored behind a shared interior-mutable
    /// handle so the lambda body's `StoreGlobal` writes propagate (the
    /// dispatch path layers each captured name into a per-call env,
    /// then reads back into this vec). The outer-frame
    /// `WritebackCaptures` Inst observes the updated values via
    /// `read_lambda_capture`.
    captures: klio_runtime::ObjRef<Vec<klio_runtime::Value>>,
}

/// Vm-level errors.
#[derive(Debug, thiserror::Error)]
pub enum VmError {
    #[error("main function not found in module")]
    InvalidMain,
    #[error("IR eval: {0}")]
    Eval(String),
}

impl From<klio_ir::eval::EvalError> for VmError {
    fn from(e: klio_ir::eval::EvalError) -> Self {
        // Format Throw variants with the thrown exception's
        // fqn + message so the user-facing diagnostic is
        // actionable rather than the trait's generic phrase.
        if let klio_ir::eval::EvalError::Throw(v) = &e
            && let klio_runtime::Value::Exception { fqn, message, .. } = v
        {
            let msg = message
                .as_deref()
                .map_or("<no message>", std::string::String::as_str);
            return VmError::Eval(format!("uncaught {fqn}: {msg}"));
        }
        VmError::Eval(e.to_string())
    }
}

/// IR Host implementation. Every method native to the new Vm lives
/// here. Methods that have no native implementation yet raise
/// `EvalError::Unimplemented` (carrying the surface name) so the
/// failure surfaces are easy to identify and migrate one by one.
/// Whether `name` names a property (not a function) reachable on
/// `receiver`'s class. Drives bound/unbound member-reference
/// invocation: a property reference reads the field, a function
/// reference calls the method. Walks the parent chain and declared
/// supertypes so inherited properties resolve too. A stored field
/// already present on the instance is conclusive.
fn member_is_property(
    classes: &klio_runtime::ObjRef<std::collections::HashMap<String, Arc<klio_runtime::ClassDef>>>,
    receiver: &klio_runtime::Value,
    name: &str,
) -> bool {
    let start = match receiver {
        klio_runtime::Value::Instance(inst) => {
            let b = inst.borrow();
            if b.fields.iter().any(|(n, _)| n == name) {
                return true;
            }
            Arc::clone(&b.class)
        }
        klio_runtime::Value::Class(cls) => Arc::clone(cls),
        _ => return false,
    };
    let mut stack = vec![start];
    let mut seen: Vec<String> = Vec::new();
    while let Some(c) = stack.pop() {
        if seen.iter().any(|s| s == &c.name) {
            continue;
        }
        seen.push(c.name.clone());
        if c.primary_params
            .iter()
            .any(|p| p.property.is_some() && p.name == name)
        {
            return true;
        }
        if c.body_properties.iter().any(|p| p.name == name) {
            return true;
        }
        if let Some(p) = c.parent.borrow().clone() {
            stack.push(p);
        }
        for sn in &c.supertype_names {
            if let Some(sc) = classes.borrow().get(sn).cloned() {
                stack.push(sc);
            }
        }
    }
    false
}

/// Whether a body's declared primitive parameter type can accept `v`.
/// Conservative: only a *definite* concrete-primitive-vs-different-
/// primitive pairing rejects. A generic / supertype / non-primitive
/// param type, or a non-primitive argument, always accepts — so this
/// never rejects a legitimately-bound overload, only flags a body
/// bound to the wrong type-specialized sibling.
fn primitive_param_accepts(type_name: &str, v: &klio_runtime::Value) -> bool {
    use klio_runtime::Value::{
        Bool, Byte, Char, Double, Float, Int, Long, Short, String, UByte, UInt, ULong, UShort,
    };
    let arg_is_primitive = matches!(
        v,
        Int(_)
            | Long(_)
            | Short(_)
            | Byte(_)
            | UInt(_)
            | ULong(_)
            | UShort(_)
            | UByte(_)
            | Double(_)
            | Float(_)
            | Char(_)
            | Bool(_)
            | String(_)
    );
    if !arg_is_primitive {
        return true;
    }
    match type_name {
        "Int" => matches!(v, Int(_)),
        "Long" => matches!(v, Long(_)),
        "Short" => matches!(v, Short(_)),
        "Byte" => matches!(v, Byte(_)),
        "UInt" => matches!(v, UInt(_)),
        "ULong" => matches!(v, ULong(_)),
        "UShort" => matches!(v, UShort(_)),
        "UByte" => matches!(v, UByte(_)),
        "Double" => matches!(v, Double(_)),
        "Float" => matches!(v, Float(_)),
        "Char" => matches!(v, Char(_)),
        "Boolean" => matches!(v, Bool(_)),
        "String" => matches!(v, String(_)),
        _ => true,
    }
}

struct VmHost<'a> {
    globals: klio_runtime::ObjRef<klio_runtime::Env>,
    module: Arc<klio_ir::Module>,
    scheduler: &'a mut dyn klio_runtime::Scheduler,
    out: &'a mut dyn Output,
    instance_id_counter: Arc<AtomicU64>,
    classes: klio_runtime::ObjRef<std::collections::HashMap<String, Arc<klio_runtime::ClassDef>>>,
    prog: Arc<ProgramImage>,
    anon_methods: AnonMethods,
    class_default_outer:
        klio_runtime::ObjRef<std::collections::HashMap<String, klio_runtime::Value>>,
    closures: SharedClosures,
    out_sink: klio_runtime::SharedOutput,
    threads: Arc<Mutex<std::collections::HashMap<u64, ThreadEntry>>>,
}

/// Pack trailing positional args into a single `Value::Array` when
/// the target function's last param is marked `vararg`. Leaves
/// non-vararg signatures untouched. A single passed-in array slips
/// through as-is to support `f(*arr)` call sites.
/// True when an extension's declared receiver type name denotes a
/// user / pack class — i.e. not a builtin, an open supertype a
/// builtin satisfies (`Any`, `CharSequence`, `Comparable`, …), or a
/// bare type parameter. Such a receiver can never be a builtin
/// value, so the extension is definitively inapplicable to one.
/// Permissive receiver/param-type compatibility used by extension
/// overload pickers. Returns false only when the runtime value
/// (built-in: List, Map, Result, String, …) provably does not satisfy
/// the parameter's nominal type. Instances and unconstrained / Any /
/// function-typed / generic parameters always pass — the per-candidate
/// scorer decides among compatible candidates.
fn receiver_compatible_with_param(
    receiver: &klio_runtime::Value,
    param_ty: &klio_ir::TypeRef,
) -> bool {
    if matches!(receiver, klio_runtime::Value::Instance(_)) {
        return true;
    }
    let pn = param_ty.name.as_str();
    let pn_simple = pn.rsplit('.').next().unwrap_or(pn);
    if matches!(pn_simple, "Any" | "Any?" | "Unit")
        || pn_simple.starts_with("Function")
        || (pn_simple.len() <= 2 && pn_simple.chars().all(|c| c.is_ascii_uppercase()))
    {
        return true;
    }
    receiver.is_runtime_type(pn_simple)
}

fn ext_decl_recv_is_user_class(ty_name: &str) -> bool {
    let s = ty_name.rsplit('.').next().unwrap_or(ty_name);
    if s.is_empty() {
        return false;
    }
    if s.len() <= 2 && s.chars().all(|c| c.is_ascii_uppercase()) {
        return false; // type parameter (T, R, E, K, V, …)
    }
    !matches!(
        s,
        "String"
            | "StringBuilder"
            | "CharSequence"
            | "Appendable"
            | "Int"
            | "Long"
            | "Short"
            | "Byte"
            | "Double"
            | "Float"
            | "Char"
            | "Boolean"
            | "Number"
            | "Array"
            | "List"
            | "MutableList"
            | "Collection"
            | "Iterable"
            | "Map"
            | "MutableMap"
            | "Set"
            | "MutableSet"
            | "Sequence"
            | "Comparable"
            | "Any"
            | "Unit"
    )
}

/// True when `fqn` names a builtin `kotlin.*` Throwable-hierarchy class
/// that klio constructs as a host `Value::Exception` (via an `excn_*`
/// intrinsic) rather than a generic Instance. These ship as
/// declaration-only `expect` classes whose constructors have no body to
/// store `message`/`cause`, so their construction must route to the host
/// constructor. Matching is on the exact builtin FQN, so a user subclass
/// — which carries its own FQN — is never intercepted.
fn is_builtin_throwable_fqn(fqn: &str) -> bool {
    matches!(
        fqn,
        "kotlin.Throwable"
            | "kotlin.Exception"
            | "kotlin.Error"
            | "kotlin.RuntimeException"
            | "kotlin.IllegalArgumentException"
            | "kotlin.IllegalStateException"
            | "kotlin.IndexOutOfBoundsException"
            | "kotlin.NullPointerException"
            | "kotlin.ArithmeticException"
            | "kotlin.ClassCastException"
            | "kotlin.NoSuchElementException"
            | "kotlin.NumberFormatException"
            | "kotlin.UnsupportedOperationException"
            | "kotlin.NoWhenBranchMatchedException"
            | "kotlin.ConcurrentModificationException"
            | "kotlin.AssertionError"
    )
}

/// True for a builtin (non-`Instance`, non-`Class`) value — one that
/// can never be an instance of a user-declared class.
fn value_is_builtin(v: &klio_runtime::Value) -> bool {
    matches!(
        v,
        klio_runtime::Value::String(_)
            | klio_runtime::Value::StringBuilder(_)
            | klio_runtime::Value::Int(_)
            | klio_runtime::Value::Long(_)
            | klio_runtime::Value::Short(_)
            | klio_runtime::Value::Byte(_)
            | klio_runtime::Value::Double(_)
            | klio_runtime::Value::Float(_)
            | klio_runtime::Value::Char(_)
            | klio_runtime::Value::Bool(_)
            | klio_runtime::Value::Array { .. }
            | klio_runtime::Value::List { .. }
            | klio_runtime::Value::Map { .. }
            | klio_runtime::Value::Result { .. }
    )
}

fn pack_vararg_args(
    func: &klio_ir::Func,
    args: Vec<klio_runtime::Value>,
) -> Vec<klio_runtime::Value> {
    if let Some(last) = func.params.last()
        && last.is_vararg
    {
        let fixed = func.params.len().saturating_sub(1);
        if args.len() == func.params.len()
            && matches!(args.last(), Some(klio_runtime::Value::Array { .. }))
        {
            return args;
        }
        let mut out: Vec<klio_runtime::Value> = Vec::with_capacity(func.params.len());
        for v in args.iter().take(fixed) {
            out.push(v.clone());
        }
        let rest: Vec<klio_runtime::Value> = args.into_iter().skip(fixed).collect();
        out.push(klio_runtime::Value::Array {
            items: klio_runtime::ObjRef::new(rest),
            prim: None,
        });
        return out;
    }
    args
}

/// Build the `n_params`-length argument vector for a closure call,
/// filling positions past the provided args from the target's
/// registered default-arg thunks (each binds the params before it),
/// falling back to `Null` when a slot has no default. This mirrors
/// the trailing-arg padding `Vm::call_func` does for top-level
/// functions so a local `fun f(a, b = a + 1)` called `f(1)` yields
/// `b == 2`.
/// A `TypeRef` denoting a Kotlin function type — `() -> T` lowers
/// to a `FunctionN` / `kotlin.FunctionN` nominal, or carries an
/// arrow in the rendered name.
fn is_function_type(ty: &klio_ir::TypeRef) -> bool {
    let n = ty.name.rsplit('.').next().unwrap_or(&ty.name);
    n.starts_with("Function") || ty.name.contains("->")
}

/// Whether a runtime value can be invoked as `f(...)`.
fn value_is_callable(v: &klio_runtime::Value) -> bool {
    matches!(
        v,
        klio_runtime::Value::IrClosure { .. }
            | klio_runtime::Value::Lambda { .. }
            | klio_runtime::Value::Function { .. }
            | klio_runtime::Value::Intrinsic { .. }
            | klio_runtime::Value::BoundMethod { .. }
            | klio_runtime::Value::PropertyRef { .. }
    )
}

fn pad_args_with_defaults<H: klio_ir::eval::Host>(
    module: &klio_ir::Module,
    n_params: usize,
    provided: &[klio_runtime::Value],
    defaults: Option<&Vec<Option<klio_ir::FuncId>>>,
    host: &mut H,
) -> Result<Vec<klio_runtime::Value>, klio_ir::eval::EvalError> {
    let mut call_args: Vec<klio_runtime::Value> = Vec::with_capacity(n_params);
    for i in 0..n_params {
        if i < provided.len() {
            call_args.push(provided[i].clone());
            continue;
        }
        let dfid = defaults.and_then(|d| d.get(i).copied().flatten());
        if let Some(dfid) = dfid {
            let dfunc = module.funcs.get(dfid.0 as usize).cloned().ok_or_else(|| {
                klio_ir::eval::EvalError::Type(format!(
                    "default-arg FuncId {} out of range",
                    dfid.0
                ))
            })?;
            // A default-arg thunk lowered inside an extension fn
            // body that references the receiver (`toIndex = size` on
            // `IntArray.fill`) records `this` as a capture, not a
            // param. Seed the capture slot with the receiver so the
            // bare `size` resolves through it instead of failing as
            // an unresolved global.
            let captures: Vec<klio_runtime::Value> = if call_args.is_empty() {
                Vec::new()
            } else {
                vec![call_args[0].clone()]
            };
            let v = klio_ir::eval::eval_with_captures(
                module,
                &dfunc,
                call_args.clone(),
                captures,
                host,
            )?;
            call_args.push(v);
        } else {
            call_args.push(klio_runtime::Value::Null);
        }
    }
    Ok(call_args)
}

/// Structural value hash matching `Value::structural_eq`. Used by
/// data-class auto `hashCode`. Mirrors klio-interp's helper.
/// Kotlin-faithful `hashCode()` for builtin value types. Matches the values
/// `kotlinc` produces so a program that prints `x.hashCode()` agrees, and —
/// critically — terminates: dispatching `hashCode` on a primitive/collection
/// previously found no handler and fell through to a recursive fallback that
/// allocated without bound (OOM). Instances are handled by their own
/// identity/override path and are not routed here.
// Kotlin hashCode() reinterprets/folds bit patterns (UInt as Int, the
// Long fold, Double bits) so truncation/wrap/sign-loss are required.
#[allow(
    clippy::cast_possible_wrap,
    clippy::cast_possible_truncation,
    clippy::cast_sign_loss
)]
fn kotlin_hash_code(v: &klio_runtime::Value) -> i32 {
    use klio_runtime::Value::{
        Array, Bool, Byte, Char, Double, Float, Int, List, Long, Map, Null, Range, Set, Short,
        String, UByte, UInt, ULong, UShort,
    };
    match v {
        Null => 0,
        Bool(b) => {
            if *b {
                1231
            } else {
                1237
            }
        }
        Char(c) => i32::from(*c),
        Byte(x) => i32::from(*x),
        Short(x) => i32::from(*x),
        Int(x) => *x,
        UByte(x) => i32::from(*x),
        UShort(x) => i32::from(*x),
        UInt(x) => *x as i32,
        Long(l) => (*l ^ (((*l as u64) >> 32) as i64)) as i32,
        ULong(u) => (*u ^ (*u >> 32)) as i32,
        // Kotlin/JVM Float/Double.hashCode use the IEEE bit pattern.
        Float(f) => f.to_bits() as i32,
        Double(d) => {
            let b = d.to_bits() as i64;
            (b ^ (((b as u64) >> 32) as i64)) as i32
        }
        // java.lang.String polynomial hash: s[0]*31^(n-1) + … + s[n-1].
        String(s) => {
            let mut h: i32 = 0;
            for ch in s.encode_utf16() {
                h = h.wrapping_mul(31).wrapping_add(i32::from(ch));
            }
            h
        }
        // List: h=1; h = 31*h + e.hashCode().  Set: sum of element hashes.
        List { items, .. } => {
            let mut h: i32 = 1;
            for e in items.borrow().iter() {
                h = h.wrapping_mul(31).wrapping_add(kotlin_hash_code(e));
            }
            h
        }
        Set { items, .. } => items
            .borrow()
            .iter()
            .fold(0i32, |acc, e| acc.wrapping_add(kotlin_hash_code(e))),
        Map { entries, .. } => entries.borrow().iter().fold(0i32, |acc, (k, val)| {
            acc.wrapping_add(kotlin_hash_code(k) ^ kotlin_hash_code(val))
        }),
        Array { items, .. } => {
            // Arrays use identity hashCode in Kotlin, but a deterministic
            // structural fold is the least-surprising answer here and avoids
            // leaking a nondeterministic identity. (Array.hashCode() is rarely
            // printed; contentHashCode() is the structural API.)
            let mut h: i32 = 1;
            for e in items.borrow().iter() {
                h = h.wrapping_mul(31).wrapping_add(kotlin_hash_code(e));
            }
            h
        }
        // Kotlin hashes a plain `IntRange`/`CharRange` (`a..b`, `a until b`,
        // step 1) as `31*first+last`, but an `IntProgression` (`downTo`,
        // `step n`) as `31*(31*first+last)+step`. klio's Value::Range carries
        // no range-vs-progression tag, so use step==1 as the discriminant
        // (the common case; `a..b step 1` — a step-1 progression — is the only
        // rare divergence). Empty ranges hash to -1.
        Range {
            start, end, step, ..
        } => {
            let (f, l, s) = (*start as i32, *end as i32, *step as i32);
            let empty = if *step > 0 { start > end } else { start < end };
            if empty {
                -1
            } else if *step == 1 {
                31i32.wrapping_mul(f).wrapping_add(l)
            } else {
                (31i32.wrapping_mul(31i32.wrapping_mul(f).wrapping_add(l))).wrapping_add(s)
            }
        }
        // Anything else (closures, opaque host values): fall back to the
        // structural digest — terminating, just not JVM-identical.
        other => value_structural_hash(other),
    }
}

// Folds a 64-bit digest down to the i32 Kotlin hashCode() returns.
#[allow(clippy::cast_possible_truncation)]
fn value_structural_hash(v: &klio_runtime::Value) -> i32 {
    use klio_runtime::Value::{
        Bool, Byte, Char, Double, Float, Int, Long, Null, Short, String, UByte, UInt, ULong,
        UShort, Unit,
    };
    use std::hash::{Hash, Hasher};
    let mut h = std::collections::hash_map::DefaultHasher::new();
    match v {
        Unit => 0i32.hash(&mut h),
        Null => 1i32.hash(&mut h),
        Bool(b) => {
            2i32.hash(&mut h);
            b.hash(&mut h);
        }
        Char(c) => {
            3i32.hash(&mut h);
            c.hash(&mut h);
        }
        Int(i) => {
            4i32.hash(&mut h);
            i64::from(*i).hash(&mut h);
        }
        Long(l) => {
            4i32.hash(&mut h);
            l.hash(&mut h);
        }
        Short(s) => {
            4i32.hash(&mut h);
            i64::from(*s).hash(&mut h);
        }
        Byte(b) => {
            4i32.hash(&mut h);
            i64::from(*b).hash(&mut h);
        }
        UInt(u) => {
            4i32.hash(&mut h);
            i64::from(*u).hash(&mut h);
        }
        ULong(u) => {
            4i32.hash(&mut h);
            u.hash(&mut h);
        }
        UShort(u) => {
            4i32.hash(&mut h);
            i64::from(*u).hash(&mut h);
        }
        UByte(u) => {
            4i32.hash(&mut h);
            i64::from(*u).hash(&mut h);
        }
        Float(f) => {
            5i32.hash(&mut h);
            f.to_bits().hash(&mut h);
        }
        Double(d) => {
            5i32.hash(&mut h);
            d.to_bits().hash(&mut h);
        }
        String(s) => {
            6i32.hash(&mut h);
            s.hash(&mut h);
        }
        _ => 7i32.hash(&mut h),
    }
    h.finish() as i32
}

/// Best-effort fold of trivially-literal AST expressions to a
/// runtime Value. Used by anonymous-object body-property
/// initialisation where the IR module's full thunk-lowering
/// hasn't run.
/// Eagerly resolve a primary-constructor parameter default. Covers
/// `simple_literal` shapes plus zero-arg empty-collection factory
/// calls (`mutableListOf()` / `mutableMapOf()` / `mutableSetOf()` /
/// `listOf()` / `setOf()` / `mapOf()` / `emptyList()` / `emptySet()`
/// / `emptyMap()`) that arise in property-bag class declarations.
fn default_value_for_primary(e: &klio_ast::Expr) -> Option<klio_runtime::Value> {
    use klio_ast::Expr::{Call, Path};
    if let Some(v) = simple_literal(e) {
        return Some(v);
    }
    if let Call { callee, args, .. } = e {
        if !args.is_empty() {
            return None;
        }
        if let Path { segments, .. } = callee.as_ref()
            && segments.len() == 1
        {
            match segments[0].name.as_str() {
                "mutableListOf" | "arrayListOf" | "ArrayList" | "ArrayDeque" => {
                    return Some(klio_runtime::Value::List {
                        items: klio_runtime::ObjRef::new(Vec::new()),
                        mutable: true,
                        enum_class: None,
                        backing: None,
                    });
                }
                "listOf" | "emptyList" => {
                    return Some(klio_runtime::Value::List {
                        items: klio_runtime::ObjRef::new(Vec::new()),
                        mutable: false,
                        enum_class: None,
                        backing: None,
                    });
                }
                "mutableSetOf" | "hashSetOf" | "linkedSetOf" => {
                    return Some(klio_runtime::Value::Set {
                        items: klio_runtime::ObjRef::new(Vec::new()),
                        mutable: true,
                        backing: None,
                    });
                }
                "setOf" | "emptySet" => {
                    return Some(klio_runtime::Value::Set {
                        items: klio_runtime::ObjRef::new(Vec::new()),
                        mutable: false,
                        backing: None,
                    });
                }
                "mutableMapOf" | "hashMapOf" | "linkedMapOf" => {
                    return Some(klio_runtime::Value::Map {
                        entries: klio_runtime::ObjRef::new(Vec::new()),
                        mutable: true,
                    });
                }
                "mapOf" | "emptyMap" => {
                    return Some(klio_runtime::Value::Map {
                        entries: klio_runtime::ObjRef::new(Vec::new()),
                        mutable: false,
                    });
                }
                _ => {}
            }
        }
    }
    None
}

fn simple_literal(e: &klio_ast::Expr) -> Option<klio_runtime::Value> {
    use klio_ast::Expr::{BoolLit, CharLit, FloatLit, IntLit, NullLit, StringTemplate};
    match e {
        IntLit { value, .. } => Some(klio_runtime::Value::new_int(*value)),
        FloatLit { value, .. } => Some(klio_runtime::Value::Double(*value)),
        BoolLit { value, .. } => Some(klio_runtime::Value::Bool(*value)),
        NullLit { .. } => Some(klio_runtime::Value::Null),
        CharLit { value, .. } => Some(klio_runtime::Value::Char(*value)),
        StringTemplate { parts, .. }
            if parts
                .iter()
                .all(|p| matches!(p, klio_ast::StringPart::Text(_))) =>
        {
            let mut s = String::new();
            for p in parts {
                if let klio_ast::StringPart::Text(t) = p {
                    s.push_str(t);
                }
            }
            Some(klio_runtime::Value::String(Arc::new(s)))
        }
        _ => None,
    }
}

// Kotlin Char ranges materialize code units; the i64 cursor narrows to u16.
#[allow(clippy::cast_possible_truncation, clippy::cast_sign_loss)]
fn materialise_range_items(
    start: i64,
    end: i64,
    step: i64,
    kind: klio_runtime::RangeKind,
) -> Vec<klio_runtime::Value> {
    use klio_runtime::{RangeKind, Value};
    let mut out: Vec<Value> = Vec::new();
    let mut cur = start;
    if step > 0 {
        while cur <= end {
            match kind {
                RangeKind::Int => out.push(Value::new_int(cur)),
                RangeKind::Long => out.push(Value::Long(cur)),
                RangeKind::Char => out.push(Value::Char(cur as u16)),
            }
            cur = cur.saturating_add(step);
            if cur > end && step > 0 {
                break;
            }
        }
    } else if step < 0 {
        while cur >= end {
            match kind {
                RangeKind::Int => out.push(Value::new_int(cur)),
                RangeKind::Long => out.push(Value::Long(cur)),
                RangeKind::Char => out.push(Value::Char(cur as u16)),
            }
            cur = cur.saturating_add(step);
            if cur < end {
                break;
            }
        }
    }
    out
}

/// Stdlib `CallCtx` host adapter for native Vm dispatch. HOF
/// bindings (`map`, `forEach`, scope fns, ...) reach back through
/// this adapter to invoke the lambda they were passed. The Vm
/// dispatches `Value::IrClosure` via the IR evaluator, reusing the
/// same closure / class / globals tables the outer Vm uses.
struct VmIntrinsicHost<'a> {
    scheduler: &'a mut dyn klio_runtime::Scheduler,
    module: Arc<klio_ir::Module>,
    closures: SharedClosures,
    globals: klio_runtime::ObjRef<klio_runtime::Env>,
    classes: klio_runtime::ObjRef<std::collections::HashMap<String, Arc<klio_runtime::ClassDef>>>,
    prog: Arc<ProgramImage>,
    anon_methods: AnonMethods,
    class_default_outer:
        klio_runtime::ObjRef<std::collections::HashMap<String, klio_runtime::Value>>,
    instance_id_counter: Arc<AtomicU64>,
    out_sink: klio_runtime::SharedOutput,
    threads: Arc<Mutex<std::collections::HashMap<u64, ThreadEntry>>>,
}

/// How the default interceptor interprets a `delay` directive.
/// `Wall` (the default) consumes real wall-clock time, matching the
/// JVM. `Virtual` advances a logical clock instantly — deterministic
/// and fast, used by the test scheduler and the parity / conformance
/// harnesses.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub enum TimeMode {
    #[default]
    Wall,
    Virtual,
}

thread_local! {
    /// When set, `call_member` resolves only a real member of the
    /// receiver (the instance / IR-class / anon-object method walk)
    /// and returns not-found instead of falling back to a top-level
    /// extension, a SAM `__sam_target__` dispatch, or a global. Used
    /// by CallMemberOrGlobal to probe each implicit receiver (the
    /// lambda's own `this`, then the lexically enclosing `this@…`
    /// chain) for a *member* before any extension is considered —
    /// Kotlin's rule that a member of an implicit receiver outranks
    /// a same-named extension. This is what makes bare `collect`
    /// inside upstream `transform`'s `flow { collect { … } }` bind
    /// the enclosing source flow's `collect` member rather than the
    /// `Flow<T>.collect` extension on the inner `flow{}` collector.
    static MEMBER_ONLY_PROBE: std::cell::Cell<bool> =
        const { std::cell::Cell::new(false) };
    /// Re-entry guard for the user-Iterable extension fallback in
    /// `call_member`. The fallback drains the user iterable's
    /// `iterator()` into a list; a user iterator's `next()` may
    /// itself return Instances whose own bare-name probes must not
    /// loop back through this fallback.
    static ITERABLE_FALLBACK_ACTIVE: std::cell::Cell<bool> =
        const { std::cell::Cell::new(false) };

    static COROUTINE_TIME_MODE: std::cell::Cell<TimeMode> =
        const { std::cell::Cell::new(TimeMode::Wall) };

    /// Coroutines that parked indefinitely inside a `startCoroutine`
    /// driver and are awaiting an external `Continuation.resume`.
    /// Keyed by rendezvous slot; the resume drives the saved state to
    /// completion. Program-lifetime (the held continuation outlives
    /// the driver that started it).
    static PERSISTED_PARKED: std::cell::RefCell<
        std::collections::HashMap<i64, klio_ir::eval::SuspendState>,
    > = std::cell::RefCell::new(std::collections::HashMap::new());
}

/// Set the coroutine time mode for the current thread. The default
/// is [`TimeMode::Wall`]; tests and the parity/conformance harnesses
/// opt into [`TimeMode::Virtual`] for determinism.
pub fn set_coroutine_time_mode(mode: TimeMode) {
    COROUTINE_TIME_MODE.with(|m| m.set(mode));
}

/// Current coroutine time mode for this thread.
#[must_use]
pub fn coroutine_time_mode() -> TimeMode {
    COROUTINE_TIME_MODE.with(std::cell::Cell::get)
}

/// Layer 2 — the default `ContinuationInterceptor`.
///
/// This is the only place coroutine *scheduling* happens. The core
/// suspend engine (Layer 1, `klio_ir::eval`) is dispatcher- and
/// time-agnostic: it only pauses an activation into a
/// `SuspendState` and resumes one. Every decision about *when* and
/// in what order parked activations resume — the cooperative ready
/// queue and virtual-time advance — lives here, behind the named
/// seam below, so a later thread-dispatching interceptor can
/// replace it without touching Layer 1.
///
/// A stack of these supports nested `runBlocking` /
/// `coroutineScope`.
/// Cross-thread wakeup primitive shared between a `runBlocking`
/// driver and any worker threads it has dispatched via
/// `__kxco_dispatch` (real-thread `Dispatchers.Default`). Workers
/// post resume entries into the mailbox and notify; the driver
/// drains the mailbox and parks on the condvar when there is no
/// local progress and at least one worker is still outstanding.
pub struct DriverWakeup {
    mailbox: std::sync::Mutex<Vec<(i64, klio_runtime::Value)>>,
    pending_workers: std::sync::atomic::AtomicUsize,
    cv: std::sync::Condvar,
    owned_slots: std::sync::Mutex<std::collections::HashSet<i64>>,
}

static SLOT_OWNERS: std::sync::LazyLock<
    std::sync::Mutex<std::collections::HashMap<i64, Arc<DriverWakeup>>>,
> = std::sync::LazyLock::new(|| std::sync::Mutex::new(std::collections::HashMap::new()));

fn register_slot_owner(slot: i64, wakeup: &Arc<DriverWakeup>) {
    wakeup.add_owned_slot(slot);
    SLOT_OWNERS.lock().unwrap().insert(slot, Arc::clone(wakeup));
}

fn lookup_slot_owner(slot: i64) -> Option<Arc<DriverWakeup>> {
    SLOT_OWNERS.lock().unwrap().get(&slot).cloned()
}

fn unregister_slot(slot: i64) {
    SLOT_OWNERS.lock().unwrap().remove(&slot);
}

struct CooperativeInterceptor {
    /// Cross-thread wakeup. Shared with worker threads dispatched
    /// from this driver and with `SLOT_OWNERS` entries for any slot
    /// this driver owns. Workers post completion resumes through it.
    wakeup: Arc<DriverWakeup>,
    mode: TimeMode,
    /// Wall-clock origin; `delay` deadlines are measured from here.
    /// Set lazily on first use so an all-virtual run never reads the
    /// clock.
    started: Option<std::time::Instant>,
    next_token: u64,
    virtual_now: i64,
    /// token → (parked activation, virtual-time wakeup; `i64::MAX` =
    /// indefinite — only an explicit ready entry resumes it).
    parked: std::collections::HashMap<u64, (klio_ir::eval::SuspendState, i64)>,
    /// FIFO of tokens whose wakeup is due (timer fired or yielded).
    ready: std::collections::VecDeque<u64>,
    /// Child `launch` blocks queued during the active scope.
    launched: Vec<klio_runtime::Value>,
    /// Set by `__kxco_parkSlot` immediately before the activation
    /// unwinds with an indefinite suspend; consumed by the next
    /// `intercept_suspend` to bind that token to the slot.
    pending_slot: Option<i64>,
    /// slot id → token of the activation parked on that slot. An
    /// explicit `__kxco_resumeSlot(slot)` moves the token into
    /// `ready` and clears the entry.
    slot_to_token: std::collections::HashMap<i64, u64>,
    /// token → value the activation should observe as the result of
    /// its suspending call when resumed (the `kotlin.coroutines`
    /// `Continuation.resumeWith` payload). Absent ⇒ resume with the
    /// default `Unit`.
    token_resume_value: std::collections::HashMap<u64, klio_runtime::Value>,
}

/// The per-thread interpreter execution context — the single named
/// home for state that belongs to *one* interpreting thread.
///
/// This is the publication boundary. Everything in here is private
/// to the thread running the Vm; nothing in it may be shared with
/// another thread directly. When real threads land, each gets its
/// own `ExecState`, and the only legal cross-thread transfer of a
/// Kotlin value is through the fence-and-publish primitive — never
/// by reaching into another thread's `ExecState`. Process-global
/// configuration that is deliberately shared (e.g. the
/// `klio-stdlib` known-packages registry) lives *outside* this
/// boundary by design and is documented as such where it is
/// defined.
#[derive(Default)]
struct ExecState {
    /// Cooperative interceptor stack (nested `runBlocking` /
    /// `coroutineScope`).
    coro: RefCell<Vec<CooperativeInterceptor>>,
    /// Classes whose instance shell is mid-construction for a
    /// non-delegating secondary constructor. While a class is on
    /// this stack, `new_instance` skips secondary dispatch and
    /// builds the primary shell, so a `constructor() { … }` body
    /// that re-enters `new_instance` doesn't recurse forever.
    ctor_guard: RefCell<Vec<String>>,
    /// Enclosing-`this` stack for receiver lambdas. A scope function
    /// (`apply` / `with` / `buildString`) rebinds the lambda's
    /// implicit `this` to its receiver, but Kotlin keeps the
    /// lexically enclosing `this@Outer` reachable as an outer
    /// implicit receiver. Each receiver-lambda invocation pushes the
    /// instance it displaced; member / `this@Label` resolution falls
    /// back to the top of this stack when the inner receiver lacks
    /// the member.
    outer_this: RefCell<Vec<klio_runtime::Value>>,
    /// Outer-`this` candidates for inner-class allocation. Pushed by
    /// the IR's `Inst::NewInstance` handler before each inner-class
    /// `new_instance` call so init blocks can read the soon-to-be
    /// `outer` field through the runtime's outer-chain walk.
    inner_outer_hint: RefCell<Vec<klio_runtime::Value>>,
    /// Active receiver-lambda labels: each entry is the lambda's
    /// implicit label (the scope-function / HOF simple name like
    /// `with` / `apply`) paired with the receiver it was invoked with.
    /// `this@<label>` resolves against this stack (innermost first), so
    /// an outer `this@with` is reachable even when an inner receiver
    /// lambda has displaced the bare `this`. Distinct from `outer_this`
    /// (which is class-keyed and only holds instances) so the existing
    /// class / member-visibility walks are unaffected.
    receiver_labels: RefCell<Vec<(String, klio_runtime::Value)>>,
}

thread_local! {
    static EXEC: ExecState = ExecState::default();
    /// Separate re-entrancy booleans for the inner-class outer-chain
    /// dispatch fallback — one for the call-side (`call_member`) walk,
    /// one for the field-side (`get_field`) walk. Each prevents *its
    /// own* unbounded re-entrancy (a self-referential `outer` link /
    /// deep re-walk), exactly like a single boolean would. Keeping
    /// them independent avoids the over-suppression a *shared* guard
    /// caused: a field-side outer-chain legitimately reached from
    /// within a call-side outer-chain (the `closeCause` getter read
    /// from an inner-class method invoked via the call fallback) must
    /// still run. A shared depth counter instead re-allowed the
    /// unbounded recursion (gate hang), so this is the correct middle.
    static CALL_OUTER_ACTIVE: std::cell::Cell<bool> = const { std::cell::Cell::new(false) };
    static FIELD_OUTER_ACTIVE: std::cell::Cell<bool> = const { std::cell::Cell::new(false) };
    /// Re-entrancy stack of `(receiver-identity, name)` pairs whose
    /// `get_field` resolution is in progress along the heuristic
    /// outer-instance / enclosing-`this` fallbacks. An inner class
    /// reading an enclosing instance's getter-only property must
    /// reach the outer's *getter* via a recursive `get_field` on
    /// the outer — but the same `(outer, name)` pair must never be
    /// re-resolved through these fallbacks while already on the
    /// stack, or two instances that each forward the name to the
    /// other loop forever. Keying on identity+name makes the
    /// fallbacks provably terminating while still allowing the one
    /// legitimate hop.
    static FIELD_RESOLVE_STACK: std::cell::RefCell<Vec<(usize, String)>> =
        const { std::cell::RefCell::new(Vec::new()) };
    /// Stack of the active coroutine's `CoroutineScope` value (the
    /// `runBlocking` / driven-root scope). The suspend-implicit
    /// `kotlin.coroutines.coroutineContext` intrinsic is the
    /// *running* coroutine's context, not a member of whatever `this`
    /// a suspend member happens to have. klio has no native
    /// intrinsic, so a bare `coroutineContext` read is redirected to
    /// the active scope's context via this stack.
    static ACTIVE_CORO_SCOPE: std::cell::RefCell<Vec<klio_runtime::Value>> =
        const { std::cell::RefCell::new(Vec::new()) };
    /// Top-level property initializers currently executing — breaks
    /// initializer cycles (a re-entrant on-demand drive returns the
    /// placeholder rather than recursing).
    static IN_PROGRESS: std::cell::RefCell<std::collections::HashSet<String>> =
        std::cell::RefCell::new(std::collections::HashSet::new());
    /// Nesting depth of top-level property initializers currently on
    /// the stack. The forward-reference on-demand drive only applies
    /// while a top-level initializer is running — at ordinary runtime
    /// a not-yet-resolved name must keep its existing resolution path
    /// (driving it early there changes execution order and context,
    /// e.g. resolving `MAX_MILLIS` against a live `this`).
    static TL_INIT_DEPTH: std::cell::Cell<u32> = const { std::cell::Cell::new(0) };
}

fn in_top_level_init() -> bool {
    TL_INIT_DEPTH.with(|c| c.get() > 0)
}

struct TlInitGuard;
impl TlInitGuard {
    fn enter() -> Self {
        TL_INIT_DEPTH.with(|c| c.set(c.get() + 1));
        TlInitGuard
    }
}
impl Drop for TlInitGuard {
    fn drop(&mut self) {
        TL_INIT_DEPTH.with(|c| c.set(c.get().saturating_sub(1)));
    }
}

/// Run `f` only if `(id, name)` is not already being resolved through
/// the `get_field` heuristic fallbacks; pushes/pops the pair so the
/// recursion is bounded by the distinct instances on the stack.
fn with_field_resolve_pair<R>(id: usize, name: &str, f: impl FnOnce() -> R) -> Option<R> {
    let key = (id, name.to_string());
    let entered = FIELD_RESOLVE_STACK.with(|s| {
        if s.borrow().iter().any(|k| k == &key) {
            false
        } else {
            s.borrow_mut().push(key.clone());
            true
        }
    });
    if !entered {
        return None;
    }
    let r = f();
    FIELD_RESOLVE_STACK.with(|s| {
        let mut v = s.borrow_mut();
        if let Some(pos) = v.iter().rposition(|k| k == &key) {
            v.remove(pos);
        }
    });
    Some(r)
}

fn with_call_outer_guard<R>(f: impl FnOnce(bool) -> R) -> R {
    let was = CALL_OUTER_ACTIVE.with(|c| {
        let p = c.get();
        c.set(true);
        p
    });
    let r = f(!was);
    if !was {
        CALL_OUTER_ACTIVE.with(|c| c.set(false));
    }
    r
}

fn with_field_outer_guard<R>(f: impl FnOnce(bool) -> R) -> R {
    let was = FIELD_OUTER_ACTIVE.with(|c| {
        let p = c.get();
        c.set(true);
        p
    });
    let r = f(!was);
    if !was {
        FIELD_OUTER_ACTIVE.with(|c| c.set(false));
    }
    r
}

/// Run `f` against this thread's coroutine interceptor stack.
fn with_coro<R>(f: impl FnOnce(&RefCell<Vec<CooperativeInterceptor>>) -> R) -> R {
    EXEC.with(|e| f(&e.coro))
}

/// The active coroutine scope (top of the driver stack), if any.
/// True when `v` is a `Value::Exception` whose `fqn` names a
/// `CancellationException` (including the timeout variant). Used to
/// swallow cooperative-cancel throws that bubble out of launched
/// child activations whose Job was cancelled.
fn is_cancellation_exception(v: &klio_runtime::Value) -> bool {
    if let klio_runtime::Value::Exception { fqn, .. } = v {
        let s: &str = fqn;
        return s.ends_with("CancellationException") || s.ends_with("TimeoutCancellationException");
    }
    if let klio_runtime::Value::Instance(inst) = v {
        let name = inst.borrow().class.name.clone();
        return name.ends_with("CancellationException")
            || name.ends_with("TimeoutCancellationException");
    }
    false
}

fn active_coro_scope() -> Option<klio_runtime::Value> {
    ACTIVE_CORO_SCOPE.with(|s| s.borrow().last().cloned())
}

/// RAII guard: pushes the driven coroutine's scope for the lifetime
/// of a `drive_root` activation so the `coroutineContext` intrinsic
/// resolves to it.
struct ActiveScopeGuard(bool);
impl ActiveScopeGuard {
    fn enter(scope: &klio_runtime::Value) -> Self {
        if matches!(scope, klio_runtime::Value::Instance(_)) {
            ACTIVE_CORO_SCOPE.with(|s| s.borrow_mut().push(scope.clone()));
            ActiveScopeGuard(true)
        } else {
            ActiveScopeGuard(false)
        }
    }
}
impl Drop for ActiveScopeGuard {
    fn drop(&mut self) {
        if self.0 {
            ACTIVE_CORO_SCOPE.with(|s| {
                s.borrow_mut().pop();
            });
        }
    }
}

/// Run `f` against this thread's constructor-shell recursion guard.
fn with_ctor_guard<R>(f: impl FnOnce(&RefCell<Vec<String>>) -> R) -> R {
    EXEC.with(|e| f(&e.ctor_guard))
}

/// Run `f` against this thread's enclosing-`this` stack for receiver
/// lambdas.
fn with_inner_outer_hint<R>(f: impl FnOnce(&RefCell<Vec<klio_runtime::Value>>) -> R) -> R {
    EXEC.with(|e| f(&e.inner_outer_hint))
}

fn with_outer_this<R>(f: impl FnOnce(&RefCell<Vec<klio_runtime::Value>>) -> R) -> R {
    EXEC.with(|e| f(&e.outer_this))
}

/// Run `f` against this thread's active receiver-lambda label stack.
fn with_receiver_labels<R>(f: impl FnOnce(&RefCell<Vec<(String, klio_runtime::Value)>>) -> R) -> R {
    EXEC.with(|e| f(&e.receiver_labels))
}

/// Look up the receiver bound for the innermost active receiver lambda
/// whose implicit label matches `qualifier` (`this@with` → the `with`
/// receiver). `None` when no active lambda carries that label.
fn receiver_for_label(qualifier: &str) -> Option<klio_runtime::Value> {
    with_receiver_labels(|s| {
        s.borrow()
            .iter()
            .rev()
            .find(|(label, _)| label == qualifier)
            .map(|(_, v)| v.clone())
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use klio_ir::build::FuncBuilder;
    use klio_ir::{Const, Inst, Module, Terminator, TypeRef};

    #[derive(Default)]
    struct StringOut(String);

    impl Output for StringOut {
        fn writeln(&mut self, s: &str) {
            self.0.push_str(s);
            self.0.push('\n');
        }
        fn write(&mut self, s: &str) {
            self.0.push_str(s);
        }
    }

    #[test]
    fn vm_runs_simple_main_returns_const() {
        let mut module = Module::default();
        let mut b = FuncBuilder::new(&mut module);
        let r = b.emit_const(Const::Int(42));
        b.terminate(Terminator::Return(Some(r)));
        let main_func = b.finish("main", "main", TypeRef::int());
        // FuncId is u32-indexed; the test module's func count fits.
        #[allow(clippy::cast_possible_truncation)]
        let main_id = klio_ir::FuncId(module.funcs.len() as u32);
        let mut placed = main_func;
        placed.id = main_id;
        module.funcs.push(placed);
        module.func_index.push(("main".into(), main_id));
        module
            .func_name_index
            .entry("main".into())
            .or_default()
            .push(main_id);
        module.top_level.push(main_id);

        let mut vm = Vm::new(Arc::new(module));
        let mut out = StringOut::default();
        let v = vm.run(main_id, &mut out).unwrap();
        match v {
            klio_runtime::Value::Int(42) => {}
            other => panic!("expected Int(42), got {other:?}"),
        }
    }

    #[test]
    fn vm_runs_println_via_intrinsic() {
        let mut module = Module::default();
        let mut b = FuncBuilder::new(&mut module);
        let callee = b.alloc_reg();
        let nm = b.module.intern_const(Const::String("println".into()));
        b.push(Inst::LoadGlobal {
            dst: callee,
            name: nm,
        });
        let arg = b.emit_const(Const::String("hello".into()));
        let args_start = b.alloc_reg();
        b.push(Inst::Move {
            dst: args_start,
            src: arg,
        });
        let dst = b.alloc_reg();
        b.push(Inst::CallValue {
            dst,
            callee,
            args: args_start,
            n_args: 1,
            arg_names: Vec::new(),
        });
        b.terminate(Terminator::Return(Some(dst)));
        let main_func = b.finish("main", "main", TypeRef::unit());
        // FuncId is u32-indexed; the test module's func count fits.
        #[allow(clippy::cast_possible_truncation)]
        let main_id = klio_ir::FuncId(module.funcs.len() as u32);
        let mut placed = main_func;
        placed.id = main_id;
        module.funcs.push(placed);
        module.func_index.push(("main".into(), main_id));
        module
            .func_name_index
            .entry("main".into())
            .or_default()
            .push(main_id);
        module.top_level.push(main_id);

        let mut vm = Vm::new(Arc::new(module));
        let mut out = StringOut::default();
        vm.run(main_id, &mut out).unwrap();
        assert_eq!(out.0, "hello\n");
    }
}

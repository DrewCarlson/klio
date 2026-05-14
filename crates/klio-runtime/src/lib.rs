//! Shared runtime types for the interpreter and the stdlib.
//!
//! `Value`, `RuntimeError`, the `Output` trait, and `Env` live here so that
//! `klio-stdlib` can express Rust-native intrinsics in terms of the same
//! types `klio-interp` evaluates against, without either crate depending on
//! the other.

use std::cell::RefCell;
use std::collections::HashMap;
use std::fmt;
use std::rc::Rc;

use thiserror::Error;

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
}

/// Cooperative scheduler the runtime exposes to anything called
/// from inside an evaluation. A `launch { … }` builder pushes
/// onto the queue with [`Scheduler::spawn`]; a parked
/// `Continuation` records itself with [`Scheduler::schedule_resume`].
/// The interpreter pulls from these queues between rounds to
/// interleave sibling coroutines.
pub trait Scheduler {
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
    /// Spec §18.2 sentinel `kotlin.coroutines.intrinsics.COROUTINE_SUSPENDED`.
    /// Returned from a suspending call site when the underlying
    /// state machine elected to pause; the carried frame is the
    /// continuation entry point that, when resumed, will drive
    /// execution forward.
    CoroutineSuspended(Rc<RefCell<SuspendFrame>>),
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
    String(Rc<String>),
    Char(char),
    Null,
    /// Inclusive integer progression with a signed step. `1..10` is
    /// `{start:1,end:10,step:1}`; `1..<10` clamps end to 9; `10 downTo 1` is
    /// `{start:10,end:1,step:-1}`; `x step n` produces `step:n`. Iteration
    /// honors `step`'s sign. `kind` distinguishes `IntRange` (values widen to
    /// `Value::Int`) from `LongRange` (values widen to `Value::Long`).
    Range { start: i64, end: i64, step: i64, kind: RangeKind },
    Function { decl: Rc<klio_ast::Function>, env: Rc<RefCell<Env>> },
    Lambda {
        params: Rc<Vec<String>>,
        body: Rc<klio_ast::Block>,
        env: Rc<RefCell<Env>>,
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
    IrClosure { id: u64, captures: Rc<Vec<Value>> },
    /// A method intrinsic bound to a specific receiver — produced by member
    /// access like `s.uppercase`. Calling it invokes `func` with the receiver
    /// prepended to the user arguments.
    BoundMethod { fqn: &'static str, func: StdlibFn, receiver: Box<Value> },
    /// A user-method reference bound to a specific instance — produced by
    /// `instance::method`. Calling it dispatches through the method
    /// resolution chain on `receiver` with the caller's arguments.
    BoundUserMethod { receiver: Rc<RefCell<InstanceData>>, method: Rc<MethodDef> },
    /// A thrown value, modeled as a Kotlin Throwable. Carries an FQN
    /// (e.g. `kotlin.IllegalArgumentException`), an optional message, and
    /// an optional cause (another Throwable) per spec §3.12.
    Exception { fqn: Rc<String>, message: Option<Rc<String>>, cause: Option<Box<Value>> },
    /// `kotlin.collections.List` / `MutableList`. The mutability tag drives
    /// `type_fqn` and any mutability checks; the storage is shared.
    /// `enum_class` is `Some(name)` for the result of `EnumName.entries` /
    /// `EnumName.values()`, tagging the list as a `kotlin.enums.EnumEntries`
    /// for `is`-checks; `None` for ordinary user lists.
    List {
        items: Rc<RefCell<Vec<Value>>>,
        mutable: bool,
        enum_class: Option<Rc<String>>,
    },
    /// `kotlin.Array<T>` and the primitive-array siblings (`IntArray`,
    /// `DoubleArray`, …). Fixed-size, mutable element storage. The
    /// `prim` tag, when set, surfaces the typed-array FQN via
    /// `type_fqn()` so member dispatch and `is`-checks see e.g.
    /// `kotlin.IntArray` rather than the generic object array.
    Array {
        items: Rc<RefCell<Vec<Value>>>,
        prim: Option<PrimitiveArrayKind>,
    },
    /// `kotlin.collections.Set` / `MutableSet`. Vec-backed with linear-scan
    /// uniqueness, matching `LinkedHashSet` semantics (insertion order).
    Set { items: Rc<RefCell<Vec<Value>>>, mutable: bool },
    /// `kotlin.collections.Map` / `MutableMap`. Vec-backed, insertion-ordered
    /// (mirrors `LinkedHashMap`, which is Kotlin's default Map impl).
    Map { entries: Rc<RefCell<Vec<(Value, Value)>>>, mutable: bool },
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
    Comparator { steps: Rc<Vec<(Value, bool)>>, descending: bool },
    /// A user-declared class. Calling it constructs an `Instance`. Holds the
    /// declaration plus the env it was declared in (for resolving names from
    /// method bodies, supertypes, etc.).
    Class(Rc<ClassDef>),
    /// An `inner class` bound to a specific outer-instance. Produced when
    /// the source navigates `outer.Inner` (or refers to `Inner` unqualified
    /// inside an outer-class method, where `this` is the outer instance).
    /// Calling it constructs an `Instance` with `InstanceData.outer = Some(outer)`.
    BoundInnerClass { class: Rc<ClassDef>, outer: Rc<RefCell<InstanceData>> },
    /// A live instance of a user-declared class.
    Instance(Rc<RefCell<InstanceData>>),
    /// `kotlin.sequences.Sequence<T>`. Lazy: a source plus a chain of
    /// pipeline ops. Terminal ops drive the pull, so unbounded generators
    /// (`generateSequence { … }`) only emit as many items as the terminal
    /// op consumes.
    Sequence(Rc<SequenceData>),
    /// `kotlin.collections.Iterator<T>` and its primitive specializations
    /// (`IntIterator`, `CharIterator`, …). Sequential cursor over a fixed
    /// vector; `prim` tags the typed-iterator variant so `is`-checks and
    /// `next{TYPE}` dispatch resolve correctly.
    Iterator {
        items: Rc<RefCell<Vec<Value>>>,
        pos: Rc<RefCell<usize>>,
        prim: Option<PrimitiveArrayKind>,
    },
    /// A built-in property delegate produced by `lazy { … }` /
    /// `Delegates.observable(...)` / `Delegates.notNull()`. Carries the
    /// state the delegate needs across calls (cached value, change
    /// callback, etc.).
    Delegate(Rc<RefCell<DelegateKind>>),
    /// `::foo` — a lightweight property/function reference. The
    /// `.name: String` member is the only feature delegate `getValue` /
    /// `setValue` calls reach for; anything richer waits on a reflection
    /// surface.
    PropertyRef { name: Rc<String> },
    /// `kotlin.text.Regex`. Carries the source pattern plus a compiled
    /// Rust regex. The compiled object is shared via `Rc` so cloning a
    /// `Value::Regex` is cheap.
    Regex(Rc<RegexData>),
    /// `kotlin.text.MatchResult` — single match outcome produced by
    /// `Regex.find` / `Regex.matchEntire` / `Regex.findAll` iteration.
    /// Holds the originating regex + input so `next()` can resume.
    Match(Rc<MatchData>),
    /// `kotlin.text.MatchGroup` — one captured group of a `MatchResult`.
    /// `value` is the matched substring; `start`/`end_inclusive` are
    /// Kotlin char-indices into the original input.
    MatchGroup { value: Rc<String>, start: i64, end_inclusive: i64 },
    /// `kotlin.text.StringBuilder` — mutable string buffer. Shared
    /// storage so `sb1 === sb2` semantics hold across cloned values.
    StringBuilder(Rc<RefCell<String>>),
}

/// Compiled regex + the original pattern source. Cheap to clone via `Rc`.
#[derive(Debug)]
pub struct RegexData {
    pub pattern: Rc<String>,
    pub re: regex::Regex,
}

/// A single regex match outcome — full match plus capture groups, with
/// enough state to resume scanning via `MatchResult.next()`.
#[derive(Debug)]
pub struct MatchData {
    pub input: Rc<String>,
    /// Index 0 is the whole match; later indices are capture groups.
    /// `None` means a group did not participate in this match.
    pub groups: Vec<Option<MatchGroupData>>,
    /// Byte offset in `input` immediately after the matched span — used
    /// by `next()` to advance past the current match.
    pub end_byte: usize,
    pub regex: Rc<RegexData>,
}

#[derive(Debug, Clone)]
pub struct MatchGroupData {
    pub value: Rc<String>,
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
    pub decl: Rc<klio_ast::Function>,
    pub body: Rc<SuspendBody>,
    pub env: Rc<RefCell<Env>>,
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
    Frame(Rc<RefCell<SuspendFrame>>),
    HostSlot(Rc<RefCell<Option<Result<Value, Value>>>>),
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
    pub init_blocks: Vec<Rc<klio_ast::Block>>,
    pub is_data: bool,
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
    pub parent: RefCell<Option<Rc<ClassDef>>>,
    /// Resolved interface supertypes (any number). Walked after `parent` for
    /// default-method lookup and `is`-check membership. Each entry is a
    /// `ClassDef` with `is_interface = true`.
    pub interfaces: RefCell<Vec<Rc<ClassDef>>>,
    /// `true` for a class declared with the `interface` keyword.
    pub is_interface: bool,
    /// `true` for a `fun interface` (a SAM interface eligible for lambda
    /// conversion via the constructor-call form `Foo { … }`).
    pub is_fun_interface: bool,
    /// Constructor argument expressions for the parent class, captured at
    /// declaration time from `: Parent(args)`. Evaluated in the subclass's
    /// constructor env when an instance is built.
    pub parent_ctor_args: Vec<Rc<klio_ast::Expr>>,
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
    pub secondary_ctors: Vec<Rc<klio_ast::SecondaryCtor>>,
    /// Eagerly-constructed enum entries in source order. Each value is a
    /// `Value::Instance` whose class is either this `ClassDef` or a
    /// synthetic per-entry subclass when the entry declared an override
    /// body. Populated after the enclosing `Rc<ClassDef>` exists so
    /// entries can carry a `Rc<ClassDef>` back-reference.
    pub enum_entries: RefCell<Vec<(String, Value)>>,
    /// Companion object, if any. Stored as a class with `is_object: true`.
    /// Companion object instance. Interior mutability lets the
    /// interpreter defer construction until after the enclosing
    /// class is bound to the env, so `class Outer { companion {
    /// val X = Outer() } }` can resolve `Outer` during its
    /// companion's init. Construction sites set this once.
    pub companion: RefCell<Option<Rc<RefCell<InstanceData>>>>,
    /// For a companion-object class (`is_object: true` built from a
    /// `companion object` declaration), this points back to the enclosing
    /// class. Lets the interpreter expose enum entries / `entries` inside
    /// the companion's own method bodies.
    pub enclosing_class: RefCell<Option<Rc<ClassDef>>>,
    /// Nested classes by simple name (both plain nested and `inner` —
    /// `is_inner` lives on the nested class's own `ClassDef`).
    pub nested_classes: RefCell<Vec<(String, Rc<ClassDef>)>>,
    /// Captured env in which the class was declared (for closure-like
    /// resolution in method bodies).
    pub captured_env: Rc<RefCell<Env>>,
    /// Inheritance-delegation table: for each delegated supertype entry,
    /// the supertype name and the expression that produces the delegate
    /// instance. Evaluated once during construction; the resulting value
    /// is stored on the instance under `$$delegate$<idx>`. Resolved by
    /// the interpreter to forward calls to abstract methods that are not
    /// overridden in this class.
    pub supertype_delegates: RefCell<Vec<SupertypeDelegate>>,
    /// Synthesized forwarder methods built once the delegated interfaces
    /// are resolved (at parent-link time). Walked by `find_method_walk`
    /// after the class's own methods miss but before the parent chain.
    pub delegate_forwarders: RefCell<Vec<MethodDef>>,
    /// Lazily-constructed singleton for `is_object` classes that are
    /// nested inside another classifier. Top-level objects materialize
    /// their singleton at file load and bind it in globals; nested
    /// objects (including ones inside sealed classes) need lazy
    /// construction the first time `Outer.NestedObj` is read.
    pub object_singleton: RefCell<Option<Rc<RefCell<InstanceData>>>>,
}

#[derive(Debug, Clone)]
pub struct SupertypeDelegate {
    /// Simple name of the delegated interface (the type written before
    /// `by`). Used so the runtime can look up the interface's method
    /// table for forwarder synthesis.
    pub interface_name: String,
    /// Resolved interface class, if it resolves at registration time.
    pub interface: Option<Rc<ClassDef>>,
    /// Delegate expression — evaluated in the primary-ctor parameter
    /// scope at construction.
    pub expr: Rc<klio_ast::Expr>,
    /// Field key on the instance where the resolved delegate value lives.
    pub field_key: String,
}

#[derive(Debug, Clone)]
pub struct ClassParamDef {
    /// `Some(true)` for `var`, `Some(false)` for `val`, `None` if the param
    /// isn't a property.
    pub property: Option<bool>,
    pub name: String,
    pub default: Option<Rc<klio_ast::Expr>>,
}

#[derive(Debug, Clone)]
pub struct MethodDef {
    pub name: String,
    pub decl: Rc<klio_ast::Function>,
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
}

#[derive(Debug, Clone)]
pub struct PropertyDef {
    pub name: String,
    pub mutable: bool,
    pub init: Option<Rc<klio_ast::Expr>>,
    /// Custom getter body, if the source declared `get() = …` / `get() { … }`.
    pub getter: Option<Rc<klio_ast::Accessor>>,
    /// Custom setter body, if the source declared `set(value) { … }`.
    pub setter: Option<Rc<klio_ast::Accessor>>,
    /// `val foo by expr` — the delegate expression. Evaluated once at
    /// instance construction; its result is stored under
    /// `__delegate$<name>` in the instance field map and consulted on
    /// every read/write of the property.
    pub delegate: Option<Rc<klio_ast::Expr>>,
    /// `true` when the property was declared `abstract`. Such properties
    /// have no `init` and serve as a contract for subclasses.
    pub is_abstract: bool,
    /// `true` for a `lateinit var`. Reads before the first write throw
    /// `kotlin.UninitializedPropertyAccessException`.
    pub is_lateinit: bool,
}

#[derive(Debug)]
pub struct InstanceData {
    pub class: Rc<ClassDef>,
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
    /// dropped when the last `Rc<RefCell<InstanceData>>` clone is
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
    pub data: Rc<RefCell<dyn std::any::Any>>,
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
    pub fn find_method(self: &Rc<Self>, name: &str) -> Option<(MethodDef, Rc<ClassDef>)> {
        let mut seen: Vec<*const ClassDef> = Vec::new();
        find_method_walk(self, name, &mut seen)
    }

    /// Like `find_method`, but among overloads with this name, prefers one
    /// whose first declared parameter type name matches `arg_type_name` —
    /// used by operator dispatch to pick `plus(Bag)` over `plus(Int)` when
    /// the argument is a `Bag`. Falls back to the unspecific lookup.
    pub fn find_method_for_arg(
        self: &Rc<Self>,
        name: &str,
        arg_type_name: Option<&str>,
    ) -> Option<(MethodDef, Rc<ClassDef>)> {
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
    pub fn find_body_property(self: &Rc<Self>, name: &str) -> Option<(PropertyDef, Rc<ClassDef>)> {
        let mut seen: Vec<*const ClassDef> = Vec::new();
        find_body_property_walk(self, name, &mut seen)
    }

    /// Returns the list of declared interface supertypes (resolved).
    #[must_use]
    pub fn interface_refs(&self) -> Vec<Rc<ClassDef>> {
        self.interfaces.borrow().clone()
    }

    /// Collect companions reachable from this class: self, parent chain, and
    /// transitive interfaces. Used to resolve bare-name references to
    /// companion-object members (`Counter.n` accessed as `n` inside a
    /// `Counter.inc()` default body that runs on a class implementing
    /// `Counter`).
    #[must_use]
    pub fn all_companions(self: &Rc<Self>) -> Vec<Rc<RefCell<InstanceData>>> {
        let mut out: Vec<Rc<RefCell<InstanceData>>> = Vec::new();
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
    cls: &Rc<ClassDef>,
    out: &mut Vec<Rc<RefCell<InstanceData>>>,
    seen: &mut Vec<*const ClassDef>,
) {
    let ptr = Rc::as_ptr(cls);
    if seen.iter().any(|p| *p == ptr) || seen.len() > 128 {
        return;
    }
    seen.push(ptr);
    if let Some(c) = cls.companion.borrow().as_ref() {
        out.push(Rc::clone(c));
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
    cls: &Rc<ClassDef>,
    name: &str,
    arg_type_name: &str,
    seen: &mut Vec<*const ClassDef>,
) -> Option<(MethodDef, Rc<ClassDef>)> {
    let ptr = Rc::as_ptr(cls);
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
        return Some((m.clone(), Rc::clone(cls)));
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
    cls: &Rc<ClassDef>,
    name: &str,
    seen: &mut Vec<*const ClassDef>,
) -> Option<(MethodDef, Rc<ClassDef>)> {
    let ptr = Rc::as_ptr(cls);
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
        return Some((m.clone(), Rc::clone(cls)));
    }
    // Inheritance-delegation forwarders synthesized at parent-link
    // resolution time. Consulted before the parent chain so a delegated
    // member wins over a default body the same way an explicit override
    // would.
    if let Some(m) = cls.delegate_forwarders.borrow().iter().find(|m| m.name == name) {
        return Some((m.clone(), Rc::clone(cls)));
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
        return Some((m.clone(), Rc::clone(cls)));
    }
    None
}

fn find_body_property_walk(
    cls: &Rc<ClassDef>,
    name: &str,
    seen: &mut Vec<*const ClassDef>,
) -> Option<(PropertyDef, Rc<ClassDef>)> {
    let ptr = Rc::as_ptr(cls);
    if seen.iter().any(|p| *p == ptr) || seen.len() > 128 {
        return None;
    }
    seen.push(ptr);
    if let Some(p) = cls.body_properties.iter().find(|p| p.name == name) {
        return Some((p.clone(), Rc::clone(cls)));
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
    pub fn ensure_native_state<T: std::any::Any>(
        &mut self,
        kind: &'static str,
        init: impl FnOnce() -> T,
    ) -> Rc<RefCell<dyn std::any::Any>> {
        if let Some(ns) = &self.native_state {
            assert_eq!(
                ns.kind, kind,
                "native_state kind mismatch: instance carries `{}`, binding asked for `{}`",
                ns.kind, kind,
            );
            return Rc::clone(&ns.data);
        }
        let data: Rc<RefCell<dyn std::any::Any>> = Rc::new(RefCell::new(init()));
        self.native_state = Some(NativeState { kind, data: Rc::clone(&data) });
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
    Items(Rc<Vec<Value>>),
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
            Self::Unit => write!(f, "Unit"),
            Self::CoroutineSuspended(_) => write!(f, "CoroutineSuspended"),
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
            Self::Unit => write!(f, "kotlin.Unit"),
            Self::CoroutineSuspended(_) => write!(f, "COROUTINE_SUSPENDED"),
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
                if inst.class.is_data {
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
            Self::Unit => "kotlin.Unit",
            Self::CoroutineSuspended(_) => "kotlin.coroutines.intrinsics.COROUTINE_SUSPENDED",
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
            Value::CoroutineSuspended(_) => false,
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
            (Instance(a), Instance(b)) => {
                if Rc::ptr_eq(a, b) {
                    return true;
                }
                let aa = a.borrow();
                let bb = b.borrow();
                if aa.class.fqn != bb.class.fqn {
                    return false;
                }
                if !aa.class.is_data {
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
    parent: Option<Rc<RefCell<Env>>>,
    vars: HashMap<String, Value>,
}

impl Env {
    #[must_use]
    pub fn new() -> Self {
        Self::default()
    }

    #[must_use]
    pub fn with_parent(parent: Rc<RefCell<Env>>) -> Self {
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

    /// Resolve `name` ignoring any binding that lives in `stop_at` (compared
    /// by `Rc::ptr_eq`). Used by the interpreter to ask "would this lookup
    /// have come from the implicit prelude?" — pass the prelude env in
    /// `stop_at` and a non-prelude binding (locals, file-scope, …) is
    /// returned; a None means only the prelude could have answered it.
    #[must_use]
    pub fn lookup_excluding(
        &self,
        name: &str,
        stop_at: &Rc<RefCell<Env>>,
    ) -> Option<Value> {
        if let Some(v) = self.vars.get(name) {
            return Some(v.clone());
        }
        let parent = self.parent.as_ref()?;
        if Rc::ptr_eq(parent, stop_at) {
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

#[cfg(test)]
mod tests {
    use super::*;

    fn make_class(name: &str, is_data: bool, is_object: bool, is_enum: bool) -> Rc<ClassDef> {
        Rc::new(ClassDef {
            name: name.to_string(),
            fqn: name.to_string(),
            annotation_names: Vec::new(),
            primary_params: Vec::new(),
            methods: Vec::new(),
            body_properties: Vec::new(),
            init_blocks: Vec::new(),
            is_data,
            is_object,
            is_enum,
            is_sealed: false,
            supertype_names: Vec::new(),
            parent: RefCell::new(None),
            interfaces: RefCell::new(Vec::new()),
            is_interface: false,
            is_fun_interface: false,
            parent_ctor_args: Vec::new(),
            is_open: false,
            is_abstract: false,
            is_inner: false,
            is_anonymous: false,
            secondary_ctors: Vec::new(),
            enum_entries: RefCell::new(Vec::new()),
            companion: RefCell::new(None),
            enclosing_class: RefCell::new(None),
            nested_classes: RefCell::new(Vec::new()),
            captured_env: Rc::new(RefCell::new(Env::new())),
            supertype_delegates: RefCell::new(Vec::new()),
            delegate_forwarders: RefCell::new(Vec::new()),
            object_singleton: RefCell::new(None),
        })
    }

    #[test]
    fn plain_instance_display_uses_class_at_hex() {
        let cls = make_class("Foo", false, false, false);
        let inst = Rc::new(RefCell::new(InstanceData {
            class: cls,
            fields: Vec::new(),
            outer: None,
            identity: 0x2a,
            native_state: None,
        }));
        assert_eq!(format!("{}", Value::Instance(inst)), "Foo@2a");
    }

    #[test]
    fn data_instance_display_unchanged() {
        // Data classes still render via the data-class form; identity is
        // irrelevant. (Field rendering exercised by integration tests.)
        let cls = make_class("D", true, false, false);
        let inst = Rc::new(RefCell::new(InstanceData {
            class: cls,
            fields: Vec::new(),
            outer: None,
            identity: 99,
            native_state: None,
        }));
        assert_eq!(format!("{}", Value::Instance(inst)), "D()");
    }

    #[test]
    fn enum_entries_is_runtime_type_matches_both() {
        let entries = Value::List {
            items: Rc::new(RefCell::new(vec![Value::Int(1)])),
            mutable: false,
            enum_class: Some(Rc::new("Color".to_string())),
        };
        assert!(entries.is_runtime_type("List"));
        assert!(entries.is_runtime_type("EnumEntries"));
        assert!(entries.is_runtime_type("Collection"));

        let plain = Value::List {
            items: Rc::new(RefCell::new(vec![Value::Int(1)])),
            mutable: false,
            enum_class: None,
        };
        assert!(plain.is_runtime_type("List"));
        assert!(!plain.is_runtime_type("EnumEntries"));
    }

    #[test]
    fn enum_entries_keeps_list_type_fqn_for_dispatch() {
        // Stdlib member dispatch keys on type_fqn — EnumEntries values must
        // continue to dispatch through `kotlin.collections.List`.
        let entries = Value::List {
            items: Rc::new(RefCell::new(vec![Value::Int(1)])),
            mutable: false,
            enum_class: Some(Rc::new("Color".to_string())),
        };
        assert_eq!(entries.type_fqn(), "kotlin.collections.List");
    }
}

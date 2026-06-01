use crate::*;

use std::fmt;
use std::sync::Arc;

use thiserror::Error;

/// Which face of a `MutableMap` a live view exposes.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum MapViewKind {
    Keys,
    Values,
    Entries,
}

/// Back-reference carried by a live `MutableMap.keys` / `.values` /
/// `.entries` collection so its mutators edit the originating map.
#[derive(Clone, Debug)]
pub struct MapBacking {
    pub entries: ObjRef<Vec<(Value, Value)>>,
    pub kind: MapViewKind,
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
    /// Kotlin `Char` is a single UTF-16 code unit, so it is stored as a
    /// `u16` (0x0000..=0xFFFF) and may hold a lone surrogate. Astral
    /// scalars (U+10000..) are NOT a single `Char` — they are a surrogate
    /// pair across two `Char`s, matching Kotlin's `String` indexing.
    Char(u16),
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
        /// Set when this list is a live `MutableMap.values` view: bulk
        /// mutators (`remove`/`clear`/`removeAll`/`retainAll`) propagate
        /// back to the backing map's entries. `None` for ordinary lists.
        backing: Option<Box<MapBacking>>,
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
    Set {
        items: ObjRef<Vec<Value>>,
        mutable: bool,
        /// Set when this set is a live `MutableMap.keys` / `.entries`
        /// view: bulk mutators propagate to the backing map. `None` for
        /// ordinary sets.
        backing: Option<Box<MapBacking>>,
    },
    /// `kotlin.collections.Map` / `MutableMap`. Vec-backed, insertion-ordered
    /// (mirrors `LinkedHashMap`, which is Kotlin's default Map impl).
    Map { entries: ObjRef<Vec<(Value, Value)>>, mutable: bool },
    /// `kotlin.Pair`. `to` constructs one.
    Pair(Box<Value>, Box<Value>),
    /// `kotlin.Triple`. Built by `Triple(a, b, c)`.
    Triple(Box<Value>, Box<Value>, Box<Value>),
    /// `kotlin.collections.Map.Entry`. Yielded by iterating a `Map`.
    /// Exposes `.key` / `.value`. `toString` renders as `key=value`.
    /// `backing`, when set, is the live map's entries: `setValue`
    /// writes through to the slot keyed by `key`.
    MapEntry {
        key: Box<Value>,
        value: Box<Value>,
        backing: Option<ObjRef<Vec<(Value, Value)>>>,
    },
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
    /// Lazy O(1)-memory iterator over a `Range`/progression. Unlike
    /// `Iterator`, which carries a fully-materialised `Vec`, this
    /// computes each element arithmetically from `cur`/`step`, matching
    /// the JVM `IntProgressionIterator`. `cur` is the only mutable
    /// state. `kind` selects the element width (`Int`/`Long`/`Char`).
    /// Produced by `iterator()` on a `Value::Range` so `for (i in a..b)`,
    /// `repeat(n)`, and `range.forEach { }` never allocate per-element.
    RangeIter { cur: ObjRef<i64>, end: i64, step: i64, kind: RangeKind },
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
    /// `onEach { }` — run the lambda for its side effect, pass the item through.
    OnEach(Value),
    /// `mapIndexed { index, value -> }` — like Map but the lambda also receives
    /// the 0-based index of the item within this op's input stream.
    MapIndexed(Value),
    /// `filterIndexed { index, value -> }`.
    FilterIndexed(Value),
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
            Self::Char(v) => write!(f, "Char('{}')", char_unit_to_string(*v)),
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
            Self::List { items, mutable, enum_class, .. } => {
                let tag = match enum_class {
                    Some(n) => format!("EnumEntries<{n}>"),
                    None => (if *mutable { "mut" } else { "ro" }).to_string(),
                };
                write!(f, "List({}, {} items)", tag, items.borrow().len())
            }
            Self::Set { items, mutable, .. } => {
                write!(f, "Set({}, {} items)", if *mutable { "mut" } else { "ro" }, items.borrow().len())
            }
            Self::Map { entries, mutable } => {
                write!(f, "Map({}, {} entries)", if *mutable { "mut" } else { "ro" }, entries.borrow().len())
            }
            Self::Pair(a, b) => write!(f, "Pair({a:?}, {b:?})"),
            Self::Triple(a, b, c) => write!(f, "Triple({a:?}, {b:?}, {c:?})"),
            Self::MapEntry { key, value, .. } => write!(f, "Map.Entry({key:?}={value:?})"),
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
            Self::RangeIter { cur, end, step, kind } => write!(
                f,
                "RangeIter(cur={}, end={end}, step={step}, kind={kind:?})",
                cur.borrow()
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
            Self::Char(v) => write!(f, "{}", char_unit_to_string(*v)),
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
            Self::MapEntry { key, value, .. } => {
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
            Self::RangeIter { kind, .. } => match kind {
                RangeKind::Int => write!(f, "kotlin.ranges.IntProgressionIterator"),
                RangeKind::Long => write!(f, "kotlin.ranges.LongProgressionIterator"),
                RangeKind::Char => write!(f, "kotlin.ranges.CharProgressionIterator"),
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
            Self::RangeIter { kind, .. } => match kind {
                RangeKind::Int => "kotlin.collections.IntIterator",
                RangeKind::Long => "kotlin.collections.LongIterator",
                RangeKind::Char => "kotlin.collections.CharIterator",
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
                    matches!(
                        name,
                        "MutableList"
                            | "List"
                            | "Collection"
                            | "MutableCollection"
                            | "Iterable"
                            | "MutableIterable"
                            | "RandomAccess"
                            | "Any"
                    )
                } else {
                    matches!(
                        name,
                        "List" | "Collection" | "Iterable" | "RandomAccess" | "Any"
                    )
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
            Value::RangeIter { kind, .. } => {
                if matches!(name, "Iterator" | "Any") {
                    return true;
                }
                match kind {
                    RangeKind::Int => name == "IntIterator",
                    RangeKind::Long => name == "LongIterator",
                    RangeKind::Char => name == "CharIterator",
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
    /// Equality with *boxed* `Number` semantics, as the JVM applies when a
    /// numeric is stored as `Any` / inside a collection: each boxed type's
    /// `equals` only matches its own type, so `Integer(1) != Long(1)` and
    /// `1 != 1.0`. Collections compare their elements boxed too (that is how
    /// `listOf(1) == listOf(1L)` evaluates to `false`). Non-numeric,
    /// non-collection values fall back to the structural rules.
    pub fn structural_eq_boxed(a: &Value, b: &Value) -> bool {
        use Value::*;
        match (a, b) {
            (Double(x), Double(y)) => x.to_bits() == y.to_bits(),
            (Float(x), Float(y)) => x.to_bits() == y.to_bits(),
            (Int(x), Int(y)) => x == y,
            (Long(x), Long(y)) => x == y,
            (Short(x), Short(y)) => x == y,
            (Byte(x), Byte(y)) => x == y,
            (UInt(x), UInt(y)) => x == y,
            (ULong(x), ULong(y)) => x == y,
            (UShort(x), UShort(y)) => x == y,
            (UByte(x), UByte(y)) => x == y,
            (List { items: a, .. }, List { items: b, .. }) => {
                let (ab, bb) = (a.borrow(), b.borrow());
                ab.len() == bb.len()
                    && ab.iter().zip(bb.iter()).all(|(x, y)| Value::structural_eq_boxed(x, y))
            }
            (Set { items: a, .. }, Set { items: b, .. }) => {
                let (ab, bb) = (a.borrow(), b.borrow());
                ab.len() == bb.len()
                    && ab.iter().all(|x| bb.iter().any(|y| Value::structural_eq_boxed(x, y)))
            }
            (Map { entries: a, .. }, Map { entries: b, .. }) => {
                let (ab, bb) = (a.borrow(), b.borrow());
                ab.len() == bb.len()
                    && ab.iter().all(|(k, v)| {
                        bb.iter().any(|(k2, v2)| {
                            Value::structural_eq_boxed(k, k2)
                                && Value::structural_eq_boxed(v, v2)
                        })
                    })
            }
            (Pair(a1, a2), Pair(b1, b2)) => {
                Value::structural_eq_boxed(a1, b1) && Value::structural_eq_boxed(a2, b2)
            }
            (Triple(a1, a2, a3), Triple(b1, b2, b3)) => {
                Value::structural_eq_boxed(a1, b1)
                    && Value::structural_eq_boxed(a2, b2)
                    && Value::structural_eq_boxed(a3, b3)
            }
            (MapEntry { key: k1, value: v1, .. }, MapEntry { key: k2, value: v2, .. }) => {
                Value::structural_eq_boxed(k1, k2) && Value::structural_eq_boxed(v1, v2)
            }
            // Any other mix of two numerics (Int vs Long, Int vs Double, …)
            // is a cross-type boxed comparison: never equal.
            _ if a.is_numeric() && b.is_numeric() => false,
            _ => Value::structural_eq(a, b),
        }
    }

    pub fn structural_eq(a: &Value, b: &Value) -> bool {
        use Value::*;
        // Numeric `equals` matches Kotlin's boxed `Number` semantics: each
        // type only equals its own type (`1 != 1L`, `1 != 1.0`). Valid Kotlin
        // only compares same-typed numerics with `==` (or boxes both to a
        // common supertype, which still dispatches per-type `equals`), so
        // type-strict matching is correct here and lets a generic
        // `equals` (e.g. data-class / Pair component comparison) reject a
        // cross-type pair the way the JVM does.
        if a.is_numeric() && b.is_numeric() {
            return match (a, b) {
                (Int(x), Int(y)) => x == y,
                (Long(x), Long(y)) => x == y,
                (Short(x), Short(y)) => x == y,
                (Byte(x), Byte(y)) => x == y,
                (UInt(x), UInt(y)) => x == y,
                (ULong(x), ULong(y)) => x == y,
                (UShort(x), UShort(y)) => x == y,
                (UByte(x), UByte(y)) => x == y,
                (Double(x), Double(y)) => x == y,
                (Float(x), Float(y)) => x == y,
                _ => false,
            };
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
            // Collection elements / tuple components are boxed, so they
            // compare with boxed `Number` semantics: `listOf(1) == listOf(1L)`
            // is `false` even though `1 == 1` at the top level is `true`.
            (List { items: a, .. }, List { items: b, .. }) => {
                let ab = a.borrow();
                let bb = b.borrow();
                ab.len() == bb.len()
                    && ab.iter().zip(bb.iter()).all(|(x, y)| Value::structural_eq_boxed(x, y))
            }
            (Set { items: a, .. }, Set { items: b, .. }) => {
                let ab = a.borrow();
                let bb = b.borrow();
                ab.len() == bb.len()
                    && ab.iter().all(|x| bb.iter().any(|y| Value::structural_eq_boxed(x, y)))
            }
            (Map { entries: a, .. }, Map { entries: b, .. }) => {
                let ab = a.borrow();
                let bb = b.borrow();
                ab.len() == bb.len()
                    && ab.iter().all(|(k, v)| {
                        bb.iter().any(|(k2, v2)| {
                            Value::structural_eq_boxed(k, k2) && Value::structural_eq_boxed(v, v2)
                        })
                    })
            }
            (Pair(a1, a2), Pair(b1, b2)) => {
                Value::structural_eq_boxed(a1, b1) && Value::structural_eq_boxed(a2, b2)
            }
            (Triple(a1, a2, a3), Triple(b1, b2, b3)) => {
                Value::structural_eq_boxed(a1, b1)
                    && Value::structural_eq_boxed(a2, b2)
                    && Value::structural_eq_boxed(a3, b3)
            }
            (MapEntry { key: k1, value: v1, .. }, MapEntry { key: k2, value: v2, .. }) => {
                Value::structural_eq_boxed(k1, k2) && Value::structural_eq_boxed(v1, v2)
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

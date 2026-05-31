//! IR evaluator.
//!
//! Walks a `Func`'s `Vec<Block>` and produces a `Value`. Today
//! supports the subset of `Inst`s the lowering pass emits: `Const`,
//! `BinOp`, `UnOp`, `Not`, `Move`, plus `Goto` / `Branch` / `Return`
//! / `Throw` / `Unreachable` terminators. Other ops trap as
//! `EvalError::Unsupported`.
//!
//! The evaluator does not yet replace `klio-interp`. It exists so
//! the IR shape can be exercised end-to-end on hand-built or
//! lowered modules; as the lowering pass grows, the evaluator
//! grows alongside it, and the cutover lands once parity holds
//! across the corpus.

use klio_runtime::Value;

fn display_throw(v: &Value) -> String {
    match v {
        Value::Exception { fqn, message, .. } => match message {
            Some(m) => format!("{}({})", fqn, m),
            None => format!("{}", fqn),
        },
        Value::Instance(inst) => {
            let b = inst.borrow();
            let name = b.class.name.clone();
            let msg = b.fields.iter().find_map(|(k, v)| {
                if k == "message" {
                    if let Value::String(s) = v { Some(s.to_string()) } else { None }
                } else {
                    None
                }
            });
            match msg {
                Some(m) => format!("{}({})", name, m),
                None => name,
            }
        }
        _ => format!("{v:?}"),
    }
}

use crate::{BinOp, BlockId, Const, Func, FuncId, Inst, Module, Reg, Terminator, TypeRef, UnOp};

/// Pluggable callbacks the evaluator delegates non-trivial dispatch
/// through. The IR is intentionally agnostic about how user
/// classes and top-level functions are resolved; a real frontend
/// supplies a host implementation that ties into the interpreter's
/// class table / dispatch machinery. A default no-op `NullHost`
/// exists for unit tests.
pub trait Host {
    /// Resolve a CallValue invocation against a runtime value.
    /// Default rejects so wiring is visible.
    fn call_value(&mut self, _callee: &Value, _args: &[Value]) -> Result<Value, EvalError> {
        Err(EvalError::Unsupported("Host::call_value"))
    }
    /// Same as `call_value` but with named-arg metadata. Default
    /// drops the names and routes through `call_value`.
    fn call_value_named(
        &mut self,
        callee: &Value,
        args: &[Value],
        _arg_names: &[Option<String>],
    ) -> Result<Value, EvalError> {
        self.call_value(callee, args)
    }
    /// Resolve a CallMember invocation against the receiver.
    fn call_member(
        &mut self,
        _receiver: &Value,
        _name: &str,
        _args: &[Value],
    ) -> Result<Value, EvalError> {
        Err(EvalError::Unsupported("Host::call_member"))
    }
    fn call_member_named(
        &mut self,
        receiver: &Value,
        name: &str,
        args: &[Value],
        _arg_names: &[Option<String>],
    ) -> Result<Value, EvalError> {
        self.call_member(receiver, name, args)
    }
    /// Whether `receiver`'s class (transitively over supertypes)
    /// declares a member function `name`. Lets the evaluator honor
    /// Kotlin's rule that an explicit-receiver call `recv.name(args)`
    /// is a member call whenever the member exists, and only falls to
    /// a same-named local extension/lambda when it does not.
    fn host_has_member(&mut self, _receiver: &Value, _name: &str) -> bool {
        false
    }
    /// Construct an instance of a class referenced by ID. The
    /// implementation looks up the corresponding ClassDef and
    /// invokes the primary constructor with the supplied args.
    fn new_instance(&mut self, _class: crate::ClassId, _args: &[Value]) -> Result<Value, EvalError> {
        Err(EvalError::Unsupported("Host::new_instance"))
    }
    fn new_instance_named(
        &mut self,
        class: crate::ClassId,
        args: &[Value],
        _arg_names: &[Option<String>],
    ) -> Result<Value, EvalError> {
        self.new_instance(class, args)
    }
    /// Read a property on the receiver. Default for instances is
    /// the raw field lookup via `InstanceData::get`; concrete
    /// hosts route through the tree walker's
    /// `eval_property_access` so getters / delegates / extension
    /// properties fire.
    fn get_field(
        &mut self,
        receiver: &Value,
        name: &str,
    ) -> Result<Value, EvalError> {
        match receiver {
            Value::Instance(inst) => Ok(inst.borrow().get(name).unwrap_or(Value::Null)),
            _ => Err(EvalError::Type(format!(
                "GetField on non-instance: {receiver:?}"
            ))),
        }
    }

    /// Write a property on the receiver. Default writes directly to
    /// the instance backing store; concrete hosts route through the
    /// tree walker's assignment path so extension-property setters
    /// fire.
    fn set_field(
        &mut self,
        receiver: &Value,
        name: &str,
        value: Value,
    ) -> Result<(), EvalError> {
        match receiver {
            Value::Instance(inst) => {
                inst.borrow_mut().define(name, value);
                Ok(())
            }
            Value::Null => Ok(()),
            _ => Err(EvalError::Type(format!(
                "SetField on non-instance: {receiver:?}"
            ))),
        }
    }

    /// Test whether `value` is an instance of `ty`. The default
    /// implementation handles the primitive nominal types via
    /// `Value::type_fqn`; complex types defer to the host.
    fn instance_of(&mut self, value: &Value, ty: &TypeRef) -> bool {
        // Primitive name-match suffices for the simple shapes the
        // IR evaluator can reason about standalone.
        let nominal = value.type_fqn();
        nominal == ty.name || nominal.ends_with(&format!(".{}", ty.name))
    }
    /// Resolve a bare global identifier (top-level fn, intrinsic,
    /// imported symbol). Default returns Unit which surfaces as a
    /// runtime "value not callable" error if the caller tries to
    /// call it; concrete hosts route through the interpreter's
    /// global env.
    fn lookup_global(&mut self, _name: &str) -> Option<Value> {
        None
    }

    /// Throwing-aware variant of `lookup_global`. Hosts override
    /// this when a delegated top-level property's getter may raise
    /// a Throwable (e.g. `Delegates.notNull()` accessed before its
    /// first set). The default forwards to `lookup_global`.
    fn lookup_global_throwing(&mut self, name: &str) -> Result<Option<Value>, EvalError> {
        Ok(self.lookup_global(name))
    }

    /// Write a top-level binding. Used by compound assignment on
    /// a `Path` target that names a top-level `var` (or a delegated
    /// property whose setter must fire). Default fails so the
    /// missing wiring is visible.
    fn store_global(&mut self, _name: &str, _value: Value) -> Result<(), EvalError> {
        Err(EvalError::Unsupported("Host::store_global"))
    }

    /// Evaluate a stashed AST expression under a snapshot of the
    /// caller's scope. Used by `Inst::EvalAst` for constructs the
    /// IR lowering doesn't yet model structurally (anonymous
    /// objects today).
    /// Register a local class declaration with the host's class
    /// table so subsequent `NewInstance` / `lookup_global` find it.
    fn register_class(&mut self, _class: &klio_ast::Class) -> Result<(), EvalError> {
        Err(EvalError::Unsupported("Host::register_class"))
    }

    /// Register a local class declaration with captured outer
    /// locals so the class methods can read names from the
    /// enclosing function's scope. Default ignores captures and
    /// routes to `register_class`.
    fn register_class_captured(
        &mut self,
        class: &klio_ast::Class,
        _captured_names: &[String],
        _captures: Vec<Value>,
    ) -> Result<(), EvalError> {
        self.register_class(class)
    }

    /// Synthesise an anonymous-object instance from an `object {
    /// … }` AST node. Hosts build a fresh ClassDef from the AST's
    /// members, hook up the captured env from `captures`, and
    /// return the resulting `Value::Instance`.
    fn build_object(
        &mut self,
        _ast: &klio_ast::Expr,
        _captured_names: &[String],
        _captures: Vec<Value>,
    ) -> Result<Value, EvalError> {
        Err(EvalError::Unsupported("Host::build_object"))
    }

    /// Materialise a closure value capturing the supplied snapshot
    /// of register values. `body_func` is a FuncId in the active
    /// module; concrete hosts build a `Value::Lambda` (or
    /// equivalent) wrapping the body + env so it can be invoked
    /// through `call_value`.
    /// Invoke a callable with `this_value` bound as the
    /// implicit receiver inside the body. Used by receiver-
    /// typed lambda invocations like `list.block()` where
    /// `block: T.() -> R` is a local in scope.
    fn call_value_with_this(
        &mut self,
        _callee: &Value,
        _this_value: &Value,
        _args: &[Value],
        _arg_names: &[Option<String>],
    ) -> Result<Value, EvalError> {
        Err(EvalError::Unsupported("Host::call_value_with_this"))
    }

    /// Dispatch `super.name(args)` on `receiver` against the
    /// parent of `owner_class`. Hosts walk the parent chain and
    /// invoke the matching method body.
    fn call_super(
        &mut self,
        _receiver: &Value,
        _owner_class: &str,
        _qualifier: Option<&str>,
        _name: &str,
        _args: &[Value],
        _arg_names: &[Option<String>],
    ) -> Result<Value, EvalError> {
        Err(EvalError::Unsupported("Host::call_super"))
    }

    /// Resolve `this@Qual` by walking the receiver's outer
    /// instance chain looking for one whose class matches
    /// `qualifier`. Returns the receiver itself when the
    /// qualifier matches the leaf class.
    fn qualified_this(
        &mut self,
        _receiver: &Value,
        _qualifier: &str,
    ) -> Result<Value, EvalError> {
        Err(EvalError::Unsupported("Host::qualified_this"))
    }

    /// Read a captured variable's current value out of a
    /// `Value::Lambda`'s env. Used after closure-mutating calls
    /// to sync writes back into the caller's regs.
    fn read_lambda_capture(
        &mut self,
        _lambda: &Value,
        _name: &str,
    ) -> Result<Value, EvalError> {
        Err(EvalError::Unsupported("Host::read_lambda_capture"))
    }

    /// Resolve `receiver::name` to a callable reference value.
    /// Concrete hosts dispatch through the receiver's class table
    /// to produce a `BoundMethod` / intrinsic / property-ref shape.
    fn member_ref(
        &mut self,
        _receiver: &Value,
        _name: &str,
    ) -> Result<Value, EvalError> {
        Err(EvalError::Unsupported("Host::member_ref"))
    }

    fn build_closure(
        &mut self,
        _module: &Module,
        _body_func: FuncId,
        _captures: Vec<Value>,
    ) -> Result<Value, EvalError> {
        Err(EvalError::Unsupported("Host::build_closure"))
    }

    /// Build a `Value::Lambda`-compatible closure straight from an
    /// AST block. Concrete hosts populate the captured env from
    /// `captures` and produce a Value the tree walker's lambda
    /// dispatch (call_lambda etc.) can consume directly.
    fn build_ast_lambda(
        &mut self,
        _params: &[String],
        _body: &klio_ast::Block,
        _captured_names: &[String],
        _captures: Vec<Value>,
    ) -> Result<Value, EvalError> {
        Err(EvalError::Unsupported("Host::build_ast_lambda"))
    }

    /// Variant of `build_ast_lambda` that threads the
    /// `absorb_return` flag through. Anonymous-fn expressions
    /// (`fun(x): T = …`) set `true` so `return` inside the body
    /// stops at the fn boundary; ordinary `{ … }` lambdas use the
    /// default `false`.
    fn build_ast_lambda_with_flag(
        &mut self,
        params: &[String],
        body: &klio_ast::Block,
        captured_names: &[String],
        captures: Vec<Value>,
        _absorb_return: bool,
    ) -> Result<Value, EvalError> {
        self.build_ast_lambda(params, body, captured_names, captures)
    }

    /// Variant that also receives the lambda body's lowered FuncId
    /// when available. The default ignores it; klio's interp host
    /// registers the FuncId under the lambda's body pointer so
    /// later call sites can dispatch through IR.
    fn build_ast_lambda_with_flag_funcid(
        &mut self,
        params: &[String],
        body: &klio_ast::Block,
        captured_names: &[String],
        captures: Vec<Value>,
        absorb_return: bool,
        _body_func: Option<FuncId>,
    ) -> Result<Value, EvalError> {
        self.build_ast_lambda_with_flag(params, body, captured_names, captures, absorb_return)
    }

    /// Resolve a function call by FuncId. The default routes
    /// through `eval()` recursively, so a single-module IR program
    /// stays self-contained.
    fn call_func(
        &mut self,
        module: &Module,
        func: FuncId,
        args: Vec<Value>,
    ) -> Result<Value, EvalError> {
        let f = module
            .funcs
            .get(func.0 as usize)
            .ok_or_else(|| EvalError::Type(format!("unknown FuncId {}", func.0)))?;
        eval(module, f, args)
    }
    fn call_func_named(
        &mut self,
        module: &Module,
        func: FuncId,
        args: Vec<Value>,
        _arg_names: &[Option<String>],
    ) -> Result<Value, EvalError> {
        self.call_func(module, func, args)
    }
    /// Variant that carries call-site type arguments (e.g. for
    /// `inline fun <reified T> foo<Int>()`). The default ignores
    /// them; klio's interp host pushes a reified frame.
    fn call_func_typed(
        &mut self,
        module: &Module,
        func: FuncId,
        args: Vec<Value>,
        arg_names: &[Option<String>],
        _type_args: &[String],
    ) -> Result<Value, EvalError> {
        self.call_func_named(module, func, args, arg_names)
    }
    /// Resolve a bare-name call against the top-level function table
    /// with runtime-argument overload selection. Returns `Ok(None)`
    /// when the name is not an overloaded top-level function (the
    /// caller then falls back to the plain global-value path). Lets
    /// `foo(x)` pick between `fun foo(Long)` / `fun foo(Double)` even
    /// when the call site baked in a single global at lower time.
    fn call_named_overload(
        &mut self,
        _module: &Module,
        _name: &str,
        _args: &[Value],
        _arg_names: &[Option<String>],
    ) -> Result<Option<Value>, EvalError> {
        Ok(None)
    }
    /// The lexically enclosing `this` displaced by a receiver lambda
    /// (`apply` / `with` / `buildString` written inside a member).
    /// Member resolution and `this@Label` consult it when the inner
    /// receiver lacks the member. `None` outside a receiver lambda.
    fn enclosing_this(&self) -> Option<Value> {
        None
    }
    /// The full lexically-enclosing-`this` chain, innermost first.
    /// Nested receiver lambdas mean the intended `this@Outer` may be
    /// deeper than the immediate enclosing. Default: the single
    /// `enclosing_this()`.
    fn enclosing_this_chain(&self) -> Vec<Value> {
        self.enclosing_this().into_iter().collect()
    }

    /// Report `(n_params, first_param_is_this)` for a callable whose
    /// dispatch shape the IR's call sites need to know. Returns
    /// `None` when the callable isn't a closure / shape the host can
    /// introspect. Used by `CallValue` to prepend the calling frame's
    /// `this` when invoking a receiver-typed lambda value as `body()`
    /// (no explicit `this.body()`).
    fn callable_receiver_shape(&self, _v: &Value) -> Option<(usize, bool)> {
        None
    }

    /// True when the closure carries a captured `this` slot whose
    /// current value isn't a usable receiver — a sign the lambda is
    /// being invoked as `body()` instead of `recv.body()` and the
    /// receiver should be supplied from the calling frame.
    fn closure_needs_this_capture(&self, _v: &Value) -> bool {
        false
    }

    /// Override the closure's captured `this` slot with `new_this`
    /// for the duration of the impending invocation. Paired with
    /// `closure_needs_this_capture`.
    fn override_closure_this(&mut self, _v: &Value, _new_this: &Value) {}
    /// Resolve `name` as a *member* of `receiver` only — the
    /// instance / class / anon-object method walk — without falling
    /// back to a top-level extension, SAM dispatch, or a global.
    /// Returns `Err` when `receiver` has no such member. Used to give
    /// a member of any implicit receiver precedence over a same-named
    /// extension (Kotlin resolution order). Default: the normal
    /// member call.
    fn call_member_only(
        &mut self,
        receiver: &Value,
        name: &str,
        args: &[Value],
        arg_names: &[Option<String>],
    ) -> Result<Value, EvalError> {
        self.call_member_named(receiver, name, args, arg_names)
    }
    /// Make `v` reachable as the lexically enclosing `this` for the
    /// duration of a member access whose receiver displaces it — the
    /// same nested-receiver rule receiver lambdas use, extended to a
    /// `recv.member` access so a member extension property/function
    /// accessor (whose body calls enclosing-class members) resolves
    /// them against the class instance the access was written in.
    /// Default: no-op (non-Vm Hosts have no enclosing-this stack).
    fn push_access_enclosing(&self, _v: &Value) {}
    fn pop_access_enclosing(&self) {}

    /// Stash an outer-`this` candidate for a soon-to-be-allocated
    /// inner-class instance. The host pops it at the matching
    /// `pop_inner_outer_hint` call after `new_instance_named`
    /// returns, and consults the top during init-block dispatch so
    /// the instance carries `outer` before any init body runs.
    fn push_inner_outer_hint(&mut self, _v: &Value) {}
    fn pop_inner_outer_hint(&mut self) {}
    /// True when `name` is bound, in the innermost scoped-global layer
    /// (an anon-object method's capture env), to a callable value. A
    /// captured callable is a closed-over parameter/local, which in
    /// Kotlin shadows a same-named member — the bare call must invoke
    /// it rather than be probed as a member of an implicit receiver.
    /// Default: false (no scoped-capture layer).
    fn is_shadowing_capture(&self, _name: &str) -> bool {
        false
    }
}

/// No-op host for unit tests and IR-shape exercises.
#[derive(Default)]
pub struct NullHost;
impl Host for NullHost {}

#[derive(Debug, thiserror::Error)]
pub enum EvalError {
    #[error("IR evaluator does not yet support: {0}")]
    Unsupported(&'static str),
    #[error("IR type error: {0}")]
    Type(String),
    #[error("uncaught throw inside IR evaluator: {}", display_throw(.0))]
    Throw(Value),
    /// `return` from a nested lambda whose target is an
    /// enclosing IR function frame. `eval_with` catches this at
    /// the matching fn boundary and converts it to a normal
    /// return value.
    #[error("non-local return inside IR evaluator")]
    NonLocalReturn(Value),
    /// `return@label value` whose target is a named function/lambda
    /// frame. `eval_with_captures` catches this when the active
    /// frame's `func.name` matches the label.
    #[error("labeled return inside IR evaluator")]
    LabeledReturn(String, Value),
    /// Arity mismatch — caller passed wrong number of args.
    #[error("arity mismatch: {0}")]
    Arity(String),
    /// Unbound identifier reachable through the IR.
    #[error("unbound identifier: {0}")]
    Unbound(String),
    /// Operation not yet implemented on this value.
    #[error("not yet implemented: {0}")]
    Unimplemented(String),
    /// A suspension point fired (`delay` / `yield` /
    /// `suspendCoroutine`). Each `eval_with_captures` frame on the
    /// unwind path pushes its [`FrameSnapshot`] onto `state.frames`
    /// (innermost last) and re-propagates; the coroutine driver
    /// parks the resulting [`SuspendState`] and resumes it later via
    /// [`resume_continuation`].
    #[error("coroutine suspended (token {})", .0.token)]
    Suspended(Box<SuspendState>),
}

/// One active try-region recorded on the eval's try-stack. Separates
/// the *entry* (where to jump to start running finally / catch) from
/// the *done sentinel* (the synthesized block whose entry signals
/// the finally body has run to completion regardless of any internal
/// control flow in the user finally body).
#[derive(Debug, Clone)]
pub struct TryFrame {
    /// The try body's entry block — the key for matching pop /
    /// pending-return / pending-rethrow against `Block::finally_done_for`.
    pub body: BlockId,
    pub catches: Vec<crate::CatchHandler>,
    /// Where to jump to start running the finally / first catch.
    /// `None` for a try with only catches and no finally.
    pub finally_entry: Option<BlockId>,
    /// The post-finally sentinel block: control reaches this only
    /// after the user finally body has finished, no matter what its
    /// internal control flow looked like. The eval keys its
    /// pop / pending-return / pending-rethrow checks against this
    /// rather than `finally_entry`.
    pub finally_done: Option<BlockId>,
}

/// One paused `eval_with_captures` activation. Enough to re-enter
/// the block loop exactly where it left off.
#[derive(Debug, Clone)]
pub struct FrameSnapshot {
    pub func: FuncId,
    pub block: BlockId,
    /// Index of the *next* instruction to run within `block.insts`.
    pub inst_idx: usize,
    pub regs: Vec<Value>,
    pub params: Vec<Value>,
    pub captures: Vec<Value>,
    pub try_stack: Vec<TryFrame>,
    pub is_lambda: bool,
    /// Register the resumed value is written into before execution
    /// continues (the destination of the suspending call site).
    pub resume_reg: Option<Reg>,
}

/// Layer 1 — a parked activation: a stack of frame snapshots
/// (outermost first, innermost last) plus the token the interceptor
/// uses to resume it. This is pure suspend mechanism: it carries no
/// thread, dispatcher, or timing policy of its own.
#[derive(Debug, Clone)]
pub struct SuspendState {
    pub token: u64,
    pub frames: Vec<FrameSnapshot>,
    /// Opaque Layer-2 resume directive, set by the suspending API
    /// (a suspending primitive) and interpreted only by
    /// the interceptor — never by Layer 1. The default cooperative
    /// interceptor reads it as virtual-time millis: `>= 0` resumes
    /// after that much virtual time, `< 0` parks indefinitely until
    /// an explicit resume.
    pub wake_in_millis: i64,
    /// Transient: set by the suspending call instruction to its
    /// destination register, consumed by the enclosing block loop
    /// when it records the frame snapshot. Always `None` once a
    /// frame has been pushed.
    pub pending_resume_reg: Option<Reg>,
}

/// Per-call evaluation frame.
struct Frame<'a> {
    module: &'a Module,
    func: &'a Func,
    regs: Vec<Value>,
    params: Vec<Value>,
    captures: Vec<Value>,
}

impl<'a> Frame<'a> {
    fn new_with_captures(
        module: &'a Module,
        func: &'a Func,
        params: Vec<Value>,
        captures: Vec<Value>,
    ) -> Self {
        Self {
            module,
            func,
            regs: vec![Value::Unit; func.n_locals as usize],
            params,
            captures,
        }
    }

    fn read(&self, r: Reg) -> Value {
        self.regs.get(r.0 as usize).cloned().unwrap_or(Value::Unit)
    }

    fn write(&mut self, r: Reg, v: Value) {
        let idx = r.0 as usize;
        if idx >= self.regs.len() {
            self.regs.resize(idx + 1, Value::Unit);
        }
        self.regs[idx] = v;
    }

    fn block(&self, b: BlockId) -> &crate::Block {
        &self.func.blocks[b.0 as usize]
    }
}

/// Run a function body with the given positional arguments.
/// Returns the value carried by the terminating `Return`, or
/// `Unit` for a fall-off. Uses `NullHost` for delegated calls.
pub fn eval(module: &Module, func: &Func, args: Vec<Value>) -> Result<Value, EvalError> {
    let mut host = NullHost;
    eval_with(module, func, args, &mut host)
}

/// Run a function body, routing non-trivial dispatch (CallValue /
/// CallMember / NewInstance / InstanceOf) through the supplied
/// host implementation.
pub fn eval_with(
    module: &Module,
    func: &Func,
    args: Vec<Value>,
    host: &mut dyn Host,
) -> Result<Value, EvalError> {
    eval_with_captures(module, func, args, Vec::new(), host)
}

/// Like `eval_with` but seeds the frame with a captured-values
/// vector. Used by closure invocation so `Inst::LoadCapture` reads
/// from the closure's snapshotted env rather than the call args.
pub fn eval_with_captures(
    module: &Module,
    func: &Func,
    args: Vec<Value>,
    captures: Vec<Value>,
    host: &mut dyn Host,
) -> Result<Value, EvalError> {
    // Each interpreted Kotlin call chains into another Rust stack
    // frame here, so deep Kotlin recursion (typical in
    // kotlinx-coroutines internals — BufferedChannel's segment walks,
    // CancellableContinuationImpl's state machine) can blow the
    // default OS thread stack long before the program is buggy.
    // `stacker` checks the remaining headroom on the current thread
    // stack and transparently grows onto a heap-allocated stack when
    // it dips below the red zone. 64 KiB headroom / 4 MiB grow are
    // conservative defaults sufficient for the deepest known
    // interpreted call chains in the pack corpus.
    stacker::maybe_grow(64 * 1024, 4 * 1024 * 1024, || {
        let mut try_stack: Vec<TryFrame> = Vec::new();
        let func_name = func.name.clone();
        let mut frame = Frame::new_with_captures(module, func, args, captures);
        let cur = func.entry;
        match run_frame(module, &mut frame, &mut try_stack, cur, 0, host) {
            // A labeled return whose target is this function exits it as
            // a normal return. Other labels propagate further outward
            // until the matching frame catches them.
            Err(EvalError::LabeledReturn(label, v)) if label == func_name => Ok(v),
            other => other,
        }
    })
}

/// Resume a parked coroutine. `resume_value` is written into the
/// innermost frame's resume register, then that frame runs to
/// completion (or re-suspends). When it returns, its value feeds
/// the next-outer frame's resume register, and so on up the stack.
pub fn resume_continuation(
    module: &Module,
    state: SuspendState,
    resume_value: Value,
    host: &mut dyn Host,
) -> Result<Value, EvalError> {
    let mut carry = resume_value;
    // `frames` is innermost-first (the deepest activation snapshots
    // itself first as `Suspended` unwinds). Resume the innermost,
    // then feed its return value to the next-outer frame, and so on.
    let mut frames: std::collections::VecDeque<FrameSnapshot> =
        state.frames.into();
    let mut first = true;
    let mut pending_throw_from_inner: Option<Value> = None;
    while let Some(snap) = frames.pop_front() {
        let func = &module.funcs[snap.func.0 as usize];
        let mut frame = Frame::new_with_captures(
            module,
            func,
            snap.params.clone(),
            snap.captures.clone(),
        );
        frame.regs = snap.regs.clone();
        // Kotlin `Continuation.resumeWith(Result.failure(e))` means
        // "resume by throwing `e` at the suspension point". Only the
        // innermost (suspending) frame sees the raw failure Result;
        // route it as a throw there instead of delivering it as the
        // suspending call's value, so a cancellation preempts a
        // parked `delay`/acquire rather than letting it complete.
        let resume_throw = if let Some(exc) = pending_throw_from_inner.take() {
            // An inner frame finished with an uncaught throw — route
            // it through this frame's restored try-stack so an
            // enclosing `try { suspendingCall() } catch (e)` fires.
            Some(exc)
        } else if first {
            match &carry {
                Value::Result { ok: false, payload } => {
                    Some((**payload).clone())
                }
                _ => None,
            }
        } else {
            None
        };
        first = false;
        if resume_throw.is_none() {
            if let Some(r) = snap.resume_reg {
                frame.write(r, carry.clone());
            }
        }
        let mut try_stack = snap.try_stack.clone();
        match run_frame_inner(
            module,
            &mut frame,
            &mut try_stack,
            snap.block,
            snap.inst_idx,
            resume_throw,
            host,
        ) {
            Ok(v) => {
                carry = v;
            }
            Err(EvalError::Suspended(mut inner)) => {
                // Re-suspended before this frame finished. The newly
                // captured inner frames stay innermost-first; the
                // still-pending outer frames sit after them.
                inner.frames.extend(frames.into_iter());
                return Err(EvalError::Suspended(inner));
            }
            Err(EvalError::Throw(exc)) => {
                // Route the throw through the next-outer frame's
                // restored try-stack: a `try { suspendingCall() }
                // catch (e) { … }` should see exceptions raised
                // after the parked call resumes.
                if frames.is_empty() {
                    return Err(EvalError::Throw(exc));
                }
                pending_throw_from_inner = Some(exc);
            }
            Err(e) => return Err(e),
        }
    }
    Ok(carry)
}

/// Run (or resume) a single activation's block loop. `start_idx` is
/// the instruction index to begin at within `cur` (0 for a fresh
/// call, the post-suspension index on resume).
fn run_frame<'a>(
    module: &'a Module,
    frame: &mut Frame<'a>,
    try_stack: &mut Vec<TryFrame>,
    cur: BlockId,
    resume_idx: usize,
    host: &mut dyn Host,
) -> Result<Value, EvalError> {
    run_frame_inner(module, frame, try_stack, cur, resume_idx, None, host)
}

/// `resume_throw`: when a continuation is resumed with
/// `Result.failure(e)` (Kotlin's `resumeWith(failure)` =
/// "resume by throwing at the suspension point"), the exception is
/// routed through this frame's restored try-stack instead of being
/// delivered as the suspending call's value. This makes a
/// cancellation actually preempt a parked `delay` / acquire.
fn run_frame_inner<'a>(
    module: &'a Module,
    frame: &mut Frame<'a>,
    try_stack: &mut Vec<TryFrame>,
    mut cur: BlockId,
    mut resume_idx: usize,
    mut resume_throw: Option<Value>,
    host: &mut dyn Host,
) -> Result<Value, EvalError> {
    let mut pending_rethrow: Option<(BlockId, Value)> = None;
    let mut pending_return: Option<(BlockId, Value)> = None;
    let func: &'a Func = frame.func;
    loop {
        // Push any catch / finally metadata attached to this block.
        // The `func` reference (lifetime `'a`) lets us read block
        // contents without cloning the instruction vector or the
        // (usually empty) catch list every loop iteration.
        let block = &func.blocks[cur.0 as usize];
        let insts: &[Inst] = &block.insts;
        let term = block.terminator.clone();
        let finally = block.finally;
        let finally_done = block.finally_done;
        let has_catches = !block.catches.is_empty();
        if resume_idx == 0 && (has_catches || finally.is_some()) {
            try_stack.push(TryFrame {
                body: cur,
                catches: block.catches.clone(),
                finally_entry: finally,
                finally_done,
            });
        }
        let mut thrown: Option<Value> = None;
        let mut start_idx = std::mem::take(&mut resume_idx);
        if let Some(exc) = resume_throw.take() {
            // Resumed with an exception: skip the remaining
            // instructions of the suspending block and route the
            // throw through the restored try-stack exactly as a
            // mid-block throw would.
            thrown = Some(exc);
            start_idx = insts.len();
        }
        for (idx, inst) in insts.iter().enumerate() {
            if idx < start_idx {
                continue;
            }
            match exec_inst(frame, inst, host) {
                Ok(()) => {}
                Err(EvalError::Throw(v)) => { thrown = Some(v); break; }
                Err(EvalError::NonLocalReturn(v)) => {
                    // A non-local return unwinds through the lambda
                    // frame *and* through any inline-function frames
                    // it was passed into, landing in the function
                    // that wrote the lambda (Kotlin allows non-local
                    // return only via inline functions).
                    if frame.func.is_lambda || frame.func.is_inline {
                        return Err(EvalError::NonLocalReturn(v));
                    }
                    return Ok(v);
                }
                Err(EvalError::Suspended(mut state)) => {
                    // Snapshot this activation so it can be resumed
                    // just past the suspending instruction. The
                    // resume value lands in the suspending call's
                    // destination register (or one a binding set
                    // explicitly via `pending_resume_reg`).
                    let resume_reg =
                        state.pending_resume_reg.take().or_else(|| inst_dst(inst));
                    state.frames.push(FrameSnapshot {
                        func: frame.func.id,
                        block: cur,
                        inst_idx: idx + 1,
                        regs: frame.regs.clone(),
                        params: frame.params.clone(),
                        captures: frame.captures.clone(),
                        try_stack: try_stack.clone(),
                        is_lambda: frame.func.is_lambda,
                        resume_reg,
                    });
                    return Err(EvalError::Suspended(state));
                }
                Err(e) => return Err(e),
            }
        }
        if let Some(exc) = thrown {
            // Mid-block throw — same try-stack walk as Terminator::Throw.
            let mut routed = false;
            while let Some(tf) = try_stack.pop() {
                if let Some(h) = tf.catches.iter().find(|h| host.instance_of(
                    &exc,
                    &TypeRef {
                        name: h.type_name.clone(),
                        nullable: false,
                        args: Vec::new(),
                    },
                )) {
                    frame.write(h.exception_reg, exc.clone());
                    cur = h.handler;
                    routed = true;
                    break;
                } else if let Some(fin) = tf.finally_entry {
                    let key = tf.finally_done.unwrap_or(fin);
                    pending_rethrow = Some((key, exc.clone()));
                    cur = fin;
                    routed = true;
                    break;
                }
            }
            if !routed {
                return Err(EvalError::Throw(exc));
            }
            continue;
        }
        // Symmetric try-stack pop on normal flow through finally.
        // The push at the loop top is the only way a try-frame
        // enters `try_stack`; without a corresponding pop on
        // normal completion, an entry leaks past the try, and a
        // later `Return` (e.g. the enclosing lambda's overall
        // return terminator) can mis-route through `pending_return`
        // and replay the same finally a second time.
        //
        // The pop fires on either of two signals:
        //   * `block.finally_done_for == Some(body_entry)` — this
        //     block is the post-finally sentinel synthesized by the
        //     try lowering. Pop the try-stack entry whose body
        //     entry matches, no matter what the user finally body's
        //     internal control flow looks like.
        //   * Legacy match `cur == entry.finally` — kept for
        //     non-Try blocks that share the `finally` field shape
        //     and for safety until the sentinel is everywhere.
        if matches!(term, Terminator::Goto(_))
            && pending_rethrow.is_none()
            && pending_return.is_none()
        {
            let done_for = frame.block(cur).finally_done_for;
            let pos = if let Some(body) = done_for {
                try_stack.iter().rposition(|tf| tf.body == body)
            } else {
                try_stack
                    .iter()
                    .rposition(|tf| matches!(tf.finally_entry, Some(b) if b == cur))
            };
            if let Some(p) = pos {
                try_stack.remove(p);
            }
        }
        // Finally exit with a pending return: replay the return
        // through any outer finally, otherwise complete it. The key
        // pinned in `pending_return` is the *done sentinel* — the
        // synthesized exit block of the user finally body, so an
        // `if`/`when` inside the finally still resolves here once
        // its join reaches the sentinel.
        if let Some((fin, _)) = &pending_return {
            if *fin == cur && matches!(term, Terminator::Goto(_)) {
                let (_, v) = pending_return.take().unwrap();
                let mut chosen: Option<(usize, BlockId, BlockId)> = None;
                for i in (0..try_stack.len()).rev() {
                    if let Some(fin2) = try_stack[i].finally_entry {
                        let key = try_stack[i].finally_done.unwrap_or(fin2);
                        chosen = Some((i, fin2, key));
                        break;
                    }
                }
                if let Some((i, jump, key)) = chosen {
                    try_stack.truncate(i);
                    pending_return = Some((key, v));
                    cur = jump;
                    continue;
                }
                return Ok(v);
            }
            if *fin == cur
                && matches!(
                    term,
                    Terminator::Return(_)
                        | Terminator::NonLocalReturn(_)
                        | Terminator::LabeledReturn(_, _)
                        | Terminator::Throw(_)
                )
            {
                pending_return = None;
            }
        }
        // Finally re-throw: if we entered the current block as a
        // finally on the uncaught-throw path, and the block exits
        // via a plain Goto (no `return` / `throw` swallowed the
        // pending exception), re-raise the saved exception through
        // the enclosing try-stack just like a fresh throw.
        if let Some((fin, _)) = &pending_rethrow {
            if *fin == cur && matches!(term, Terminator::Goto(_)) {
                let (_, exc) = pending_rethrow.take().unwrap();
                let mut routed = false;
                while let Some(tf) = try_stack.pop() {
                    if let Some(h) = tf.catches.iter().find(|h| host.instance_of(
                        &exc,
                        &TypeRef {
                            name: h.type_name.clone(),
                            nullable: false,
                            args: Vec::new(),
                        },
                    )) {
                        frame.write(h.exception_reg, exc.clone());
                        cur = h.handler;
                        routed = true;
                        break;
                    } else if let Some(fin2) = tf.finally_entry {
                        let key = tf.finally_done.unwrap_or(fin2);
                        pending_rethrow = Some((key, exc.clone()));
                        cur = fin2;
                        routed = true;
                        break;
                    }
                }
                if !routed {
                    return Err(EvalError::Throw(exc));
                }
                continue;
            }
            // A `return` / `throw` inside finally clears the pending
            // re-throw (Kotlin: finally's exit replaces the original).
            if *fin == cur
                && matches!(
                    term,
                    Terminator::Return(_)
                        | Terminator::NonLocalReturn(_)
                        | Terminator::LabeledReturn(_, _)
                        | Terminator::Throw(_)
                )
            {
                pending_rethrow = None;
            }
        }
        match term {
            Terminator::Goto(next) => cur = next,
            Terminator::Branch { cond, t, f } => {
                let v = frame.read(cond);
                cur = if value_truthy(&v)? { t } else { f };
            }
            Terminator::Return(r) => {
                let v = r.map(|r| frame.read(r)).unwrap_or(Value::Unit);
                // Walk the try-stack for the nearest finally; route
                // the return through it (finally's own exit completes
                // the return, and an inner `return` inside finally
                // overrides the saved value). The pinned key is the
                // *done sentinel* so a finally body with internal
                // control flow still completes the return when its
                // join reaches the sentinel.
                let mut chosen: Option<(usize, BlockId, BlockId)> = None;
                for i in (0..try_stack.len()).rev() {
                    if let Some(fin) = try_stack[i].finally_entry {
                        let key = try_stack[i].finally_done.unwrap_or(fin);
                        chosen = Some((i, fin, key));
                        break;
                    }
                }
                if let Some((i, jump, key)) = chosen {
                    try_stack.truncate(i);
                    pending_return = Some((key, v));
                    cur = jump;
                    continue;
                }
                return Ok(v);
            }
            Terminator::NonLocalReturn(r) => {
                let v = r.map(|r| frame.read(r)).unwrap_or(Value::Unit);
                if frame.func.is_lambda || frame.func.is_inline {
                    return Err(EvalError::NonLocalReturn(v));
                }
                return Ok(v);
            }
            Terminator::LabeledReturn(label, r) => {
                let v = r.map(|r| frame.read(r)).unwrap_or(Value::Unit);
                if frame.func.name == *label {
                    return Ok(v);
                }
                return Err(EvalError::LabeledReturn(label.clone(), v));
            }
            Terminator::Throw(r) => {
                let exc = frame.read(r);
                if std::env::var("KLIO_THROW_TRACE").is_ok() {
                    eprintln!(
                        "[throw-trace] from fn {} (fqn={}): {}",
                        frame.func.name,
                        frame.func.fqn,
                        display_throw(&exc)
                    );
                }
                // Walk the try stack for a matching handler.
                let mut routed = false;
                while let Some(tf) = try_stack.pop() {
                    let hcatches = &tf.catches;
                    let hfinally = tf.finally_entry;
                    if let Some(h) = hcatches.iter().find(|h| host.instance_of(
                        &exc,
                        &TypeRef {
                            name: h.type_name.clone(),
                            nullable: false,
                            args: Vec::new(),
                        },
                    )) {
                        // Bind exception, jump to handler.
                        frame.write(h.exception_reg, exc.clone());
                        cur = h.handler;
                        routed = true;
                        break;
                    } else if let Some(fin) = hfinally {
                        // No matching catch on this frame — run
                        // finally, then re-throw the original
                        // exception when finally exits normally
                        // (Goto). A `return` / `throw` inside
                        // finally clears the pending re-throw.
                        let key = tf.finally_done.unwrap_or(fin);
                        pending_rethrow = Some((key, exc.clone()));
                        cur = fin;
                        routed = true;
                        break;
                    }
                }
                if !routed {
                    return Err(EvalError::Throw(exc));
                }
            }
            Terminator::Unreachable => {
                return Err(EvalError::Type("reached Terminator::Unreachable".into()));
            }
            Terminator::TailJump { args, n_args } => {
                let mut new_params: Vec<Value> = Vec::with_capacity(n_args as usize);
                for i in 0..n_args {
                    new_params.push(frame.read(Reg(args.0 + i as u32)));
                }
                frame.params = new_params;
                let n = frame.regs.len();
                frame.regs.clear();
                frame.regs.resize(n, Value::Unit);
                try_stack.clear();
                cur = frame.func.entry;
                continue;
            }
            Terminator::TailCallFunc { func, args, n_args } => {
                let mut new_params: Vec<Value> = Vec::with_capacity(n_args as usize);
                for i in 0..n_args {
                    new_params.push(frame.read(Reg(args.0 + i as u32)));
                }
                let new_func = &module.funcs[func.0 as usize];
                frame.func = new_func;
                frame.params = new_params;
                frame.regs.clear();
                frame.regs.resize(new_func.n_locals as usize, Value::Unit);
                try_stack.clear();
                cur = new_func.entry;
                continue;
            }
            Terminator::Switch { reg, arms, default } => {
                let v = frame.read(reg);
                let next = arms
                    .iter()
                    .find_map(|(c, b)| if const_matches(frame.module, *c, &v) { Some(*b) } else { None })
                    .unwrap_or(default);
                cur = next;
            }
        }
    }
}

/// Destination register of a value-producing instruction, used to
/// route a coroutine resume value back to the suspending call site.
fn inst_dst(inst: &Inst) -> Option<Reg> {
    match inst {
        Inst::Call { dst, .. }
        | Inst::CallValue { dst, .. }
        | Inst::CallValueWithThis { dst, .. }
        | Inst::CallSpread { dst, .. }
        | Inst::CallSuper { dst, .. }
        | Inst::CallMember { dst, .. }
        | Inst::CallMemberOrGlobal { dst, .. }
        | Inst::CallValueOrMember { dst, .. }
        | Inst::CallMemberOrValue { dst, .. }
        | Inst::NewInstance { dst, .. } => Some(*dst),
        _ => None,
    }
}

fn exec_inst(
    frame: &mut Frame<'_>,
    inst: &Inst,
    host: &mut dyn Host,
) -> Result<(), EvalError> {
    match inst {
        Inst::SuspendResumePoint { .. } => {
            // No runtime effect on its own. Lowered state-machine
            // dispatch interprets these markers at the function
            // entry; mid-flow they're traversed transparently.
        }
        Inst::Const { dst, value } => {
            let v = const_to_value(&frame.module.consts[value.0 as usize]);
            frame.write(*dst, v);
        }
        Inst::Move { dst, src } => {
            let v = frame.read(*src);
            frame.write(*dst, v);
        }
        Inst::MakeCell { dst, src } => {
            let v = frame.read(*src);
            frame.write(*dst, Value::new_cell(v));
        }
        Inst::CellGet { dst, cell } => {
            let v = match frame.read(*cell) {
                Value::Cell(c) => c.borrow().clone(),
                // Tolerate a non-cell (e.g. captured before boxing
                // analysis saw it) by passing the value through.
                other => other,
            };
            frame.write(*dst, v);
        }
        Inst::CellSet { cell, value } => {
            let v = frame.read(*value);
            match frame.read(*cell) {
                Value::Cell(c) => {
                    *c.borrow_mut() = v;
                }
                _ => {
                    // Not yet a cell — fall back to a plain reg write
                    // so semantics degrade gracefully.
                    frame.write(*cell, v);
                }
            }
        }
        Inst::Not { dst, src } => {
            let v = frame.read(*src);
            // User-defined `operator fun not(): T` overrides the
            // builtin Bool inversion; route through call_member.
            if matches!(v, Value::Instance(_)) {
                let result = host.call_member(&v, "not", &[])?;
                frame.write(*dst, result);
                return Ok(());
            }
            let b = match v {
                Value::Bool(b) => !b,
                _ => return Err(EvalError::Type("Not on non-bool".into())),
            };
            frame.write(*dst, Value::Bool(b));
        }
        Inst::UnOp { dst, op, operand } => {
            let v = frame.read(*operand);
            let method = match op {
                UnOp::Neg => "unaryMinus",
                UnOp::Plus => "unaryPlus",
                UnOp::Inc => "inc",
                UnOp::Dec => "dec",
            };
            // User-class operator dispatch for unary +/-/inc/dec on
            // an Instance always wins.
            if matches!(v, Value::Instance(_)) {
                let result = host.call_member(&v, method, &[])?;
                frame.write(*dst, result);
                return Ok(());
            }
            // Member-extension operator on a primitive receiver
            // (`operator fun Int.unaryPlus()` inside a class). The
            // calling frame's `this` carries the enclosing class —
            // surface it as enclosing-this so the extension-fallback
            // visibility filter accepts the member-ext owner, mirroring
            // the `CallMember` dispatch path. Built-in unary ops on
            // primitives are still reached if no user member-ext is
            // visible (call_member returns Unimplemented and we fall
            // through to apply_unop).
            let pushed_enclosing = match frame.params.first() {
                Some(p @ Value::Instance(_)) => {
                    host.push_access_enclosing(p);
                    true
                }
                _ => false,
            };
            let extension_result = host.call_member(&v, method, &[]);
            if pushed_enclosing {
                host.pop_access_enclosing();
            }
            match extension_result {
                Ok(result) => {
                    frame.write(*dst, result);
                    return Ok(());
                }
                Err(EvalError::Unimplemented(_)) => {}
                Err(e) => return Err(e),
            }
            let out = apply_unop(*op, &v)?;
            frame.write(*dst, out);
        }
        Inst::BinOp { dst, op, lhs, rhs } => {
            let l = frame.read(*lhs);
            let r = frame.read(*rhs);
            // StringConcat over a Value::Instance routes the
            // instance through toString so user-defined overrides
            // fire (e.g. `Instant.toString()` → ISO-8601).
            if matches!(op, BinOp::StringConcat) {
                let ls = stringify(host, &l)?;
                let rs = stringify(host, &r)?;
                let combined = format!("{ls}{rs}");
                frame.write(*dst, Value::String(std::sync::Arc::new(combined)));
                return Ok(());
            }
            // User-class operator dispatch: when an operand is a
            // Value::Instance, route through the host's
            // call_member for the matching operator method
            // (plus/minus/times/div/rem/compareTo/equals/etc.).
            // Collection `+` / `-` operators: `map + pair`,
            // `list + elem`, `set - x` are stdlib operator functions
            // (`plus`/`minus`) on the left collection. Route them
            // through call_member so the stdlib intrinsic handles
            // the merge/remove, just like a user `operator fun`.
            if matches!(*op, BinOp::Add | BinOp::Sub)
                && matches!(l, Value::Map { .. } | Value::List { .. } | Value::Set { .. })
            {
                let method = if matches!(*op, BinOp::Add) { "plus" } else { "minus" };
                let result = host.call_member(&l, method, std::slice::from_ref(&r))?;
                frame.write(*dst, result);
                return Ok(());
            }
            // Referential identity (`===` / `!==`): pure pointer
            // identity, never a user `equals` dispatch — so a
            // `this === other` guard inside an `equals` / `plus`
            // override (e.g. `CombinedContext`) does not recurse.
            if matches!(*op, BinOp::IdentEq | BinOp::IdentNeq) {
                let same = Value::reference_eq(&l, &r);
                let b = if matches!(*op, BinOp::IdentNeq) { !same } else { same };
                frame.write(*dst, Value::Bool(b));
                return Ok(());
            }
            // COROUTINE_SUSPENDED and Result have no user `equals`
            // surface: any equality against them is structural /
            // identity, never a `call_member("equals")` dispatch.
            if matches!(
                *op,
                BinOp::Eq | BinOp::NotEq | BinOp::BoxedEq | BinOp::BoxedNotEq
            ) && (matches!(l, Value::CoroutineSuspended)
                || matches!(r, Value::CoroutineSuspended)
                || matches!(l, Value::Result { .. })
                || matches!(r, Value::Result { .. }))
            {
                let eq = Value::structural_eq(&l, &r);
                let b = if matches!(*op, BinOp::NotEq | BinOp::BoxedNotEq) {
                    !eq
                } else {
                    eq
                };
                frame.write(*dst, Value::Bool(b));
                return Ok(());
            }
            if let Some(method) = operator_method(*op) {
                if matches!(l, Value::Instance(_)) || matches!(r, Value::Instance(_)) {
                    let result = host.call_member(&l, method, std::slice::from_ref(&r))?;
                    // compareTo wrappers (Less/LessEq/Greater/GreaterEq)
                    // need to be reduced to a Bool.
                    let final_val = match *op {
                        BinOp::Less => Value::Bool(value_to_i64(&result).map_or(false, |i| i < 0)),
                        BinOp::LessEq => Value::Bool(value_to_i64(&result).map_or(false, |i| i <= 0)),
                        BinOp::Greater => Value::Bool(value_to_i64(&result).map_or(false, |i| i > 0)),
                        BinOp::GreaterEq => Value::Bool(value_to_i64(&result).map_or(false, |i| i >= 0)),
                        _ => result,
                    };
                    frame.write(*dst, final_val);
                    return Ok(());
                }
            }
            let out = apply_binop(*op, &l, &r)?;
            frame.write(*dst, out);
        }
        Inst::Trace { .. } => {}
        Inst::LoadParam { dst, idx } => {
            let v = frame
                .params
                .get(*idx as usize)
                .cloned()
                .unwrap_or(Value::Unit);
            frame.write(*dst, v);
        }
        Inst::NotNullAssert { dst, src } => {
            let v = frame.read(*src);
            if matches!(v, Value::Null) {
                let exc = Value::Exception {
                    fqn: std::sync::Arc::new("kotlin.NullPointerException".into()),
                    message: None,
                    cause: None,
                };
                return Err(EvalError::Throw(exc));
            }
            frame.write(*dst, v);
        }
        Inst::GetField { dst, receiver, field } => {
            let r = frame.read(*receiver);
            let name = match &frame.module.consts[field.0 as usize] {
                Const::String(s) => s.clone(),
                _ => return Err(EvalError::Type("GetField: name not a string const".into())),
            };
            // The executing function's receiver (`this`, param 0 of a
            // method / extension) is the instance this access was
            // lexically written in. Keep it reachable as the enclosing
            // `this` while the field/property is resolved, so a member
            // extension property accessor whose body calls enclosing-
            // class members resolves them against that instance rather
            // than the extension receiver. Only an Instance distinct
            // from the receiver is pushed (matches the receiver-lambda
            // nested-`this` rule); other cases are unaffected.
            let pushed_enclosing = match frame.params.first() {
                Some(p @ Value::Instance(pi)) => {
                    let same = matches!(&r, Value::Instance(ri) if klio_runtime::ObjRef::ptr_eq(pi, ri));
                    if same {
                        false
                    } else {
                        host.push_access_enclosing(p);
                        true
                    }
                }
                _ => false,
            };
            let got = host.get_field(&r, &name);
            if pushed_enclosing {
                host.pop_access_enclosing();
            }
            let v = got?;
            frame.write(*dst, v);
        }
        Inst::SetField { receiver, field, value } => {
            let r = frame.read(*receiver);
            let v = frame.read(*value);
            let name = match &frame.module.consts[field.0 as usize] {
                Const::String(s) => s.clone(),
                _ => return Err(EvalError::Type("SetField: name not a string const".into())),
            };
            host.set_field(&r, &name, v)?;
        }
        Inst::Call { dst, func, args, n_args, arg_names, type_args } => {
            let arg_values = read_arg_run(frame, *args, *n_args);
            let names = resolve_arg_names(frame.module, arg_names);
            let ta: Vec<String> = type_args
                .iter()
                .map(|c| match &frame.module.consts[c.0 as usize] {
                    crate::Const::String(s) => s.clone(),
                    _ => String::new(),
                })
                .collect();
            // Invoking an extension / member-extension function (its
            // first param is the `this` receiver) from inside a method:
            // keep the caller's instance `this` reachable as the
            // enclosing receiver so the callee's body can resolve bare
            // enclosing-class members (the same nested-`this` rule used
            // for receiver lambdas and member-extension property
            // accessors). Only fires when the caller's `this` is an
            // Instance distinct from the extension receiver.
            let callee_is_ext = frame
                .module
                .funcs
                .get(func.0 as usize)
                .and_then(|f| f.params.first())
                .map(|p| p.name == "this")
                .unwrap_or(false);
            let pushed_enclosing = if callee_is_ext {
                let caller_this = frame
                    .func
                    .params
                    .iter()
                    .position(|p| p.name == "this")
                    .and_then(|i| frame.params.get(i));
                match caller_this {
                    Some(p @ Value::Instance(pi)) => {
                        let same = matches!(
                            arg_values.first(),
                            Some(Value::Instance(ri)) if klio_runtime::ObjRef::ptr_eq(pi, ri)
                        );
                        if same {
                            false
                        } else {
                            host.push_access_enclosing(p);
                            true
                        }
                    }
                    _ => false,
                }
            } else {
                false
            };
            let res = host.call_func_typed(frame.module, *func, arg_values, &names, &ta);
            if pushed_enclosing {
                host.pop_access_enclosing();
            }
            let result = res?;
            frame.write(*dst, result);
        }
        Inst::CallValue { dst, callee, args, n_args, arg_names } => {
            let callee_v = frame.read(*callee);
            let mut arg_values = read_arg_run(frame, *args, *n_args);
            let mut names = resolve_arg_names(frame.module, arg_names);
            // Receiver-typed lambda bare invocation: `body()` where
            // `body: T.()->R` declares `this:T` as its leading param.
            // When the supplied arg count is one short and the
            // closure's first declared param is `this`, prepend the
            // calling frame's `this` so the body sees its expected
            // receiver. Without this the body's bare references to
            // T's members fall through to globals.
            let caller_this: Option<Value> = frame
                .func
                .params
                .iter()
                .position(|p| p.name == "this")
                .and_then(|i| frame.params.get(i).cloned())
                .filter(|v| matches!(v, Value::Instance(_)));
            if let Some((n_params, first_is_this)) =
                host.callable_receiver_shape(&callee_v)
            {
                if first_is_this && arg_values.len() + 1 == n_params {
                    if let Some(ct) = &caller_this {
                        arg_values.insert(0, ct.clone());
                        names.insert(0, None);
                    }
                }
            }
            // Receiver lambda whose `this` arrives via a captured
            // slot (not a leading param). `body()` from inside a
            // method body needs the method's `this` substituted in.
            if host.closure_needs_this_capture(&callee_v) {
                if let Some(ct) = &caller_this {
                    host.override_closure_this(&callee_v, ct);
                }
            }
            // Receiver-lambda fallback for bare names lowered as
            // LoadGlobal: push the calling frame's `this` so the
            // global-miss path in LoadGlobal can fall back to a
            // member of the receiver. Only fires when invoking a
            // lambda value bare from inside a method — same scope
            // as the `body()` style invocation.
            let pushed_caller_this = if matches!(
                callee_v,
                Value::IrClosure { .. } | Value::Lambda { .. }
            ) {
                if let Some(ct) = &caller_this {
                    host.push_access_enclosing(ct);
                    true
                } else {
                    false
                }
            } else {
                false
            };
            let result = host.call_value_named(&callee_v, &arg_values, &names);
            if pushed_caller_this {
                host.pop_access_enclosing();
            }
            let result = result?;
            frame.write(*dst, result);
        }
        Inst::CallValueWithThis { dst, callee, receiver, args, n_args, arg_names } => {
            let callee_v = frame.read(*callee);
            let recv = frame.read(*receiver);
            let arg_values = read_arg_run(frame, *args, *n_args);
            let names = resolve_arg_names(frame.module, arg_names);
            let result = host.call_value_with_this(&callee_v, &recv, &arg_values, &names)?;
            frame.write(*dst, result);
        }
        Inst::CallSpread { dst, callee, parts, arg_names } => {
            let callee_v = frame.read(*callee);
            let mut arg_values: Vec<Value> = Vec::with_capacity(parts.len());
            let mut effective_names: Vec<Option<String>> = Vec::new();
            let in_names = resolve_arg_names(frame.module, arg_names);
            for (i, part) in parts.iter().enumerate() {
                let v = frame.read(part.reg);
                let name = in_names.get(i).cloned().flatten();
                if part.is_spread {
                    let items = spread_items(&v)?;
                    for item in items {
                        arg_values.push(item);
                        effective_names.push(None);
                    }
                } else {
                    arg_values.push(v);
                    effective_names.push(name);
                }
            }
            let result = host.call_value_named(&callee_v, &arg_values, &effective_names)?;
            frame.write(*dst, result);
        }
        Inst::CallSuper { dst, receiver, owner_class, qualifier, name, args, n_args, arg_names } => {
            let recv = frame.read(*receiver);
            let owner_str = match &frame.module.consts[owner_class.0 as usize] {
                Const::String(s) => s.clone(),
                _ => return Err(EvalError::Type("CallSuper: owner not a string const".into())),
            };
            let qual_str: Option<String> = qualifier.and_then(|id| match &frame.module.consts[id.0 as usize] {
                Const::String(s) => Some(s.clone()),
                _ => None,
            });
            let name_str = match &frame.module.consts[name.0 as usize] {
                Const::String(s) => s.clone(),
                _ => return Err(EvalError::Type("CallSuper: name not a string const".into())),
            };
            let arg_values = read_arg_run(frame, *args, *n_args);
            let names = resolve_arg_names(frame.module, arg_names);
            let result = host.call_super(&recv, &owner_str, qual_str.as_deref(), &name_str, &arg_values, &names)?;
            frame.write(*dst, result);
        }
        Inst::CallMemberOrGlobal { dst, this_idx, name, args, n_args, arg_names } => {
            let name_str = match &frame.module.consts[name.0 as usize] {
                Const::String(s) => s.clone(),
                _ => return Err(EvalError::Type(
                    "CallMemberOrGlobal: name not a string const".into(),
                )),
            };
            let arg_values = read_arg_run(frame, *args, *n_args);
            let names = resolve_arg_names(frame.module, arg_names);
            let mut this_val = frame
                .captures
                .get(*this_idx as usize)
                .cloned()
                .unwrap_or(Value::Null);
            // The receiver may be the enclosing function's `this`
            // *parameter* (extension / member / local-extension-fn
            // body) rather than a lambda capture. When the capture
            // slot is empty, fall back to that param so a bare member
            // call (`sorted()`, `toInt()`) dispatches on the
            // receiver instead of escaping to a global.
            if matches!(this_val, Value::Null | Value::Unit) {
                if let Some(idx) =
                    frame.func.params.iter().position(|p| p.name == "this")
                {
                    if let Some(v) = frame.params.get(idx) {
                        this_val = v.clone();
                    }
                }
            }
            // A bare callee whose name starts uppercase is a
            // constructor / type (`UnsupportedOperationException(msg)`,
            // `Foo(...)`), never an instance member (Kotlin members are
            // lowerCamelCase). Dispatching it as `this.<Name>(...)`
            // prepends the receiver and a 1-arg exception constructor
            // is misread as `(message, cause)`. Skip the member probe
            // for such names and let the constructor / global path
            // (below) build it with the real arguments.
            let is_ctor_name = name_str
                .chars()
                .next()
                .map_or(false, |c| c.is_uppercase());
            let mut resolved: Option<Value> = None;
            // A probe that *found* the member but whose body failed
            // (any error that is not the `Unimplemented`
            // "no-such-member" sentinel) is recorded here. Probing
            // continues across the remaining receivers — a later one
            // may legitimately resolve — but if nothing resolves this
            // genuine failure is surfaced instead of the misleading
            // `unresolved global` diagnostic that would otherwise
            // mask it.
            let mut first_real_err: Option<EvalError> = None;
            // A bare `name` bound to a captured callable in the
            // innermost scoped-global layer (an anon-object method's
            // capture env) is a closed-over parameter/local: Kotlin
            // scoping has it shadow any same-named member, so skip the
            // implicit-receiver member probe and member dispatch and
            // bind the captured callable via the global path below.
            // But a genuine member of the implicit receiver still wins
            // over an over-captured scoped global: anon-object capture
            // sets are built from the whole visible scope, so a bare
            // name can land in the capture layer even though the real
            // binding is the receiver's member. Only shadow when the
            // receiver does not actually carry the member.
            let shadow_capture = host.is_shadowing_capture(&name_str)
                && !(!matches!(this_val, Value::Null | Value::Unit)
                    && host.host_has_member(&this_val, &name_str));
            // Implicit-receiver search, Kotlin order: a *member* of
            // the lambda's own `this` or of any lexically enclosing
            // `this@…` outranks a same-named top-level extension.
            // Probe each receiver for a member only (no extension /
            // SAM / global) before the general resolution below — so a
            // bare name inside a nested lambda binds the enclosing
            // receiver's member when one is in scope. Extensions still
            // resolve normally below when no receiver in the chain has
            // the member.
            if !is_ctor_name && !shadow_capture {
                let mut chain: Vec<Value> = Vec::new();
                if !matches!(this_val, Value::Null | Value::Unit) {
                    chain.push(this_val.clone());
                }
                chain.extend(host.enclosing_this_chain());
                for recv in chain {
                    if matches!(recv, Value::Null | Value::Unit) {
                        continue;
                    }
                    match host.call_member_only(
                        &recv, &name_str, &arg_values, &names,
                    ) {
                        Ok(v) => {
                            resolved = Some(v);
                            break;
                        }
                        Err(e @ EvalError::Suspended(_)) => {
                            return Err(e)
                        }
                        // `Unimplemented` is klio's "no such member"
                        // sentinel — keep probing the next receiver.
                        // A different error means the member *was*
                        // found and its body failed: record it (so it
                        // can be surfaced if nothing resolves) but
                        // keep probing — a later receiver may bind.
                        Err(EvalError::Unimplemented(_)) => {}
                        Err(e) => {
                            if first_real_err.is_none() {
                                first_real_err = Some(e);
                            }
                        }
                    }
                }
            }
            if resolved.is_none()
                && !is_ctor_name
                && !shadow_capture
                && !matches!(this_val, Value::Null | Value::Unit)
            {
                match host.call_member_named(
                    &this_val, &name_str, &arg_values, &names,
                ) {
                    Ok(v) => resolved = Some(v),
                    // A suspension is not a "member not found": the
                    // target *was* dispatched and parked. Propagate it
                    // so the cooperative driver resumes the activation,
                    // instead of swallowing it and misreporting the
                    // name as an unresolved global.
                    Err(e @ EvalError::Suspended(_)) => return Err(e),
                    Err(EvalError::Unimplemented(_)) => {}
                    Err(e) => {
                        if first_real_err.is_none() {
                            first_real_err = Some(e);
                        }
                    }
                }
            }
            // Enclosing-receiver fallback: inside a receiver lambda
            // (`buildString { … }` in a member) a bare call may be a
            // member of the lexically enclosing `this@Outer` rather
            // than the lambda receiver.
            if resolved.is_none() && !shadow_capture {
                if let Some(outer) = host.enclosing_this() {
                    if !matches!(outer, Value::Null | Value::Unit) {
                        match host.call_member_named(
                            &outer, &name_str, &arg_values, &names,
                        ) {
                            Ok(v) => resolved = Some(v),
                            Err(e @ EvalError::Suspended(_)) => {
                                return Err(e)
                            }
                            Err(EvalError::Unimplemented(_)) => {}
                            Err(e) => {
                                if first_real_err.is_none() {
                                    first_real_err = Some(e);
                                }
                            }
                        }
                    }
                }
            }
            // Inner-class outer-chain fallback: a bare call inside an
            // `inner class` method may target an enclosing-class
            // member. The enclosing instance is the receiver's
            // captured `outer` link (not the receiver-lambda
            // `enclosing_this` stack), so walk it.
            if resolved.is_none() && !shadow_capture {
                let mut cur = match &this_val {
                    Value::Instance(i) => i.borrow().outer.clone(),
                    _ => None,
                };
                while let Some(o) = cur {
                    if matches!(o, Value::Null | Value::Unit) {
                        break;
                    }
                    match host.call_member_named(
                        &o, &name_str, &arg_values, &names,
                    ) {
                        Ok(v) => {
                            resolved = Some(v);
                            break;
                        }
                        Err(e @ EvalError::Suspended(_)) => return Err(e),
                        Err(EvalError::Unimplemented(_)) => {}
                        Err(e) => {
                            if first_real_err.is_none() {
                                first_real_err = Some(e);
                            }
                        }
                    }
                    cur = match &o {
                        Value::Instance(i) => i.borrow().outer.clone(),
                        _ => None,
                    };
                }
            }
            // The receiver carries this member but none of the probes
            // above bound it (a class whose method is registered via
            // the hierarchy map rather than the IR class table).
            // Dispatch the member rather than fall through to the
            // global path, which would otherwise mis-bind to a
            // captured closure and recurse.
            if resolved.is_none()
                && !is_ctor_name
                && !matches!(this_val, Value::Null | Value::Unit)
                && host.host_has_member(&this_val, &name_str)
            {
                match host.call_member_named(
                    &this_val, &name_str, &arg_values, &names,
                ) {
                    Ok(v) => resolved = Some(v),
                    Err(e @ EvalError::Suspended(_)) => return Err(e),
                    Err(EvalError::Unimplemented(_)) => {}
                    Err(e) => {
                        if first_real_err.is_none() {
                            first_real_err = Some(e);
                        }
                    }
                }
            }
            // Lexically-enclosing receivers as extension candidates.
            // The chain probe above used `call_member_only` so it
            // never tried a same-named extension (`Iterable<T>.forEach`)
            // declared on an OUTER lexical receiver — only members.
            // Now walk the chain with full `call_member` so extension
            // dispatch is given a chance to score against each
            // enclosing `this@…` before the bare-name global path
            // commits to a `func_id` candidate without receiver-type
            // awareness. Without this, `forEach { emit(it) }` inside
            // `Iterable<T>.asFlow() = flow { forEach { … } }` resolves
            // its bare `forEach` to the pack's `Flow<T>.forEach`
            // deprecation stub instead of `Iterable<T>.forEach`,
            // because the bare-name global path can't tell those
            // overloads apart.
            if resolved.is_none() && !is_ctor_name && !shadow_capture {
                let mut chain: Vec<Value> = Vec::new();
                if !matches!(this_val, Value::Null | Value::Unit) {
                    chain.push(this_val.clone());
                }
                chain.extend(host.enclosing_this_chain());
                for recv in chain.iter().skip(1) {
                    if matches!(recv, Value::Null | Value::Unit) {
                        continue;
                    }
                    match host.call_member_named(
                        recv, &name_str, &arg_values, &names,
                    ) {
                        Ok(v) => {
                            resolved = Some(v);
                            break;
                        }
                        Err(e @ EvalError::Suspended(_)) => return Err(e),
                        Err(EvalError::Unimplemented(_)) => {}
                        Err(e) => {
                            if first_real_err.is_none() {
                                first_real_err = Some(e);
                            }
                        }
                    }
                }
            }
            let result = match resolved {
                Some(v) => v,
                None => {
                    // Overloaded top-level function: select by runtime
                    // arg types before falling back to the single
                    // global value baked in at lower time.
                    if let Some(v) = host.call_named_overload(
                        frame.module, &name_str, &arg_values, &names,
                    )? {
                        v
                    } else {
                        match host.lookup_global_throwing(&name_str)? {
                            Some(callee) => host.call_value_named(
                                &callee, &arg_values, &names,
                            )?,
                            None => {
                                // Last resort: a bare call that is a
                                // The frame's bound `this` param (the
                                // method / extension body) — or, when
                                // the bare call is inside a lambda,
                                // the lexically enclosing receiver.
                                // Dispatch the bare call on it before
                                // giving up so a sibling method
                                // call resolves.
                                let own_this = frame
                                    .func
                                    .params
                                    .iter()
                                    .position(|p| p.name == "this")
                                    .and_then(|i| frame.params.get(i))
                                    .cloned()
                                    .filter(|v| {
                                        matches!(v, Value::Instance(_))
                                    })
                                    .or_else(|| {
                                        host.enclosing_this_chain()
                                            .into_iter()
                                            .find(|v| {
                                                matches!(
                                                    v,
                                                    Value::Instance(_)
                                                ) && host.host_has_member(
                                                    v, &name_str,
                                                )
                                            })
                                    });
                                if let Some(t @ Value::Instance(_)) =
                                    own_this
                                {
                                    match host.call_member_named(
                                        &t, &name_str, &arg_values,
                                        &names,
                                    ) {
                                        Ok(v) => v,
                                        Err(
                                            e @ EvalError::Suspended(_),
                                        ) => return Err(e),
                                        Err(_) => {
                                            return Err(first_real_err
                                                .unwrap_or(
                                                EvalError::Unbound(
                                                    format!("unresolved global `{name_str}`"),
                                                ),
                                            ))
                                        }
                                    }
                                } else {
                                    // Nothing resolved this name. If a
                                    // probe found the member but its
                                    // body failed, surface that real
                                    // error instead of the misleading
                                    // `unresolved global`.
                                    return Err(first_real_err.unwrap_or(
                                        EvalError::Unbound(format!(
                                            "unresolved global `{name_str}`"
                                        )),
                                    ));
                                }
                            }
                        }
                    }
                }
            };
            frame.write(*dst, result);
        }
        Inst::CallMember { dst, receiver, name, args, n_args, arg_names } => {
            let recv = frame.read(*receiver);
            let name_str = match &frame.module.consts[name.0 as usize] {
                Const::String(s) => s.clone(),
                _ => return Err(EvalError::Type("CallMember: name not a string const".into())),
            };
            let arg_values = read_arg_run(frame, *args, *n_args);
            let names = resolve_arg_names(frame.module, arg_names);
            // Keep the caller's instance `this` reachable as the
            // enclosing receiver while a `recv.member(...)` call runs,
            // so a member-extension function/property whose body calls
            // bare enclosing-class members resolves them (same nested-
            // `this` rule as receiver lambdas). Only an Instance `this`
            // distinct from the receiver is pushed; ordinary method
            // bodies never consult the enclosing-this fallback.
            let pushed_enclosing = match frame.params.first() {
                Some(p @ Value::Instance(pi)) => {
                    let same = matches!(&recv, Value::Instance(ri) if klio_runtime::ObjRef::ptr_eq(pi, ri));
                    if same {
                        false
                    } else {
                        host.push_access_enclosing(p);
                        true
                    }
                }
                _ => false,
            };
            let res = host.call_member_named(&recv, &name_str, &arg_values, &names);
            if pushed_enclosing {
                host.pop_access_enclosing();
            }
            let result = res?;
            frame.write(*dst, result);
        }
        Inst::CallMemberOrValue {
            dst,
            receiver,
            name,
            fallback,
            args,
            n_args,
            arg_names,
        } => {
            let recv = frame.read(*receiver);
            let user_args = read_arg_run(frame, *args, *n_args);
            let names = resolve_arg_names(frame.module, arg_names);
            let name_str = match &frame.module.consts[name.0 as usize] {
                Const::String(s) => s.clone(),
                _ => {
                    return Err(EvalError::Type(
                        "CallMemberOrValue: name not a string const".into(),
                    ))
                }
            };
            let result = if host.host_has_member(&recv, &name_str) {
                host.call_member_named(&recv, &name_str, &user_args, &names)?
            } else {
                let fb = frame.read(*fallback);
                // Invoke with `recv` bound as the callable's receiver.
                // For a lowered extension fn (param 0 is `this`) this
                // prepends `recv`; for a receiver lambda that captured
                // `this` (`Sink.(Int) -> Unit` written `{ v -> … }`)
                // the receiver is delivered through the capture and
                // the declared params stay the value params — so a
                // blind `recv`-prepend would bind `v` to the receiver.
                host.call_value_with_this(&fb, &recv, &user_args, &names)?
            };
            frame.write(*dst, result);
        }
        Inst::CallValueOrMember {
            dst,
            callee,
            this_recv,
            name,
            args,
            n_args,
            arg_names,
        } => {
            let callee_v = frame.read(*callee);
            let arg_values = read_arg_run(frame, *args, *n_args);
            let names = resolve_arg_names(frame.module, arg_names);
            let invocable = match &callee_v {
                Value::Function { .. }
                | Value::Lambda { .. }
                | Value::Intrinsic { .. }
                | Value::IrClosure { .. }
                | Value::BoundMethod { .. }
                | Value::BoundUserMethod { .. } => true,
                Value::Instance(i) => {
                    let cls = i.borrow().class.name.clone();
                    frame
                        .module
                        .registry
                        .hierarchy_methods
                        .get(&cls)
                        .map_or(false, |m| m.contains("invoke"))
                }
                _ => false,
            };
            let result = if invocable {
                host.call_value_named(&callee_v, &arg_values, &names)?
            } else {
                let recv = frame.read(*this_recv);
                let name_str = match &frame.module.consts[name.0 as usize] {
                    Const::String(s) => s.clone(),
                    _ => {
                        return Err(EvalError::Type(
                            "CallValueOrMember: name not a string const".into(),
                        ))
                    }
                };
                host.call_member_named(&recv, &name_str, &arg_values, &names)?
            };
            frame.write(*dst, result);
        }
        Inst::NewInstance { dst, class, args, n_args, arg_names } => {
            let arg_values = read_arg_run(frame, *args, *n_args);
            let names = resolve_arg_names(frame.module, arg_names);
            // A bare `Inner(args)` inside a member of the enclosing
            // class is `this@Outer.Inner(args)` — an `inner class`
            // captures the enclosing instance. Surface the caller's
            // `this` to the host *before* allocation so init blocks
            // running on the new Inner instance can reach outer
            // members through the `outer` chain.
            let outer_hint = frame
                .func
                .params
                .iter()
                .position(|p| p.name == "this")
                .and_then(|i| frame.params.get(i).cloned())
                .filter(|v| matches!(v, Value::Instance(_)));
            if let Some(h) = &outer_hint {
                host.push_inner_outer_hint(h);
            }
            let result = host.new_instance_named(*class, &arg_values, &names);
            if outer_hint.is_some() {
                host.pop_inner_outer_hint();
            }
            let result = result?;
            if let Value::Instance(inst) = &result {
                let needs_outer = {
                    let b = inst.borrow();
                    b.class.is_inner && b.outer.is_none()
                };
                if needs_outer {
                    if let Some(h) = outer_hint {
                        inst.borrow_mut().outer = Some(h);
                    }
                }
            }
            frame.write(*dst, result);
        }
        Inst::InstanceOf { dst, src, ty } => {
            let v = frame.read(*src);
            let is = host.instance_of(&v, ty);
            frame.write(*dst, Value::Bool(is));
        }
        Inst::Cast { dst, src, ty, safe } => {
            let v = frame.read(*src);
            if host.instance_of(&v, ty) {
                frame.write(*dst, v);
            } else if *safe {
                frame.write(*dst, Value::Null);
            } else {
                // Failed unchecked cast raises ClassCastException
                // so user `catch (e: ClassCastException)` arms fire.
                let exc = Value::Exception {
                    fqn: std::sync::Arc::new("kotlin.ClassCastException".into()),
                    message: Some(std::sync::Arc::new(format!(
                        "cast to `{}` failed",
                        ty.name
                    ))),
                    cause: None,
                };
                return Err(EvalError::Throw(exc));
            }
        }
        Inst::Lambda { dst, body_func, captures } => {
            let cap_values: Vec<Value> = captures.iter().map(|r| frame.read(*r)).collect();
            let v = host.build_closure(frame.module, *body_func, cap_values)?;
            frame.write(*dst, v);
        }
        Inst::AstLambda { dst, params, body_ast, captures, captured_names, absorb_return, body_func } => {
            let cap_values: Vec<Value> = captures.iter().map(|r| frame.read(*r)).collect();
            let v = host.build_ast_lambda_with_flag_funcid(
                params,
                body_ast,
                captured_names,
                cap_values,
                *absorb_return,
                *body_func,
            )?;
            frame.write(*dst, v);
        }
        Inst::RegisterClass { class, captured_names, captures } => {
            let cap_values: Vec<Value> = captures.iter().map(|r| frame.read(*r)).collect();
            host.register_class_captured(class, captured_names, cap_values)?;
        }
        Inst::BuildObject { dst, ast, captured_names, captures } => {
            let captured_values: Vec<Value> = captures.iter().map(|r| frame.read(*r)).collect();
            let v = host.build_object(ast, captured_names, captured_values)?;
            frame.write(*dst, v);
        }
        Inst::StoreGlobal { name, value } => {
            let name_str = match &frame.module.consts[name.0 as usize] {
                Const::String(s) => s.clone(),
                _ => return Err(EvalError::Type("StoreGlobal: name not a string const".into())),
            };
            let v = frame.read(*value);
            host.store_global(&name_str, v)?;
        }
        Inst::StoreToThisOrGlobal { this_idx, name, value } => {
            let name_str = match &frame.module.consts[name.0 as usize] {
                Const::String(s) => s.clone(),
                _ => return Err(EvalError::Type(
                    "StoreToThisOrGlobal: name not a string const".into(),
                )),
            };
            let v = frame.read(*value);
            let this_val = frame
                .captures
                .get(*this_idx as usize)
                .cloned()
                .unwrap_or(Value::Null);
            // Bound-receiver property write inside a receiver lambda
            // (`Sink.(Int) -> Unit` doing `sum = 99`). Only treat the
            // assign as a receiver-member write when the receiver
            // actually carries that name — otherwise the assign is a
            // genuine top-level binding. Routing to `set_field` on
            // an Instance that doesn't declare the name would create
            // a phantom field while leaving the actual top-level
            // global unmodified.
            let route_to_member = matches!(this_val, Value::Instance(_))
                && host.host_has_member(&this_val, &name_str);
            if route_to_member {
                host.set_field(&this_val, &name_str, v)?;
            } else {
                host.store_global(&name_str, v)?;
            }
        }
        Inst::LoadGlobal { dst, name } => {
            let name_str = match &frame.module.consts[name.0 as usize] {
                Const::String(s) => s.clone(),
                _ => return Err(EvalError::Type("LoadGlobal: name not a string const".into())),
            };
            let v = match host.lookup_global_throwing(&name_str)? {
                Some(v) => v,
                None => {
                    // Receiver-lambda fallback: a lambda body whose
                    // bare reference was lowered as LoadGlobal (the
                    // lower had no type info and assumed top-level)
                    // may actually name a member of an enclosing
                    // receiver — pushed onto enclosing-this by
                    // `invoke_callable_with_this` for scope functions
                    // and by `CallValue`'s caller-this assist for
                    // bare receiver-typed lambda invocations.
                    let mut resolved: Option<Value> = None;
                    for outer in host.enclosing_this_chain() {
                        if matches!(outer, Value::Null | Value::Unit) {
                            continue;
                        }
                        if let Ok(v) = host.get_field(&outer, &name_str) {
                            if !matches!(v, Value::Unit) {
                                resolved = Some(v);
                                break;
                            }
                        }
                    }
                    resolved.ok_or_else(|| {
                        EvalError::Unbound(format!(
                            "unresolved global `{name_str}`"
                        ))
                    })?
                }
            };
            frame.write(*dst, v);
        }
        Inst::LoadCapture { dst, idx } => {
            // Captures live in the frame's separate captures vec —
            // distinct from positional params so the closure body
            // can index by its own capture order.
            let v = frame
                .captures
                .get(*idx as usize)
                .cloned()
                .unwrap_or(Value::Unit);
            frame.write(*dst, v);
        }
        Inst::LoadFromThisOrGlobal { dst, this_idx, name } => {
            let name_str = match &frame.module.consts[name.0 as usize] {
                Const::String(s) => s.clone(),
                _ => return Err(EvalError::Type(
                    "LoadFromThisOrGlobal: name not a string const".into(),
                )),
            };
            let this_val = frame
                .captures
                .get(*this_idx as usize)
                .cloned()
                .unwrap_or(Value::Null);
            // First try resolving as a property/field on the captured
            // this. Swallow errors so the global fallback fires.
            let mut resolved: Option<Value> = None;
            if !matches!(this_val, Value::Null | Value::Unit) {
                if let Ok(v) = host.get_field(&this_val, &name_str) {
                    if !matches!(v, Value::Unit) {
                        resolved = Some(v);
                    }
                }
            }
            // Enclosing-receiver fallback: a bare property read inside
            // a receiver lambda may name a member of the lexically
            // enclosing `this@Outer`.
            if resolved.is_none() {
                if let Some(outer) = host.enclosing_this() {
                    if !matches!(outer, Value::Null | Value::Unit) {
                        if let Ok(v) = host.get_field(&outer, &name_str) {
                            if !matches!(v, Value::Unit) {
                                resolved = Some(v);
                            }
                        }
                    }
                }
            }
            let v = match resolved {
                Some(v) => v,
                None => host
                    .lookup_global_throwing(&name_str)?
                    .ok_or_else(|| EvalError::Unbound(
                        format!("unresolved global `{name_str}`"),
                    ))?,
            };
            frame.write(*dst, v);
        }
        Inst::Index { dst, receiver, index } => {
            let r = frame.read(*receiver);
            let i = frame.read(*index);
            let result = host.call_member(&r, "get", &[i])?;
            frame.write(*dst, result);
        }
        Inst::IndexSet { receiver, index, value } => {
            let r = frame.read(*receiver);
            let i = frame.read(*index);
            let v = frame.read(*value);
            let _ = host.call_member(&r, "set", &[i, v])?;
        }
        Inst::NewList { dst, args, n_args } => {
            let items: Vec<Value> = read_arg_run(frame, *args, *n_args);
            frame.write(
                *dst,
                Value::List {
                    items: klio_runtime::ObjRef::new(items),
                    mutable: false,
                    enum_class: None,
                },
            );
        }
        Inst::WritebackCaptures { lambda, names, dsts } => {
            let lam = frame.read(*lambda);
            for (name_id, dst) in names.iter().zip(dsts.iter()) {
                let name_str = match &frame.module.consts[name_id.0 as usize] {
                    Const::String(s) => s.clone(),
                    _ => return Err(EvalError::Type(
                        "WritebackCaptures: name not a string const".into(),
                    )),
                };
                let v = host.read_lambda_capture(&lam, &name_str)?;
                frame.write(*dst, v);
            }
        }
        Inst::QualifiedThis { dst, receiver, qualifier } => {
            let recv = frame.read(*receiver);
            let qual_str = match &frame.module.consts[qualifier.0 as usize] {
                Const::String(s) => s.clone(),
                _ => return Err(EvalError::Type("QualifiedThis: qualifier not a string const".into())),
            };
            let v = host.qualified_this(&recv, &qual_str)?;
            frame.write(*dst, v);
        }
        Inst::PropertyRef { dst, name } => {
            let name_str = match &frame.module.consts[name.0 as usize] {
                Const::String(s) => s.clone(),
                _ => return Err(EvalError::Type("PropertyRef: name not a string const".into())),
            };
            frame.write(
                *dst,
                Value::PropertyRef { name: std::sync::Arc::new(name_str) },
            );
        }
        Inst::MemberRef { dst, receiver, name } => {
            let recv = frame.read(*receiver);
            let name_str = match &frame.module.consts[name.0 as usize] {
                Const::String(s) => s.clone(),
                _ => return Err(EvalError::Type("MemberRef: name not a string const".into())),
            };
            let v = host.member_ref(&recv, &name_str)?;
            frame.write(*dst, v);
        }
    }
    Ok(())
}

/// Pull `n_args` register values starting at `args_start` into a
/// fresh Vec. Args are laid out contiguously by the lowering pass
/// in a `Move`-sequence, so reading the run is straight indexing.
/// Flatten an array / list / range / set into a Vec of its items
/// for spread-arg dispatch. Returns an error if the value isn't
/// iterable in a way that maps to positional args.
fn spread_items(v: &Value) -> Result<Vec<Value>, EvalError> {
    use Value::*;
    match v {
        Array { items, .. } => Ok(items.borrow().clone()),
        List { items, .. } => Ok(items.borrow().clone()),
        Set { items, .. } => Ok(items.borrow().clone()),
        _ => Err(EvalError::Type(format!(
            "spread argument: expected an array/list, got `{}`",
            v.type_fqn()
        ))),
    }
}

fn read_arg_run(frame: &Frame<'_>, args_start: Reg, n: u8) -> Vec<Value> {
    let mut out = Vec::with_capacity(n as usize);
    for i in 0..n as u32 {
        let reg = Reg(args_start.0 + i);
        out.push(frame.read(reg));
    }
    out
}

/// Resolve a per-call `arg_names: Vec<Option<ConstId>>` into a
/// parallel `Vec<Option<String>>`. Empty input yields an empty
/// output — callers treat that as "every arg positional".
fn resolve_arg_names(module: &Module, names: &[Option<crate::ConstId>]) -> Vec<Option<String>> {
    names
        .iter()
        .map(|opt| {
            opt.and_then(|id| match &module.consts[id.0 as usize] {
                Const::String(s) => Some(s.clone()),
                _ => None,
            })
        })
        .collect()
}

fn value_truthy(v: &Value) -> Result<bool, EvalError> {
    match v {
        Value::Bool(b) => Ok(*b),
        _ => Err(EvalError::Type(format!("non-bool in branch: {v:?}"))),
    }
}

fn const_matches(module: &Module, id: crate::ConstId, v: &Value) -> bool {
    let lhs = const_to_value(&module.consts[id.0 as usize]);
    Value::structural_eq(&lhs, v)
}

fn const_to_value(c: &Const) -> Value {
    match c {
        Const::Unit => Value::Unit,
        Const::Int(i) => Value::Int(*i),
        Const::Long(l) => Value::Long(*l),
        Const::UInt(v) => Value::UInt(*v),
        Const::ULong(v) => Value::ULong(*v),
        Const::UShort(v) => Value::UShort(*v),
        Const::UByte(v) => Value::UByte(*v),
        Const::Short(v) => Value::Short(*v),
        Const::Byte(v) => Value::Byte(*v),
        Const::Double(d) => Value::Double(*d),
        Const::Float(f) => Value::Float(*f),
        Const::Bool(b) => Value::Bool(*b),
        Const::Char(c) => Value::Char(*c),
        Const::String(s) => Value::String(std::sync::Arc::new(s.clone())),
        Const::Null => Value::Null,
    }
}

fn apply_unop(op: UnOp, v: &Value) -> Result<Value, EvalError> {
    match (op, v) {
        (UnOp::Neg, Value::Int(i)) => Ok(Value::Int(-i)),
        (UnOp::Neg, Value::Long(l)) => Ok(Value::Long(-l)),
        (UnOp::Neg, Value::Double(d)) => Ok(Value::Double(-d)),
        (UnOp::Neg, Value::Float(f)) => Ok(Value::Float(-f)),
        (UnOp::Plus, v) => Ok(v.clone()),
        (UnOp::Inc, Value::Int(i)) => Ok(Value::Int(i.wrapping_add(1))),
        (UnOp::Inc, Value::Long(l)) => Ok(Value::Long(l.wrapping_add(1))),
        (UnOp::Inc, Value::Float(f)) => Ok(Value::Float(f + 1.0)),
        (UnOp::Inc, Value::Double(d)) => Ok(Value::Double(d + 1.0)),
        (UnOp::Dec, Value::Int(i)) => Ok(Value::Int(i.wrapping_sub(1))),
        (UnOp::Dec, Value::Long(l)) => Ok(Value::Long(l.wrapping_sub(1))),
        (UnOp::Dec, Value::Float(f)) => Ok(Value::Float(f - 1.0)),
        (UnOp::Dec, Value::Double(d)) => Ok(Value::Double(d - 1.0)),
        _ => Err(EvalError::Type(format!("UnOp::{op:?} on {v:?}"))),
    }
}

/// Render a Value to its Kotlin string representation. For
/// Value::Instance, dispatches `toString()` through the host so
/// user-defined overrides fire; primitives use `render_value`'s
/// fast path.
fn stringify(host: &mut dyn Host, v: &Value) -> Result<String, EvalError> {
    if let Value::Instance(_) = v {
        let result = host.call_member(v, "toString", &[])?;
        if let Value::String(s) = result {
            return Ok(s.as_str().to_string());
        }
        return Ok(render_value(&result));
    }
    Ok(render_value(v))
}

fn value_to_i64(v: &Value) -> Option<i64> {
    match v {
        Value::Int(i) => Some(*i as i64),
        Value::Long(l) => Some(*l),
        _ => None,
    }
}

/// Operator-name a BinOp dispatches through when one operand is a
/// user class. Returns `None` for ops that have no operator-method
/// counterpart (e.g. boolean short-circuits).
fn operator_method(op: BinOp) -> Option<&'static str> {
    Some(match op {
        BinOp::Add => "plus",
        BinOp::Sub => "minus",
        BinOp::Mul => "times",
        BinOp::Div => "div",
        BinOp::Mod => "rem",
        BinOp::Eq => "equals",
        BinOp::Less | BinOp::LessEq | BinOp::Greater | BinOp::GreaterEq => "compareTo",
        BinOp::RangeTo => "rangeTo",
        BinOp::RangeUntil => "rangeUntil",
        _ => return None,
    })
}

fn render_value(v: &Value) -> String {
    match v {
        Value::Unit => "kotlin.Unit".to_string(),
        Value::Int(i) => i.to_string(),
        Value::Long(l) => l.to_string(),
        Value::Short(s) => s.to_string(),
        Value::Byte(b) => b.to_string(),
        Value::UInt(u) => u.to_string(),
        Value::ULong(u) => u.to_string(),
        Value::UShort(u) => u.to_string(),
        Value::UByte(u) => u.to_string(),
        // Use the same Kotlin-faithful formatters as `Value`'s Display so a
        // Double/Float in a string template (`"$x"`) or `+` concatenation
        // renders identically to `println(x)` — Kotlin's `1.0E20`,
        // `1.0E-7`, `Infinity`, `NaN`, not Rust's `100000000000000000000`,
        // `0.0000001`, `inf`.
        Value::Double(d) => klio_runtime::kotlin_double_to_string(*d),
        Value::Float(f) => klio_runtime::kotlin_float_to_string(*f),
        Value::Bool(b) => b.to_string(),
        Value::String(s) => s.as_str().to_string(),
        Value::Char(c) => c.to_string(),
        Value::Null => "null".to_string(),
        _ => format!("{v}"),
    }
}

/// Lexicographic compare in UTF-16 code units to match Kotlin's
/// `String.compareTo`. Surrogates above the BMP encode as two u16
/// units and sort accordingly — `<` on `"😀"` vs `""` differs
/// from a UTF-8 byte compare.
fn utf16_cmp(a: &str, b: &str) -> std::cmp::Ordering {
    let mut ai = a.encode_utf16();
    let mut bi = b.encode_utf16();
    loop {
        match (ai.next(), bi.next()) {
            (None, None) => return std::cmp::Ordering::Equal,
            (None, Some(_)) => return std::cmp::Ordering::Less,
            (Some(_), None) => return std::cmp::Ordering::Greater,
            (Some(x), Some(y)) => match x.cmp(&y) {
                std::cmp::Ordering::Equal => continue,
                o => return o,
            },
        }
    }
}

fn arith_exc(msg: &str) -> EvalError {
    EvalError::Throw(Value::Exception {
        fqn: std::sync::Arc::new("kotlin.ArithmeticException".into()),
        message: Some(std::sync::Arc::new(msg.into())),
        cause: None,
    })
}

fn apply_binop(op: BinOp, l: &Value, r: &Value) -> Result<Value, EvalError> {
    use Value::{Bool, Double, Int, Long};
    // Kotlin promotes `Byte`/`Short` to `Int` in arithmetic and
    // comparison (`b0 >= 0` where `b0: Byte`). Widen and re-dispatch;
    // the promoted operands are `Int`, so this recurses at most once.
    let promote = |v: &Value| -> Option<Value> {
        match v {
            Value::Byte(b) => Some(Int(*b as i32)),
            Value::Short(s) => Some(Int(*s as i32)),
            _ => None,
        }
    };
    if (promote(l).is_some() || promote(r).is_some())
        && !matches!(op, BinOp::StringConcat)
    {
        let nl = promote(l).unwrap_or_else(|| l.clone());
        let nr = promote(r).unwrap_or_else(|| r.clone());
        return apply_binop(op, &nl, &nr);
    }
    match (op, l, r) {
        (BinOp::Add, Int(a), Int(b)) => Ok(Int(a.wrapping_add(*b))),
        (BinOp::Sub, Int(a), Int(b)) => Ok(Int(a.wrapping_sub(*b))),
        // Kotlin Char arithmetic: `Char - Char` → Int (code-point
        // distance); `Char + Int` / `Char - Int` → Char.
        (BinOp::Sub, Value::Char(a), Value::Char(b)) => {
            Ok(Int(*a as i32 - *b as i32))
        }
        (BinOp::Add, Value::Char(a), Int(b)) => {
            let cp = (*a as i64).wrapping_add(*b as i64);
            Ok(Value::Char(char::from_u32(cp as u32).unwrap_or('\u{0}')))
        }
        (BinOp::Sub, Value::Char(a), Int(b)) => {
            let cp = (*a as i64).wrapping_sub(*b as i64);
            Ok(Value::Char(char::from_u32(cp as u32).unwrap_or('\u{0}')))
        }
        (BinOp::Add, Value::Char(a), Long(b)) => {
            let cp = (*a as i64).wrapping_add(*b);
            Ok(Value::Char(char::from_u32(cp as u32).unwrap_or('\u{0}')))
        }
        (BinOp::Sub, Value::Char(a), Long(b)) => {
            let cp = (*a as i64).wrapping_sub(*b);
            Ok(Value::Char(char::from_u32(cp as u32).unwrap_or('\u{0}')))
        }
        (BinOp::Mul, Int(a), Int(b)) => Ok(Int(a.wrapping_mul(*b))),
        // (Int Div/Mod handled below, after Long, with ArithmeticException throw.)
        (BinOp::Add, Long(a), Long(b)) => Ok(Long(a.wrapping_add(*b))),
        (BinOp::Sub, Long(a), Long(b)) => Ok(Long(a.wrapping_sub(*b))),
        (BinOp::Mul, Long(a), Long(b)) => Ok(Long(a.wrapping_mul(*b))),
        (BinOp::Div, Long(a), Long(b)) => {
            if *b == 0 { return Err(arith_exc("/ by zero")); }
            Ok(Long(a.wrapping_div(*b)))
        }
        (BinOp::Mod, Long(a), Long(b)) => {
            if *b == 0 { return Err(arith_exc("/ by zero")); }
            Ok(Long(a.wrapping_rem(*b)))
        }
        (BinOp::Div, Int(a), Int(b)) => {
            if *b == 0 { return Err(arith_exc("/ by zero")); }
            Ok(Int(a.wrapping_div(*b)))
        }
        (BinOp::Mod, Int(a), Int(b)) => {
            if *b == 0 { return Err(arith_exc("/ by zero")); }
            Ok(Int(a.wrapping_rem(*b)))
        }
        // Mixed Int/Long arithmetic — widen the Int operand to Long
        // and apply Long arithmetic. Matches Kotlin's numeric tower.
        (BinOp::Add, Long(a), Int(b)) => Ok(Long(a.wrapping_add(*b as i64))),
        (BinOp::Add, Int(a), Long(b)) => Ok(Long((*a as i64).wrapping_add(*b))),
        (BinOp::Sub, Long(a), Int(b)) => Ok(Long(a.wrapping_sub(*b as i64))),
        (BinOp::Sub, Int(a), Long(b)) => Ok(Long((*a as i64).wrapping_sub(*b))),
        (BinOp::Mul, Long(a), Int(b)) => Ok(Long(a.wrapping_mul(*b as i64))),
        (BinOp::Mul, Int(a), Long(b)) => Ok(Long((*a as i64).wrapping_mul(*b))),
        (BinOp::Div, Long(a), Int(b)) => Ok(Long(a.wrapping_div(*b as i64))),
        (BinOp::Div, Int(a), Long(b)) => Ok(Long((*a as i64).wrapping_div(*b))),
        (BinOp::Mod, Long(a), Int(b)) => Ok(Long(a.wrapping_rem(*b as i64))),
        (BinOp::Mod, Int(a), Long(b)) => Ok(Long((*a as i64).wrapping_rem(*b))),
        // Mixed Int/Double + Long/Double + Int/Long comparison.
        (BinOp::Add, Double(a), Int(b)) => Ok(Double(a + (*b as f64))),
        (BinOp::Add, Int(a), Double(b)) => Ok(Double((*a as f64) + b)),
        (BinOp::Sub, Double(a), Int(b)) => Ok(Double(a - (*b as f64))),
        (BinOp::Sub, Int(a), Double(b)) => Ok(Double((*a as f64) - b)),
        (BinOp::Mul, Double(a), Int(b)) => Ok(Double(a * (*b as f64))),
        (BinOp::Mul, Int(a), Double(b)) => Ok(Double((*a as f64) * b)),
        (BinOp::Div, Double(a), Int(b)) => Ok(Double(a / (*b as f64))),
        (BinOp::Div, Int(a), Double(b)) => Ok(Double((*a as f64) / b)),
        (BinOp::Add, Double(a), Long(b)) => Ok(Double(a + (*b as f64))),
        (BinOp::Add, Long(a), Double(b)) => Ok(Double((*a as f64) + b)),
        (BinOp::Sub, Double(a), Long(b)) => Ok(Double(a - (*b as f64))),
        (BinOp::Sub, Long(a), Double(b)) => Ok(Double((*a as f64) - b)),
        (BinOp::Mul, Double(a), Long(b)) => Ok(Double(a * (*b as f64))),
        (BinOp::Mul, Long(a), Double(b)) => Ok(Double((*a as f64) * b)),
        (BinOp::Div, Double(a), Long(b)) => Ok(Double(a / (*b as f64))),
        (BinOp::Div, Long(a), Double(b)) => Ok(Double((*a as f64) / b)),
        (BinOp::Mod, Double(a), Long(b)) => Ok(Double(a % (*b as f64))),
        (BinOp::Mod, Long(a), Double(b)) => Ok(Double((*a as f64) % b)),
        // Unsigned integer arithmetic.
        (BinOp::Add, Value::UInt(a), Value::UInt(b)) => Ok(Value::UInt(a.wrapping_add(*b))),
        (BinOp::Sub, Value::UInt(a), Value::UInt(b)) => Ok(Value::UInt(a.wrapping_sub(*b))),
        (BinOp::Mul, Value::UInt(a), Value::UInt(b)) => Ok(Value::UInt(a.wrapping_mul(*b))),
        (BinOp::Div, Value::UInt(a), Value::UInt(b)) => {
            if *b == 0 { return Err(arith_exc("/ by zero")); }
            Ok(Value::UInt(a / b))
        }
        (BinOp::Mod, Value::UInt(a), Value::UInt(b)) => {
            if *b == 0 { return Err(arith_exc("/ by zero")); }
            Ok(Value::UInt(a % b))
        }
        (BinOp::Add, Value::ULong(a), Value::ULong(b)) => Ok(Value::ULong(a.wrapping_add(*b))),
        (BinOp::Sub, Value::ULong(a), Value::ULong(b)) => Ok(Value::ULong(a.wrapping_sub(*b))),
        (BinOp::Mul, Value::ULong(a), Value::ULong(b)) => Ok(Value::ULong(a.wrapping_mul(*b))),
        (BinOp::Div, Value::ULong(a), Value::ULong(b)) => {
            if *b == 0 { return Err(arith_exc("/ by zero")); }
            Ok(Value::ULong(a / b))
        }
        (BinOp::Mod, Value::ULong(a), Value::ULong(b)) => {
            if *b == 0 { return Err(arith_exc("/ by zero")); }
            Ok(Value::ULong(a % b))
        }
        // Mixed unsigned widening.
        (BinOp::Add, Value::ULong(a), Value::UInt(b)) => Ok(Value::ULong(a.wrapping_add(*b as u64))),
        (BinOp::Add, Value::UInt(a), Value::ULong(b)) => Ok(Value::ULong((*a as u64).wrapping_add(*b))),
        (BinOp::Mul, Value::ULong(a), Value::UInt(b)) => Ok(Value::ULong(a.wrapping_mul(*b as u64))),
        (BinOp::Mul, Value::UInt(a), Value::ULong(b)) => Ok(Value::ULong((*a as u64).wrapping_mul(*b))),
        (BinOp::Sub, Value::ULong(a), Value::UInt(b)) => Ok(Value::ULong(a.wrapping_sub(*b as u64))),
        (BinOp::Sub, Value::UInt(a), Value::ULong(b)) => Ok(Value::ULong((*a as u64).wrapping_sub(*b))),
        // Float arithmetic + mixed Float/Double promotion.
        (BinOp::Add, Value::Float(a), Value::Float(b)) => Ok(Value::Float(a + b)),
        (BinOp::Sub, Value::Float(a), Value::Float(b)) => Ok(Value::Float(a - b)),
        (BinOp::Mul, Value::Float(a), Value::Float(b)) => Ok(Value::Float(a * b)),
        (BinOp::Div, Value::Float(a), Value::Float(b)) => Ok(Value::Float(a / b)),
        (BinOp::Add, Value::Float(a), Double(b)) => Ok(Double(*a as f64 + b)),
        (BinOp::Add, Double(a), Value::Float(b)) => Ok(Double(a + *b as f64)),
        (BinOp::Sub, Value::Float(a), Double(b)) => Ok(Double(*a as f64 - b)),
        (BinOp::Sub, Double(a), Value::Float(b)) => Ok(Double(a - *b as f64)),
        (BinOp::Mul, Value::Float(a), Double(b)) => Ok(Double(*a as f64 * b)),
        (BinOp::Mul, Double(a), Value::Float(b)) => Ok(Double(a * *b as f64)),
        (BinOp::Div, Value::Float(a), Double(b)) => Ok(Double(*a as f64 / b)),
        (BinOp::Div, Double(a), Value::Float(b)) => Ok(Double(a / *b as f64)),
        (BinOp::Add, Int(a), Value::Float(b)) => Ok(Value::Float(*a as f32 + b)),
        (BinOp::Add, Value::Float(a), Int(b)) => Ok(Value::Float(a + *b as f32)),
        (BinOp::Sub, Int(a), Value::Float(b)) => Ok(Value::Float(*a as f32 - b)),
        (BinOp::Sub, Value::Float(a), Int(b)) => Ok(Value::Float(a - *b as f32)),
        (BinOp::Mul, Int(a), Value::Float(b)) => Ok(Value::Float(*a as f32 * b)),
        (BinOp::Mul, Value::Float(a), Int(b)) => Ok(Value::Float(a * *b as f32)),
        (BinOp::Div, Int(a), Value::Float(b)) => Ok(Value::Float(*a as f32 / b)),
        (BinOp::Div, Value::Float(a), Int(b)) => Ok(Value::Float(a / *b as f32)),
        (BinOp::Add, Long(a), Value::Float(b)) => Ok(Value::Float(*a as f32 + b)),
        (BinOp::Add, Value::Float(a), Long(b)) => Ok(Value::Float(a + *b as f32)),
        (BinOp::Sub, Long(a), Value::Float(b)) => Ok(Value::Float(*a as f32 - b)),
        (BinOp::Sub, Value::Float(a), Long(b)) => Ok(Value::Float(a - *b as f32)),
        (BinOp::Mul, Long(a), Value::Float(b)) => Ok(Value::Float(*a as f32 * b)),
        (BinOp::Mul, Value::Float(a), Long(b)) => Ok(Value::Float(a * *b as f32)),
        (BinOp::Div, Long(a), Value::Float(b)) => Ok(Value::Float(*a as f32 / b)),
        (BinOp::Div, Value::Float(a), Long(b)) => Ok(Value::Float(a / *b as f32)),
        (BinOp::Add, Double(a), Double(b)) => Ok(Double(a + b)),
        (BinOp::Sub, Double(a), Double(b)) => Ok(Double(a - b)),
        (BinOp::Mul, Double(a), Double(b)) => Ok(Double(a * b)),
        (BinOp::Div, Double(a), Double(b)) => Ok(Double(a / b)),
        (BinOp::Eq, a, b) => Ok(Bool(Value::structural_eq(a, b))),
        (BinOp::NotEq, a, b) => Ok(Bool(!Value::structural_eq(a, b))),
        (BinOp::BoxedEq, a, b) => Ok(Bool(Value::structural_eq_boxed(a, b))),
        (BinOp::BoxedNotEq, a, b) => Ok(Bool(!Value::structural_eq_boxed(a, b))),
        (BinOp::Less, Int(a), Int(b)) => Ok(Bool(a < b)),
        (BinOp::LessEq, Int(a), Int(b)) => Ok(Bool(a <= b)),
        (BinOp::Greater, Int(a), Int(b)) => Ok(Bool(a > b)),
        (BinOp::GreaterEq, Int(a), Int(b)) => Ok(Bool(a >= b)),
        (BinOp::Less, Long(a), Long(b)) => Ok(Bool(a < b)),
        (BinOp::LessEq, Long(a), Long(b)) => Ok(Bool(a <= b)),
        (BinOp::Greater, Long(a), Long(b)) => Ok(Bool(a > b)),
        (BinOp::GreaterEq, Long(a), Long(b)) => Ok(Bool(a >= b)),
        (BinOp::Less, Double(a), Double(b)) => Ok(Bool(a < b)),
        (BinOp::LessEq, Double(a), Double(b)) => Ok(Bool(a <= b)),
        (BinOp::Greater, Double(a), Double(b)) => Ok(Bool(a > b)),
        (BinOp::GreaterEq, Double(a), Double(b)) => Ok(Bool(a >= b)),
        (BinOp::Less, Value::Char(a), Value::Char(b)) => Ok(Bool(a < b)),
        (BinOp::LessEq, Value::Char(a), Value::Char(b)) => Ok(Bool(a <= b)),
        (BinOp::Greater, Value::Char(a), Value::Char(b)) => Ok(Bool(a > b)),
        (BinOp::GreaterEq, Value::Char(a), Value::Char(b)) => Ok(Bool(a >= b)),
        // Mixed-type comparisons widen to the larger of the two.
        (BinOp::Less, Int(a), Long(b)) => Ok(Bool((*a as i64) < *b)),
        (BinOp::Less, Long(a), Int(b)) => Ok(Bool(*a < *b as i64)),
        (BinOp::LessEq, Int(a), Long(b)) => Ok(Bool((*a as i64) <= *b)),
        (BinOp::LessEq, Long(a), Int(b)) => Ok(Bool(*a <= *b as i64)),
        (BinOp::Greater, Int(a), Long(b)) => Ok(Bool((*a as i64) > *b)),
        (BinOp::Greater, Long(a), Int(b)) => Ok(Bool(*a > *b as i64)),
        (BinOp::GreaterEq, Int(a), Long(b)) => Ok(Bool((*a as i64) >= *b)),
        (BinOp::GreaterEq, Long(a), Int(b)) => Ok(Bool(*a >= *b as i64)),
        (BinOp::Less, Int(a), Double(b)) => Ok(Bool((*a as f64) < *b)),
        (BinOp::Less, Double(a), Int(b)) => Ok(Bool(*a < *b as f64)),
        (BinOp::Less, Long(a), Double(b)) => Ok(Bool((*a as f64) < *b)),
        (BinOp::Less, Double(a), Long(b)) => Ok(Bool(*a < *b as f64)),
        (BinOp::LessEq, Int(a), Double(b)) => Ok(Bool((*a as f64) <= *b)),
        (BinOp::LessEq, Double(a), Int(b)) => Ok(Bool(*a <= *b as f64)),
        (BinOp::LessEq, Long(a), Double(b)) => Ok(Bool((*a as f64) <= *b)),
        (BinOp::LessEq, Double(a), Long(b)) => Ok(Bool(*a <= *b as f64)),
        (BinOp::Greater, Int(a), Double(b)) => Ok(Bool((*a as f64) > *b)),
        (BinOp::Greater, Double(a), Int(b)) => Ok(Bool(*a > *b as f64)),
        (BinOp::Greater, Long(a), Double(b)) => Ok(Bool((*a as f64) > *b)),
        (BinOp::Greater, Double(a), Long(b)) => Ok(Bool(*a > *b as f64)),
        (BinOp::GreaterEq, Int(a), Double(b)) => Ok(Bool((*a as f64) >= *b)),
        (BinOp::GreaterEq, Double(a), Int(b)) => Ok(Bool(*a >= *b as f64)),
        (BinOp::GreaterEq, Long(a), Double(b)) => Ok(Bool((*a as f64) >= *b)),
        (BinOp::GreaterEq, Double(a), Long(b)) => Ok(Bool(*a >= *b as f64)),
        (BinOp::Less, Value::String(a), Value::String(b)) => {
            Ok(Bool(utf16_cmp(a, b) == std::cmp::Ordering::Less))
        }
        (BinOp::LessEq, Value::String(a), Value::String(b)) => {
            Ok(Bool(utf16_cmp(a, b) != std::cmp::Ordering::Greater))
        }
        (BinOp::Greater, Value::String(a), Value::String(b)) => {
            Ok(Bool(utf16_cmp(a, b) == std::cmp::Ordering::Greater))
        }
        (BinOp::GreaterEq, Value::String(a), Value::String(b)) => {
            Ok(Bool(utf16_cmp(a, b) != std::cmp::Ordering::Less))
        }
        (BinOp::And, Bool(a), Bool(b)) => Ok(Bool(*a && *b)),
        (BinOp::Or, Bool(a), Bool(b)) => Ok(Bool(*a || *b)),
        (BinOp::RangeTo, Int(a), Int(b)) => Ok(Value::Range {
            start: *a as i64,
            end: *b as i64,
            step: 1,
            kind: klio_runtime::RangeKind::Int,
        }),
        (BinOp::RangeUntil, Int(a), Int(b)) => Ok(Value::Range {
            start: *a as i64,
            end: (*b as i64) - 1,
            step: 1,
            kind: klio_runtime::RangeKind::Int,
        }),
        (BinOp::RangeTo, Value::Char(a), Value::Char(b)) => Ok(Value::Range {
            start: *a as i64,
            end: *b as i64,
            step: 1,
            kind: klio_runtime::RangeKind::Char,
        }),
        (BinOp::RangeUntil, Value::Char(a), Value::Char(b)) => Ok(Value::Range {
            start: *a as i64,
            end: (*b as i64) - 1,
            step: 1,
            kind: klio_runtime::RangeKind::Char,
        }),
        (BinOp::RangeTo, Long(a), Long(b)) => Ok(Value::Range {
            start: *a, end: *b, step: 1, kind: klio_runtime::RangeKind::Long,
        }),
        (BinOp::StringConcat, a, b) => {
            let mut s = render_value(a);
            s.push_str(&render_value(b));
            Ok(Value::String(std::sync::Arc::new(s)))
        }
        (BinOp::Add, Value::String(a), b) => {
            let mut s = a.as_str().to_string();
            s.push_str(&render_value(b));
            Ok(Value::String(std::sync::Arc::new(s)))
        }
        (BinOp::Add, a, Value::String(b)) => {
            let mut s = render_value(a);
            s.push_str(b.as_str());
            Ok(Value::String(std::sync::Arc::new(s)))
        }
        _ => Err(EvalError::Type(format!(
            "BinOp::{op:?} on {l:?} and {r:?}"
        ))),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::build::FuncBuilder;
    use crate::{Const, Inst, TypeRef};

    fn lit(b: &mut FuncBuilder<'_>, v: i32) -> Reg {
        b.emit_const(Const::Int(v))
    }

    #[test]
    fn eval_int_const() {
        let mut m = Module::default();
        let mut b = FuncBuilder::new(&mut m);
        let r = lit(&mut b, 7);
        b.terminate(Terminator::Return(Some(r)));
        let func = b.finish("f", "test.f", TypeRef::int());
        let v = eval(&m, &func, Vec::new()).unwrap();
        assert!(matches!(v, Value::Int(7)));
    }

    #[test]
    fn eval_int_add() {
        let mut m = Module::default();
        let mut b = FuncBuilder::new(&mut m);
        let l = lit(&mut b, 2);
        let r = lit(&mut b, 40);
        let dst = b.alloc_reg();
        b.push(Inst::BinOp { dst, op: BinOp::Add, lhs: l, rhs: r });
        b.terminate(Terminator::Return(Some(dst)));
        let func = b.finish("f", "test.f", TypeRef::int());
        let v = eval(&m, &func, Vec::new()).unwrap();
        assert!(matches!(v, Value::Int(42)));
    }

    #[test]
    fn eval_load_param() {
        let mut m = Module::default();
        let mut b = FuncBuilder::new(&mut m);
        let p = b.alloc_reg();
        b.push(Inst::LoadParam { dst: p, idx: 0 });
        b.terminate(Terminator::Return(Some(p)));
        let func = b.finish("f", "test.f", TypeRef::int());
        let v = eval(&m, &func, vec![Value::Int(99)]).unwrap();
        assert!(matches!(v, Value::Int(99)));
    }

    #[test]
    fn eval_branch() {
        let mut m = Module::default();
        let mut b = FuncBuilder::new(&mut m);
        let cond = b.emit_const(Const::Bool(true));
        let t_blk = b.alloc_block();
        let f_blk = b.alloc_block();
        b.terminate(Terminator::Branch { cond, t: t_blk, f: f_blk });

        b.switch_to(t_blk);
        let t_val = lit(&mut b, 1);
        b.terminate(Terminator::Return(Some(t_val)));

        b.switch_to(f_blk);
        let f_val = lit(&mut b, 0);
        b.terminate(Terminator::Return(Some(f_val)));

        let func = b.finish("f", "test.f", TypeRef::int());
        let v = eval(&m, &func, Vec::new()).unwrap();
        assert!(matches!(v, Value::Int(1)));
    }
}

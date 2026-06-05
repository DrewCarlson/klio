use super::{EvalError, FuncId, Module, TypeRef, Value, eval};

/// Pluggable callbacks the evaluator delegates non-trivial dispatch
/// through. The IR is intentionally agnostic about how user
/// classes and top-level functions are resolved; a real frontend
/// supplies a host implementation that ties into the interpreter's
/// class table / dispatch machinery. A default no-op `NullHost`
/// exists for unit tests.
pub trait Host {
    /// Resolve a `CallValue` invocation against a runtime value.
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
    /// Resolve a `CallMember` invocation against the receiver.
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
    /// implementation looks up the corresponding `ClassDef` and
    /// invokes the primary constructor with the supplied args.
    fn new_instance(
        &mut self,
        _class: crate::ClassId,
        _args: &[Value],
    ) -> Result<Value, EvalError> {
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
    fn get_field(&mut self, receiver: &Value, name: &str) -> Result<Value, EvalError> {
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
    fn set_field(&mut self, receiver: &Value, name: &str, value: Value) -> Result<(), EvalError> {
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

    /// True when `name` denotes a concrete type a checked cast can test
    /// against — a user class, a builtin, or a reified type-param bound
    /// to a concrete class at the call site. A name that resolves to no
    /// concrete type is an *erased* type parameter (`TBuilder`,
    /// `TConfig`, …): `x as <that>` is an unchecked cast that never
    /// throws on the JVM. The default conservatively reports every name
    /// as concrete (preserving the throwing behaviour); the interpreter
    /// host overrides this with the real class/global/builtin tables.
    fn is_concrete_cast_target(&mut self, _name: &str) -> bool {
        true
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
    /// … }` AST node. Hosts build a fresh `ClassDef` from the AST's
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
    /// of register values. `body_func` is a `FuncId` in the active
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
    fn qualified_this(&mut self, _receiver: &Value, _qualifier: &str) -> Result<Value, EvalError> {
        Err(EvalError::Unsupported("Host::qualified_this"))
    }

    /// Read a captured variable's current value out of a
    /// `Value::Lambda`'s env. Used after closure-mutating calls
    /// to sync writes back into the caller's regs.
    fn read_lambda_capture(&mut self, _lambda: &Value, _name: &str) -> Result<Value, EvalError> {
        Err(EvalError::Unsupported("Host::read_lambda_capture"))
    }

    /// Resolve `receiver::name` to a callable reference value.
    /// Concrete hosts dispatch through the receiver's class table
    /// to produce a `BoundMethod` / intrinsic / property-ref shape.
    fn member_ref(&mut self, _receiver: &Value, _name: &str) -> Result<Value, EvalError> {
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
    /// dispatch (`call_lambda` etc.) can consume directly.
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

    /// Variant that also receives the lambda body's lowered `FuncId`
    /// when available. The default ignores it; klio's interp host
    /// registers the `FuncId` under the lambda's body pointer so
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

    /// Resolve a function call by `FuncId`. The default routes
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
        _exact: bool,
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

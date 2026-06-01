use crate::*;

impl<'a> klio_ir::eval::Host for VmHost<'a> {
    fn enclosing_this(&self) -> Option<klio_runtime::Value> {
        Self::enclosing_this(self)
    }

    fn enclosing_this_chain(&self) -> Vec<klio_runtime::Value> {
        Self::enclosing_this_chain(self)
    }

    fn callable_receiver_shape(
        &self,
        v: &klio_runtime::Value,
    ) -> Option<(usize, bool)> {
        Self::callable_receiver_shape(self, v)
    }

    /// True when the closure captures a `this` slot whose current
    /// value isn't a usable Instance — used by CallValue to decide
    /// whether to override the slot with the calling frame's `this`
    /// for a receiver-typed lambda invoked bare (`body()` rather
    /// than `this.body()`).
    fn closure_needs_this_capture(
        &self,
        v: &klio_runtime::Value,
    ) -> bool {
        Self::closure_needs_this_capture(self, v)
    }

    fn override_closure_this(
        &mut self,
        v: &klio_runtime::Value,
        new_this: &klio_runtime::Value,
    ) {
        Self::override_closure_this(self, v, new_this)
    }

    fn call_member_only(
        &mut self,
        receiver: &klio_runtime::Value,
        name: &str,
        args: &[klio_runtime::Value],
        arg_names: &[Option<String>],
    ) -> Result<klio_runtime::Value, klio_ir::eval::EvalError> {
        Self::call_member_only(self, receiver, name, args, arg_names)
    }

    fn is_shadowing_capture(&self, name: &str) -> bool {
        Self::is_shadowing_capture(self, name)
    }

    fn push_inner_outer_hint(&mut self, v: &klio_runtime::Value) {
        Self::push_inner_outer_hint(self, v)
    }

    fn pop_inner_outer_hint(&mut self) {
        Self::pop_inner_outer_hint(self)
    }

    fn push_access_enclosing(&self, v: &klio_runtime::Value) {
        Self::push_access_enclosing(self, v)
    }

    fn pop_access_enclosing(&self) {
        Self::pop_access_enclosing(self)
    }

    fn lookup_global(&mut self, name: &str) -> Option<klio_runtime::Value> {
        Self::lookup_global(self, name)
    }

    fn store_global(
        &mut self,
        name: &str,
        value: klio_runtime::Value,
    ) -> Result<(), klio_ir::eval::EvalError> {
        Self::store_global(self, name, value)
    }

    fn lookup_global_throwing(
        &mut self,
        name: &str,
    ) -> Result<Option<klio_runtime::Value>, klio_ir::eval::EvalError> {
        Self::lookup_global_throwing(self, name)
    }

    fn call_value(
        &mut self,
        callee: &klio_runtime::Value,
        args: &[klio_runtime::Value],
    ) -> Result<klio_runtime::Value, klio_ir::eval::EvalError> {
        Self::call_value(self, callee, args)
    }

    fn call_value_named(
        &mut self,
        callee: &klio_runtime::Value,
        args: &[klio_runtime::Value],
        _arg_names: &[Option<String>],
    ) -> Result<klio_runtime::Value, klio_ir::eval::EvalError> {
        Self::call_value_named(self, callee, args, _arg_names)
    }

    fn call_value_with_this(
        &mut self,
        callee: &klio_runtime::Value,
        this_value: &klio_runtime::Value,
        args: &[klio_runtime::Value],
        _arg_names: &[Option<String>],
    ) -> Result<klio_runtime::Value, klio_ir::eval::EvalError> {
        Self::call_value_with_this(self, callee, this_value, args, _arg_names)
    }

    fn get_field(
        &mut self,
        receiver: &klio_runtime::Value,
        name: &str,
    ) -> Result<klio_runtime::Value, klio_ir::eval::EvalError> {
        Self::get_field(self, receiver, name)
    }

    fn set_field(
        &mut self,
        receiver: &klio_runtime::Value,
        name: &str,
        value: klio_runtime::Value,
    ) -> Result<(), klio_ir::eval::EvalError> {
        Self::set_field(self, receiver, name, value)
    }

    fn member_ref(
        &mut self,
        receiver: &klio_runtime::Value,
        name: &str,
    ) -> Result<klio_runtime::Value, klio_ir::eval::EvalError> {
        Self::member_ref(self, receiver, name)
    }

    fn register_class(
        &mut self,
        class: &klio_ast::Class,
    ) -> Result<(), klio_ir::eval::EvalError> {
        Self::register_class(self, class)
    }

    fn register_class_captured(
        &mut self,
        class: &klio_ast::Class,
        captured_names: &[String],
        captures: Vec<klio_runtime::Value>,
    ) -> Result<(), klio_ir::eval::EvalError> {
        Self::register_class_captured(self, class, captured_names, captures)
    }

    fn build_object(
        &mut self,
        ast: &klio_ast::Expr,
        captured_names: &[String],
        captures: Vec<klio_runtime::Value>,
    ) -> Result<klio_runtime::Value, klio_ir::eval::EvalError> {
        Self::build_object(self, ast, captured_names, captures)
    }

    fn call_super(
        &mut self,
        receiver: &klio_runtime::Value,
        owner_class: &str,
        qualifier: Option<&str>,
        name: &str,
        args: &[klio_runtime::Value],
        _arg_names: &[Option<String>],
    ) -> Result<klio_runtime::Value, klio_ir::eval::EvalError> {
        Self::call_super(self, receiver, owner_class, qualifier, name, args, _arg_names)
    }

    fn qualified_this(
        &mut self,
        receiver: &klio_runtime::Value,
        qualifier: &str,
    ) -> Result<klio_runtime::Value, klio_ir::eval::EvalError> {
        Self::qualified_this(self, receiver, qualifier)
    }

    fn instance_of(
        &mut self,
        value: &klio_runtime::Value,
        ty: &klio_ir::TypeRef,
    ) -> bool {
        Self::instance_of(self, value, ty)
    }

    fn call_func(
        &mut self,
        module: &klio_ir::Module,
        func: klio_ir::FuncId,
        args: Vec<klio_runtime::Value>,
    ) -> Result<klio_runtime::Value, klio_ir::eval::EvalError> {
        Self::call_func(self, module, func, args)
    }

    fn call_func_named(
        &mut self,
        module: &klio_ir::Module,
        func: klio_ir::FuncId,
        args: Vec<klio_runtime::Value>,
        arg_names: &[Option<String>],
    ) -> Result<klio_runtime::Value, klio_ir::eval::EvalError> {
        Self::call_func_named(self, module, func, args, arg_names)
    }

    fn call_func_typed(
        &mut self,
        module: &klio_ir::Module,
        func: klio_ir::FuncId,
        args: Vec<klio_runtime::Value>,
        arg_names: &[Option<String>],
        type_args: &[String],
    ) -> Result<klio_runtime::Value, klio_ir::eval::EvalError> {
        Self::call_func_typed(self, module, func, args, arg_names, type_args)
    }

    fn call_named_overload(
        &mut self,
        module: &klio_ir::Module,
        name: &str,
        args: &[klio_runtime::Value],
        arg_names: &[Option<String>],
    ) -> Result<Option<klio_runtime::Value>, klio_ir::eval::EvalError> {
        Self::call_named_overload(self, module, name, args, arg_names)
    }

    fn build_ast_lambda_with_flag_funcid(
        &mut self,
        params: &[String],
        _body: &klio_ast::Block,
        captured_names: &[String],
        captures: Vec<klio_runtime::Value>,
        _absorb_return: bool,
        body_func: Option<klio_ir::FuncId>,
    ) -> Result<klio_runtime::Value, klio_ir::eval::EvalError> {
        Self::build_ast_lambda_with_flag_funcid(self, params, _body, captured_names, captures, _absorb_return, body_func)
    }

    fn read_lambda_capture(
        &mut self,
        lambda: &klio_runtime::Value,
        name: &str,
    ) -> Result<klio_runtime::Value, klio_ir::eval::EvalError> {
        Self::read_lambda_capture(self, lambda, name)
    }

    fn call_member(
        &mut self,
        receiver: &klio_runtime::Value,
        name: &str,
        args: &[klio_runtime::Value],
    ) -> Result<klio_runtime::Value, klio_ir::eval::EvalError> {
        Self::call_member(self, receiver, name, args)
    }

    fn host_has_member(
        &mut self,
        receiver: &klio_runtime::Value,
        name: &str,
    ) -> bool {
        Self::host_has_member(self, receiver, name)
    }

    fn call_member_named(
        &mut self,
        receiver: &klio_runtime::Value,
        name: &str,
        args: &[klio_runtime::Value],
        arg_names: &[Option<String>],
    ) -> Result<klio_runtime::Value, klio_ir::eval::EvalError> {
        Self::call_member_named(self, receiver, name, args, arg_names)
    }

    fn new_instance_named(
        &mut self,
        class: klio_ir::ClassId,
        args: &[klio_runtime::Value],
        arg_names: &[Option<String>],
    ) -> Result<klio_runtime::Value, klio_ir::eval::EvalError> {
        Self::new_instance_named(self, class, args, arg_names)
    }

    fn new_instance(
        &mut self,
        class: klio_ir::ClassId,
        args: &[klio_runtime::Value],
    ) -> Result<klio_runtime::Value, klio_ir::eval::EvalError> {
        Self::new_instance(self, class, args)
    }
}

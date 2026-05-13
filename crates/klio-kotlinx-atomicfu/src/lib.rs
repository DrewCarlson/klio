//! Native bindings for `kotlinx.atomicfu`.
//!
//! klio runs single-threaded, so the "atomic" operations are
//! trivially atomic: every binding mutates the instance's `value`
//! field directly. The Kotlin shim (under `shim/`) declares the
//! class shapes and exposes the surface area; these bindings shadow
//! the shim method bodies at dispatch time via the
//! `installed_bindings` table on the interpreter.

use klio_runtime::{CallCtx, RuntimeError, StdlibFn, Value};
use klio_stdlib::HostBindings;

#[must_use]
pub fn host_bindings() -> HostBindings {
    let mut b = HostBindings::new();
    let bindings: &[(&'static str, StdlibFn)] = &[
        ("kotlinx.atomicfu.AtomicInt.compareAndSet", atomic_int_cas),
        ("kotlinx.atomicfu.AtomicInt.getAndSet", atomic_int_get_and_set),
        ("kotlinx.atomicfu.AtomicInt.getAndIncrement", atomic_int_get_and_increment),
        ("kotlinx.atomicfu.AtomicInt.getAndDecrement", atomic_int_get_and_decrement),
        ("kotlinx.atomicfu.AtomicInt.incrementAndGet", atomic_int_increment_and_get),
        ("kotlinx.atomicfu.AtomicInt.decrementAndGet", atomic_int_decrement_and_get),
        ("kotlinx.atomicfu.AtomicInt.getAndAdd", atomic_int_get_and_add),
        ("kotlinx.atomicfu.AtomicInt.addAndGet", atomic_int_add_and_get),
        ("kotlinx.atomicfu.AtomicInt.plusAssign", atomic_int_plus_assign),
        ("kotlinx.atomicfu.AtomicInt.minusAssign", atomic_int_minus_assign),
        ("kotlinx.atomicfu.AtomicLong.compareAndSet", atomic_long_cas),
        ("kotlinx.atomicfu.AtomicLong.getAndSet", atomic_long_get_and_set),
        ("kotlinx.atomicfu.AtomicLong.getAndIncrement", atomic_long_get_and_increment),
        ("kotlinx.atomicfu.AtomicLong.getAndDecrement", atomic_long_get_and_decrement),
        ("kotlinx.atomicfu.AtomicLong.incrementAndGet", atomic_long_increment_and_get),
        ("kotlinx.atomicfu.AtomicLong.decrementAndGet", atomic_long_decrement_and_get),
        ("kotlinx.atomicfu.AtomicLong.getAndAdd", atomic_long_get_and_add),
        ("kotlinx.atomicfu.AtomicLong.addAndGet", atomic_long_add_and_get),
        ("kotlinx.atomicfu.AtomicLong.plusAssign", atomic_long_plus_assign),
        ("kotlinx.atomicfu.AtomicLong.minusAssign", atomic_long_minus_assign),
        ("kotlinx.atomicfu.AtomicBoolean.compareAndSet", atomic_bool_cas),
        ("kotlinx.atomicfu.AtomicBoolean.getAndSet", atomic_bool_get_and_set),
        ("kotlinx.atomicfu.AtomicRef.compareAndSet", atomic_ref_cas),
        ("kotlinx.atomicfu.AtomicRef.getAndSet", atomic_ref_get_and_set),
    ];
    for (k, f) in bindings {
        b.register(k, *f);
    }
    b
}

fn receiver_instance<'a>(
    ctx: &'a CallCtx,
) -> Result<&'a std::rc::Rc<std::cell::RefCell<klio_runtime::InstanceData>>, RuntimeError> {
    match ctx.args.first() {
        Some(Value::Instance(inst)) => Ok(inst),
        _ => Err(RuntimeError::Type(
            "kotlinx.atomicfu binding expected an instance receiver".into(),
        )),
    }
}

fn int_field(inst: &std::cell::RefCell<klio_runtime::InstanceData>) -> Result<i64, RuntimeError> {
    match inst.borrow().get("value") {
        Some(Value::Int(i)) => Ok(i as i64),
        Some(Value::Long(l)) => Ok(l),
        _ => Err(RuntimeError::Type(
            "AtomicInt: receiver missing `value: Int`".into(),
        )),
    }
}

fn long_field(inst: &std::cell::RefCell<klio_runtime::InstanceData>) -> Result<i64, RuntimeError> {
    match inst.borrow().get("value") {
        Some(Value::Long(l)) => Ok(l),
        Some(Value::Int(i)) => Ok(i as i64),
        _ => Err(RuntimeError::Type(
            "AtomicLong: receiver missing `value: Long`".into(),
        )),
    }
}

fn bool_field(inst: &std::cell::RefCell<klio_runtime::InstanceData>) -> Result<bool, RuntimeError> {
    match inst.borrow().get("value") {
        Some(Value::Bool(b)) => Ok(b),
        _ => Err(RuntimeError::Type(
            "AtomicBoolean: receiver missing `value: Boolean`".into(),
        )),
    }
}

fn arg_int(ctx: &CallCtx, idx: usize) -> Result<i64, RuntimeError> {
    match ctx.args.get(idx) {
        Some(Value::Int(i)) => Ok(*i as i64),
        Some(Value::Long(l)) => Ok(*l),
        _ => Err(RuntimeError::Type(format!(
            "kotlinx.atomicfu: argument {idx} must be Int/Long"
        ))),
    }
}

fn arg_bool(ctx: &CallCtx, idx: usize) -> Result<bool, RuntimeError> {
    match ctx.args.get(idx) {
        Some(Value::Bool(b)) => Ok(*b),
        _ => Err(RuntimeError::Type(format!(
            "kotlinx.atomicfu: argument {idx} must be Boolean"
        ))),
    }
}

fn store_int(inst: &std::cell::RefCell<klio_runtime::InstanceData>, v: i64) {
    inst.borrow_mut().define("value", Value::new_int(v));
}

fn store_long(inst: &std::cell::RefCell<klio_runtime::InstanceData>, v: i64) {
    inst.borrow_mut().define("value", Value::Long(v));
}

fn store_bool(inst: &std::cell::RefCell<klio_runtime::InstanceData>, v: bool) {
    inst.borrow_mut().define("value", Value::Bool(v));
}

// ---------- AtomicInt ----------

fn atomic_int_cas(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let inst = receiver_instance(ctx)?;
    let cur = int_field(inst)?;
    let expected = arg_int(ctx, 1)?;
    let update = arg_int(ctx, 2)?;
    if cur == expected {
        store_int(inst, update);
        Ok(Value::Bool(true))
    } else {
        Ok(Value::Bool(false))
    }
}

fn atomic_int_get_and_set(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let inst = receiver_instance(ctx)?;
    let prev = int_field(inst)?;
    let next = arg_int(ctx, 1)?;
    store_int(inst, next);
    Ok(Value::new_int(prev))
}

fn atomic_int_get_and_increment(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let inst = receiver_instance(ctx)?;
    let prev = int_field(inst)?;
    store_int(inst, prev.wrapping_add(1));
    Ok(Value::new_int(prev))
}

fn atomic_int_get_and_decrement(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let inst = receiver_instance(ctx)?;
    let prev = int_field(inst)?;
    store_int(inst, prev.wrapping_sub(1));
    Ok(Value::new_int(prev))
}

fn atomic_int_increment_and_get(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let inst = receiver_instance(ctx)?;
    let next = int_field(inst)?.wrapping_add(1);
    store_int(inst, next);
    Ok(Value::new_int(next))
}

fn atomic_int_decrement_and_get(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let inst = receiver_instance(ctx)?;
    let next = int_field(inst)?.wrapping_sub(1);
    store_int(inst, next);
    Ok(Value::new_int(next))
}

fn atomic_int_get_and_add(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let inst = receiver_instance(ctx)?;
    let prev = int_field(inst)?;
    let delta = arg_int(ctx, 1)?;
    store_int(inst, prev.wrapping_add(delta));
    Ok(Value::new_int(prev))
}

fn atomic_int_add_and_get(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let inst = receiver_instance(ctx)?;
    let delta = arg_int(ctx, 1)?;
    let next = int_field(inst)?.wrapping_add(delta);
    store_int(inst, next);
    Ok(Value::new_int(next))
}

fn atomic_int_plus_assign(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let _ = atomic_int_add_and_get(ctx)?;
    Ok(Value::Unit)
}

fn atomic_int_minus_assign(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let inst = receiver_instance(ctx)?;
    let delta = arg_int(ctx, 1)?;
    let next = int_field(inst)?.wrapping_sub(delta);
    store_int(inst, next);
    Ok(Value::Unit)
}

// ---------- AtomicLong ----------

fn atomic_long_cas(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let inst = receiver_instance(ctx)?;
    let cur = long_field(inst)?;
    let expected = arg_int(ctx, 1)?;
    let update = arg_int(ctx, 2)?;
    if cur == expected {
        store_long(inst, update);
        Ok(Value::Bool(true))
    } else {
        Ok(Value::Bool(false))
    }
}

fn atomic_long_get_and_set(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let inst = receiver_instance(ctx)?;
    let prev = long_field(inst)?;
    store_long(inst, arg_int(ctx, 1)?);
    Ok(Value::Long(prev))
}

fn atomic_long_get_and_increment(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let inst = receiver_instance(ctx)?;
    let prev = long_field(inst)?;
    store_long(inst, prev.wrapping_add(1));
    Ok(Value::Long(prev))
}

fn atomic_long_get_and_decrement(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let inst = receiver_instance(ctx)?;
    let prev = long_field(inst)?;
    store_long(inst, prev.wrapping_sub(1));
    Ok(Value::Long(prev))
}

fn atomic_long_increment_and_get(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let inst = receiver_instance(ctx)?;
    let next = long_field(inst)?.wrapping_add(1);
    store_long(inst, next);
    Ok(Value::Long(next))
}

fn atomic_long_decrement_and_get(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let inst = receiver_instance(ctx)?;
    let next = long_field(inst)?.wrapping_sub(1);
    store_long(inst, next);
    Ok(Value::Long(next))
}

fn atomic_long_get_and_add(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let inst = receiver_instance(ctx)?;
    let prev = long_field(inst)?;
    let delta = arg_int(ctx, 1)?;
    store_long(inst, prev.wrapping_add(delta));
    Ok(Value::Long(prev))
}

fn atomic_long_add_and_get(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let inst = receiver_instance(ctx)?;
    let delta = arg_int(ctx, 1)?;
    let next = long_field(inst)?.wrapping_add(delta);
    store_long(inst, next);
    Ok(Value::Long(next))
}

fn atomic_long_plus_assign(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let _ = atomic_long_add_and_get(ctx)?;
    Ok(Value::Unit)
}

fn atomic_long_minus_assign(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let inst = receiver_instance(ctx)?;
    let delta = arg_int(ctx, 1)?;
    let next = long_field(inst)?.wrapping_sub(delta);
    store_long(inst, next);
    Ok(Value::Unit)
}

// ---------- AtomicBoolean ----------

fn atomic_bool_cas(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let inst = receiver_instance(ctx)?;
    let cur = bool_field(inst)?;
    let expected = arg_bool(ctx, 1)?;
    let update = arg_bool(ctx, 2)?;
    if cur == expected {
        store_bool(inst, update);
        Ok(Value::Bool(true))
    } else {
        Ok(Value::Bool(false))
    }
}

fn atomic_bool_get_and_set(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let inst = receiver_instance(ctx)?;
    let prev = bool_field(inst)?;
    let next = arg_bool(ctx, 1)?;
    store_bool(inst, next);
    Ok(Value::Bool(prev))
}

// ---------- AtomicRef<T> ----------

fn atomic_ref_cas(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let inst = receiver_instance(ctx)?;
    let cur = inst.borrow().get("value").unwrap_or(Value::Null);
    let expected = ctx.args.get(1).cloned().unwrap_or(Value::Null);
    let update = ctx.args.get(2).cloned().unwrap_or(Value::Null);
    if Value::structural_eq(&cur, &expected) {
        inst.borrow_mut().define("value", update);
        Ok(Value::Bool(true))
    } else {
        Ok(Value::Bool(false))
    }
}

fn atomic_ref_get_and_set(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let inst = receiver_instance(ctx)?;
    let prev = inst.borrow().get("value").unwrap_or(Value::Null);
    let next = ctx.args.get(1).cloned().unwrap_or(Value::Null);
    inst.borrow_mut().define("value", next);
    Ok(prev)
}

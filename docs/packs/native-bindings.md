# Native Bindings

A native binding is a Rust function the interpreter calls in place of
a Kotlin body. Bindings are how klio packs reach the host: system
clock, HTTP, atomic memory, filesystem, anything outside what
interpreted Kotlin can express.

## The contract

```rust
use klio_runtime::{CallCtx, RuntimeError, Value};

pub fn my_intrinsic(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    // ctx.args is the positional argument list, including the
    // receiver as args[0] for member calls.
    Ok(Value::Unit)
}
```

`CallCtx::out` is the interpreter's `dyn Output` sink — print
through it instead of `std::println!` so test harnesses can capture
your output.

## Registering bindings

Every kotlinx-style crate exposes a single entry point:

```rust
use klio_stdlib::HostBindings;

#[must_use]
pub fn host_bindings() -> HostBindings {
    let mut b = HostBindings::new();
    b.register("com.example.greetings.now", now);
    b
}

fn now(_ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let t = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_millis() as i64)
        .unwrap_or(0);
    Ok(Value::Long(t))
}
```

The CLI calls every crate's `host_bindings()` and folds them into a
single `HostBindings` registry at startup. The pack's `klio.toml`
references the same `host_symbol` keys, and the loader joins them
at install time.

## Receiver pattern

For methods on a class declared in the pack's Kotlin source, the
receiver is the first argument:

```rust
fn buffer_size(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let Some(Value::Instance(inst)) = ctx.args.first() else {
        return Err(RuntimeError::Type("expected receiver".into()));
    };
    let size = inst.borrow().get("size_field").unwrap_or(Value::Long(0));
    Ok(size)
}
```

## Per-instance native state

`InstanceData::native_state` is an opaque per-instance slot for
host-side data. `kotlinx.io.Buffer` uses it to attach a
`VecDeque<u8>`:

```rust
const KIND: &str = "kotlinx.io.Buffer";

fn with_buffer<R>(
    ctx: &CallCtx,
    f: impl FnOnce(&mut BufferState) -> Result<R, RuntimeError>,
) -> Result<R, RuntimeError> {
    let Some(Value::Instance(inst)) = ctx.args.first() else { /* err */ };
    let cell = inst.borrow_mut().ensure_native_state(KIND, BufferState::default);
    let mut borrow = cell.borrow_mut();
    let state = borrow.downcast_mut::<BufferState>().expect("buffer state");
    f(state)
}
```

The `kind` string guards against two bindings trying to claim the
same instance — a mismatch panics rather than silently corrupts.

## Top-level binding shadowing

When a pack ships a Kotlin top-level function whose FQN
(`<package>.<fn-name>`) matches an installed native binding, the
interpreter binds the simple name to `Value::Intrinsic` instead of
the parsed Kotlin body. This is how shim libraries work:

```kotlin
package kotlinx.datetime
internal fun __kxdt_currentTimeMillis(): Long = 0L  // stub body
```

The Rust binding registered as
`"kotlinx.datetime.__kxdt_currentTimeMillis"` wins at call sites.
The stub body only fires if the binding fails to install — useful as
a fallback when consumers run a pack without its host crate
compiled in.

## Return-value etiquette

- Return `Value::Long` (i64) for `Long`-typed return types.
- Return `Value::new_int(...)` for `Int` (avoids `Value::Long → Int`
  re-typing inside the interpreter).
- For Kotlin `String` use `Value::String(Rc::new(s))`.
- For `Array<...>` build a `Vec<Value>` and wrap it in `Value::Array
  { items: Rc::new(RefCell::new(items)), prim: Some(...) }`.
- To construct a Kotlin instance (a class declared in the pack),
  prefer to do it in Kotlin in the shim and have your binding return
  primitives. Constructing instances directly from Rust requires
  reaching into the interpreter's class table and is brittle.

## ABI versioning

When you change the shape of a binding (signature, expected
argument types, return semantics), bump `klio_pack::SUPPORTED_ABI_VERSION`
and your pack's `klio.toml` `abi`. The loader rejects packs with
abi > supported and points the user at the regenerate-your-pack
remediation.

## Real examples

- `crates/klio-kotlinx-atomicfu/src/lib.rs` — read/write `Atomic*`
  fields directly on the receiver.
- `crates/klio-kotlinx-io/src/lib.rs` — `Buffer` backed by
  `VecDeque<u8>` via `native_state`.
- `crates/klio-kotlinx-datetime/src/lib.rs` — chrono-backed clock,
  tz conversions, RFC-3339 parsing.
- `crates/klio-ktor-client/src/lib.rs` — blocking HTTP via `ureq`,
  returning flat string arrays that the shim rebuilds into
  `HttpResponse`.

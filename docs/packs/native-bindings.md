# Native Bindings

A native binding is a Zig function the interpreter calls in place of
a Kotlin body. Bindings are how klio packs reach the host: system
clock, HTTP, atomic memory, filesystem, anything outside what
interpreted Kotlin can express.

## The contract

```zig
const runtime = @import("runtime");
const CallCtx = runtime.CallCtx;
const EvalResult = runtime.EvalResult;
const Value = runtime.Value;

fn myIntrinsic(ctx: *CallCtx) std.mem.Allocator.Error!EvalResult {
    // ctx.args is the positional argument list, including the
    // receiver as args[0] for member calls.
    _ = ctx;
    return .{ .ok = .Unit };
}
```

A binding is a `StdlibFn`: `*const fn (ctx: *CallCtx)
Allocator.Error!EvalResult`. `EvalResult` is a `union(enum) { ok:
Value, err: RuntimeError }`. The only Zig `error` a binding may
return is allocation failure; a Kotlin-level failure is data carried
in `EvalResult.err`. `ctx.out` is the interpreter's `Output` sink —
print through it instead of writing to stdout directly so test
harnesses can capture your output. `ctx.allocator` is the allocator
to build returned values with.

## Registering bindings

Every kotlinx-style module exposes a single entry point:

```zig
const stdlib = @import("stdlib");
const HostBindings = stdlib.HostBindings;

pub fn hostBindings(allocator: std.mem.Allocator) std.mem.Allocator.Error!HostBindings {
    var b = HostBindings.init(allocator);
    try b.register("com.example.greetings.now", now);
    return b;
}

fn now(ctx: *CallCtx) std.mem.Allocator.Error!EvalResult {
    _ = ctx;
    const ms = std.time.milliTimestamp();
    return .{ .ok = .{ .Long = ms } };
}
```

The CLI calls every module's `hostBindings()` and folds them into a
single `HostBindings` registry at startup (`mergedHostBindings`). The
pack's `klio.toml` references the same `host_symbol` keys, and the
loader joins them at install time.

## Receiver pattern

For methods on a class declared in the pack's Kotlin source, the
receiver is the first argument:

```zig
fn bufferSize(ctx: *CallCtx) std.mem.Allocator.Error!EvalResult {
    if (ctx.args.len == 0 or ctx.args[0] != .Instance) {
        return .{ .err = .{ .Type = "expected receiver" } };
    }
    const inst = ctx.args[0].Instance;
    const g = inst.borrow();
    defer g.deinit();
    const size = g.get().get("size_field") orelse Value{ .Long = 0 };
    return .{ .ok = size };
}
```

## Per-instance native state

`InstanceData.native_state` is an opaque per-instance slot for
host-side data. A binding attaches typed state via
`ensureNativeState` and reads it back through `nativeStatePtr`:

```zig
const KIND = "kotlinx.io.Buffer";

fn bufferState(ctx: *CallCtx, inst: InstanceRef) std.mem.Allocator.Error!*BufferState {
    var g = inst.borrowMut();
    defer g.deinit();
    const cell = try g.get().ensureNativeState(
        ctx.allocator,
        BufferState,
        KIND,
        BufferState.empty,
    );
    return InstanceData.nativeStatePtr(BufferState, cell);
}
```

The `kind` string guards against two bindings trying to claim the
same instance — a mismatch panics rather than silently corrupts.

## Top-level binding shadowing

When a pack ships a Kotlin top-level function whose FQN
(`<package>.<fn-name>`) matches an installed native binding, the
interpreter binds the simple name to the intrinsic instead of
the parsed Kotlin body. This is how shim libraries work:

```kotlin
package kotlinx.datetime
internal fun __kxdt_currentTimeMillis(): Long = 0L  // stub body
```

The Zig binding registered as
`"kotlinx.datetime.__kxdt_currentTimeMillis"` wins at call sites.
The stub body only fires if the binding fails to install — useful as
a fallback when consumers run a pack without its host module
compiled in.

## Return-value etiquette

- Return `Value{ .Long = ... }` (i64) for `Long`-typed return types.
- Return `Value.newInt(...)` for `Int` (avoids `Long → Int`
  re-typing inside the interpreter).
- For Kotlin `String` use `Value{ .String = try
  StringRef.init(ctx.allocator, bytes) }`.
- For `Array<...>` build a `ValueList` of items and wrap it in
  `Value{ .Array = .{ .items = items, .prim = ... } }`.
- To construct a Kotlin instance (a class declared in the pack),
  prefer to do it in Kotlin in the shim and have your binding return
  primitives. Constructing instances directly from Zig requires
  reaching into the interpreter's class table and is brittle.

## ABI versioning

When you change the shape of a binding (signature, expected
argument types, return semantics), bump `pack.SUPPORTED_ABI_VERSION`
and your pack's `klio.toml` `abi`. The loader rejects packs with
abi > supported and points the user at the regenerate-your-pack
remediation.

## Real examples

- `src/kotlinx_atomicfu/kotlinx_atomicfu.zig` — read/write `Atomic*`
  fields directly on the receiver.
- `src/kotlinx_io/kotlinx_io.zig` — `Buffer` backed by a byte
  `std.ArrayList(u8)` via `native_state`.
- `src/kotlinx_datetime/kotlinx_datetime.zig` — clock, tz
  conversions, RFC-3339 parsing.
- `src/ktor_client/ktor_client.zig` — blocking HTTP on the platform
  sockets, returning flat string arrays that the shim rebuilds into
  `HttpResponse`.

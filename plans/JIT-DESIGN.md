# KLIO JIT — tiered native compiler (design)

Goal: close the remaining gap to node-class throughput. The interpreter, after
the CPU-efficiency campaign, sits at interpreter class (~CPython, ~15× node). A
tracing/method JIT that emits native machine code for hot IR is the only path to
node-class performance — no interpreter reaches V8.

## Principle: additive tier, never a rewrite

The JIT is built **on top of** the existing IR interpreter, never replacing it:

- The interpreter remains the sole correct execution engine and the fallback for
  any IR the JIT does not (yet) compile. The build stays green at every step.
- A function is interpreted until it crosses a hotness threshold (call count /
  loop back-edge count). Then the JIT attempts to compile it. On success, future
  entries run native code; on any unsupported IR, the compile bails and the
  function stays interpreted.
- Gated behind `KLIO_JIT` (off by default) until coverage + correctness are
  proven against the full suite + corpus, then flipped on.

## Stages

1. **Foundation (this commit).** `src/jit/jit.zig`: W^X executable memory
   (`mmap` RW → write → `mprotect` RX) + a minimal x86-64 (System V) emitter.
   Unit-tested by emitting and calling a trivial function. No interpreter change.
2. **Encoder breadth.** Registers, `mov`/`add`/`sub`/`imul`/`cmp`/`jcc`/`call`,
   stack frame prologue/epilogue, RIP-relative loads. Table-tested against known
   encodings.
3. **Type-specialized arithmetic loops.** Compile the hottest shape first — an
   integer loop over `BinOp` + a fast-path array subscript — by unboxing `Value`
   to native `i64` under a type **guard**; on guard failure, **deopt** back to
   the interpreter at the IR instruction boundary (reusing the same register
   file / `Frame` so state is consistent). This is where the win is: native
   arithmetic on unboxed scalars instead of 64-byte `Value` churn.
4. **Calls + dispatch.** Compile member/intrinsic calls via a trampoline into the
   existing host dispatch; inline-cache monomorphic receivers.
5. **Coverage growth.** Widen compiled IR opcode set; keep interpreter fallback
   for the long tail (coroutine suspends, exceptions unwinding, reflection).

## Interop contract

JIT'd code shares the interpreter's `Frame` (register array, params). A compiled
function reads/writes the same `regs` slots, so deopt and partial compilation are
seamless: an uncompiled instruction hands control back to `runFrameInner` at that
index with the live register file intact.

## Why this is the only path to the goal

Measured in `bench/memcompare`: CPython (a mature bytecode VM) is itself ~15×
slower than node on the numeric workload. An interpreter cannot reach a JIT;
native code generation with type specialization is required. This document is the
deliberate, multi-session plan to build it incrementally without regressing the
working interpreter.

## Whole-function mode (native recursion)

The loop tier covers hot loops; recursion and call-bound code with no enclosing
loop (e.g. `fib`) stayed in the interpreter, bound by per-instruction dispatch.
Function mode closes that gap: when a function entry is hot, its **whole body**
(entry → `Return`) compiles to native code.

- **Opt-in.** Enabled with `KLIO_FUNC_JIT=1` on top of `KLIO_JIT=1`. It compiles
  whole bodies (including recursion) per thread with no cross-thread eviction
  path — correct and bounded for a normal single-program process, but the
  in-process multi-program test harness would accumulate per-worker compiled
  code, so it is off unless explicitly requested.
- **Trigger.** A per-function entry counter; at the threshold, `tryCompileFunc`
  compiles the body. Coexists with the loop tier — function mode fires at the
  entry block, the loop tier at inner loop headers; whichever applies first wins,
  and either bails to the interpreter on an unsupported shape.
- **Shape.** User-code only (stdlib / kotlinx-pack bodies stay interpreted so the
  tier never alters the runtime machinery cooperative scheduling relies on);
  scalar params/locals/return (exactly `Int`/`Long`/`Double`/`Float`/`Boolean`,
  or `Unit`); terminators `Goto`/`Branch`/`Return`; instructions limited to scalar
  arithmetic, `LoadParam`, and positional top-level calls. `/` and `%` are
  excluded (a divide-by-zero is the only deopt a body could raise, and a frameless
  callee has no frame to resume into).
- **Param/return ABI.** Scalar params are packed into reserved slots at entry
  (specialized on the first hot call's kinds; a later mismatch deopts to the
  interpreter); a `Return` writes the scalar result to a result slot and exits.
- **Native recursion.** A compiled body calling a compiled callee runs the
  callee's body directly through the call trampoline — no interpreter frame, no
  dispatch — bounded by a native-recursion depth limit (beyond it, the
  frame-based path takes over so deep recursion raises a catchable
  `StackOverflowError` instead of faulting the native stack). A callee throw
  propagates out without re-running (no double effects); scalar callees are pure,
  so the rare fallback re-run is observably identical.
- **Result.** `fib(34)` ~6× over the interpreter; identical output JIT off/on.

## Interpreter call fast path

Independent of the JIT: a plain top-level user function (single overload, has
body, non-extension, no varargs/defaults/type-params/native-binding) caches an
eligibility plan on its `Func` and dispatches straight to its body, skipping the
per-call overload re-resolution, extension-receiver handling, reified-type
binding, and redundant argument copies. Positional, exact-arity calls only.

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

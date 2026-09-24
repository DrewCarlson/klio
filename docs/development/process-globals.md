# Process-global state and the multi-program contract

klio's interpreter was built one-program-per-process: the `klio` CLI loads
a program, runs it, and exits. The in-process drivers (the parity itests,
e2e, differential, the commontest censuses) break that assumption — they
run hundreds of programs in ONE process, reusing addresses, arenas and
registries as they go.

Every process-global mutable that outlives a program is therefore a
potential contamination bug: program N+1 reads state program N left
behind. That bug class produced seven distinct roots in one campaign
(shared anon side-module and its clone crossing a boundary,
generation-stamped dispatch caches, the bytecode stream cache, intrinsic
intern keys, the GC remembered set, the expr-body member AST registry).
This page is the audit that followed, and the contract new state must
meet.

## The four defenses

A global that outlives a program must carry ONE of these. They are not
interchangeable — pick by what the state is keyed on.

1. **Boundary reset.** The state is per-program and is cleared when the
   program ends. `interp_ir.resetRunGlobalCaches()` is the single wired
   entry point (the anon-site cache, the static-applicability cache, the
   bytecode stream cache, suspend liveness, the stdlib empty-collection
   singletons), called by every in-process driver.
   Use when: the state is meaningless to the next program.

2. **Generation stamping.** Entries carry a generation counter; a bump
   invalidates every entry at once, including on parked worker threads a
   per-thread clear could never reach. `host_call_member.dispatch_cache_gen`
   with `bumpDispatchCacheGen()` is the reference implementation.
   Use when: the cache is thread-local or too hot to walk, and a stale hit
   would be silently wrong rather than merely stale.

3. **Identity verification on lookup.** The key alone is not trusted; the
   entry re-verifies against content or a name before it is used.
   `image.zig`'s `block_cache` keys on `(section ptr, offset, len, sig)`
   where `sig` fingerprints the bytes — a freed section's ADDRESS gets
   reused by a later pack image, and six installed packs once made
   `"A".repeat` run another pack's one-arg body through a stale
   `(ptr, offset)` hit. `eval.zig`'s `native_table` keys on `FuncId` but
   compares the entry's FQN before dispatching, so a fid reused by a
   different program falls back to interpretation instead of running the
   wrong body.
   Use when: the key is an address or an index that a later program can
   legitimately reuse.

4. **Scoped lifetime.** The global is set for a bounded operation and
   cleared on the way out, e.g. `image.zig`'s
   `bake_forest_map = &forest_map; defer bake_forest_map = null;`.
   Use when: the pointer refers to a caller's storage.

Anything that is genuinely immortal and immutable after load — the
interned intrinsic map (whose keys are duped into permanent storage
precisely so a program's arena cannot own them), the known-package set,
thread-name registries — needs no defense, but the audit should say so
explicitly rather than leaving it implied.

## Audit (2026-08-18)

53 contamination-capable globals (containers, pointers, or module handles)
across `src/ir`, `src/interp_ir`, `src/runtime`, `src/stdlib`. Every one
carries a defense above or is immortal-by-construction; **no undefended
per-program global remained** after the seven roots were fixed.

Notable classifications:

| state | defense |
|---|---|
| `host_instances.shared_anon_module` / `shared_anon_arena` | boundary reset (and the clone is dropped at every boundary — its identity gate compares run-module CELL ADDRESSES, which an arena-reusing driver reissues) |
| `host_instances.anon_site_names` / `anon_site_thunks` | boundary reset |
| `ir.bc.cache` | boundary reset (entries freed, not just cleared) |
| `inline_state.expr_body_members` | reset in the build-start cluster (AST pointers into one build's arena) |
| the thread-local dispatch caches, name-identity slots, perm slots | generation stamping |
| `image.block_cache` | content fingerprint in the key |
| `eval.native_table` | FQN verified before dispatch |
| `image.bake_forest_map` | scoped `defer ... = null` |
| `gc.nursery` / `tenured` / `remembered` / `program_perm` | collector-owned; drained at the run boundary while the cells are still mapped |
| `value.intrinsic_intern` | immortal, keys duped into permanent storage |
| `stdlib.known_packages`, `threads.hooks` / `names` | immortal registries |
| `image.decode_stats`, `eval.call_stats` / `probe_stats` | diagnostics; cumulative across programs by design |

Open, minor: `host_call_member.lenient_warned` is a warn-once set keyed by
id and is not reset per program, so the second program in a process can
lose a leniency warning the first already emitted. Cosmetic — it suppresses
a diagnostic, never changes a result — but it is the one piece of
per-program state deliberately left shared, and it is recorded here rather
than left to be rediscovered.

## The contract for new state

Any new `var` at file scope that holds a container, a pointer, or a module
handle must, in the same commit:

- state which defense it uses in a comment, and
- if it is per-program, be wired into `resetRunGlobalCaches` (or the
  build-start reset cluster for lowering-phase tables) rather than given a
  private reset that only one caller remembers to invoke.

The oracles that catch a violation: `itest-differential` (its order test
runs the corpus forward and backward, so state leaking between programs
diverges), `itest-parity_corpus_pinned`, and `KLIO_GC_STRESS=1` /
`KLIO_GC_STRESS_EVERY=N` over either.

# Open campaigns

The plan register: everything still left to do, at one line of truth
each. `plans/` holds only open work; every finished campaign log and
design record that used to live here is in git history (before the commit
that wrote this file) or under `docs/design/`. Update the state lines as
work lands; close a document when its exit conditions are met.

## The active plan

`kotlinc-box-conformance.md`: the box residue. Census 6012 / 342 / 3 at
34d1a79f, ratchet 6012 / 342; every cluster of five or more
has a fix or a recorded verdict, and the residue table there (clusters
under five, grouped by directory) is the work list: fix by mechanism,
ship an `examples/` program per fix, ratchet after every landed batch,
never edit the corpus. The conformance backlog (Stage 2 Task 4 and the
safe-tier decision) closed 2026-09-07; its records are in git history.
Standing gates: every library census at baseline, compose plugin 1390 / 0,
stdlib sweep 117 files clean, CI green (unit plus eight shards).

## Deferred fronts

Not in the active plan. Each reopens only with the trigger named on it;
"unverified" marks a claim taken from a record that was not re-checked
against the code.

### Language and type checking

- `@Retention` is parsed and dropped; nothing consumes annotation
  retention.
- Module model: visibility diagnostics across modules (`internal`),
  file-local imports; the example corpus run as one module shows about
  53 cross-file interferences (unverified).
- Constraint solver gaps noted against the spec: flexible types,
  equality substitution during incorporation, staged solving, provenance
  diagnostics (Rust-era note; unverified against the Zig solver).
- Explicit backing fields: top-level properties keep no runtime anchor
  table; placement is enforced in typeck only.
- Control-flow analysis residue: lambda-callback contract effects
  (Rust-era names; unverified).

### Runtime and interpreter

- Coroutines: `runBlocking`'s job `toString` leaks `KlioBlockingCoroutine`.
  Unverified: `SupervisorJob` with several throwing children, cancel while
  parked on a channel `send`/`receive`, `DeepRecursiveFunction` under
  `klio run`, `subscriptionCount` on a shared flow.
- GC: incremental or concurrent marking (optional next tier); hardening
  left: a recorded corpus and parity sweep under `KLIO_GC_POISON=1` and
  `KLIO_GC_STRESS=1`, a Debug keepalive lint, removal of the `KLIO_GC_EXT`
  accounting gate.
- Value 24 to 16 bytes (Array low-bit discriminator, IrClosure boxing):
  deferred by doctrine; reopen with a profile naming Value copies above
  2%.
- Resolution hatches still in `src/`: `isToplevelFunction`, `isAliasName`,
  `prefer_member`, `shadowed_inline_names`, `CONTROL_INTRINSICS`,
  `isKnownPackage`, `class_member_names`, `is_ctor_name`,
  `instance_prop_private`; their deletion was the unification plan's
  acceptance test. Three compose-gate side notes from that plan are
  unverified (a resumed activation error must not vanish, `hashCode()`
  per call site on Recomposer, a probe-raised StackOverflow surfacing as
  `unresolved global`).
- Guard inventory rows still present (`docs/design/analysis/guard-inventory.md`):
  the receiver-lambda rebuild, the caps snapshot, the stub predicates,
  `isShadowingCapture`, the `field_resolve_stack` and coroutine-time-mode
  thread locals, the inline receiver as a `this` scope local, the
  lambda-body `this` capture, `Outer$Name` mangling, the type-specialized
  fallback, the simple-name method and companion scans. Delete each once
  its detector shows it unreached.
- Six `dispatchIntrinsic` copies to fold into one; the intrinsic host as
  a thin adapter over `invokeCallable`, `invokeCallableWithThis`,
  `evalClosureRaw`.
- Zig cleanups left: `SpinMutex` yield backoff, the duplicate
  `resumeSlot`/`resumeSlotValue`, one error union in place of
  `RuntimeError`/`EvalError` and its four converters.
- Memory: the leaktrack exit-collect (exits clean today; unverified with
  live worker threads), the eval-level non-intrinsic allocation tail,
  ktor steady-state RSS below node (its own table says met; unverified).
- JIT: gate compile sampling on a warm entry so a cold sample cannot
  accept a trampoline shape the warm compile rejects (unverified).
- Deferred findings 5 and 6 (erased generic return residue, unannotated
  forward top-level read): their gating premise is gone since eager
  typeck always runs; re-check whether any residue remains.
- `kl_` leaf widening: reopen when a real program misses eligibility.
- Watch items, root-cause on recurrence: `dispatched_delay_loop_is_cancellable`
  failed once under 8-way corpus load; the `tl_atomic_update_contended`
  litmus flake.

### Packs, project model, distribution

- Workspace members and one-command multi-artifact builds; path
  dependency auto-build; dependency sources (git, registry), `klio.lock`,
  `--locked`/`--offline`; `klio run .` project mode; requesting a
  dependency's features when it loads before its dependent.
- Pack reader: mmap-backed reading (`src/pack/read.zig` reads the whole
  file), a pack-cache index sidecar, install-time dictionary-trained zstd;
  the cold `klio run hello.kt` under 50 ms acceptance (unverified).
- Multiplatform axis: `target` on sources, `--target`/`KLIO_TARGET` for
  `run` and `pack build`, per-target bindings, an emitter for
  `ACTUAL_ANNOTATIONS_NOT_MATCH_EXPECT`, splitting the monolithic
  `io.ktor` pack, retiring the interim `klio-compose-ui` pack.
- Pack-actual residuals in kotlinx-io: `SegmentPool` is a no-op,
  `isWindows` is false, the line separator is `\n`.
- Lazy image: record the RSS win; drop the retained `lifted_decls` field
  and its stale comment; base-image reuse across load modes for the
  `differential` suite.
- Tooling: an installed `klio-bench` binary; IDE support (no LSP renderer,
  `--format=lsp`, or `klio-lsp`; packs would mount as Kotlin source
  modules since the no-JDK constraint rules out klib).

### Compose UI and mobile

- Foundation sweep: `BasicTextField`, `detectTapGestures`, scrollable
  fling and drag, `SelectionContainer`, `LazyVerticalGrid`; material3
  component sweep (Card, Scaffold, TopAppBar, TextField, Checkbox, Switch,
  RadioButton, Slider, NavigationBar, Dialog, Snackbar, Icon); ripple in a
  live window.
- Lowering name index: class members need a hierarchy walk
  (`member_method_fids` is flat); public cross-package top-level
  collisions wait on the symbol index; type arguments on `CallMember`
  would retire the process-global reified `T`.
- Windows: Win32 window verification; macOS window hardening (backing
  scale, IME, right-click, color space).
- Performance: a slim custom Skia build, lazy stdlib load, a smaller
  per-call frame, dropping the per-frame display-list serialize and parse
  round trip.
- Mobile: sandbox path redirects (`~/.klio` cache, `/tmp`, zoneinfo,
  fonts), RSS-cap tuning, an in-app stdout sink, the iOS `selfExePathZ`
  branch; `klio bundle --target ios` and `ios-sim`; a `klio-mobile` dev
  host with push loop and hot reload; signing and store polish, docs, CI
  gates.
- ktor server start-path coroutine flakiness (unverified since the
  connectors resolve synchronously).

## Doc register

Open: `conformance-backlog.md` (active), `kotlinc-box-conformance.md`,
`safe-tier-allocation-fill.md`, and this file.

Reference (not campaigns): `docs/design/` (architecture summary,
coroutine model, GC, JIT, diagnostics, benchmarks, stdlib, intrinsics,
and the `analysis/` notes), `docs/development/verification-playbook.md`
(the verification playbook CLAUDE.md points at), and the user-facing
`docs/`.

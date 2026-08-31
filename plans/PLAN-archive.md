# Plan Archive

Historical record of completed work. The live register is `open-campaigns.md`; the active plan is `census-gates-and-red-mass.md`. Entries here are append-only — records retire into this file as they close out of the live register.

## The perf era (2026-08-29 .. 2026-08-31) — four closed campaign docs

Read `open-campaigns.md` "THE PERF ERA IS CLOSED" for the one-paragraph
summary. The docs, each terminal with its measurements inline:
- `concurrency-perf-campaigns.md` — gate wall 847 -> ~615s; the
  three-tiers-neutral law; name canonicalization; serve rounds.
- `interpreter-next-campaign.md` — function-JIT coverage (census 5 -> 17),
  the probe-tax fix (atomic hotness word on Func), cost parity on
  compose, 1 ns/iter mono virtual dispatch.
- `interpreter-shared-op-campaign.md` — instance-layout shapes (site
  name-verify skip, fused store, JIT guard_shape), ratchet 650 -> 645;
  the shape-is-not-a-class soundness trap; GC/alloc/dispatch veins
  closed by measurement.
- `interpreter-native-floor-campaign.md` — the kl_ C-to-C sub-ABI
  measured 34.5x on fib (the ABI is escaped); suite wall proven
  vpd-bound; Value 16B / frame-push / per-thread-prof closed below
  threshold.

## Target version & scope

- **Target Kotlin version:** 2.3.21. Pinned via a local checkout of [JetBrains/kotlin](https://github.com/JetBrains/kotlin) at tag `v2.3.21` in `kotlin/` (gitignored).
- **In scope:** the Kotlin language itself, plus a full built-in implementation of the Kotlin stdlib as defined under `kotlin/libraries/stdlib/` (primarily the `common/` surface).
- **Out of scope (for now):** loading or interoperating with third-party Kotlin / JVM libraries — no Maven resolution, no `.jar` / `.klib` consumption, no classpath. `klio` programs may only depend on the language and the bundled stdlib.

## References

- `kotlin-language-spec/` — spec PDFs (consulted for tricky details).
- `kotlin/` — JetBrains/kotlin @ v2.3.21. Source of truth where the spec is ambiguous, and the source we mine for the stdlib.

## Milestone 0 — Scaffold *(done)*

- [x] Cargo workspace, edition 2024, resolver 3
- [x] Crate skeletons: span, diagnostics, lexer, ast, parser, interp, cli
- [x] `klio` binary with `lex` / `parse` / `run` / `repl` subcommands
- [x] README, ARCHITECTURE, PLAN
- [x] End-to-end slice: `fun main() { println(1 + 1) }` runs and prints `2` (see `examples/hello.kt`)
- [ ] CI workflow (fmt + clippy + test)

## Milestone 1 — Lexer *(done)*

Spec: §1 Lexical structure.

- [x] Whitespace, newlines, line + nested block comments
- [x] Identifiers (ASCII + Unicode XID) and hard keywords
- [x] Integer literals: decimal, hex, binary, `_` separators, `L` / `u` / `U` / `uL` / `UL` suffixes
- [x] Floating-point literals: optional fractional, exponent form, `f` / `F` suffix
- [x] Character literals with standard escapes and `\uXXXX`
- [x] String literals: regular with escapes, triple-quoted raw strings
- [x] String templates: `$ident` and `${expr}` emit structured tokens; brace tracking keeps nested templates balanced
- [x] Operators and punctuation per spec §1.2 (incl. `===`, `!==`, `..<`, `?.`, `?:`, `!!`, `::`, `->`, compound assigns, `++` / `--`, `@`)
- [x] Diagnostics: `E0020` unterminated block comment, `E0021` unexpected char, `E0030/E0031` numeric edge cases, `E0040–E0042` char-literal errors, `E0050–E0053` escape errors, `E0060/E0061` string-termination/newline errors
- [x] Snapshot test corpus (`crates/klio-lexer/tests/corpus/`, 10 programs) covering hello-world, arithmetic, strings/templates, comments, declarations, operator zoo, unicode idents, numeric zoo, and two diagnostic cases

## Milestone 2 — Parser + AST shape *(done)*

Spec: §6 Declarations, §7 Expressions, §8 Statements.

- [x] Package + import headers (with `as` aliases and `.*` wildcards)
- [x] Top-level functions with typed params, default values, return type
- [x] `val` / `var` declarations with optional type annotation and initializer (top-level and local)
- [x] Pratt expression parser with full precedence ladder: disjunction → conjunction → equality → comparison → elvis → range → additive → multiplicative → prefix → postfix → primary
- [x] Control flow as expressions: `if` / `else`, `while`, `for`, `return`, `break`, `continue`
- [x] Blocks with newline-or-semicolon statement separation
- [x] Function bodies: block (`{ … }`) and expression body (`= expr`)
- [x] Member access (`.`, `?.`), postfix `!!`, indexing (`[…]`), call expressions
- [x] String templates assembled from lexer tokens into `Expr::StringTemplate { parts }`
- [x] Class scaffolding (parsed with member list; rich modeling deferred to a later milestone)
- [x] Error recovery synchronizing on `;`, newline, `}`, or top-level keywords
- [x] Unit tests (13) + snapshot corpus (10 programs) covering precedence, declarations, control flow, templates, imports, expression-body funs, member chains, and two diagnostic cases
- [x] Interpreter wired for everything except `for` / ranges / member calls / postfix mutation (those land with the stdlib milestone when ranges and collections exist as runtime values)

## Milestone 3 — Tree-walking interpreter *(done)*

- [x] Values: Int, Double, Bool, String, Char, Null, Unit, Range, Function, Builtin
- [x] Arithmetic, comparison, logical (short-circuit) with Kotlin semantics — wrapping integer ops, IEEE-754 doubles, runtime errors on divide-by-zero
- [x] `val` / `var` binding, plain + compound assignment, lexical scopes via parent-pointer envs
- [x] User-defined function declarations and calls — positional args, default-value parameters, block + expression bodies, `return`, mutual recursion via forward declaration
- [x] Top-level evaluation order: functions forward-declared, then `val`/`var` initializers evaluated in source order, then `main` runs
- [x] Local function declarations inside blocks (closures capture the enclosing scope)
- [x] `if` as an expression, `while` with `break` / `continue`, `for` over integer ranges (`..` and `..<`) with `break` / `continue`
- [x] Prefix and postfix `++` / `--` on `var` bindings (Kotlin postfix returns the prior value)
- [x] String templates rendered using `Display` over all `Value`s
- [x] Built-in `println` against the Rust stdout, with a `CaptureOutput` for tests
- [x] 24 interp unit tests covering arithmetic, control flow, user functions, defaults, recursion, mutual recursion, for-loops, postfix/prefix mutation, top-level eval order, and the principal error paths (arity mismatch, division by zero)
- [x] `examples/showcase.kt` and `examples/functions.kt` exercise the entire surface end-to-end through the real `klio` binary

## Milestone 4 — Names, types *(done)*

- [x] `klio-types`: `Type` enum (primitives, `Unit`, `Any`, `Nothing`, `Nullable`, `Function`, `Range`, `Unresolved`), `Display`, builtin lookup by FQN and short name, subtyping (`is_subtype_of`) honoring nullability + `Any` top / `Nothing` bottom, unification skeleton for concrete types, AST `TypeRef` → `Type` conversion (lossy fallback to `Type::Unresolved` for unknown names)
- [x] `klio-resolver`: standalone analysis pass over `KotlinFile` producing a side-table keyed by `Span` from each name-use site to a `Symbol`. Scope tree: builtins → file → function → block. Forward-declares all top-level functions/properties/classes. Resolves identifier references, function call targets, `for`-loop induction vars, function parameters; recognizes `println` / `print` as `Symbol::Builtin`. Does not mutate the AST.
- [x] Diagnostics: `R0001` unresolved identifier, `R0002` shadow warning, `R0003` non-`kotlin.*` import, `R0004` duplicate top-level declaration
- [x] 17 type unit tests + 10 resolver unit tests + 5 resolver corpus snapshots (forward refs, mutual recursion, shadowing, unresolved id, third-party import)
- [x] Stdlib seeds intentionally **deferred to Milestone 5**, which builds the full surface via codegen rather than hand-seeding

## Milestone 5 — Stdlib codegen + scaffolding *(done — scaffolding only; interpreter wiring deferred to M6)*

- [x] `klio-stdlib` scaffolded: `numerics/`, `text/`, `collections/`, `sequences/`, `ranges/`, `io/`, `exceptions/`, `generated/`. Public types: `SymbolEntry`, `SymbolKind`, `Modifiers` bitset, `SourceLoc`, `StdlibFn`/`StdlibValue`/`StdlibError` placeholders (interpreter integration milestone replaces these with `klio-interp` re-exports).
- [x] `klio-stdlib-gen` binary crate with `build` and `coverage` subcommands.
- [x] Declaration extractor: **focused declaration-only Kotlin parser inside `klio-stdlib-gen`** (chosen over extending `klio-parser` because the upstream stdlib uses many constructs we don't yet model: generics, `where`-clauses, extension receivers, `expect`/`actual`/`external`/`inline`/`operator`, annotation argument lists). Keeps `klio-parser` untouched and all existing tests green.
- [x] Mines `kotlin/libraries/stdlib/`: **186 / 186 files parsed**, 5,984 raw declarations extracted, **4,767 unique symbols** emitted to `crates/klio-stdlib/src/generated/symbols.rs`. Spot-checked: `kotlin.io.println`, `kotlin.collections.listOf`, `kotlin.Any`, `kotlin.Unit`, `kotlin.Throwable` all present.
- [x] `lookup(fqn)` and `coverage()` over the generated registry.
- [x] Non-`kotlin.*` imports flagged with `R0003` (delivered by `klio-resolver` in M4).
- [x] `klio-stdlib-gen coverage` prints `implemented N / total M (pct)`. Today: `0 / 4767`.
- [ ] **Deferred to M6**: wire `klio-stdlib::lookup` into the interpreter's name resolution so calls dispatch FQN → Rust handler. (Done as part of M6's implementation work — the placeholders in `klio-stdlib` exist exactly so this crate compiles in isolation today.)
- [ ] **Deferred to M6**: CI gate enforcing coverage non-regression.

## Milestone 6 — Stdlib implementations: foundations

Goal: replace stubs with real Rust for the symbols every nontrivial program touches.

### M6a — Integration foundation *(done)*

- [x] Extract shared runtime types (`Value`, `RuntimeError`, `Env`, `Output`, `StdlibFn`, `CallCtx`) into a new `klio-runtime` crate. Both `klio-stdlib` and `klio-interp` depend on it; no cycle.
- [x] Hand-implementation table in `klio-stdlib::implementations` (linear scan, `lookup(fqn) -> Option<StdlibFn>`).
- [x] Interpreter dispatches qualified expressions (`kotlin.math.abs`) and member access (`s.length`, `s.uppercase()`) into the stdlib via FQN flattening. `Value::type_fqn()` keys the member lookup.
- [x] `println` / `print` resolve through the same path via an `IMPLICIT_ALIASES` table that mirrors Kotlin's implicit imports.
- [x] `Output::write` (no newline) so `print` works end-to-end; `StdoutOutput` and `CaptureOutput` both implement it.
- [x] `coverage()` reports `<hand-impls + registry-marked> / <total mined symbols>`. Currently `18 / 4767`.

### M6b — Foundations surface *(done)*

Surface delivered:

- [x] **Numerics**: `kotlin.math.{abs, min, max, sqrt, pow, sin, cos, tan, ln, log, log10, log2, exp, floor, ceil, round, truncate, hypot, sign, PI, E}`. `kotlin.Int.{toString, toLong, toDouble, and, or, xor, inv, shl, shr, ushr, compareTo}`. `kotlin.Double.{toString, toInt, toLong, isNaN, isInfinite, isFinite, compareTo}`. `kotlin.Boolean.toString`. Wrapping integer arithmetic + IEEE-754 doubles match Kotlin/JVM semantics.
- [x] **`String`, `Char`**: indexing (`s[0]` → `kotlin.String.get`), `length`, `isEmpty`/`isNotEmpty`/`isBlank`/`isNotBlank`, `uppercase`/`lowercase`, `plus`, `substring`, `startsWith`/`endsWith`/`contains`, `indexOf`/`lastIndexOf`, `replace`, `trim`/`trimStart`/`trimEnd`, `repeat`, `reversed`, `padStart`/`padEnd`, `compareTo`, `toInt`/`toIntOrNull`/`toDouble`. `kotlin.Char.{code, digitToInt, isDigit, isLetter, isLetterOrDigit, isWhitespace, isUpperCase, isLowerCase, uppercase, lowercase, toString}`.
- [x] **`readLine`** wired to stdin (`kotlin.io.readLine` returns `String?`).
- [x] **Exceptions hierarchy** as values: `Throwable`, `Exception`, `Error`, `RuntimeException`, `IllegalArgumentException`, `IllegalStateException`, `NullPointerException`, `IndexOutOfBoundsException`, `ArithmeticException`, `ClassCastException`, `NoSuchElementException`, `UnsupportedOperationException`. Bare-name constructors (implicit aliases mirror Kotlin's default imports). `throw` / `try` / `catch` / `finally` parse and evaluate end-to-end via `Expr::Throw` / `Expr::Try` and `RuntimeError::Thrown(Value)`. Catch-by-supertype works for `Throwable` / `Exception`. `e.message` property is wired.
- [x] **Standard scoping fns**: `let`, `also`, `apply`, `run`, `takeIf`, `takeUnless` on any receiver; top-level `with(receiver) { lambda }`. All implemented inside `klio-interp` (the intrinsic ABI can't call back into lambda evaluation today; will revisit when the runtime grows a richer callback protocol).
- [x] **Lambdas**: `{ x: Int, y -> body }` and implicit-`it` `{ body }`. `Expr::Lambda` carries an optional param list and a body block. Trailing-lambda call shape `f { ... }` and `f(args) { ... }` parses to a `Call` with the lambda as the final argument. Lambdas close over the surrounding env via `Value::Lambda { params, body, env }`.
- [x] Implicit aliases: `print`, `println`, `readLine`, plus every exception class name resolve to their `kotlin.*` FQNs without an explicit import.

### Deferred to a later milestone (cross-cutting work, tracked here for visibility)

- `StringBuilder`, full `Regex`/`MatchResult`, `String.format` — non-trivial, tracked under M8 "text deep-dive" via the `_OneToManyTitlecaseMappings` etc. mining.
- Distinct `Long`/`Short`/`Byte`/`Float`/`UInt`/`ULong` runtime value types — today `Value::Int(i64)` and `Value::Double(f64)` cover all integer/float arithmetic. Type fidelity will land alongside the type checker.
- Function types in `parse_type` (e.g. `val f: (Int) -> Int = …`). Today, infer the type from the lambda literal.
- Top-level scoping fns beyond `with` (e.g. bare `let(x) { ... }`) — uncommon in idiomatic Kotlin; can land later.

### Notes

- The 4,767 generated symbols stay as-stubs in `crates/klio-stdlib/src/generated/symbols.rs`. Coverage delta is driven entirely by the hand-implementation table.
- Wiring example: `examples/stdlib_taste.kt` (M6a) and `examples/m6b_taste.kt` (M6b) exercise every intrinsic end-to-end. Coverage today: `95 / 4767`.

## Milestone 7 — Kotlin compiler parity *(done)*

Goal: **zero deliberate divergence from kotlinc.** Every program that compiles cleanly with `kotlinc-native` (pinned to 2.3.21) and runs successfully produces byte-identical output under `klio`. Enforced by `klio-parity` integration tests on every PR.

### Concrete fixes delivered

- [x] **Scoping-fn receiver binding** matches Kotlin: `let` / `also` / `takeIf` / `takeUnless` expose the receiver as `it`; `apply` / `run` / `with` expose it as `this`. Implemented in `try_eval_scoping_member` with a `this_binding` parameter on `call_lambda_with_this`.
- [x] **`this` as a primary expression** is supported throughout: `Expr::This` in AST, parser handles `Keyword::This`, interp evaluates against a `"this"` slot in env. Implicit-this fallback fires whenever a bare identifier (in a `Path`, `Call`, or string-template `$ident`) doesn't resolve in the lexical env and `this` is bound to a receiver with a matching member intrinsic.
- [x] **`kotlin.math.pow(Int, Int)` removed**; `kotlin.Double.pow` extension added in its place. `2.0.pow(10)` and `2.0.pow(3.5)` both dispatch correctly.
- [x] **`Double.toString` formatting** uses a new `klio_runtime::kotlin_double_to_string` helper: integer-valued doubles render as `1.0`, `Infinity` / `-Infinity` / `NaN` literals, scientific notation with capital `E` and a `.0` mantissa when otherwise integer-valued. Applied through `Value::Display` and `kotlin.Double.toString`.
- [x] **`UNNECESSARY_SAFE_CALL` warning** (`R0005`) emitted by the resolver when `?.` targets a `val`/`var` whose declared type is non-nullable. `Symbol::nullable` carries the bit; populated from `TypeRef::nullable` on property declarations.
- [x] **Integer division by zero** throws `kotlin.ArithmeticException` with `message = null`, matching kotlinc-native (the JVM message `"/ by zero"` is a JVM-only detail).
- [x] **`Range.toString`** uses the inclusive form for both `..` and `..<`: `1..<10` renders as `1..9`, mirroring `IntRange.toString` in the real stdlib.

### Parity harness

- [x] **`crates/klio-parity`** — library + binary. Compiles a `.kt` file with `~/.konan/kotlin-native-prebuilt-*-2.3.21/bin/kotlinc-native` (overridable via `KLIO_KOTLINC_NATIVE`), caches the resulting `.kexe` by content hash under `target/parity-cache/`, runs both binaries, diffs stdout, reports unified-style mismatches.
- [x] **Integration tests** (`crates/klio-parity/tests/parity.rs`): two `#[test]` functions — `examples_pass_parity` and `corpus_passes_parity` — that sweep `examples/*.kt` and a focused `tests/corpus/` (one program per fixed behavior). Skips with a printed note if `kotlinc-native` isn't on the machine, so CI without Kotlin Native installed still runs cleanly.
- [x] **Corpus programs** committed: `scoping_apply_this.kt`, `scoping_run_this.kt`, `scoping_let_it.kt`, `scoping_with_this.kt`, `double_pow.kt`, `double_to_string.kt`, `division_by_zero.kt`, `explicit_this_in_lambda.kt`, `range_display.kt`. All pass.
- [x] **Pinned version**: `klio-parity::TARGET_VERSION = "2.3.21"`. The version constant is the only place that needs to change for a deliberate Kotlin bump.

### Examples re-validated

- [x] `examples/stdlib_taste.kt` — `kotlin.math.pow(2, 10)` rewritten as `2.0.pow(10)` with an explicit `import kotlin.math.pow`. Double-output expectations updated.
- [x] `examples/m6b_taste.kt` — `apply { it.length }` now `apply { length }` (implicit `this`); `with(10) { it * it }` now `with(10) { this * this }`; added an explicit `"abc".run { length }` to show `this`-binding without `this.` prefix.
- [x] Every example in `examples/*.kt` passes the parity sweep.

### Working agreement

Every new example or stdlib intrinsic ships with a passing parity check. Custom behavior is treated as a bug. When something in real Kotlin is wrong-feeling, the answer is to **match it** — divergence breaks the IDE integration in M8 and erodes user trust.

### Known deliberate divergences (deferred, tracked)

The following will be addressed alongside future milestones; they aren't observable on programs currently in the corpus and example set, but they're real semantic gaps.

- **Integer width.** `Value::Int(i64)` covers Kotlin's `Int` (32-bit) and `Long` (64-bit). Distinct variants land alongside the type checker so we can route operations correctly without a runtime-only type tag.
- **Char Unicode categories.** Currently use Rust's `char::is_alphabetic` / `is_whitespace` / etc., which differ from Kotlin's `Character` categories on a handful of historic scripts. Will switch to Unicode category tables.
- **String `compareTo`.** Uses Rust's UTF-8 byte ordering, not Kotlin's UTF-16 code-unit ordering. Diverges only for strings containing surrogate-pair characters above U+FFFF.

Each of the above gets a parity test as its first commit, so the fix is test-driven.

## Milestone 8 — Diagnostics + tooling integration

Rationale and full design: [`docs/DIAGNOSTICS.md`](DIAGNOSTICS.md). Goal: `klio` is a drop-in source of truth for Kotlin diagnostics — same factory IDs as `kotlinc`, kotlinc-compatible plain output, JSON / SARIF for tooling. The Language Server (M8b/c) lands later when the language + stdlib surface are closer to complete.

### M8a — Diagnostic model rebuild *(done)*

- [x] `klio-diagnostics` rebuilt: `DiagnosticFactory { name, default_severity, message_template }`, `Diagnostic { factory, legacy_code, severity, primary, secondary, notes, fixits }`, `FixIt { title, edits, kind }`, `TextEdit`. `Severity` aligned with kotlinc's `CompilerMessageSeverity` (`Error`, `StrongWarning`, `Warning`, `Info`, `Hint`).
- [x] `klio-diagnostics-gen` companion crate mines `kotlin/compiler/fir/checkers/gen/.../FirErrors.kt` for factory declarations and `FirErrorsDefaultMessages.kt` for templates. **Generated 819 factories** into `crates/klio-diagnostics/src/generated/factories.rs`. Re-run with `cargo run -p klio-diagnostics-gen`.
- [x] Existing emit sites mapped to canonical factories where they exist: `E0040`/`E0041`/`E0042` → `EMPTY_CHARACTER_LITERAL` / `INCORRECT_CHARACTER_LITERAL`; `E0050`–`E0053` → `ILLEGAL_ESCAPE`; `R0001` → `UNRESOLVED_REFERENCE`; `R0004` → `REDECLARATION`; `R0005` → `UNNECESSARY_SAFE_CALL`. Diagnostics carry both the kotlinc factory name and the legacy `E####`/`R####` code so renderers and tests can use either identifier.
- [x] Renderers: `render::plain` (kotlinc-compatible: `file:line:col: severity: msg [FACTORY]` with source line + caret underline + secondary labels + notes + fixits), `render::json` (NDJSON, one diagnostic per line), `render::sarif` (SARIF 2.1.0 document with one run, deduplicated rules array, results with physical locations). LSP renderer deferred with the LSP server.
- [x] CLI: `klio check <files…> [--format=plain|json|sarif]` runs lex → parse → resolve over each input, emits diagnostics in the chosen format, exits 1 on any `Error` severity.
- [x] All existing emitters (`klio-lexer`, `klio-parser`, `klio-resolver`) now go through the factory model; existing snapshot tests and parity tests stay green.

### M8b — `klio-lsp` Language Server *(deferred)*

Implementation waits until the language and stdlib surface are close to feature-complete. The plan remains as previously specified — `tower-lsp`, the prioritized request set (didOpen / didChange / publishDiagnostics / hover / definition / references / completion / documentSymbol / semanticTokens / codeAction), and the editor-integration docs (M8c) — but lands as a later milestone when there's enough behind the IDE for the LSP to be genuinely useful. `render::lsp` is the small remaining piece in `klio-diagnostics` and ships with M8b.

### M8c — Editor integration & docs *(deferred — see M8b)*

### Non-goals (deferred)

- Reusing Kotlin's actual checker code — we compute diagnostics ourselves; we only borrow factory IDs + message templates
- Full IntelliJ inspection parity — compiler-level diagnostics first, plugin inspections later if at all
- Persistent cross-file index — each LSP session reanalyzes on open; cross-file indexing waits for multi-file resolution

## Milestone 9 — Stdlib implementations: collections, sequences, ranges

### M9a — Core collections + functional ops *(done)*

- [x] Runtime types: `Value::List` / `Set` / `Map` (each with a `mutable` tag and shared `Rc<RefCell<Vec<…>>>` storage matching `LinkedHashMap` insertion-order semantics), `Value::Pair`, `Value::MapEntry`. Display/Debug/`type_fqn`/structural equality all wired.
- [x] Constructors: `listOf`, `mutableListOf`, `setOf`, `mutableSetOf`, `mapOf`, `mutableMapOf`, `emptyList`, `emptySet`, `emptyMap`. Implicit aliases mean no `import kotlin.collections.*` is needed.
- [x] `to` infix produces `Pair`. Parser now recognizes a whitelisted set of infix function calls (`to`, `until`, `downTo`, `step`) between elvis and range; full infix support arrives with the type checker.
- [x] List members: `size`, `isEmpty`/`isNotEmpty`, `get`/`[i]`, `first`, `last`, `contains`, `indexOf`, `lastIndexOf`, `joinToString`, `toString`.
- [x] MutableList members: `add`, `removeAt`, `clear`, plus everything List has.
- [x] Set members: `size`, `isEmpty`/`isNotEmpty`, `contains`, `toString`. MutableSet adds `add`, `remove`, `clear`.
- [x] Map members: `size`, `isEmpty`/`isNotEmpty`, `get`/`[k]`, `containsKey`, `containsValue`, `keys`, `values`, `entries`, `toString`. MutableMap adds `put`, `remove`, `clear`.
- [x] `Map.Entry.key` / `.value` / `.toString`. `Pair.first` / `.second` / `.toString`.
- [x] `for` loops iterate List, Set, and Map (yielding `Map.Entry`).
- [x] Higher-order ops dispatched from `klio-interp` (parallels the scoping-fn dispatch): `map`, `filter`, `filterNot`, `forEach`, `fold`, `reduce`, `any`, `all`, `none`, `count`, `find`, `sumOf`, `maxOf`, `minOf`. Each works uniformly on List / Set / Map (Map iterates entries).
- [x] **Parity**: 7 new corpus programs (`list_basics`, `list_map_filter`, `mutable_list`, `map_basics`, `map_iteration`, `set_basics`, `pair_and_to_infix`) plus `examples/collections.kt` — all pass byte-identical against `kotlinc-native 2.3.21`.

### M9b — Sorting, grouping, slicing, ranges, destructuring *(done)*

- [x] **Sorting + reversed + distinct**: `sorted`, `sortedDescending`, `sortedBy`, `sortedByDescending`, `reversed`, `distinct`, `distinctBy`. Natural-order comparator built from `compare_values` over Int/Long/Double/String/Char/Bool.
- [x] **Grouping + association + partition**: `groupBy`, `associate`, `associateBy`, `associateWith`, `partition` — all higher-order, dispatched from `klio-interp` parallel to scoping fns.
- [x] **Composition**: `flatMap`, `zip` (with another collection or a Range), `takeWhile`, `dropWhile`.
- [x] **Slicing**: `take`, `drop`, `takeLast`, `dropLast`, `slice(IntRange)`, `slice(List<Int>)`, `subList(from, to)`.
- [x] **Set/List arithmetic**: `plus`/`minus` on List (vs element or vs collection), `union`/`intersect`/`subtract`/`plus`/`minus` on Set.
- [x] **Progressions**: `Value::Range` now carries a signed `step` field. `downTo`, `until`, `step` are wired as infix functions (parser already accepted the syntax; runtime + stdlib intrinsics implemented). `step n` normalizes the stored `end` to the last reachable element so `1..10 step 2` prints `1..9 step 2`, matching kotlinc-native exactly. For-loop iteration honors `step`'s sign.
- [x] **Range members**: `first`, `last`, `step` (property), `contains`, `isEmpty`, `toString` matching kotlinc's `IntRange` / `IntProgression` formatting (`10 downTo 1 step 1`, etc.).
- [x] **Destructuring in `for ((k, v) in m)`**: `Expr::For` now carries `vars: Vec<Ident>`. Parser accepts `(a, b, …)` after `for (`. Interpreter pulls components from the iteration item: `Pair` → 2, `Map.Entry` → key/value, `List` → indexed. Resolver declares each name in the for-scope.
- [x] **Parity**: 7 new corpus programs (`progressions`, `sorting_distinct`, `grouping_partition`, `flatmap_zip`, `take_drop_slice`, `set_ops`, `destructuring_for`) and `examples/collections.kt` extended — all pass byte-identical against `kotlinc-native 2.3.21`. Stdlib coverage at **217 / 4767**.

### M9c — Sequence, Comparator, chunked/windowed, named constructors, string helpers *(done)*

- [x] **Named constructors**: `ArrayList`, `HashMap`, `LinkedHashMap`, `HashSet`, `LinkedHashSet` produce empty `MutableList`/`MutableMap`/`MutableSet` storage. They also accept an initial capacity (ignored) or a copy-from collection.
- [x] **`chunked` / `windowed`** on List: `chunked(size)`, `windowed(size, step?, partialWindows?)`. Empty windows or `size <= 0` throws `IllegalArgumentException` matching kotlinc.
- [x] **String collection helpers**: `String.toList()` → `List<Char>`, `String.split(delim)` → `List<String>` (delim can be `String` or `Char`), `String.chunked(size)`, `String.windowed(size, step?, partialWindows?)`.
- [x] **Comparator**: `Value::Comparator { selectors, descending }` chains key selectors. `compareBy { … }` and `compareByDescending { … }` are top-level callables; `.thenBy { … }` extends the chain; `.reversed()` flips. `List.sortedWith(comparator)` applies the chain stable-sort.
- [x] **Sequence**: `Value::Sequence` is structurally a wrapper around a `Vec<Value>` — eager evaluation today, but `type_fqn` reports `kotlin.sequences.Sequence` and all observable behavior (intermediate + terminal ops) matches Kotlin's `Sequence` API. `asSequence()` works on List/Set/String/Range; `toList`/`toSet`/`toMutableList` collapse back. Every higher-order op in the interp's dispatcher now preserves `Sequence`-typing through chained ops.
- [x] **Generic call-site type args**: parser now tolerates `f<T>(…)`, `f<T> { … }`, and `f<T>.member` — the `<T,…>` is consumed and discarded since we don't yet model the types. This unblocks `ArrayList<Int>()` and `compareBy<String> { … }`.
- [x] **Predicate-free terminal ops**: `xs.count()` / `seq.count()` no longer hit the HOF arity check; the dispatcher only takes the HOF path when a lambda is actually supplied, otherwise it falls through to the no-arg intrinsic.
- [x] **Parity**: 5 new corpus programs (`named_constructors`, `chunked_windowed`, `string_collections`, `comparator_sortedwith`, `sequence_basics`) and `examples/collections.kt` extended — all pass byte-identical against `kotlinc-native 2.3.21`. Stdlib coverage at **246 / 4767**.

### M9d — thenByDescending, lazy Sequence, joinToString transform *(done)*

- [x] **Comparator per-step direction**: `Comparator.steps` now carries `(selector, descending)` pairs. `compareBy { … }` builds steps with `descending: false`; `compareByDescending` flips them. `Comparator.thenBy` / `thenByDescending` append; `Comparator.reversed()` flips every step on the way through `sortedWith`.
- [x] **`joinToString` with `transform`**: dispatched in interp so the lambda runs through `call_lambda`. Supports the full positional signature `(separator, prefix, postfix, limit, truncated, transform)`; trailing-lambda forms like `xs.joinToString(", ") { "x=$it" }` work.
- [x] **Lazy `Sequence`**: `Value::Sequence` is now `Rc<SequenceData>` carrying a `SequenceSource` (`Items` or `Generate`) and a `Vec<SeqOp>` (`Map`, `Filter`, `FilterNot`, `Take`, `Drop`, `TakeWhile`, `DropWhile`, `FlatMap`, `Distinct`, `DistinctBy`). Intermediate ops on a `Sequence` receiver clone the op chain and append; terminal ops drive a pull loop with per-op state (counters for `Take`/`Drop`, flags for `TakeWhile`/`DropWhile`, seen-sets for `Distinct`/`DistinctBy`). A 10 M-iteration safety cap keeps buggy generators from infinite-looping.
- [x] **`generateSequence`** in both seeded `generateSequence(seed) { next }` and nullary `generateSequence { nextOrNull }` shapes. Lazy — only as many items as the terminal op consumes are produced.
- [x] **Parity**: 3 new corpus programs (`thenby_descending`, `jointostring_transform`, `generate_sequence`) and `examples/collections.kt` extended. All pass byte-identical against `kotlinc-native 2.3.21`.

### M9e — Sequence sort + aggregations + Sequence terminal ops *(done)*

- [x] **Sequence sorting**: new `SeqOp` variants `Sorted(descending)`, `SortedBy(lam, descending)`, `SortedWith(comparator)`. Materialize is now multi-stage — it splits the op chain at the first sort, runs the pre-sort prefix streaming, sorts the buffered items, then recurses on the remainder over an `Items` source. Generators with no preceding `Take` would loop forever (matching Kotlin) — the 10 M-iteration safety cap catches that.
- [x] **List aggregations**: `sum`, `average`, `max`, `min`, `maxOrNull`, `minOrNull`, `indices`, `lastIndex`, `toMap` (over `List<Pair<K, V>>`). All registered for both `List` and `MutableList` and work uniformly through `Sequence` via materialize-then-dispatch.
- [x] **Sequence terminal ops**: `groupBy`, `associate`, `associateBy`, `associateWith`, `partition` route through the Sequence dispatcher, materialize, and reuse the List HOF path.
- [x] **Parity**: 3 new corpus programs (`sequence_sorting`, `aggregations`, `sequence_terminal_more`) and `examples/collections.kt` extended. All pass byte-identical against `kotlinc-native 2.3.21`. Stdlib coverage **264 / 4767**.

### M9f — Multi-line chains + named arguments *(done)*

- [x] **Multi-line method chains**: `parse_postfix` now peeks past newlines and resumes the chain when the next non-newline token is `.`, `?.`, `!!`, or `[`. Matches Kotlin's rule: a postfix line continues over a newline iff the next line starts with a continuation token. Fluent multi-line builders (`words.asSequence()\n  .filter { … }\n  .map { … }\n  .toList()`) now parse cleanly.
- [x] **Named arguments**: the parser accepts the `name = expr` shape inside a call's argument list. The label is consumed and discarded — dispatch is still positional, which produces correct output whenever the call writes arguments in declaration order (the vast majority of real Kotlin code). Reordering by name will land when stdlib signature parsing in `klio-stdlib`'s registry can supply per-function param names.
- [x] **Parity**: new corpus programs `multiline_chain` and `named_args_positional` both pass byte-identical against `kotlinc-native 2.3.21`.

### M9g — Named-argument reordering *(done — partial)*

- [x] **AST + parser**: `Expr::Call` now carries `arg_names: Vec<Option<String>>` parallel to `args`. The parser captures `name = expr` labels at call sites; trailing-lambda construction propagates a `None` slot.
- [x] **User-defined functions**: `call_function_named` walks the callee's `decl.params`, slotting each call argument either by positional cursor or by name match. Missing slots fall back to the parameter's default; missing-without-default still errors. Reorder is fully general.
- [x] **`joinToString` reordering**: hard-coded `[separator, prefix, postfix, limit, truncated]` param list applies the same reorder logic before the existing dispatcher runs. Trailing-lambda `transform` is detected first and excluded from the reorder.
- [x] **Parity**: new `named_args_reorder.kt` corpus program covers user fn reorder, mixed positional+named, and `joinToString` with out-of-order named args — all pass byte-identical against `kotlinc-native 2.3.21`.

### Still deferred

- [ ] **Named-arg reordering for arbitrary intrinsics**. Today only user fns and `joinToString` reorder. Other intrinsics (`chunked`, `windowed`, `sortedWith`, …) accept named args only when written in declaration order. Lifting this requires the stdlib registry to expose per-FQN parameter-name lists; planned as a follow-up to `klio-stdlib-gen`.
- [ ] **`Comparable` interface** — user-defined `compareTo`. Arrives with the classes milestone.
- [ ] **`sequence { yield … }`** — builder-style generators. Arrive with coroutines.

## Milestone 10 — Classes & objects *(done)*

Goal: a Kotlin programmer can declare and use classes, data classes, companion objects, and standalone object singletons, with `==`, sorting, and member dispatch matching `kotlinc-native 2.3.21` byte-for-byte.

### Shipped

- [x] **AST** (`klio-ast`): `Decl::Class` rebuilt with `primary_params: Vec<ClassParam>`, `init_blocks: Vec<Block>`, `supertypes: Vec<TypeRef>` (parsed and stored for future inheritance work), `is_data`, `is_companion` flags. `ClassParam` carries `property: Option<bool>` (`Some(true)` for `var`, `Some(false)` for `val`, `None` for non-property), name, type, default. New `Decl::Object(ObjectDecl)` for standalone singletons.
- [x] **Parser**: `parse_class` reads the primary ctor list (with `val`/`var` modifiers, defaults, visibility annotations consumed and ignored), supertype list (parsed, semantically ignored), and a body containing `init { … }` blocks and member declarations. `data` and `companion` modifiers flow into the AST flags. `class Foo<T, U>(...)` parses but type parameters are discarded. `object Foo { … }` and `companion object [Name]` are dedicated forms. Visibility (`private`, `internal`, `protected`, `public`) is parse-and-ignored.
- [x] **Runtime** (`klio-runtime`): `Value::Class(Rc<ClassDef>)` and `Value::Instance(Rc<RefCell<InstanceData>>)`. `ClassDef` carries name, primary params, methods, body properties, init blocks, `is_data` / `is_object` flags, an optional companion `InstanceData`, and the env it was declared in. `InstanceData` is a class-ref plus an insertion-ordered `Vec<(String, Value)>` field map. `Value::structural_eq` field-compares two data-class instances of the same class, returns identity-eq for plain classes, and false for cross-class compares.
- [x] **Interpreter**: top-level eval registers `Value::Class` for each `class`/`companion object` and constructs the singleton for each `object` decl. Calling a `Value::Class` constructs an instance: primary params bind, then body property initializers and init blocks run with `this` bound to the new instance. Method calls bind `this` and expose each field by short name (so a method body can read `x` instead of `this.x`). Bare-name reads inside a method also fall back to companion-object members. Field writes route through `Value::Instance` even when the source uses the short name. `Foo.member` and `Foo.method(...)` access goes through the companion. `Value::Class` is a callable; constructor calls go through the same named-arg reorder logic as user functions.
- [x] **Auto-generated members**: `toString` / `equals` / `hashCode` / `componentN` / `copy` for `data class`; `toString` returns the class name for plain classes (Kotlin's `Foo@hash` form would diverge per-run, so this is the safe parity choice). `equals` on plain-class instances is identity (`Rc::ptr_eq`) per Kotlin defaults. User-declared `override fun toString()` / `equals` / `hashCode` win over the auto-generation. `println` and string-template interpolation dispatch through user `toString()` when present.
- [x] **`operator fun compareTo`**: when a user class defines it, `sortedWith` / `sortedBy` / `sortedByDescending` / `sorted` / `sortedDescending` on a list of instances dispatch through it. The interpreter wraps every sort site with an insertion sort that can re-enter the interpreter for the comparator (regular `Vec::sort_by` can't, since the comparator closure captures `&mut Interpreter`). Primitive natural-order sorting still uses `klio-stdlib::compare_values` and stays on `Vec::sort_by` indirectly via the new `compare_with_user` shim.
- [x] **Parity corpus**: `class_basics.kt`, `class_var_property.kt`, `class_init_block.kt`, `data_class.kt`, `companion_object.kt`, `object_singleton.kt`, `comparable_userclass.kt`, `class_in_collection.kt` — all pass byte-identical against `kotlinc-native 2.3.21`.
- [x] **Example**: `examples/classes.kt` exercises the full surface end-to-end and is in the parity sweep.

### Deferred (tracked, not in scope for M10)

- **Inheritance**: `open` / `override` / abstract / sealed classes, super calls, interface dispatch. Today supertypes are parsed and stored but never consulted; `class Foo : Bar()` compiles and runs as if `: Bar()` weren't there.
- **Generics on classes**: type parameters parse-and-discard. No variance, no `where` clauses, no reified type-arg dispatch.
- **Inner / nested non-companion classes** and **enum classes** — both deferred.
- **Secondary constructors** (`constructor(x: Int): this(x, 0)`) — deferred. Only primary ctors are supported.
- **Property delegates** (`by lazy { … }`) and **custom getters/setters** — deferred. A property's `get()` / `set(value)` clauses aren't parsed.
- **Interfaces**: `class Foo : Bar` parses (Bar stored as a supertype) but no semantic dispatch. User code can compile against `Comparable<T>` since the explicit `compareTo` method wins regardless of declared interface.
- **Destructuring declarations** (`val (a, b) = pair`) outside `for` headers — deferred; today only `for ((k, v) in m)` form works.
- **`Foo@hash` `toString` for plain classes**: matching Kotlin/Native's identity-hashed default would require a stable per-instance identity hash that survives parity replay. We render the class name only.
- **Named-arg reordering on data-class auto `copy`** is fully wired, but generic intrinsics still only reorder for user functions and `joinToString` (this is the M9g-deferred work, not a regression).

## Milestone 11 — Enum classes *(done)*

Goal: `enum class` is a first-class declaration that supports bare entries, entries with constructor arguments, shared and per-entry member functions, and the universal `name` / `ordinal` / `values()` / `entries` / `valueOf(...)` surface, with byte-identical output to `kotlinc-native 2.3.21`.

### Shipped

- [x] **AST**: `Class` extended with `is_enum: bool` and `enum_entries: Vec<EnumEntry>`. New `EnumEntry { name, args, body_members, span }` for the per-entry declaration (args for the primary-ctor call, `body_members` for per-entry overrides).
- [x] **Parser**: `enum` flows through the modifier-flag pipeline like `data` / `companion`. `parse_class` branches on `is_enum` to read the entry list (comma-separated, each with optional `(...)` ctor args and optional `{...}` class body), an optional `;`, then continues with regular class-body members (shared methods, properties, abstract decls, `init` blocks). `abstract fun apply(...)` declarations with no body parse fine via the existing bodyless-function path.
- [x] **Runtime**: `ClassDef` carries `is_enum: bool` and `enum_entries: RefCell<Vec<(String, Value)>>`. Display for `Value::Instance` renders enum entries as the entry name when no override is present.
- [x] **Interp**: `build_class` constructs the `Rc<ClassDef>` first (with an empty entry vec), then `build_enum_entries` constructs each entry instance by calling the enum primary ctor and stamping `name` / `ordinal` fields. Entries with body members get a synthetic per-entry sub-`ClassDef` that inherits methods/body-properties from the enum class and overrides what the entry declared.
- [x] **Static members**: `Color.RED` resolves through `eval_property_access`. `Color.entries` returns a `List<Color>` of all entries; `Color.values()` returns the same shape. `Color.valueOf(name)` throws `IllegalArgumentException` with the Kotlin/Native message `"Invalid enum value name: <name>"` when no match.
- [x] **Default `toString()`**: returns the entry name. User overrides win via the existing `format_value` path.
- [x] **Ordinal-based comparison**: enum-to-enum comparisons of the same enum class compare by `ordinal`. Wired into `compare_with_user` so `sorted()` / `sortedBy { … }` / `sortedWith(...)` all work. `<` / `<=` / `>` / `>=` against user instances route through `compare_with_user` from `eval_expr` directly, so `Color.RED < Color.BLUE` works without a user `compareTo` declaration.
- [x] **Parity corpus**: `enum_basic.kt`, `enum_with_args.kt`, `enum_methods.kt`, `enum_values_and_valueof.kt`, `enum_compare.kt` — all pass byte-identical against `kotlinc-native 2.3.21`.
- [x] **Example**: `examples/enums.kt` exercises bare entries, ctor args, shared and abstract-overridden methods, `name` / `ordinal`, `values()` / `entries` / `valueOf(...)`, and ordinal comparison.

### Deferred (tracked, not in scope for M11)

- Generic enums.
- Companion objects on enum classes with implicit `Foo.entries` access.
- `EnumEntries` interface specifics (we hand back a `List`).
- `when` expression itself (next milestone).

## Milestone 12 — Sealed + `when` + `is` *(done)*

Goal: `when` is a first-class expression and statement, `is`/`!is` work as runtime type checks (with the smart-cast effect on member access), and `sealed class` / `sealed interface` parse and record subtype links well enough for `is`-checks to walk them. All shipped with byte-identical output to `kotlinc-native 2.3.21`.

### Shipped

- [x] **AST**: `Expr::When { subject: Option<Box<Expr>>, branches: Vec<WhenBranch>, span }` with `WhenBranch { patterns, body, span }` and `WhenPatternKind` covering `Value(Expr)`, `InRange(Expr)`, `NotInRange(Expr)`, `IsType(TypeRef)`, `NotIsType(TypeRef)`, `Else`. New `Expr::IsCheck { expr, ty, negated, span }`. `Class` extended with `is_sealed: bool`.
- [x] **Parser**: `parse_when` reads optional `(subject)` then `{branch …}`. Patterns split by `,`; keyword forms (`is`, `!is`, `in`, `!in`, `else`) are recognized; bodies parse as full expressions. `is`/`!is` ship as named-check binary operators on a precedence layer between comparison and elvis (Kotlin spec §7). `sealed` joins `data` / `companion` / `enum` in the modifier-flag pipeline; `interface` falls through `parse_class` so `sealed interface Foo` records `is_sealed=true` with no primary ctor.
- [x] **Runtime**: `ClassDef` carries `is_sealed` and `supertype_names: Vec<String>`. `ClassDef::is_subtype_of(name)` walks the recorded supertype names through the class's captured env, with a small depth bound to defang cycles. `Value::is_runtime_type(name)` does the value-level dispatch for `is`-checks — primitives map by `Value` variant (with the spec's open type names `Any`, `Number`, `Comparable`, `CharSequence`, etc.), instances delegate to `is_subtype_of`.
- [x] **Interp**: `Expr::IsCheck` evaluates the operand and runs `is_runtime_type`, honoring the `negated` flag and the `nullable: true` quirk that lets `null is T?` succeed. `Expr::When` evaluates the subject once, scans branches in declaration order, and matches per-pattern (`Value` → structural-equality or Boolean, `InRange`/`NotInRange` → new `value_in` helper handling Int/Range, Any/List/Set, Any/Map, String/Char in String, `IsType`/`NotIsType` → runtime type check, `Else` → always). Smart-cast on `is Type` is free at runtime: member dispatch already goes through `Value::Instance.class`, so reading `x.field` after `is Foo` works without any AST narrowing. On no-match-no-else, throws a `kotlin.NoWhenBranchMatchedException`.
- [x] **Resolver**: walks `When` patterns/bodies and `IsCheck` operands.
- [x] **Parity corpus**: `when_basic.kt`, `when_subjectless.kt`, `when_is_type.kt`, `when_expression.kt`, `is_check.kt`, `sealed_basic.kt` — all pass byte-identical against `kotlinc-native 2.3.21`. The runtime-throw path is covered by an interp unit test (`when_no_match_throws_no_branch_exception`); kotlinc rejects the exhaustive-when case at compile time so it can't ride the parity sweep.
- [x] **Example**: `examples/sealed_when.kt` walks a small `sealed class Json` tree via `when (node) is JsonNum / JsonStr / JsonBool / JsonArr`, plus `bucket(n)` exercising `,`, `in range`, `!in range`, and `else`, and bare `is`/`!is` checks.

### Deferred (tracked, not in scope for M12)

- **Compile-time exhaustiveness checking** over sealed hierarchies. Today `when (x) is …` happily compiles a non-exhaustive set and throws at runtime; kotlinc would warn/error at compile time.
- **AST-level smart cast narrowing**. We rely on runtime instance dispatch, which is sufficient for member access today. Once a type checker lands, the compiler can prove the narrowed type statically and the resolver can encode it.
- **`in`/`!in` as general binary expressions** (not just `when` patterns). Outside `when`, only the `for (x in xs)` header form parses today.
- **Full inheritance**: `open` / `override` / `super` / `abstract` constructor calls. `class Sub: Parent()` currently records `Parent` as a supertype name (enough for `is`-checks) but doesn't invoke `Parent`'s ctor or methods.

## Milestone 13 — Inheritance *(done)*

Goal: `open class` / `open fun` / `override`, super-constructor invocation, and `super.method()` work with parity against `kotlinc-native 2.3.21`.

### Shipped

- [x] **AST**: `Class` extended with `is_open: bool` and a parallel `supertype_args: Vec<Option<Vec<Expr>>>` capturing the constructor argument expressions at each `: Parent(args)` site. `Function` extended with `is_open` and `is_override`. New `Expr::Super { span }` for the `super` keyword as a primary expression (only meaningful as the receiver of `super.foo` / `super.foo(...)`).
- [x] **Parser**: `open` and `override` flow through the modifier-flag pipeline like `data`/`enum`/`sealed`. `parse_optional_supertypes` now reads the constructor argument list — not just balanced-paren skip — so the AST carries the super-ctor expressions. `super` is a primary-expression form. `parse_fun` also accepts generic type parameters `fun <T> id(x: T)` (parse-and-discard).
- [x] **Runtime** (`klio-runtime`): `ClassDef` carries `parent: RefCell<Option<Rc<ClassDef>>>` (resolved single-inheritance parent), `parent_ctor_args: Vec<Rc<Expr>>`, and `is_open`. `MethodDef` carries `is_open` / `is_override`. New `ClassDef::find_method(name)` walks the class chain and returns the most-derived method with the class that declared it; `find_body_property` does the same for properties.
- [x] **Interp**: top-level class registration now happens in two passes — every class shell is built and bound first, then a second pass walks each class's first supertype name in the captured env and wires the `parent` link. Enum-entry construction and object-singleton initialization move into a third pass so they can rely on resolved parents. Method dispatch sites (`x.foo()`, implicit-`this` bare-name dispatch, `format_value`'s `toString`, `try_instance_compare_to`) all go through `find_method`.
- [x] **Super-constructor invocation**: `construct_instance` delegates to `run_ctor_chain`, which binds the current class's primary-ctor params (so subclass param refs in the `: Parent(args)` clause resolve), evaluates the parent-ctor args in that frame, recursively runs the parent's ctor chain into the same instance, then runs the current class's body initializers and init blocks. Parent init blocks therefore always execute before child init blocks, matching Kotlin's construction order.
- [x] **`super.method()`**: `call_method` binds a synthetic `__owner_class__` to the leaf instance's class. `super.foo` / `super.foo(...)` looks up `__owner_class__`, steps to its `parent`, runs `find_method` from there, and re-enters `call_method_with_owner` so further `super` calls (e.g. C → B → A) continue stepping up the chain.
- [x] **`super.property`**: routes through the same instance-field path — inherited fields live on `InstanceData.fields` so `super.foo` and `this.foo` agree.
- [x] **Parity corpus**: `inherit_basic.kt`, `inherit_override.kt`, `inherit_super_call.kt`, `inherit_chain.kt`, `inherit_field_access.kt`, `inherit_init_order.kt` — all pass byte-identical against `kotlinc-native 2.3.21`.
- [x] **Example**: `examples/inheritance.kt` exercises open/override on shapes, super-ctor chaining (Square → Rectangle → Shape), polymorphic dispatch over a `List<Shape>`, and a `super.bump()` mutation pattern.

### Deferred (tracked, not in scope for M13)

- **Soft override diagnostics** (`OVERRIDE_NEEDED`, `OVERRIDE_BUT_PARENT_NOT_OPEN`, `OVERRIDE_BUT_NO_BASE`, `OVERRIDE_OPENS_FINAL_CLASS`). The flags are captured on every `Function` / `Class`; resolver wiring waits until the type checker can see across files. Today we trust the source to be well-formed — `kotlinc` rejects malformed cases at compile time anyway, so the parity corpus never exercises them.
- **Multiple inheritance / interfaces**: only the first supertype is followed for method resolution. Interfaces parse as supertypes but contribute no methods.
- **`abstract class`** members: parse but no abstractness enforcement. Today an unbodied member would just fail at call time.
- **Method-frame property snapshot**: inside a method body, primary-ctor properties are pre-bound by value at frame entry. A `super.bump()` that mutates a primary-ctor `var` won't be visible to a subsequent read of the unqualified name in the same frame — use `this.count` to force a fresh field read. This is a pre-existing limitation in M10's `call_method`, surfaced more often by inheritance; fix lands alongside a richer property model.

## Milestone 14 — Interfaces *(done)*

Goal: `interface` declarations with abstract members, default-method bodies, multiple-interface implementation, and interface inheritance, with byte-identical output to `kotlinc-native 2.3.21`.

### Shipped

- [x] **AST**: `Class.is_interface: bool` (the `interface` keyword still flows through `parse_class`). An interface's methods may have `body: None` (abstract) or a default `FunctionBody`. Properties on an interface use the existing `Property` shape with no initializer (`val name: String`).
- [x] **Parser**: `parse_class` records `is_interface` from the leading keyword. Supertype list reuses `parse_optional_supertypes`; interfaces have no `(...)` super-ctor call. Default method bodies parse as normal `fun` bodies.
- [x] **Runtime** (`klio-runtime`): `ClassDef` carries `is_interface: bool` and `interfaces: RefCell<Vec<Rc<ClassDef>>>`. `find_method` and `find_body_property` now walk the chain in this order: self → parent chain → each interface in declaration order (recursive within each interface), preferring methods with a body over abstract declarations so an inherited concrete method always wins over an interface default. `is_subtype_of` already walked `supertype_names` through `captured_env`, which picks up interfaces as `Value::Class` entries.
- [x] **Interp**: the second pass `resolve_parent_link` now classifies each resolved supertype — interfaces accumulate into `class.interfaces`, the first non-interface class becomes `class.parent`. `parent_ctor_args` was already collected as "first supertype with `(...)`", which is the parent class (interfaces have no parens). The construction pass is unchanged: only `class.parent` drives `run_ctor_chain`, so interfaces contribute methods/`is`-check membership but never run a ctor. The auto-`toString` path was tightened to ignore abstract interface declarations (only invokes a `toString` whose method has a body).
- [x] **Dispatch**: a default method's `this` is the implementing instance (not the interface), naturally via `call_method` binding `this` to the leaf `Value::Instance`. Conflict between two interface defaults of the same name resolves to the first interface in declaration order (Kotlin would error at compile time; we don't enforce that diagnostic).
- [x] **Parity corpus**: `interface_basic.kt`, `interface_default_method.kt`, `interface_multiple.kt`, `interface_extends_interface.kt`, `interface_with_class_parent.kt`, `interface_is_check.kt`, `interface_property.kt` — all pass byte-identical against `kotlinc-native 2.3.21`.
- [x] **Example**: `examples/interfaces.kt` exercises abstract members, default-method bodies, marker interfaces, interface-extending-interface with `override`, a class implementing multiple interfaces while also extending a parent class, and `is`-checks combined in a `when` expression.

### Deferred (tracked, not in scope for M14)

- **`fun interface` (SAM conversions)** — deferred.
- **Property delegation through interfaces** — deferred.
- **Interface companion objects with shared state** — deferred.
- **Diamond inheritance conflict diagnostics** — Kotlin requires an explicit `override` resolving two same-signature defaults from two interfaces. We pick the first interface in declaration order without diagnosing; programs that exercise the conflict aren't in our corpus.
- **Abstract-member checking at construction time** — calling an unoverridden abstract member errors at call time, not at instantiation.

## Milestone 15 — Getters/setters + delegates *(done)*

Goal: Kotlin properties carry custom accessors (`get()` / `set(value)`) and may be backed by a delegate via `by`. Built-in delegates (`lazy`, `Delegates.observable`, `Delegates.notNull`) and user-written delegate classes both work, with byte-identical output to `kotlinc-native 2.3.21`.

### Shipped

- [x] **AST** (`klio-ast`): `Property` extended with `getter: Option<Accessor>`, `setter: Option<Accessor>`, `delegate: Option<Expr>`. New `Accessor { params, body, span }`. New `Expr::PropertyRef { name, span }` for `::foo`.
- [x] **Parser**: `parse_property` accepts `= init`, `by expr`, and trailing `get()` / `set(value)` blocks across newlines. Accessors support both expression bodies (`get() = …`) and block bodies (`get() { … }`). Setter parameter name is captured (defaults to `value`). `::name` is a primary-expression form producing `Expr::PropertyRef`.
- [x] **Runtime** (`klio-runtime`): `PropertyDef` carries `getter`, `setter`, `delegate`. New `Value::Delegate(Rc<RefCell<DelegateKind>>)` for built-in delegates (`Lazy` / `Observable` / `NotNull`). New `Value::PropertyRef { name }` exposing `.name` to delegate `getValue` / `setValue` callers.
- [x] **Interp**: instance and top-level property reads/writes route through delegate / custom-accessor dispatch when present, falling back to a plain backing field otherwise. The backing slot for `var foo: T = init` lives under the property's name; the delegate value lives under `__delegate$<name>`. Accessor bodies bind `this`, the instance's fields, `field` (current backing value), and (for setters) the setter parameter. Writes inside a setter that target `field` propagate back to the backing slot.
- [x] **Built-in delegates**: `lazy { producer }` produces a `DelegateKind::Lazy` — first read invokes the producer (captured lambda) and caches; subsequent reads return the cache. `Delegates.observable(initial, onChange)` stores the value and calls `onChange(prop, old, new)` on every write. `Delegates.notNull<T>()` throws `kotlin.IllegalStateException` with the kotlinc-native message `Property <name> should be initialized before get.` on read before first write. `Delegates` is recognized as a member receiver inline in `eval_call` — no synthetic class needed.
- [x] **User delegates**: any `Value::Instance` whose class declares `getValue` / `setValue` works. Operator-modifier enforcement is deferred — calls dispatch by name only, matching the M9 / M13 pattern of being lenient on modifiers we don't yet model.
- [x] **`::name`**: evaluates to `Value::PropertyRef { name }` carrying just enough metadata for delegate callers (`.name` returns the source-level identifier). Full `KProperty` reflection is deferred.
- [x] **Parity corpus**: `prop_custom_getter.kt`, `prop_getter_setter.kt`, `prop_field_in_setter.kt`, `prop_by_lazy.kt`, `prop_by_observable.kt`, `prop_by_notnull.kt`, `prop_user_delegate.kt` — all pass byte-identical against `kotlinc-native 2.3.21`.
- [x] **Example**: `examples/delegates.kt` exercises the full surface end-to-end.

### Deferred (tracked, not in scope for M15)

- **`lateinit var`** — similar in spirit to `Delegates.notNull` but carries a real backing field instead of a delegate object. Waits on the type checker to enforce non-nullability.
- **Full `KProperty` reflection** beyond `.name` — `KProperty1.get(receiver)`, parameter introspection, annotation listing, etc.
- **Accessor return-type annotations** (`get(): Int { … }`) — the parser consumes-and-ignores the `: Type` between `()` and the body.
- **`operator` modifier enforcement** on `getValue` / `setValue` — required by Kotlin but not checked yet; matches the wider M10–M14 stance on undeclared-modifier diagnostics.
- **Property delegation through interfaces / superclasses** — only direct `class Foo { var x by … }` shapes are wired; inheriting a delegated property hasn't been verified.

## Milestone 16 — Abstract classes / secondary ctors / inner classes *(done)*

Goal: `abstract class`, secondary constructors with `this(...)` / `super(...)` delegation, and `inner class` with outer-instance capture and `this@Outer` resolution, all parity-checked against `kotlinc-native 2.3.21`.

### Shipped

- [x] **AST** (`klio-ast`): `Class` extended with `is_abstract`, `is_inner`, `secondary_ctors: Vec<SecondaryCtor>`. `Function` and `Property` extended with `is_abstract`. New `SecondaryCtor { params, delegation, body }` plus `CtorDelegation = This(args) | Super(args) | None`. `Expr::This` carries an optional `qualifier: Option<Ident>` to model `this@Label`.
- [x] **Parser**: `abstract` and `inner` flow through the modifier pipeline; `abstract` implies `open`. Secondary constructors are detected inside `parse_class_body` by the leading `constructor` keyword and parsed via `parse_secondary_ctor` — params reuse the regular param-list shape, the `: this(args)` / `: super(args)` delegation header is parsed into `CtorDelegation`, and the optional `{...}` body is captured. `this@Outer` parses as `Expr::This { qualifier: Some(...) }`.
- [x] **Runtime** (`klio-runtime`): `ClassDef` carries `is_abstract`, `is_inner`, `secondary_ctors`, and `nested_classes: RefCell<Vec<(String, Rc<ClassDef>)>>`. `MethodDef` / `PropertyDef` carry `is_abstract`. `InstanceData.outer: Option<Value>` stores the captured outer-instance for `inner class` instances. New `Value::BoundInnerClass { class, outer }` represents an inner class navigated through a specific outer (e.g. `o.Inner`); calling it constructs with `outer` populated.
- [x] **Interp**:
  - `construct_instance_with_outer` rejects `abstract` / `interface` instantiation with `kotlin.InstantiationError`, then picks primary vs secondary by arity. Secondary constructors run via `run_secondary_ctor`: bind the secondary's params, follow the delegation chain to the primary (init blocks run *once*, at primary), and finally execute the secondary's body in a child env so secondary-param values aren't shadowed by body-property defaults.
  - Inner classes: `outer.Inner` produces `Value::BoundInnerClass`; constructing it stamps `InstanceData.outer = Some(outer)`. Inside an inner-class method frame the interp binds `this@<OuterName>` to the captured outer and lifts outer fields into the frame so unqualified reads succeed; writes fall through to the outer instance (or further up the chain) so `count = count + 1` inside an inner method mutates the outer's state.
  - Plain (non-`inner`) nested classes are reachable as `Outer.Nested(...)`; inner classes are reachable as `outer.Inner(...)` or bare `Inner(...)` inside an outer method (the frame binds the name to a `BoundInnerClass` value).
  - Abstract body properties (`abstract val name: String`) get *no* backing-field write during construction, so a concrete subclass's primary-ctor property (`override val name`) isn't clobbered by the parent's body initializer.
- [x] **Parity corpus**: `abstract_basic.kt`, `abstract_property.kt`, `secondary_ctor_this_delegation.kt`, `secondary_ctor_init_order.kt`, `secondary_ctor_super_delegation.kt`, `inner_class_basic.kt`, `inner_class_outer_access.kt`, `nested_vs_inner.kt` — all pass byte-identical against `kotlinc-native 2.3.21`.
- [x] **Example**: `examples/abstract_inner.kt` exercises abstract-class polymorphism, primary-ctor `override val`, and an outer/inner pairing where the inner method composes outer + inner state.
- [x] **Unit tests** (`klio-interp`): `abstract_class_cannot_be_instantiated_directly`, `secondary_ctor_delegating_this_runs_init_once`, `inner_class_captures_outer`, `inner_class_this_at_outer`.

### Deferred (tracked, not in scope for M16)

- **Static "missing abstract override" diagnostic**: kotlinc rejects a non-abstract subclass that doesn't implement every inherited abstract member at compile time. Today the runtime never observes such a program because parity programs always supply the override; if a malformed program slips through, the call to the abstract member errors at call time with `Unimplemented`. Wait for the resolver to walk supertypes.
- **Abstract-instantiation parity corpus entry**: kotlinc rejects `Shape()` for an abstract `Shape` at compile time, so a parity program can't reach the runtime check. The runtime path is covered by a unit test (`abstract_class_cannot_be_instantiated_directly`) instead.
- **Local classes inside functions** and **anonymous object expressions** (`object : Foo() { … }`) — deferred to a later milestone.
- **`companion object` with a custom name** — the no-name form remains the only shape we wire.
- **Inner-class outer-method dispatch** for fully qualified `this@Outer.method()` — `this@Outer` resolves to the outer instance and member access works via the regular property/method-call path. A targeted parity program for that exact spelling hasn't been added.

## Milestone 17 — Anonymous objects + local classes *(done)*

Goal: anonymous `object { … }` expressions (including `object : Parent(args), Iface { … }`) and classes declared inside function bodies. Both capture the enclosing scope for method-body access. Parity-checked against `kotlinc-native 2.3.21`.

### Shipped

- [x] **AST** (`klio-ast`): new `Expr::ObjectExpr { supertypes, supertype_args, members, span }`. Local classes reuse the existing `Stmt::Decl(Decl::Class(...))` — no new node.
- [x] **Parser**: `parse_primary` recognizes `object` at expression position and emits `Expr::ObjectExpr`. `parse_stmt` branches on `class` / `interface` (with the full modifier pipeline — `data`, `enum`, `sealed`, `open`, `abstract`, `inner`) and on named `object Foo { … }` (local singleton). `parse_optional_supertypes` and `parse_class_body` now leave statement-terminating newlines in place when a class declaration has no `:` clause or `{}` body, so a local `class Foo(val x: Int)` followed by `val y = …` parses cleanly.
- [x] **Interp**: `Expr::ObjectExpr` synthesizes a fresh `klio_ast::Class`, builds the `ClassDef` against the *current* evaluation env (so method bodies close over enclosing locals via the existing `captured_env` chain), resolves parent links, and constructs a single instance through `construct_instance` — so `: Parent(ctorArgs)` naturally drives the parent ctor chain. Local classes already worked: `Stmt::Decl(Decl::Class)` in `eval_stmt` calls `build_class(c, env, …)` with the current frame env as `captured_env`, and closure semantics fall out for free.
- [x] **Resolver**: `resolve_expr` gained an `ObjectExpr` arm that walks supertype ctor args and member declarations. No new symbol kinds.
- [x] **Parity corpus**: `anon_object_basic.kt`, `anon_object_with_interface.kt`, `anon_object_with_parent.kt`, `anon_object_capture.kt`, `local_class_basic.kt`, `local_class_capture.kt`, `local_class_in_method.kt`, `local_class_data.kt` — all pass byte-identical against `kotlinc-native 2.3.21`.
- [x] **Example**: `examples/anon_local.kt` — anonymous object returned from a function, plus a local class capturing a `factor` local.
- [x] **Unit tests** (`klio-interp`): `anonymous_object_basic_expression`, `anonymous_object_implements_interface`, `anonymous_object_extends_parent_with_args`, `anonymous_object_captures_enclosing_local`, `local_class_basic`, `local_class_captures_enclosing_local`, `local_data_class`, `local_class_inside_method`.

### Deferred (tracked, not in scope for M17)

- **SAM conversion** (passing a lambda where a fun-interface / single-abstract-method type is expected). Anonymous objects are the workaround.
- **Generic local classes** (`class Foo<T> { … }` inside a function). The parser strips type parameters already but no machinery is wired.
- **`toString()` of an anonymous object** — kotlinc-native synthesizes a name (`<no name provided>` etc.). The corpus avoids `.toString()` on an anonymous-object instance so byte-identical output doesn't depend on that spelling; a future milestone can pin the format.
- **Qualified `this@<EnclosingFun>`** — local-class methods read enclosing-function locals by bare name (captured env), so the qualified spelling isn't exercised yet.

## Milestone 18 — Stdlib remainder & polish *(done)*

Goal: broaden the most-used stdlib surface so real Kotlin programs run end-to-end. Parity-checked against `kotlinc-native 2.3.21`.

### Shipped

- [x] **List / MutableList**: `firstOrNull`, `lastOrNull`, `single`, `singleOrNull`, `flatten`, `unzip`, `containsAll`, `withIndex`, `toList`, `toMutableList`, `toSet`, `toMutableSet`, `count` (no-pred), `set(i, v)`, `addAll`, `remove(elem)`, `removeAll`, `retainAll`. Indexed higher-order ops `mapIndexed`, `forEachIndexed`, `filterIndexed` in the interp dispatcher.
- [x] **Set / MutableSet**: `containsAll`, `toList`, `toMutableList`, `toSet`, `toMutableSet`, `withIndex`, `count`, `addAll`.
- [x] **Map / MutableMap**: `getOrDefault`, `getValue`, `toList`, `count`, `putAll`, `set` (operator form). Lambda-bearing variants — `filterKeys`, `filterValues`, `mapKeys`, `mapValues`, `getOrElse`, `getOrPut`, `forEach` — wired through the interp.
- [x] **String**: `substringBefore`, `substringAfter`, `substringBeforeLast`, `substringAfterLast`, `replaceFirst`, `trimIndent`, `trimMargin`, `lines`, `toCharArray`, `toLong`, `toLongOrNull`, `toDoubleOrNull`, `toBoolean`, `toBooleanStrictOrNull`.
- [x] **Char**: `uppercaseChar`, `lowercaseChar`, `digitToIntOrNull`.
- [x] **Int**: `coerceIn`, `coerceAtLeast`, `coerceAtMost`, `toChar`.
- [x] **Math**: `asin`, `acos`, `atan`, `atan2` (on top of existing floor/ceil/round/sin/cos/exp/ln/log/sqrt/pow/hypot/sign/abs).
- [x] **Ranges (IntRange / IntProgression)**: `reversed`, `toList`, `count`, `sum`.
- [x] **Pair**: `toList`.
- [x] **Top-level lambda helpers** (in interp): `repeat(n) { i -> … }`, `require(cond) { msg }`, `check(cond) { msg }`, `error(msg)`, `checkNotNull(x) { msg }`, `requireNotNull(x) { msg }`, `TODO(reason?)`.
- [x] **Parity corpus** (all byte-identical against `kotlinc-native 2.3.21`): `stdlib_list_ops.kt`, `stdlib_list_indexed.kt`, `stdlib_map_ops.kt`, `stdlib_string_ops.kt`, `stdlib_char_ops.kt`, `stdlib_math.kt`, `stdlib_ranges.kt`, `stdlib_assertions.kt`.
- [x] **Example**: `examples/stdlib_broad.kt` exercises the broadened surface end-to-end; indexed in `examples/README.md`.
- [x] **Unit tests** (`klio-stdlib`): `string_substring_before_after`, `list_first_or_null_handles_empty`, `list_single_throws_when_multi`, `map_get_or_default_falls_back`, `int_coerce_in_range_and_pair`, `string_lines_splits_on_all_line_separators`.

### Deferred (tracked, not in scope for M18)

- **Regex** (`Regex`, `Pattern`, `replace(Regex)`, `split(Regex)`, `Regex.find`): full text surface gets its own milestone.
- **`Result<T>` + `runCatching`**: needs a new runtime value variant or a synthesized class; left for when the resolver can model `Result` cleanly.
- **`Triple<A, B, C>`**: new runtime variant; one-off for now, surfaces in too few real programs to justify the variant.
- **`Array<T>` and primitive `IntArray` / `DoubleArray` / `BooleanArray` / `CharArray`**: needs a dedicated `Value::Array` variant and index-assign desugaring (`xs[i] = v` is not yet parsed as `Index` LHS). Collection ops cover the most-used surface already.
- **`Sequence.withIndex` / `mapIndexed` lazy**: the eager List route already covers parity for deterministic programs; full lazy `Sequence` versions queued.
- **`StringBuilder`**, `String.format`, `kotlin.text.format`: queued behind regex.
- **`Comparator.naturalOrder()` / `reverseOrder()`**: `compareBy` / `thenBy` / `reversed` already cover the in-corpus shapes.
- **`Int.toString(radix)` / `String.toInt(radix)`**: named-arg threading through the radix parameter into the intrinsic isn't wired; deferred.
- **Text deep-dive**: full `kotlin.text` (regex flavors, formatting, case mapping incl. `_OneToManyTitlecaseMappings.kt`), `StringBuilder` parity — promoted to its own milestone.
- **Unsigned**: `UInt`, `ULong`, `UByte`, `UShort` and their array/range/collection variants (`_UArrays`, `_UCollections`, `_URanges`, `_USequences`) — its own milestone.
- **Reflection-lite**: just enough of `kotlin.reflect` to flesh out `::` references and `KClass` identity for richer examples — its own milestone.
- **Coroutines / time / IO**: scoped to what example programs and the test corpus actually exercise; full coroutine machinery is a separate later milestone.

## Milestone 19 — Type checker *(done)*

Goal: a flow-insensitive static type checker that rejects clearly wrong programs while leaving every parity-corpus program runnable.

### Shipped

- [x] **New crate** `klio-typeck` (separate crate, not nested inside `klio-types`, to avoid a circular dep: the checker reads `Resolution` and `klio-resolver` already depends on `klio-types`). Houses the `TypeChecker` (`crates/klio-typeck/src/check.rs`) with scope-stack frames, smart-cast narrowings, a `Span -> Type` side table, and a diagnostic sink. Public entry point: `typecheck(&KotlinFile, &Resolution) -> TypeCheck`.
- [x] **Pipeline wiring** in `klio-cli`: `parse -> resolve -> typecheck -> interp`. `klio run` aborts on type-check failure; `klio check` aggregates type-check diagnostics with the lexer/parser/resolver ones.
- [x] **Type representation** reuses `klio_types::Type` (already has `Unit`, `Nothing`, `Any`, the eight primitive numerics, `Boolean`, `Char`, `String`, `Nullable`, `Function`, `Range`, `Unresolved`). `Unresolved` doubles as the `Error` propagation sentinel: it's compatible with everything in `is_subtype_of`, so cascading false positives die quietly.
- [x] **Expression typing**: literals (with integer-literal-fits-Long context inference), string templates, binary ops (`+` overloaded for String concat and numeric LUB; `-/*//%` numeric; relational/equality → Boolean; `&&`/`||` → Boolean; `..`/`..<` → `Range`; Elvis with LUB), unary (`-/+`, `!`, `++`/`--`), `if`/`when`/`try` as expressions producing branch LUB, `for`/`while` → Unit, `return`/`throw`/`break`/`continue` → Nothing, lambdas, `is`/`as`/`?.`/`!!`, member access, calls.
- [x] **Declaration typing**: top-level `fun` signatures forward-declared so mutual recursion typechecks; classes get a `ClassInfo` table seeded before bodies; primary-ctor params with `val`/`var` become member properties; secondary ctors relax primary-arity checks on call sites.
- [x] **Smart casts**: `if (x != null) { … }`, `if (x is T) { … }`, negation, `&&` / `||` short-circuit narrowings — flow-insensitively scoped to the true/false-branch frames via a `narrowings` overlay map. Smart cast applies only to local bindings (frame entries), not class fields.
- [x] **Diagnostics**: legacy codes `T0001..T0008` (`TYPE_MISMATCH`, `TYPE_UNRESOLVED_REFERENCE`, `TYPE_NULL_SAFETY`, `TYPE_ARGUMENT_COUNT`, `TYPE_MISSING_RETURN`, `TYPE_VAL_REASSIGN`, `TYPE_ABSTRACT_MEMBER_NOT_IMPLEMENTED`, `TYPE_WRONG_RECEIVER`). Messages echo the spirit of `kotlinc` output without being byte-identical.
- [x] **Abstract-member implementation check**: a concrete subclass of one of our `abstract class` / `interface` declarations that fails to provide all abstract members emits `T0007` at compile time instead of trapping the runtime.
- [x] **Tests**: 17 unit tests in `klio_typeck::check::tests`, 6 negative `.kt` programs under `crates/klio-typeck/tests/negative/` exercising each emitted code, and a corpus-sweep test (`tests/corpus_sweep.rs`) that runs the checker over every parity-corpus and `examples/` program and asserts no hard errors. All 100 corpus programs and 14 examples type-check clean.

### Deferred

- Declaration-site / use-site variance (`in T` / `out T`); generic bound checking (`T : Comparable<T>`); inline/reified/crossinline.
- Full inference for generic call chains (`listOf(1).map { it * 2 }.fold(0) { a, b -> a + b }`). The checker falls back to `Type::Unresolved` for any callee it can't introspect (the vast stdlib surface), so these programs type-check by accepting `Unresolved` everywhere.
- Receiver-style extension function resolution; named-argument reorder + first-fit overload resolution; definite-assignment for `var`; full member-access lookup against class subtypes (today the checker silently returns `Unresolved` for `instance.member`).

### Surprises / corpus relaxations

- The resolver already emits `R0001 Unresolved reference` for every stdlib symbol (`listOf`, `map`, …) because we have no global symbol table at resolve time. The interp resolves them dynamically. To keep `klio run` working on every corpus program, the type checker treats unresolved names as `Type::Unresolved` and propagates silently. Hard errors are reserved for unambiguous mistakes against locally-knowable shapes.
- Classes with secondary constructors skip primary-ctor arity enforcement at the call site (interp picks the matching overload).

### Verification

- `cargo test --workspace` — 39 test executables green, 0 failures.
- `cargo test -p klio-parity --test parity` — 2 passed (skipped where `kotlinc-native` is unavailable, the project's documented offline path).
- `cargo test -p klio-typeck` — 17 + 6 + 2 = 25 tests green (unit + negative + corpus sweep).

## Milestone 20 — Deferred cleanup batch *(done)*

Goal: clear a backlog of small deferred items from M10–M18 without expanding the surface meaningfully. Every item ships with at least one parity-corpus program and (where it applies) negative type-checker tests.

### Shipped

- [x] **Destructuring declarations outside `for`** (`val (a, b) = pair`). Parser emits a new `Stmt::DestructuringDecl`. The interpreter dispatches `componentN` on `Pair`, `Triple`, `MapEntry`, `List`/`Set`, and on user instances (data-class auto-`componentN`, or user-declared). Underscore is a discard. Parity programs: `destructure_pair.kt`, `destructure_triple.kt`, `destructure_data_class.kt`, `destructure_underscore.kt`.
- [x] **`in` / `!in` as general binary expressions outside `when`** (`x in 1..10`, `5 !in xs`). New `BinOp::In` / `BinOp::NotIn` at comparison precedence, threaded into the existing `value_in` helper (`Range`, `List`/`Set`/`Map`, `String`/`Char`). Parity programs: `in_binary_expr.kt`, `not_in_binary_expr.kt`.
- [x] **Custom-named `companion object Foo { … }`**. Parser already accepted it; the interp now exposes the companion at both `Outer.member` (unchanged) and `Outer.Foo` (returns the companion instance). Parity program: `companion_named.kt`.
- [x] **`Triple<A, B, C>`**. New `Value::Triple` variant mirroring `Pair` through Display/Debug/`type_fqn`/`is_runtime_type`/`structural_eq`. Stdlib intrinsics: `Triple(a,b,c)` constructor, `.first/.second/.third`, `.toString` (`(a, b, c)`), `.toList`. Destructuring routes through the M20 #1 path. Parity programs: `triple_basic.kt`, `triple_destructure.kt`.
- [x] **`Int.toString(radix)` / `String.toInt(radix)`**. Both honor the optional `radix` argument (range `2..36`, otherwise `IllegalArgumentException`). `String.toInt` throws `NumberFormatException` on parse failure to match kotlinc-native. Parity programs: `int_tostring_radix.kt`, `string_toint_radix.kt`.
- [x] **`naturalOrder<T>()` / `reverseOrder<T>()`**. Top-level intrinsics returning a `Value::Comparator` with an empty step chain; the interp's `sortedWith` and the sequence `SortedWith` path special-case empty-steps as "compare items directly via the natural order". Parity program: `comparator_natural_reverse.kt`.
- [x] **Soft override diagnostics in the type checker.** New codes `T0009 OVERRIDE_NEEDED`, `T0010 OVERRIDE_BUT_PARENT_NOT_OPEN`, `T0011 OVERRIDE_BUT_NO_BASE`. The checker walks `supertypes` transitively, gathers per-member `(is_open, is_override, is_abstract)` flags from each parent (interface members and abstract members are implicitly `open`; an `override` member is itself open for diagnostic purposes since we don't model `final`), and compares against each function declared on the subclass. Well-known names that derive from built-in shapes (`toString`/`equals`/`hashCode`/`compareTo`/…) are exempted from the no-base diagnostic since their bases live outside the user table. Negative tests: `neg_override_needed.kt`, `neg_override_no_base.kt`, `neg_override_parent_not_open.kt`.
- [x] **`this@Outer.method()` parity coverage.** The M16 implementation already supported it; the corpus now proves it: `inner_this_at_outer_method.kt`.

### Surprises / new deferrals

- Property `override` modifiers don't round-trip through the AST (`Property` / `ClassParam` carry no `is_override` flag), so the override diagnostics restrict themselves to `Decl::Function`. Promoting `override` to a property-level AST flag is queued as a small follow-up.
- The conventional call shape `Comparator.naturalOrder<Int>()` from some Kotlin tutorials maps to top-level `naturalOrder()` in `kotlin.comparisons` against `kotlinc-native`. The corpus uses the top-level form to stay byte-identical; the stdlib also registers the dotted `Comparator.naturalOrder` aliases so the older spelling keeps working in the interp.

### Verification

- `cargo build` clean.
- `cargo test --workspace` — 39 test executables green, 0 failures.
- `cargo test -p klio-parity --test parity` — 2 tests green (110 parity-corpus programs + 14 examples byte-identical against `kotlinc-native 2.3.21`).

## Milestone 21 — Mid-tier deferred cleanup *(done)*

Goal: clear a batch of medium-sized items left over from M9, M15, M18, M19, M20 without expanding language surface meaningfully. Every shipped item carries at least one parity-corpus program against `kotlinc-native 2.3.21`.

### Shipped

- [x] **Property `override` round-trip** (M20 follow-up). `Property.is_override` joins the AST; the parser sets it from the modifier pipeline; the type checker generalizes T0009/T0010/T0011 to properties. Parity: `prop_override_in_subclass.kt`. Negative typeck: `neg_prop_override_needed.kt`.
- [x] **`lateinit var`** (M15 deferred). `lateinit` joins `ModifierFlags`; `Property.is_lateinit` and `PropertyDef.is_lateinit` carry the flag through to the runtime. Uninitialized slots are seeded with a private sentinel (`Value::Exception` keyed by a unique FQN); reads at every property-read site detect the sentinel and throw `kotlin.UninitializedPropertyAccessException("lateinit property <name> has not been initialized")`. Writes overwrite the sentinel. `exception_matches` learned the `RuntimeException`-subtypes table so `catch (e: RuntimeException)` catches the lateinit throw. Parity: `lateinit_basic.kt`, `lateinit_throws_before_init.kt`. The deferred primitive-type / `lateinit val` rejection in the type checker was not landed in this milestone — see below.
- [x] **Named-arg reordering for arbitrary intrinsics** (M9 deferred). The single source of truth was already in place — `reorder_intrinsic_args` consults `klio_stdlib::param_names` at every intrinsic dispatch site. M21 extends `PARAM_NAMES` with entries for `String.indexOf`/`lastIndexOf`/`contains`/`startsWith`/`endsWith`/`toInt`/`toIntOrNull`, `Int.toString`, `Set.joinToString`, `MutableSet.joinToString`, `IntRange.joinToString`, `IntProgression.joinToString`, `Map.getOrDefault`, `MutableMap.getOrDefault`, `List.sortedWith`, `MutableList.sortedWith`, and `Result.getOrDefault`. Parity: `named_args_chunked.kt`, `named_args_windowed.kt`, `named_args_sortedwith.kt`, `named_args_associate.kt`.
- [x] **`Result<T>` + `runCatching`** (M18 deferred). New `Value::Result { ok, payload }` mirrors `Pair`/`Triple` through Display/Debug/`type_fqn`/`is_runtime_type`/`structural_eq`. `Result.success(x)` / `Result.failure(e)` are recognized as static factories in `eval_call`. Intrinsic table: `Result.isSuccess`, `Result.isFailure`, `Result.getOrNull`, `Result.exceptionOrNull`, `Result.getOrDefault`, `Result.toString`. Lambda-bearing members live in the interp's `try_eval_result_member`: `fold`, `map`, `mapCatching`, `onSuccess`, `onFailure`, `getOrElse`. `runCatching { … }` and `T.runCatching { … }` invoke the lambda and turn `RuntimeError::Thrown` into `Result.failure(e)`. Parity: `result_basic.kt`, `result_run_catching.kt`, `result_fold.kt`.

### Dropped — promoted to backlog with documented scope

- **Generic inference for stdlib call chains** (M19 deferred). The proposed intrinsic-signature table risked silent corpus regressions if any rule didn't generalize. Promoted to the backlog as part of "Type-checker depth".
- **`Array<T>` + primitive arrays + index-assign LHS** (M18 deferred). The largest item in the batch — new `Value::Array` variant, primitive-array constructors, member surface, parser change for `xs[i] = v` LHS. Promoted to the backlog with the scope unchanged.

### Surprises

- The parity harness picks up `kotlin-native-prebuilt-macos-aarch64-2.3.21` automatically when it's installed locally; the M21 work was developed against a live `kotlinc-native` for cross-checking. The corpus stayed byte-identical.
- `UninitializedPropertyAccessException` is marked `internal` in Kotlin/Native — the corpus catches as `RuntimeException` to stay byte-identical with `kotlinc-native`, and the interpreter's `exception_matches` learned the broader `RuntimeException`-subtype table to make that work.
- `Result.mapCatching` catches division-by-zero in Kotlin/Native — its message is `null`, matching klio's behavior. The fold/runCatching corpus avoids exception-message comparisons where Native and JVM diverge.

### Verification

- `cargo build` clean.
- `cargo test --workspace` green.
- `cargo test -p klio-parity --test parity` — 2 tests green (corpus now 122 programs + 14 examples byte-identical against `kotlinc-native 2.3.21`).

## Backlog — larger milestones (not yet scheduled)

Each entry below is queued for a future milestone. One-line scope; promoted to a full milestone block when picked up.

- **Regex** — `Regex`, `Pattern`, `Regex.find`, `Regex.findAll`, `Regex.matchAt`, `String.split(Regex)`, `String.replace(Regex)`, `MatchResult`/`MatchGroup`. New runtime variant; integrate Rust's `regex` crate.
- **`StringBuilder` + `String.format` + `kotlin.text` deep-dive** — full mutable string buffer, printf-style formatting, case-mapping `_OneToManyTitlecaseMappings`, escape/quote helpers.
- **Unsigned types** — `UInt` / `ULong` / `UByte` / `UShort` + their array / range / collection variants. Likely new `Value` variants and operator overloads.
- **SAM conversion** — passing a lambda where a `fun interface` / single-abstract-method type is expected. AST flag on the interface, type-checker bridging, interp adapter.
- **Reflection-lite** — `KClass`, `KProperty1.get(receiver)`, `KFunction.call(...)`, `::ClassName`, `instance::method`. New runtime values + a minimal reflection table.
- **Coroutines / time / IO** — `suspend fun`, `launch`/`async`/`runBlocking`, structured concurrency, `Duration`/`DurationUnit`, basic file/stdin I/O beyond `readLine`. Far-future, large surface.
- **Variance + generic bounds** — declaration-site `in T`/`out T`, use-site projections, `T : Comparable<T>` upper bounds, where-clauses, reified.
- **Sequence (true lazy)** — `Sequence<T>` with lazy iterator semantics; `generateSequence`, `sequence { yield … }` builder (requires coroutine machinery).
- **Comparator full surface** — `compareBy`/`thenBy`/`thenComparator`/`reversed`/`then`/`compareValuesBy` — most exist; tighten edge cases.
- **Type-checker depth** — member-access lookup on class subtypes (currently silent `Unresolved`), receiver-style extension function resolution, definite-assignment for `var`, full first-fit overload resolution, generic inference for stdlib call chains (deferred from M19 / M21).
- **`Array<T>` + primitive arrays + index-assign LHS** — new `Value::Array` variant with primitive-array tag, `arrayOf` / `IntArray` / `DoubleArray` / `BooleanArray` / `CharArray` / `LongArray` constructors, `.size` / `[i]` / `[i] = v` / `.indices` / `.lastIndex` / `.toList()` / iteration, and the parser change to recognize `xs[i] = v` as an assignment with an `Expr::Index` LHS. Deferred from M18 / M21.
- **`lateinit` type-checker rules** — reject `lateinit val`, reject `lateinit` on primitive types (`Int`, `Long`, `Double`, `Boolean`, `Char`) at compile time to match `kotlinc`. Deferred from M21; the runtime currently allows these forms and they only fail when read.

## Milestone 25 — Regex + `kotlin.text` deep-dive *(done)*

- **`kotlin.text.Regex`** — new `Value::Regex` variant wraps a Rust `regex::Regex` plus the source pattern. Surface: ctor, `pattern`, `toString`, `matches`, `containsMatchIn`, `find`, `findAll` (returns `Sequence<MatchResult>`), `matchEntire`, `matchAt`, `matchesAt`, `replace`, `replaceFirst`, `split(input[, limit])`. Companion statics: `Regex.escape` (returns Kotlin's `\Qx\E` form), `Regex.fromLiteral`, `Regex.escapeReplacement`. `String.split(Regex)` and `String.replace(Regex, replacement)` recognized at the existing String-member dispatch.
- **`MatchResult` / `MatchGroup`** — `Value::Match` and `Value::MatchGroup` variants with `value`, `range`, `groupValues`, `groups`, and `next()`. `for (m in regex.findAll(s))` now iterates a `Sequence<MatchResult>` via the new for-loop arm that materializes a Sequence and the new String arm that yields chars.
- **`\Q...\E` literal blocks** — preprocessing in `compile_regex` expands Java-style literal blocks into per-character `regex::escape`d output before handing the pattern to Rust's regex engine. Lets `Regex.fromLiteral` and any user pattern with `\Q...\E` work even though Rust's `regex` crate doesn't natively support that syntax.
- **`kotlin.text.StringBuilder`** — `Value::StringBuilder(Rc<RefCell<String>>)` with `append` (variadic overloads via `Any?`), `appendLine`, `length`, `toString`, `get(i)`, `isEmpty`, `isNotEmpty`, `clear`, `insert(idx, value)`, `deleteAt`, `deleteRange`, `setLength`, `reverse`, `substring`. `StringBuilder()` / `StringBuilder("seed")` / `StringBuilder(capacity)`.
- **`String.format` / `kotlin.text.format`** — printf-style formatter covering `%[flags][width][.precision]conv` with d/i/x/X/o/s/S/c/C/b/B/f/e/E/g/G/%/n, flags `-`, `0`, `+`, ` `, `#`, `,`, and `n$` argument-index reordering. Implementation is parity-tested by unit tests only — Kotlin/Native 2.3.21's stdlib does not expose `String.format`, so no kotlinc-native parity program is possible for this surface.
- **Char title-case helpers** — `Char.titlecase` / `Char.titlecaseChar` (approximated as `uppercase()` for the majority of characters; the four diacritic-ligature `Lt` codepoints fall through to the same path).
- **Corpus + examples** — `regex_basic.kt`, `regex_groups.kt`, `regex_split_replace.kt`, `regex_escape.kt`, `string_builder.kt`, `string_builder_substring.kt` under `crates/klio-parity/tests/corpus/`; `examples/regex.kt`, `examples/string_builder.kt`. All parity-validated byte-identical against kotlinc-native 2.3.21.

## Milestone 28 — Variance + generic bounds *(done)*

Generic surface lifted from "parsed-and-discarded" to first-class. New AST: `Variance`, `TypeParam` (with `is_reified` + optional `upper_bound`), `WhereBound`, `TypeArg`. Parser captures all forms — declaration-site `<out T : Foo>`, multi-bound `where T : Foo, T : Bar`, use-site projections (`List<out Any>`, `MutableList<in Int>`, star `*`), `vararg` / `crossinline` / `noinline` parameter modifiers, `inline fun` flag, and explicit call-site type args (`foo<String>(...)`). The type model gained `Type::TypeParam` and `Type::Generic { name, args: Vec<GenericArg> }`; `is_subtype_of` applies use-site variance (covariant for `out`, contravariant for `in`, equality otherwise). The type checker emits T0023 (`reified` outside `inline fun`), T0024 (declaration-site variance violation: `out T` in input position or `in T` in output position of a member function), T0025 (multiple `vararg` params or non-defaulted parameter trailing a `vararg`), and T0026 (`crossinline` / `noinline` outside `inline fun`). Reified runtime: `Interpreter` carries a `reified_stack: Vec<HashMap<String,String>>`; `eval_call` pushes a frame for `inline fun`s with explicit call-site type args, and `Expr::IsCheck` / `T::class` resolve through the frame. User-defined generic classes still convert to `Type::Unresolved` for parity safety; T0021 (use-site variance enforcement at assignment) and T0022 (call-site bound enforcement) are deferred to follow-ups along with vararg call-site array packing. Parity corpus + examples: `variance_out.kt`, `variance_in.kt`, `upper_bound.kt`, `where_clause_multi.kt`, `use_site_projection.kt`, `reified_isinstance.kt`, `inline_lambda_param.kt` under `crates/klio-parity/tests/corpus/`; `examples/variance.kt`, `examples/bounds.kt`, `examples/reified.kt`, `examples/inline_modifiers.kt` mirror them. Negative-corpus T0023..T0026 added to `crates/klio-typeck/tests/negative/`.

## Milestone 22+ — TBD

Picked from the backlog as scope clarifies. Each gets its own milestone block when started.

## Working agreements

- Land milestones via small PR-sized changes; keep `main` always green.
- Drive design of non-trivial subsystems with role-based adversarial agents (e.g. *Language Designer*, *Compiler Programmer*) before implementing.
- Update this document at the end of every working session: tick boxes, add discoveries, retire stale items.

## Testing discipline (applies to every milestone)

Every language feature we add must ship with **comprehensive** tests, not just one happy-path check. For each feature:

1. **Unit tests** in the owning crate covering: success paths, all spec-listed edge cases, and every diagnostic the code can emit.
2. **End-to-end tests** that drive the full pipeline (`lexer → parser → resolver → interpreter`) and assert observable behavior — stdout, return values, diagnostics with their codes — not just "didn't panic."
3. **A growing `.kt` corpus.** Per-crate snapshot corpora (e.g. `crates/klio-lexer/tests/corpus/`) and, once the interpreter can run programs, a workspace-level corpus of runnable `.kt` programs with expected output. The corpus only grows; we never delete a passing program when adding a feature.
4. **Complex features especially.** String templates, smart casts, `when` exhaustiveness, lambdas with non-local returns, generics + variance, coroutines — these get extra scrutiny: tests across many concrete shapes, plus negative tests for the error paths.

A feature is not "done" if removing or breaking it would leave the test suite green.

## Example programs (applies to every milestone)

Maintain a growing set of runnable `.kt` programs under `examples/` (indexed by `examples/README.md`). Rules:

1. **One example per new feature, minimum.** When a feature lands, add an example (or extend an existing one) that demonstrates the feature end-to-end via `cargo run -p klio-cli -- run examples/<name>.kt`.
2. **Deterministic output.** Every example must print stable output so we can wire it into an end-to-end test harness later.
3. **Examples never regress.** Once an example runs cleanly, future milestones must keep it running. If a milestone requires changing a program's expected output, update both the program and any harness in the same change.
4. **Keep the index honest.** `examples/README.md` lists every example and the features it exercises.

---

## Campaign log archive (2026-08-16 register reconciliation)

The 2026-08-16 plan-register reconciliation made `open-campaigns.md`
the single live register. The finished campaign docs below stay in
place as logs and are indexed here; the closed campaign records that
lived inline in `open-campaigns.md` and `worklist.md` are moved here.

### Finished campaign docs

| doc | outcome | closed |
|---|---|---|
| `bytecode-vm-plan.md` | Bytecode tier complete and fused (jump/br/cmp_br streams, counted range loops); loop shapes 10-13x JIT-off vs JIT-on, fib 1.9x; the next lever it names became the Value-layout campaign | — |
| `ci-green.md` | Shard serialization + wall-cap hang tooling landed; its in-flight items were all root-fixed by later work; the census duty continues in `simplify-validate-accelerate.md` Track V | — |
| `compose-dirty-bits-plan.md` | Per-param $changed/$dirty calculus landed; checkboxLike slot-exact; plugin ratchet floor 1340 -> 1370 | 2026-08-15 |
| `compose-plugin-lowering.md` | The plugin cutover LANDED — the lowering pass is the only compose path, the implicit-composer hook and its gate are deleted (8835dfc8); conformance ratchet floor 1370 | 2026-08-16 |
| `CPU-EFFICIENCY-CAMPAIGN.md` | Loop JIT (60-79x hot loops), dispatch inline caches + member-resolve cache, packed numeric arrays; residual named as the boxed-value interpreter floor, taken up by the later campaigns | — |
| `eager-resolution-plan.md` | Typeck-eager lowering landed; its goals were absorbed and completed by the resolution-unification and static-dispatch campaigns | — |
| `feedback-loop-plan.md` | Development loop fixed: material3 bake 302s -> 12s, warm pack load ~0.5s | — |
| `interpreter-perf-campaign.md` | Profile-guided perf rounds landed; the continuation is `simplify-validate-accelerate.md` Track A | — |
| `interpreter-performance-plan.md` | Flat-eval analysis; verdict "the target needs an execution-strategy change, not more tuning" — delivered as the bytecode tier | — |
| `klio-bundle-plan.md` | `klio bundle` landed and gated on Linux + macOS (signed Mach-O overlay, three itest suites); Windows remains a recorded drop-in extension point | — |
| `LANGUAGE-GAPS.md` | All tracked language gaps closed; pack-actual residuals recorded in the doc | — |
| `LAZY-IMAGE.md` | Per-decl lazy stdlib image flip landed (forest resolver, per-decl sections, empty baked forest); the RSS win is confirmed by the memory-parity targets | — |
| `loadglobal-member-fallback-audit.md` | Audit closed: one classification path for bare-name call lowering; the separate writeback lowerers deleted | — |
| `MEMORY-PARITY-CAMPAIGN.md` | All five memory-parity targets met (bare runtime 27MB, ktor start 49MB < node); deferred road: extend-model COPY -> DELEGATION rearchitecture | — |
| `PACK-ROADMAP.md` | Container format, binding registry, embedded stdlib, pack workflow CLI shipped; residual mmap-backed reader + cache-index hygiene recorded in the doc | — |
| `p2-applicability-design.md` | Shared applicability engine live in `src/ir/applicability.zig`; all four scoring callers flipped, legacy scorers removed | — |
| `p3-resolvecall-design.md` | `Module.resolveCall` is the live bare-call resolver; the ad-hoc lowering helpers are gone | — |
| `resolution-unification-plan.md` | Resolved-IR / one-engine build landed; trust KLIO_RESOLVE_AUDIT over the flaky canonical count | — |
| `static-dispatch-campaign.md` | Closed verified end to end at ZERO no_receiver_type rows (gate at 5dd6bd4a; plugin canonical 1336/46/0 vs ratchet 1305) | — |
| `worklist.md` (the ordered round) | Transpiler 16.6x rangebench round + native leaf-serve; compose suite long tail enumerated and mostly fixed; correctness items C1-C3 closed; concurrency perf round landed with the continuation open in the active plan. Full record below | 2026-08-16 |

### Transpiler + Value layout record (moved from open-campaigns.md §1)

- [x] Value 40 -> 24: RangeIter/Iterator folds; Range/BoundMethod/
      MapEntry/Triple/MatchGroup/Pair/Comparator/Result boxed; Intrinsic
      interned; Array repacked; dead AST-era variants deleted. Verified:
      sweep 117/0, ratchet 1339, rangebench neutral.
- [x] Hot-view sub-ABI landed + measured: +3.2% rangebench RF JIT-off at
      293/293 corpus parity (a14d89e2).

Handover note (Value=24 VERIFIED):

The whole 24B tier is done: Triple boxed, MatchGroup boxed (shared
descriptor struct), Intrinsic INTERNED (immortal records — no refcount,
no GC), Array REPACKED (the boxed/scalars tag was derivable from
`prim == null`, so the payload is (cell ptr, prim) with storage()
rebuilding typed handles). Census: Value 32 -> 24, NO payload >= 24.
rangebench 82.6s (band 83.0-83.7 — neutral/slightly better); units
zero-leak; hello smoke green. VERIFIED: sweep 117/0, corpus + compose slice at
baseline, litmus 43/44 (only the yield flake), plugin ratchet 1339
(ABOVE the 1337 baseline; the GC-stress step green).
16B wave state: Pair BOXED; dead AST-era variants (Function,
BoundUserMethod, BoundInnerClass) DELETED (net -74 lines, sweep 117/0).
Comparator BOXED (sweep 117/0), Result BOXED (units zero-leak). The
16B ENDGAME is now a recorded measured-first road, NOT the next step:
only IrClosure ({id u64, captures ValueSlice} — the side table already
keys canonical captures by id, so the payload could become the bare id
IF the per-value dup'd captures snapshot is semantically redundant —
verify against the closure invoke path before touching) and Array
remain at 16, both hot, and 24 -> 16 pays only if BOTH shrink. Measure
Value=24's own wins first (rangebench + suite wall vs the 40B-era
records). HOT-VIEW SUB-ABI LANDED (a14d89e2): the emitted C inlines
const_int/move/bin/cmp_br over the runtime-measured layout slot —
Int/Int + Long/Long + mixed-width promotion with applyBinop-exact
semantics, per-op helper fallback everywhere, gated on KV.usable
(computed from reclaimRequested; the live per-thread flag sampled too
early left the path dark — found via the layout probe). MEASURED:
rangebench RF JIT-off 13.38s native vs 13.82s interp = +3.2% at full
293/293 corpus parity. Honest reading: the fused stream was already
cheap, and the remaining per-iteration costs (edge guard, trace
bookkeeping) are SHARED with the interpreter — next recorded levers are
an inline trace store (frame.cur_span offset via the same probe
mechanism) and wider op coverage.

Earlier note (Value=32 landed, superseded above):

The Iterator fold landed (2a6e72f3): census Value 40 -> 32, units green
zero leaks, rangebench 83.0s (inside the pre-fold band), sweep 117/0,
corpus/litmus at the known baseline.

### Compose plugin triage record (moved from open-campaigns.md §2)

The doc's original checklist was stale: entries 43-47, the window
family, foundation_lazy, and serial_names are ALL FIXED (triage memory
54i/54j/54k + entry records; the 2026-08-15 corpus = the 3 interactive
permanents + lazy's Debug-CLI time cap + the animation load flake).

- [x] Local-ext-on-declared-builtin family FIXED (c3f3fc38 + 75a92601):
      the static subtype judgment learned the builtin collection
      hierarchy + the bare-type-param non-refuting rule (the deriver
      leaves factory type args unsubstituted — MutableList<T>).
      MovableContentTests 41 -> 42/44; ratchet 1338; guard example
      local_ext_declared_receiver.kt. Deeper channel recorded: the
      deriver should substitute call-site type args.
- [x] anchorIndex-on-MutableList FIXED: nested splice-window hole —
      a lambda spliced from inside another spliced lambda (let inside
      fastForEach's action) records a caller window whose region
      includes the OUTER inline fn's receiver bind, so bare `this`
      resolved to the outer splice receiver (`scopes`) instead of the
      class instance. Fix: `splice_hidden_bands` stack on FuncBuilder —
      every active window registers its hidden `[caller_depth,
      own_base)` band and the windowed caller scan skips enclosing
      bands. MovableContentTests 42 -> 44/44. NOTE: the wrong spliced
      code lowers in EVERY context but is live only via the pack-loaded
      module (test-file lowering ran an alternate emission), so
      standalone repros pass pre-fix — in-situ probe (println in
      SlotTable.kt + pack rebuild) was the discriminator.
- [x] GroupSizeValidationTests 2 -> 4/5: two roots.
      (a) file-private classifier refutation — staticReceiverCompatibility
      resolved an unqualified declared head (`Modifier`) module-wide
      (unique-name = null, or the wrong package's namesake), refuting the
      right overload; now resolves in the DECLARATION's file scope
      (exact import, then decl-package FQN — the mangled `$fN` class's
      fqn stays clean — then classIdIndexed). (b) the plugin's
      strong-skipping memo wrap emitted qualified-Path
      `androidx.compose.runtime.remember(keys..., calc)` UNTHREADED,
      which lowered through the arity-blind global-value route and
      invoked the 0-key overload with junk args; the wrap now appends
      the composer pair, multi-segment Path callees route through the
      FQN flatten/global-fit lowering, and the flatten's exact-arity
      match skips vararg decls (fixed-arity wins, Kotlin rule).
- [x] Per-class census (heavies excluded) surfaced two more roots, both
      FIXED: CompositionLocalTests 31/31 — a member overload whose
      declared param type provably rejects the arg now stands aside for
      the same-named extension (`putAll(pairsArray)` inside the stdlib
      `plusAssign` hit the builder's `putAll(Map)`; Array vs non-array
      container heads is now a definite disproof + member walk consults
      it when a surviving extension exists). SlotTableEditorTests
      11/11 — a bare `::ref` to a LOCAL EXTENSION fn now eta-expands
      binding the enclosing implicit receiver (arity carried in the
      inherited local-ext mark). Guard examples
      local_ext_fn_reference.kt, member_arg_disproof_extension.kt.
- [x] checkboxLike anchor GREEN (f6bbd362 + 03e41d70): the dirty-bits
      campaign landed — per-param `$dirty` triples, caller-certainty-
      guarded probes, call-site `$changed` bits (lowering-side,
      resolved-signature named-arg mapping, defaulted-param `$arg`
      forwarding), zero-key-slot memo shapes (cache from `$dirty`,
      lifted `{}` singletons, cache(false)). checkboxLike went 24
      slots -> slot-exact PASS (<= 8 groups / <= 18 slots);
      GroupSizeValidationTests 5/5; remember-family 26/26;
      funInterface_isMemoized green; ratchet observed 1370-1372,
      floor RAISED 1305 -> 1340. Full record in
      plans/compose-dirty-bits-plan.md.
- [x] CompositionTests remember-family FIXED — 26/26 solo (was ~8
      fails), LocalRememberReproTests 4/4. Three stacked roots, all
      landed:
      (a) OWN-RUN capture shadow: ImplicitCandidate carries an `own`
      bit (the frame's own dispatch receiver + its companion/nesting
      tower); a scoped-capture binding now loses only to the OWN run's
      members — a dispatch-published chain receiver's same-name member
      no longer outranks a captured local, on the read AND write arms
      (`count++` in a local-class init binds the captured `count`, and
      storeGlobal writes through its Cell).
      (b) runtime-lowered bodies know their CAPTURE NAMES:
      registerClassCaptured/buildObject install captured_names via
      build.setLowerAnonCaptureNames; the bare-name classifiers skip
      top-level-const inline / LoadGlobal binding for captured names
      (SlotTableEditorTests' file-private `const val count = 100` was
      const-inlined into another test's local-class init).
      (c) keyChange: delegated-local param shadow — inside compareBy's
      spliced `{ a, b -> compareValuesBy(a, b, selector) }`, `a`/`b`
      resolved to the TEST's `var a by mutableIntStateOf(0)` delegates
      (getValue → Int) instead of the lambda params;
      plainShadowsDelegate walks the scope chain in resolve order and
      an inner plain binding now shadows the delegate read AND
      setValue write-through. Guard examples:
      delegated_var_param_shadow.kt, captured_local_shadows_const.kt.
      Also: intrinsic_host.invokeMethod no longer swallows CalleeFailed
      into a null dispatch-miss (it masked (c) as
      "unresolved global sortWith").
      STILL RECORDED (not blocking any live test here): the private
      member-extension-property visibility gate (plain (recv,name)
      registration leaks program-wide; first gating attempt broke
      JobSupport's `Any?.exceptionOrNull` — needs frame-owner-aware
      visibility, not just the this-chain tower).
- [x] movableContentOf factory wrap RECLASSIFIED latent: the gated
      wrap (movableContent* factory names, compose_pass wrap_ret) is
      in tree and MovableContentTests is 44/44 — no live test pins the
      ungated arms. Widening to all composable-returning factories
      stays recorded (the drafted ungated patch core-dumped with
      10001-frame recursion; bisect plan in triage memory) and waits
      for a failure that names it.
- [x] Group start/end imbalance RECLASSIFIED latent: the tests that
      exposed it (movable multi-ref family) are green after the window
      band + judgment + dispatch fixes; no live failing test remains.
      The op-trace probe recipe stays in the triage memory
      (Operations.kt [op] print with val op0=this.operation) for when
      a shape re-pins it. checkboxLike's SLOT count is the live
      emission-shape anchor instead.

### Coroutine debt cluster record (closed 2026-08-16; moved from open-campaigns.md §3)

The two open remnants (tl_atomic_update_contended watch,
background-yield perf) stay in the live register.

- [x] with_timeout preempt — STALE: re-verified passing
      (withTimeoutOrNull(5){delay(50)} = null, standalone and nested
      under coroutineScope / withTimeout; fixed by intervening work).
- [x] private_shadow cells — STALE: both val and var shapes print the
      exact kotlinc outputs (distinct per-class cells).
- [x] THE #10 "CHANNEL DEADLOCK" FIXED — it was the LOOP JIT, not
      the channel: a trampolined callee's SUSPENSION propagated as a
      plain error, dropping the JITted loop frame from the
      continuation. A `for (i in 1..N) ch.send(i)` lost every element
      after the ~64-iteration tier-up (KLIO_JIT=0 was the decisive
      bisect; segment-size and capacity sweeps were red herrings, as
      was the entire cross-thread machinery — resumeExternal and the
      mailboxes traced clean). Fix: the trampoline stashes the call
      site's inst+dst on a Suspended result and the interpreter parks
      the frame at the call site (park_out), exactly the interpreted
      protocol. Whole family green: 1..2000 items, 5-actor original,
      worker/inline variants. Guard: litmus
      tl_channel_jit_send_loop.kt (litmus now 45/45). The park/resume
      empty-TailSeg leak is fixed too (chains hold at one segment;
      ratchet 1353 with DNC classes 3 -> 2).
- [x] combine/zip FIXED (the last of the flow-campaign #3 family).
      zip: the runtime extension-arity check was trailing-lambda-blind
      (`produce<Any> {}` against `produce(context=, capacity=, block)`
      needs only the GAP defaulted when the last arg is callable and
      the last param function-typed — extArityApplicableTL,
      host_call_member.zig). combine: a receiver-lambda param invoked
      bare from inside a coroutine lambda now binds the lexically
      innermost implicit receiver of its declared head through the
      receiver tower's `this@fn` slot, with the head riding
      CallValueWithThis (`recv_head`) for VM re-selection; the dynamic
      enclosing-this chain cannot serve this after a pump resume. The
      "raw collector closure" seating that looked wrong is CORRECT by
      design — FlowCollector is a fun interface and SAM lambdas stay
      raw IrClosures; bare `emit` on one SAM-invokes it. Guards
      examples/flow_zip.kt + examples/flow_combine.kt
      (kotlinc/JVM-verified); traps recorded in memory
      klio-flow-zip-combine-fixed (vmhost @hasDecl re-export, flat-call
      preempt gate, clear the cache BEFORE `pack build`).
- [x] Cancellation cluster CLOSED BY RE-VERIFICATION (2026-08-15): the
      flow campaign's recorded repros all pass on current main
      (plans/repros/channel_segment_rotation_break sum=2415,
      channel_worker_send_park_lost_wakeup sum=5050, both matching the
      JVM oracle; combine_captured_param_typeparam_cast is a distilled
      erasure probe the JVM itself CCEs on — not an oracle), and the
      litmus tl_cancel_* family is green in the 45/45 baseline.
- [x] Unconfined event loop: eager start (guard
      unconfined_starts_eagerly.kt), yield order (oracle-verified:
      kotlinc 2.2.20 + kotlinx-coroutines 1.9.0 on JVM prints
      U1 U2 L1 L2, exactly klio's order — NOT a bug; guard example
      unconfined_yield_order.kt), and the manual
      CancellableContinuation save/resume crash (`get_field context on
      Unit`) all pass on current main — the save/resume shape matches
      the JVM byte-for-byte (guard
      cancellable_continuation_save_resume.kt).
- [x] tl_yield_cross_thread_teardown "flake" was the litmus sweep's
      expectation PARSER stopping at the first code line (bottom-of-
      file //> lines read as empty). Fixed; litmus baseline is now
      45/45 — any litmus failure is REAL.
- [x] Stale-killed on re-verification: with_timeout preempt,
      private_shadow val+var, atomicfu SupervisorJob CAS.
- [x] CompositionTests.testCompositionAndRecomposerDeadlock +
      PausableCompositionTests.markInvalidFromBackgroundThread —
      RECLASSIFIED (2026-08-15): no stall remains. The deadlock test
      PASSES solo under the census recipe (10s virtual cap); the
      markInvalid test PASSES in 40s wall once the virtual timeout
      admits it (kotlinx_coroutines_test_default_timeout=600s) — its
      body runs 10,000 interpreted background invalidates (repeat(1000)
      × 10 launches + joins), which is the compute-heavy category from
      the suite-wall profile, not a cross-thread dispatch loss. Under
      the census's 10s cap it reports UncompletedCoroutinesError by
      design; it counts as wall-capped in the ratchet, not as a bug.

### ktor commontest campaign record (closed by record; moved from open-campaigns.md §4)

The recorded "292" was stale AND inflated by a stale-pack census trap:
the itest REBUILDS all five packs before running — a census against
old installed packs fails 100%. Fresh-pack per-class census (43 files,
ktor-io/utils/http common tests): 322/444 passing at the start of the
stretch.

- [x] Triage: the DOMINANT class was not interpreter bugs at all — the
      io.ktor pack's curated `include` lists simply omit upstream files
      the tests exercise (Base64, Crypto/Hash/Nonce, converters, date
      parsing, Cookie/Mimes/FileContentType/AcceptEncoding,
      LineEnding(Mode)/ByteChannelScanner/SinkByteWriteChannel...).
      Recipe proven and applied in three batches: 322 -> 399/444
      (Base64Test, AcceptEncoding, ContentType*, CommonHeaders,
      RenderSetCookie, GMTDate*, ReadLine 22/25... whole classes to
      green). One trap: a speculative include (IpParser.kt) pulled the
      unconsumed parsing DSL and broke the whole bake — add only files
      a failing test names, drop on bake error.
- [x] Interpreter root-causes landed off the cluster list (each with a
      guard example; commits 21186c6e, 44471f59, eac108fa):
      * anon-object method params typed by the ENCLOSING declaration's
        type params registered + consulted in the anon disproof, so an
        unrelated class named `Key` no longer refutes `add(element: Key)`
        (ConcurrentSetTest 1/10 -> 10/10).
      * `return@inlineFn` across nested inline splices resolves at
        lowering (InlineReturn carries the fn name), and a label crossing
        a REAL frame inside a spliced body is absorbed by a runtime
        `Block.lr_absorb` region at the splice join (CookieDateParser
        4/4). Image FORMAT_VERSION 45 -> 46.
      * companion members through the class name bind with a leading
        defaulted param skipped (trailing-lambda pmo remap + named-ladder
        companion forwarding): `StringValues.build { }`, `Parameters
        .build { }` (UrlTest testEncoding included).
      * intrinsic applicability predicates consulted unconditionally;
        `String.repeat` declines non-(Int) calls — a bare `repeat(n){}`
        against an in-scope String receiver silently NO-OPED (this also
        produced the CookieDateParser NumberFormatException).
      * `typeOf<T>()` carries generic ARGUMENTS end-to-end (full-spelling
        reified stamps + KTypeProjection materialisation)
        (DataConversion 4/4); tuple `contains` dispatches user equals
        through Pair components (MimesTest 3/3).
      * `object : Iface by <expr> {}` evaluates the delegate through a
        site-cached thunk (SinkByteWriteChannel 4/4); KClass.isInstance
        agrees with `is` via the registry walk (ByteChannel 13/13).
      * `io/ktor/util/ByteChannels.kt` include (copyToBoth; ChannelTest
        21/22 -> full class green).
- [x] Second interpreter batch (commits 44471f59, eac108fa, 036aa54a,
      3776afc5): full-spelling reified stamps + KType arguments; tuple
      contains via user equals; anon-object interface delegation thunks;
      KClass.isInstance registry walk; spliced-receiver-lambda bare reads
      prefer a window member the head declares (the whole URLBuilder
      `parameters`-as-Function family); trailing-vararg element
      adjudication + Pair-component disproof (StringValues 9/9); range
      literal peer widening (list-of-ranges vs Long peer).
- [x] Census at 464 passed / 3 failed / 0 incomplete (was 322/444-ish
      at the stretch start; the deadlocked classes' tests now all
      count and PipelineTest is 18/18 in 10s). Landing (e2200304):
      CallValueOrMember's non-invocable arm walks the outer implicit
      receivers on the canonical miss — a NON-callable captured local
      (val pipeline = pipeline()) no longer strands the enclosing
      member. LANDMARK (704597a0): the inline `synchronized` actual
      leaked its monitor on NON-LOCAL RETURN/exception exits;
      TestCoroutineScheduler.tryRunNextTaskUnless returns from inside
      synchronized(lock), so under runTest the root thread owned the
      scheduler lock forever and every cross-thread resume spun in
      registerEvent's monitorEnter — the ENTIRE GlobalScope.writer/
      reader deadlock family. try/finally fixed it: CoroutinesTest 2/2,
      WriterReaderTest 4/4, PipelineTest completes solo. Pack-baked
      splices carry the old enter/exit sequence until rebuilt. Landed
      since the 435 snapshot: named args on RESOLVED member calls bind
      by name (ReadLineTest 25/25 with the exact-limit pair),
      partial-index overload repick + eager unresolved-param gate
      (ByteReadChannel(byteArray) overload), and the pack-scale
      String-factory scope fix (plans/repros/pack_scale_repeat_echo.md
      — RESOLVED; shadowedByClass now tier-filters factory
      competitors, fixing "A".repeat receiver-echo in fully-loaded
      homes and both remaining ReadLine/Utf8 limit tests).
      * CodecTest.testFormUrlEncode — FIXED: bareCallReturnTypeRef's
        sole-bodied-candidate fallback now respects the extension
        receiver (kotlinx's deprecated `Flow.flatMap` was the sole
        bodied 1-arg candidate in the pack universe and stamped
        `declared=Flow` on a Set-receiver chain).
      * Side find: fast/flat `eq(0, 0L)` peer widening — FIXED
        (leafExprServeAt applies the coerce plan; guard:
        examples/generic_literal_long_widening.kt).
- [x] FINAL census: **465 passed / 2 failed / ZERO incomplete** — the 2
      = URLBuilder scheme-with-digits (klio MATCHES Kotlin; do not
      "fix"; anatomy kept in the live register §4).
      RangesTest.testResolveRanges CLOSED (27/27 solo): the
      self-recursive member bind now defers to the runtime walk when an
      argument's generic content is unresolved (`List<*>` from the
      un-derived map), and argDefinitelyNotParamType refutes a List of
      Long-kind Ranges against an invariant `List<IntRange>` param, so
      the walk binds kotlin.test.assertEquals exactly as kotlinc does
      (guard: examples/member_invariant_arg_delegation.kt).
- [x] The last 2 CLOSED BY RECORD; the suite baseline is ratcheted at
      440 in src/itests/ktor_commontest.zig (census floor 465 solo).

### Suite-wall profile record (moved from open-campaigns.md §5)

The pending question from the compose suite perf work: is
SlotTableBuilder's buildSubTable an O(n^2) pathology or genuine
compute? Reference: memory klio-compose-suite-perf; `BENCHMARKS.md`
for harness practice.

- [x] Profile buildSubTable under KLIO_PROF (`klio test` now honors
      KLIO_PROF like `run` does)
- [x] Verdict: NOT a pathology. oneRectBenchmarkSimulation solo = 56.7s,
      57k samples with NO dominant user frame — time spreads across
      generic dispatch (runFrameExec/execInst/member dispatch), ~8.6%
      memset (regs/array-init churn), ~8% name-keyed hashmap equality.
      Genuine interpreted compute; the floor stands until a generic
      interpreter-speed lever (the JIT is off under `klio test` by
      design, and the loop JIT measured unhelpful on this workload).

### Master-worklist round (closed 2026-08-16; moved from worklist.md)

The ordered execution round across everything then open, worked top to
bottom. Open residue carried into `simplify-validate-accelerate.md`
(the four stress tests + validatePotentialDeadlock as the accelerate
acceptance metric; the E4 continuation as Track A; the deferred
measured-first roads).

Performance round:

- [x] A1. Baseline re-measured: interp 13.68s / native 13.89s (the
      +3.2% did not hold on then-current main — native was ~1.5%
      BEHIND).
- [x] A2+A3 LANDED TOGETHER (50754db8), measured 13.8s -> 0.97s
      interp / 0.83s native (16.6x / 16.8x; native +17% over interp;
      312/312 transpiler parity, corpus 316/316, ratchet 1370):
      * KLIO_PROF on the native binary attributed the wall to
        INTERPRETED machinery, which led to two interpreter-side roots
        the emitted C merely inherited:
      * computeBoxedVars falsely boxed every var a same-function
        string template `$name`-mentioned (a template is not a
        lambda) — rangebench's accumulator paid a locked cell op per
        iteration. Unboxed; unit test pins it.
      * literal-step progressions (`step k`) ran the virtual iterator
        protocol per iteration; now counted register loops with
        kotlinc's overflow-free last-element snapping (JVM-verified;
        guard example step_progression_counted.kt).
      * the emitted C inlines the per-statement trace store (span
        offsets in the hot layout) and the fused edge guard
        (klio_edge_view flag polling; ABI v3).
- [x] A4 first increment (fdded783): native calls LEAF-SERVE in place
      (the glue answers monomorphic plain calls to leaf expression
      bodies via leafExprServe, no recursive full-frame serve, no
      unwind round trip). fib native 695ms -> 220ms, ahead of the
      interpreter's 232ms; rangebench unchanged. Deeper C-to-C frames
      (non-leaf callees) remain a recorded road — measure-first, the
      remaining gap on call-heavy code is now against the JIT ceiling,
      not the interpreter.
- [ ] A5. Value 16B endgame DEFERRED BY ITS OWN DOCTRINE: the 32B
      payloads already landed (Value = 24, hot-layout-confirmed);
      the 24 -> 16 tail needs BOTH remaining 16B payloads under 8:
      Array (clean: steal the cell pointer's low bit for the
      boxed-vs-PrimBuf discriminator, kind lives in the PrimBuf
      already) and IrClosure (every shape adds an allocation or an
      id-table lifetime problem to the HOTTEST creation path — compose
      builds closures per execution). The campaign doc marks these
      "measured-first, NOT the active front"; correctness work (the
      compose-suite failing tests below) outranked a speculative
      layout change with regression risk. Re-open when a measurement
      motivates it.
- [x] A6 CLOSED BY VERIFICATION: the yieldbench GPF family
      (activateChain chain-lifetime) is dead on current main — 15/15
      clean runs, ~230ms warm. resumeOnBackgroundThread PASSES in ~50s
      and profiles as the compute-heavy category by design (1000
      composables resumed incrementally under a background mutator
      thrash loop; memset of frame register files 13%, no stall, no
      single hot bug). Frame-pool/lazy-zero ideas belong to the CPU
      campaign's recorded roads, not this worklist.

Compose plugin suite long tail:

- [x] B1. Census enumeration: per-class children at P=2, heavies solo
      uncapped; name every failing test; cluster by mechanism.
      Result: 12 unique failing tests (not ~60 — the larger number was
      contention duplication): 4 fast-real, 7 concurrent-stress
      timeouts (verify solo before believing), validatePotentialDeadlock
      (300s wall). "INCOMPLETE" census rows were "no tests found"
      helper-class over-collection, not failures.
- [ ] B2. Fix the clusters, largest mechanism first; guard example per
      fix; ratchet floor raised as observed counts stabilize.
      - [x] validate_subList_remove + subList family (23/23): ERROR/HIDDEN
            deprecated declarations excluded as extension candidates
            (`deprecated_error` skip in resolveExtensionCall); guard
            examples/deprecated_error_not_callable.kt.
      - [x] restart_and_skip (RestartTests 6/6): restart lambda re-invoke
            wraps $changed in updateChangedFlags; ratchet 1374 observed.
      - [x] testApplierBeginEndCallbacks: elvis static type is the JOIN
            of both branches, not the lhs type — lhs-typed elvis
            devirtualized `applier.onBeginChanges()` to the interface
            default through final RecordingApplier; guard
            examples/elvis_join_dispatch.kt + lower.expr unit test.
      - [ ] The 7 concurrent-stress timeouts: verified REAL solo (not
            census contention). Root mechanism profiled (put_replace as
            proxy): the run was ATOMICS-BOUND, not interpretation-bound —
            31% in the slab allocator's per-class spinlock (rawAlloc/
            rawFree), then the SpinRwLock reader cmpxchg storm, then
            three global GC external-bytes counters RMW'd on every frame.
            Landed levers, each re-profiled: per-thread slab magazines
            (batched refill/flush; flushed at worker exit), wait-free
            reader entry (fetchAdd + undo; writer unlock clears only the
            sign bit), per-thread buffered external-bytes deltas (flush
            at ±256KB, thread exit, and collect start). put_replace
            24→55 outer iterations per 30s (2.3x). Remaining profile:
            memset (frame zeroing) ~9%, arg refcount fetchAdd ~9%,
            shared-instance borrow (setFieldInner) ~10%, prog/classes
            registry read locks ~10%. The tests still exceed their
            declared runTest timeouts interpreted; next levers listed
            in the same profile order.
      - [x] 3 of the 7 stress timeouts now PASS solo (concurrentMixing
            WriteApply_add, concurrentModificationInGlobal_put_replace,
            resumeOnBackgroundThread) after the second lever round:
            lock-free steady-state registry reads (resolvedNativeForm /
            lookupIntrinsic via `asPtrConst` gated on an atomic
            `resolved_linked`), exponential lock backoff, ObjRef.clone
            gated like deinit, CallVirtual host-receiver site memo
            (native / host-slot-op / by-name verdicts), ClassDef
            resolved-ClassId memo, Module.classIdByStaticFqn
            pointer-identity memo. put_replace 24 -> 62 outer
            iterations per 30s cumulative.
      - [ ] The 4 remaining (SnapshotStateMapTests.concurrentMixing
            WriteApply_clear + SnapshotStateListTests addAll_removeRange /
            addAll_clear / concurrentGlobalModifications_addAll) fail
            their own declared runTest(timeout=30s): ~5s per outer rep
            interpreted, 10 reps. The residual profile is spread
            (memset frame zeroing ~9%, string-eql walk internals ~9%,
            shared-instance borrows ~5%, unattributed ~15%) — no single
            lever left; needs the next measured campaign round (frame
            pooling, walk-internal caches).
      - [ ] RecomposerTests.validatePotentialDeadlock: see E3's
            disproof — compute-bound, not a repost race; the lever is
            the E4 profile (frame pooling + string-eql/hash caches).
- [x] B3. The 3 DNC heavy classes: CLOSED by the two concurrency lever
      rounds — the ratchet's last three runs report "0 did not
      complete" across all 46 classes (previously 3-5 classes variably
      crossed the 480s cap and RecomposerTests always did). Floor
      raised 1340 -> 1370 on observed 1375.

Open residuals from this block (carried into the active plan): the 4
declared-30s stress tests and validatePotentialDeadlock — the
accelerate acceptance metric.

Recorded correctness items:

- [x] C1. Inline-class dispatch family: CLOSED BY VERIFICATION — the
      recorded repro (CheckboxSlotDumpTests slot walk) and harder
      shapes (value class behind an interface through generic
      containers/Any casts; ULong-payload value class in Any? slots)
      all pass and match kotlinc/JVM byte-for-byte; fixed by the
      intervening dispatch work. Guards:
      examples/value_class_interface_dispatch.kt,
      examples/value_class_any_slot.kt.
- [x] C2. Private member-extension-property visibility LANDED: a
      PRIVATE member-ext property registers only under its
      owner-qualified key; resolution covers the legal scopes via the
      receiver-tower probe (now walking the WHOLE resolved parent
      chain — JobSupport sits several classes above a coroutine's
      class), an "Any"-key tower probe (`private val
      Any?.exceptionOrNull` registers under recv "Any" while receivers
      have their own heads), and a file-import probe
      (`import Duration.Companion.seconds` — the import fqn minus its
      leaf IS the owner key). NON-private member exts keep the plain
      pair: kotlinc scopes them to the tower too, but the tower
      emulation does not yet see every legal frame — gating them cost
      the compose suite ~400 tests (two traps hit and fixed on the
      way: public Duration companion imports in stdlib TimeMark tests,
      JobSupport under compose). Guard:
      examples/member_ext_prop_visibility.kt (kotlinc/JVM-verified
      shadow/tower/import surface). Ratchet 1372-1373 observed, floor
      trimmed to 1365 (pre-change peak 1375 inside the ±3 band).
- [x] C3. ktor server/client e2e itests: client GET works END-TO-END
      (status=200) — itest-ktor_client_get 4/4 and channel_async PASS
      after peeling five pre-existing roots, each with a
      kotlinc-verified guard example:
      1. Stored-lambda receiver seating: a `{ scope -> … }` lambda
         stored through a generic slot (`plugins[key] = …`) and
         replayed via `receiver.apply(it)` / `handler(recv, arg)` now
         seats the receiver positionally when the declared arity says
         so (unknown-shape closures; headerless speculative-`it`
         blocks excluded — that exclusion also protects suspend-lambda
         starts whose (receiver, completion) pair must not split).
         examples/stored_lambda_receiver_seat.kt.
      2. `::proceed` inside a receiver lambda binds the receiver's
         member through the capture slot the runtime receiver-binding
         fills (was a KProperty shell / a global miss).
         examples/receiver_member_callable_ref.kt.
      3. The innermost receiver's member outranks a top-level pick for
         bare `::name` refs (stdlib alias intrinsics excluded).
      4. A foreign class's PRIVATE stored field never answers another
         class's private computed property: stored privates now
         register in instance_prop_private, the sgetter virtual walk
         skips them, and owner_applies uses the module-walk ownership
         test (the value-level check misses pack-loaded chains).
         examples/private_stored_no_override.kt.
      5. Pack include: ktor-client-core jvmAndPosix
         `checkContentLength` actual.
      SERVER GATE ALSO GREEN after four more roots (each verified):
      6. Hierarchy ascent by name evidence when a pack shim class's
         cross-root supertype ids never resolved (KlioApplicationResponse
         walked as a leaf, hiding BaseApplicationResponse.status).
      7. Bodyless member declarations join overload ranking: the
         registry records abstract member arities (rides pack images —
         LAYOUT CHANGE, rebuild installed packs), and the inline-target
         pick declines an extension/top-level candidate when an implicit
         receiver's hierarchy declares an abstract member taking the
         call (respond(message, typeInfo<T>()) spliced the reified 2-arg
         respond(status, message), binding CONTENT to status).
         Member-inline picks exempt (DebugPipelineContext.proceed).
      8. Scope-qualified property reads whose lexical-owner premise
         fails (a companion-fn lambda reading the RECEIVER's `call`
         while the outer class declares an instance `call`) retry the
         implicit-receiver candidates with the plain name before
         failing. examples/companion_lambda_receiver_read.kt.
      9. The gate fixtures themselves were ILLEGAL Kotlin (bare
         get/post never imported — kotlinc rejects them); klio's
         unimported-extension leniency resolved them but mistyped the
         handler lambdas' receivers, unbinding `call`. The fixtures now
         import routing.get/post. RECORDED klio-ism: that leniency
         still mistypes receiver lambdas when it engages.
      All three ktor e2e gates green: itest-ktor_server,
      itest-ktor_client_get, itest-ktor_channel_async.
      Also recorded: hangbisect3 shape (foreign private stored + async
      in interface default member) hung pre-existing — resolved in E2
      below.

Next round (E items; E4's continuation is the active plan's
accelerate track):

- [x] E1. Free-win harvest + pack hygiene. COMPLETE (both pack homes
      rebuilt again after the receiver-head lowering landed, since
      baked pack IR carries lowering output):
      - [x] Pack homes rebuilt on the new image layout (`~/.klio` all
            26 shipped packs, `.klio-local` via install-local-packs;
            caches cleared). Corpus re-warmed — the 17 "failures" were
            cold-bake timeouts, all pass warm including the heavy four
            (material3, m3_text, multiwindow, window).
      - [x] flow ZIP FIXED (was the recorded receiver-publication
            zip half): the runtime extension-arity check was
            trailing-lambda-blind — `produce<Any> { }` against
            `produce(context=, capacity=, block)` needs only the GAP
            defaulted when the last arg is callable and the last param
            function-typed (extArityApplicableTL). All three produce
            overloads were silently dropped and a lenient tail ran
            produce with the wrong binding, so zipImpl's `second`
            failed the SendChannel cast. Guard examples/flow_zip.kt
            (kotlinc/JVM-verified).
      - [x] flow COMBINE FIXED. Root cause was two-layered. (1) A
            receiver-lambda param invoked bare from inside a coroutine
            lambda must bind the lexically innermost implicit receiver
            of its DECLARED head, and the dynamic enclosing-this chain
            cannot recover it after a pump resume (the chain at the
            call held only FlowCoroutine + SAM-collector closures).
            The lowering now records the declared receiver head per
            receiver-lambda param (decl.zig / lambda_body.zig), walks
            the labeled receiver tower at the captured-RLP call site,
            and lowers the matching `this@<label>` slot (the same slot
            extension-fn entry binds) as the call receiver;
            CallValueWithThis carries `recv_head` so the VM re-selects
            by head (callValueWithThisHead, resel off) when the tower
            gave nothing. (2) Two engagement traps cost most of the
            session: the vmhost re-export for callValueWithThisHead
            was missing so the eval arm's @hasDecl gate silently chose
            the old path, and the flat-call fast path intercepted
            CallValueWithThis before the head branch (now gated on
            recv_head == null). Also: pack BUILD consumes the lowering
            cache — clear `~/.klio/cache` BEFORE `pack build`, not
            just before the run, or the pack bakes stale IR. The
            "receiverless closure" theory was wrong: this@combineInternal
            IS an IrClosure by design (FlowCollector is a fun
            interface; SAM lambdas stay raw closures and bare `emit`
            on one SAM-invokes it). Guard examples/flow_combine.kt
            (kotlinc/JVM-verified).
      NOTE: the cached ratchet binary was pruned with the zig cache;
      ratchet now runs via `zig build itest-compose_plugin_commontest`
      (source floor 1365 then, 1370 now).
- [x] E2. hangbisect3 hang RESOLVED: the repro (foreign private stored
      field + async in an interface default member) now prints `open`,
      stable across repeated runs. The fix rode the zip landing —
      `async(context, start, block)` has exactly the produce shape the
      trailing-lambda-blind extension-arity filter dropped, and with
      every overload gone a lenient tail mis-bound the call; the
      sgetter suspicion was a downstream symptom. Guard
      examples/interface_private_shadow_async.kt.
- [x] E3. Pump fairness: CLOSED AS DISPROVEN. Measured solo with
      KLIO_SPIN_TRACE (5 samples over 60s) and KLIO_PROF (61k
      samples): every spin sample is INSIDE active recompose /
      change-list work (Text endNode, SlotWriter.advanceBy,
      Operations.push — different positions each sample, marching),
      and the profile is diffuse interpreter cost (mum 10.9%, read
      5.7%, eqlBytes 4.8%, hash/update/final1 ~3% — the hash+string
      floor), with NO drain-poll churn and NO dominant pathological
      function. validatePotentialDeadlock is compute-bound: each
      advance(5000) marches ~312 TestMonotonicFrameClock frames and
      every frame recomposes all 200 Texts (both loops bump `state`
      per frame), so the test needs ~3120 interpreted recompose
      passes inside the 90s wall cap. The "always loses the repost
      race" theory was wrong; "daemon task abandoned" is the
      wall-cap's abandon diagnostic, not a mechanism. The lever is
      E4 (frame pooling + string-eql/hash caches — exactly this
      profile). If E4 lands and an advance still cannot finish,
      revisit bounding mid-pass Default reposts per frame (the
      b/329011032 re-dirty multiplier) as a second-order item.
- [ ] E4. Concurrency perf round 3 — ROUND LANDED, item continues as
      the active plan's accelerate track.
      Measurement rig: standalone addAll_clear rep bench
      (scratchpad reprosrc/aacbench.kt, one test rep per measure) on
      the ReleaseSafe harness — MEASURE ON THE HARNESS BINARY, the
      default `zig-out/bin/klio` is a Debug build with a completely
      different profile (its hash/eql dominance sent this round down
      a wrong path for an hour). Landed this round, measured:
      1. Member-resolve cache stands UP under imported-pack-extension
         shadowing instead of standing down: the resolve key gains
         (file+1, argc) so file-scope-dependent resolutions memoize
         per call-site file (`writable`/`withCurrent` on snapshot
         records re-ran the full stdlib probe ladder + overload
         scoring 40k times per rep; now 2). 4.17s -> ~3.7s/rep
         (~11%).
      2. Leaf serves skip the register-bank Unit fill when a
         def-before-use pass over the body (entry-block-dominates
         rule, ir.zig leafNoFill) proves no stale read; a lazy pin
         zeroes not-yet-written slots first since the keepalive pins
         the whole slice (leaf-fill memset samples 381 -> 0,
         inside run variance on the wall).
      3. TOOLING: the KLIO_PROF sampler recovers the caller of
         FP-less leaves (compiler-rt memset, libc) by scanning the
         SP..BP window for the first own-text return address — the
         8% <no-fp> memset bucket is now attributable.
      Standing (solo, ReleaseSafe, declared runTest budgets):
      addAll_clear 30.6s/30s, concurrentGlobalModifications_addAll
      32.0s/30s (both marginal), addAll_removeRange 69.7s/30s,
      concurrentGlobalModification_add 10.2s/10s. Remaining profile
      is FLAT: interpreter core loop ~7%, ReleaseSafe
      undefined-poison memsets ~3% (build-mode constant, gone under
      ReleaseFast), refcount/borrow atomics ~4%, futex/lock ~6%
      (the test IS contention by design). Measured-negative this
      round: KLIO_GC_GROWTH sweep (3/4/6 — wall flat, memory up);
      frame-buffer pooling (already exists; the reg fill was the
      cost and is now gone where provable). Next round candidates,
      in order: cross-thread refcount/borrow elision, snapshot
      global-lock sharding, core-loop dispatch micro-opts.
- [x] E5. Leniency diagnostic LANDED as a loud once-per-declaration
      runtime warning at the exact bind. Anatomy established first:
      the mistyping is NOT fixable at lowering for the ktor shape —
      the io.ktor.server pack's declarations are not in the lowering
      module's func_name_index at user-file lower time (even the
      IMPORTED `routing` lowers as unresolved_bare_call; the eager
      lambda-receiver channel comes from TYPECK, which correctly
      declines unimported calls), so the unimported handler lambda
      keeps a synthetic `it`, the RoutingContext arrives positionally,
      and bare `call` dies as an unresolved global. Correct-typing
      would need speculative cross-pack candidate search at lowering;
      a hard "unresolved reference" error would false-positive on
      klio's import-tracking gaps. Instead the extension-fallback's
      top-level winner path now warns (once per declaration):
      "warning: `get` binds `io.ktor.server.routing.get` without an
      import; add `import io.ktor.server.routing.get` — kotlinc
      rejects the unimported call, and klio may type its lambda
      arguments incorrectly". Gated tightly: shipped-pack packages
      only (kotlin.* exempt as default imports), caller file outside
      known packages (pack-internal cross-package binds stay quiet),
      same-package exempt, wildcard/alias imports checked. Verified:
      unimported produce + unimported routing get warn with the exact
      import line; imported variants and zip/combine are silent.
      Repros: scratchpad reprosrc/lenient1.kt, lenient_ktor.kt.
- [ ] E6. Deferred measured-first roads, only when a measurement
      motivates: C-transpiler C-to-C frames (A4 continuation), Value
      24 -> 16 (A5), C2 completion (nullable member-ext gating; tower
      strength for public member exts).

Watches (carried into the live register):

- tl_atomic_update_contended litmus flake: postmortem on next natural
  occurrence (the sweep prints got-vs-expected tails now).
- URLBuilder scheme-with-digits ×2: klio matches Kotlin, intentionally
  red upstream — never "fix".
- checkboxLike stays the slot-exact anchor; any emission work re-runs
  GroupSizeValidationTests.

Done this stretch (index): ktor commontest 465/468 zero-incomplete;
compose remember-family 26/26; dirty-bits calculus + slot-exact
checkboxLike; corpus 315/315 with the interactive-example contract;
coroutine debt closed by JVM oracle; ratchet floor 1305 -> 1340 (then
1370). The follow-on work — codebase simplification, test/validation
repair, and the performance campaign's continuation with the E4
standing as its acceptance metric — is
`plans/simplify-validate-accelerate.md`.


## simplify-validate-accelerate (closed 2026-08-17)

Three tracks, every item landed, `scripts/gate.sh` GREEN at close.

Simplify: dead compose-plugin gate deleted; the three giant modules each
split once, behavior-frozen (expr.zig 24070->21554, host_call_member.zig
16057->13628, eval.zig 12893->9628, with three new siblings) and the
measured per-file extraction ceilings recorded so later cuts are a
judgment, not a guess; plan register reduced to one live file; 122
undocumented trace knobs catalogued; itest suites 69 -> 57 with 15
verified-duplicate tests dropped and every unique pin moved first.

Validate: a fresh red-set census exposed 15 failures + 44 crashes; the
crashes were ONE family — in-process multi-program stale state — with
seven distinct roots (shared anon side-module, generation-stamped
dispatch caches, bytecode stream cache, intrinsic intern keys, the GC
remembered set, the expr-body member AST registry, and the anon clone
crossing a program boundary). Ratchet baselines made honest; ktor tail
closed by record. Interpreter correctness roots fixed along the way:
declaring-scope bounds for bare type-parameter returns, invoke-convention
scope rank, typealias constructors and default-package aliases,
FQN-opened stdlib gate, trailing-lambda scorer fall-through, cross-thread
activation TLS rebind, deterministic ui-text paragraph measure, missing
kotlin.system timing helpers, and dispatched-task failures ending the run
instead of hanging it.

Accelerate: A2 core loop -10.2% on the rig (framed no-fill register files
behind a def-before-use proof; arity-forced member picks cached), with
const+binop fusion built, measured negative, and reverted. A3 integer-keyed
field memos + TLS L1s (wall-neutral, cleaner mechanics). A6 turned
compose_foundation_lazy 42.6s -> 1.07s (40x) and retired the "55s yield
round-trip" attribution as wrong — the hop is ~100us; the wall was
upstream's own quadratic resume protocol. A5 disproved the slab premise
(slab holds ~60MB at a 6GB peak) and met its acceptance number by
retiring the per-program anon-module clone, adding a program-perm
generation, boundary trims, and grouping the corpus by dependency-base
key; e2e and differential now run under the 6.5GB cap, differential green
for the first time on record. A7: ReleaseFast is at parity with
ReleaseSafe now that the no-fill lever removed the poison-memset gap.


## conformance-and-hardening (closed 2026-08-18)

Every item landed; `scripts/gate.sh` GREEN at close. The campaign asked
what the censuses do NOT name, and the answer was that they were not
measuring their libraries at all.

Conformance. Three suites had been sitting behind pass-count floors that
hid most of their surface:

  coroutines    350 -> 1073 passed (896 -> 137 failed), floor 340 -> 1040
  serialization   9 ->   60 passed (129 ->  78 failed), floor   9 ->   60
  datetime      212 ->  457 passed (291 ->  62 failed), floor 205 ->  450

coroutines was 84% ONE missing test-support surface (`TestBase` from
`kotlinx.coroutines.testing`, a pack `[[test]]` root the census never
passed to the child). serialization was a missing `expect val
currentPlatform` actual plus a deliberately narrow 17-file include list.
datetime was a genuine MIX — eleven roots, nine of them in the
interpreter. Across the three, ~25 shared-path interpreter fixes landed
(parser, lowering, reified inference, member and receiver dispatch, the
integral range builders) with the rig unchanged at ~3340 ms/rep and both
heavy ratchets holding exactly, which is the evidence they were
root-cause fixes rather than special cases.

Every census now carries `max_failed`/`max_incomplete` ceilings beside
its floor, seeded from solo measurements and verified by negative
control — a floor alone cannot see a fixed case traded for a broken one.

Corpus: 18 `.out` files sat in `examples/` while e2e reads only
`tests/corpus/expected/`, so those guards had never been enforced (all 18
matched — nothing had regressed behind the gap). Pins 292 -> 320, plus a
new `tests/corpus/expected-cli/` for the 16 programs the in-process
runner cannot execute at all.

Hardening produced three documents rather than three refactors, because
the audits found the invariants already held and the value was writing
them down: `docs/development/process-globals.md` (53 globals classified,
the four defenses named, no undefended per-program state remaining),
`docs/development/resolution-paths.md` (the eager map is built ONLY under
src/cli, so users and most of the test apparatus run different resolution
configurations — measured: 4 disagreements in 60 examples, all
"lazy declined, eager supplied", zero contradictions), and the
dispatched-task terminal-state contract in COROUTINE-MODEL.md (litmus
58 -> 60). H4 and H5 closed BY MEASUREMENT against their own premises:
the dispatch ladder is 0.10% of dispatches, and a per-program heap is not
justified at e2e 4G / differential 6G against the 6.5G cap — with
differential's ~8% margin recorded as the trip-wire.

`scripts/coroutines-census.py` and `scripts/stdlib-surface-inventory.py`
are the reusable instruments: per-failure error-shape histograms, and the
upstream-vs-klio surface diff with a `--probe` mode that confirms
suspects instead of trusting a static diff.

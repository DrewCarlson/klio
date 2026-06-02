# Plan Archive (M0–M21)

Historical record of completed milestones. The active plan lives in `PLAN.md`. Entries here are append-only — newer milestones are summarized in as they retire from the active plan.

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

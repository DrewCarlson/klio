# Retiring the old checker

`klio check` still runs the resolver and the type checker (`src/resolver`,
`src/typeck`, with `src/cfa` and `src/types` under them); `klio run` runs
sema. This plan moves every diagnostic the old checker reports that kotlinc
also reports into sema, switches `klio check` to sema, and deletes the old
checker (about 29k lines).

The old checker is not the oracle: it reports errors in 211 of the 673
examples, which run and which kotlinc accepts. Every check is judged against
kotlinc 2.4.20 (the pinned dist in the main checkout's `target/parity-cache`).

## Rules the diff enforces

Per input and per line, over `examples/`, `tests/fixtures/typeck_negative`,
`tests/fixtures/*.kt`, the itests' inline diagnostic cases, the packs' own
sources and the box corpus's valid files:

1. Every old diagnostic that kotlinc also reports at that line has a sema
   diagnostic there with kotlinc's factory.
2. An old diagnostic may disappear only where kotlinc accepts the line.
3. Every sema diagnostic matches a kotlinc one.
4. The severity is kotlinc's.

## Tools

- `klio check --engine sema`: the files analyzed as `klio run` analyzes
  them, with kotlinc's factory names as codes (`--format json` for tools).
- `scripts/sema-oracle.sh --diagnostics FILE...`: kotlinc's diagnostics.
  From a worktree set `SEMA_ORACLE_KOTLINC` to the main checkout's
  `target/parity-cache/kotlinc-2.4.20`. Probing kotlinc with a small file is
  how every rule below was settled; do that before writing a check.
- `scripts/check-diff.py`: both engines and kotlinc over the inputs, the four
  rules, per category. `--save DIR` keeps each side; `--old`, `--sema`,
  `--kotlinc` reuse one (the old side is 20 minutes, the sema side about 30 on
  a fresh binary, which bakes each compose base image once).
- `KLIO_CHECK_PACKS=1` (docs/development/debugging.md): the declaration,
  annotation and use checks also run over the installed packs' sources, which
  kotlinc compiled, so a finding there is a false positive or klio-authored
  code kotlinc would refuse. Run `klio sema --bodies all` over a probe that
  imports the pack, as `scripts/sema-census.py` does. `use` findings there are
  noise: the packs build with module `-opt-in` flags and `@file:Suppress`.

## Where the code is

- `src/sema/census.zig`: a site's severity (warnings are kept apart and never
  counted), `Factory` (every name sema reports; a cli test holds each to a
  factory kotlinc or klio declares), related places, notes.
- `src/sema/suppress.zig`: `@Suppress` regions.
- `src/cli/sema_diagnostics.zig`: sites to `Diagnostic`s; no warning is shown
  when there is an error.
- `src/sema/declcheck.zig` (B1), `src/sema/annocheck.zig` and
  `src/sema/usecheck.zig` (B2): run from `body.resolveAll` after the
  program's bodies.

## Order and status

A. Infrastructure. Done: census severities and factory names, `@Suppress`,
`klio check --engine sema`, the oracle's `--diagnostics`, `check-diff.py`.

B. Port the missing checks by category, errors before warnings, with sema
unit tests; `typeck_negative` is the acceptance list.

- B1. Declarations, modifiers and overrides. Done (`declcheck.zig`):
  modifiers that exclude each other or do not apply; data, value and enum
  classes; supertypes (final, an object, sealed from a local class, `by` to a
  class, uninitialized, a generic `Throwable`); `lateinit`, `const`,
  extension, inline and explicit-backing-field properties; reified,
  `crossinline`, `noinline`, vararg parameters; overrides (nothing, final,
  visibility, return and property type, `var` by `val`, `suspend`);
  unimplemented abstract members and members several supertypes implement;
  operator and infix shapes, and `OPERATOR_MODIFIER_REQUIRED` /
  `INFIX_MODIFIER_REQUIRED` at the call; constructor cycles; an escaping
  object expression's type. Warnings `NOTHING_TO_INLINE`,
  `PARAMETER_NAME_CHANGED_ON_OVERRIDE`, `REDUNDANT_EXPLICIT_BACKING_FIELD`.
- B2. Annotations, targets, opt-in and deprecation. Partly done:
  - done: annotation class shape (members, parameter types, `val`, constant
    defaults, cycles), `REPEATED_ANNOTATION`, `DEPRECATION`,
    `DEPRECATION_ERROR` (with `@DeprecatedSinceKotlin` against 2.4) at calls,
    reads, constructors and header types, `OVERRIDE_DEPRECATION`;
  - not done: `WRONG_ANNOTATION_TARGET` and its use-site-target forms (the
    `@all:` and defaulting rules are in `ast.annotation_targets`; the 13
    diagnostic rows of the `annotation_targets` itest define them);
    `ANNOTATION_ARGUMENT_MUST_BE_CONST`;
  - opt-in (`OPT_IN_USAGE`, `OPT_IN_USAGE_ERROR`, `OPT_IN_OVERRIDE*`) was
    written and taken out before landing, for two regressions it caused in
    examples that run. What kotlinc does (probed): a declaration's markers
    are its own and its containing classes' (a member of a marked class
    needs the opt-in, a constructor its class's), the use is reported at the
    call, read, constructor or header type, a site is opted in by `@M` or
    `@OptIn(M::class)` on any enclosing declaration or the file, and an
    override of a marked member is `OPT_IN_OVERRIDE`; the message says
    "must" for an error and "should" for a warning. The two things to solve
    first: the kotlinx.serialization plugin's generated serializers sit in
    the program's file and use `@InternalSerializationApi` members, so code
    the plugin generates must be exempt; and whether kotlinc 2.4 still marks
    `kotlin.time.Instant` `@ExperimentalTime` (examples/
    instant_component_serializer.kt uses it without an opt-in; the oracle has
    no kotlinx-datetime jar to say).
- B3. Visibility and names, context parameters. Not started.
- B4. Types. Not started. It also fixes the wrong factory for a call no
  candidate accepts: sema says `NONE_APPLICABLE` where kotlinc, with a single
  candidate, names its problem (`TOO_MANY_ARGUMENTS`, `ARGUMENT_TYPE_MISMATCH`,
  `NO_VALUE_FOR_PARAMETER`, `NON_VARARG_SPREAD`, `INAPPLICABLE_CANDIDATE` with
  `UPPER_BOUND_VIOLATED`) — five typeck_negative fixtures.
- B5. Null safety and casts. Not started.
- B6. Control flow: a structured flow pass over the syntax and sema's
  records, not cfa. Not started.
- B7. suspend, inline, tailrec. Not started.

C. Switch: `klio check` defaults to sema; `typeck_negative` asserts kotlinc
factory names from `klio check` (its 8 inline cases become fixtures); the 46
diagnostic rows of `annotation_targets`, `context_parameters` and
`explicit_backing_fields` move to the sema engine (their run rows stay);
`check_examples` covers every example kotlinc accepts; the JSON
`legacy_code` field goes; `scripts/stdlib-surface-inventory.py` greps check's
"unresolved reference" text and needs the new wording. check-diff joins
`scripts/gate.sh`.

D. Delete, each step building:

1. The pack typeck section: `pack_build.zig` `buildTypeckBundle`,
   `pack/schema.zig` `TypeckBundle`; drop `types` from pack's deps.
2. The CLI's use: `check_cmd.zig`'s old engine, `cli.zig`
   `resolver.pool_backing`, the `mem_census.zig` row.
3. The itests' use; `cfa_builder` and `cfa_smartcast` go with cfa.
4. `src/typeck` (19,988 lines) and `src/resolver` (2,026).
5. `src/cfa` (4,280).
6. `src/types` (2,587), then `stdlib.isKnownPackage`. Keep
   `ast.annotation_targets` if B2's targets use it.

The mirrors to edit with each: `build.zig` `mod_list` (it panics on a stale
dependency), `scripts/zigcheck.py` `GRAPH`, `itests.zig`, and the debugging
knobs (`KLIO_TC_*`, `KLIO_RESOLVE_THREADS`) in the docs.

## Where it stands

`scripts/check-diff.py` over the 807 inputs (kotlinc judges 524 examples,
every typeck_negative fixture and 4 fixtures; the rest import a library the
pinned kotlinc does not ship and are taken as valid):

| | Baseline | After B1 | After B2 (part) |
|---|---:|---:|---:|
| rule 1: typeck_negative kept | 9 | 69 | 76 |
| rule 1: typeck_negative missing | 110 | 50 | 43 |
| rule 1: examples missing (warnings) | 11 | 11 | 11 |
| rule 2: old false positives dropped | 785 | 785 | 785 |
| rule 3: sema matches kotlinc, typeck_negative | 8 | 77 | 85 |
| rule 3: sema matches kotlinc, examples | 0 | 16 | about 20 |
| rule 3: sema misses | 9 | 6 | 6 |
| rule 4: wrong severity | 0 | 0 | 0 |

Sema reports no error in the examples kotlinc judges. The 6 rule-3 misses are
the five `NONE_APPLICABLE` (B4) and a `NOTHING_TO_INLINE` warning kotlinc
leaves out beside the `NON_PUBLIC_CALL_FROM_PUBLIC_INLINE` error sema does
not report yet (B3).

What rule 1 still misses, by the category that will cover it:

- B2: neg_annotation_target_class_only_on_function (`WRONG_ANNOTATION_TARGET`),
  neg_opt_in_missing (`OPT_IN_USAGE_ERROR`); in the examples,
  select_and_semaphore and select_on_timeout_loses (`OPT_IN_USAGE`).
- B3: neg_dsl_marker_nested_shadow (`DSL_SCOPE_VIOLATION`, twice),
  neg_field_in_extension_property (`UNRESOLVED_REFERENCE` of `field`),
  neg_published_api_missing (`NON_PUBLIC_CALL_FROM_PUBLIC_INLINE`),
  neg_recursive_typealias (`RECURSIVE_TYPEALIAS_EXPANSION`),
  neg_super_qualifier_not_supertype (`NOT_A_SUPERTYPE`),
  neg_unresolved_label (`NOT_A_LOOP_LABEL`).
- B4: neg_accessor_return_type_mismatch (`WRONG_GETTER_RETURN_TYPE`),
  neg_arity (`TOO_MANY_ARGUMENTS`), neg_catch_type_param
  (`TYPE_PARAMETER_IN_CATCH_CLAUSE`), neg_circular_type_bound and
  neg_circular_type_bound_self (`CYCLIC_GENERIC_UPPER_BOUND`),
  neg_class_literal_nullable (`EXPRESSION_OF_NULLABLE_TYPE_IN_CLASS_LITERAL_LHS`),
  neg_class_literal_type_param (`TYPE_PARAMETER_AS_REIFIED`),
  neg_compound_assign_ambiguity (`ASSIGN_OPERATOR_AMBIGUITY`),
  neg_declaration_variance_violation (`TYPE_VARIANCE_CONFLICT_ERROR`),
  neg_definitely_non_null (`INCORRECT_LEFT_COMPONENT_OF_INTERSECTION`),
  neg_delegation_type_mismatch and neg_throw_non_throwable (`TYPE_MISMATCH`),
  neg_reference_equality_distinct (`FORBIDDEN_IDENTITY_EQUALS`),
  neg_spread_requires_vararg (`ARGUMENT_TYPE_MISMATCH`, `NON_VARARG_SPREAD`,
  `NO_VALUE_FOR_PARAMETER`, twice), neg_spread_type_mismatch and
  neg_wrong_arg_type (`ARGUMENT_TYPE_MISMATCH`), neg_type_bound_not_satisfied
  (`INAPPLICABLE_CANDIDATE`, `UPPER_BOUND_VIOLATED`), neg_type_mismatch
  (`INITIALIZER_TYPE_MISMATCH`), neg_value_equality_distinct
  (`EQUALITY_NOT_APPLICABLE`).
- B5: neg_as_safe_type_param, neg_as_unchecked_type_param and
  neg_unchecked_cast twice (`UNCHECKED_CAST`), neg_is_type_param
  (`CANNOT_CHECK_FOR_ERASED`), neg_null_deref (`UNSAFE_CALL`); in the
  examples, annotated_function_types and as_cast (`USELESS_CAST`),
  cast_null_and_erasure twice, collection_bridges_and_throwable_cause and
  ieee754_comparisons twice (`UNCHECKED_CAST`), stdlib_taste
  (`UNNECESSARY_SAFE_CALL`).
- B6: neg_val_reassign (`VAL_REASSIGNMENT`), neg_var_not_definitely_assigned
  (`UNINITIALIZED_VARIABLE`).
- B7: neg_crossinline_param_leak and neg_inline_param_leak
  (`USAGE_IS_NOT_INLINABLE`), neg_suspend_call_from_non_suspend
  (`ILLEGAL_SUSPEND_FUNCTION_CALL`), neg_tailrec_no_calls and
  neg_tailrec_non_tail (`NO_TAIL_CALLS_FOUND`), neg_tailrec_non_tail
  (`NON_TAIL_RECURSIVE_CALL`); in the examples, tailrec_forms
  (`NON_TAIL_RECURSIVE_CALL`).

kotlinc also reports warnings in the examples neither engine does
(`USELESS_IS_CHECK` 36, `NOTHING_TO_INLINE` now matched, and a few more),
which parity will want after the categories.

The pack-source check (`KLIO_CHECK_PACKS=1`) finds no declaration or
annotation site in any pack. The klio glue it once flagged
(`KlioComposeOwner`, `KlioPointerIconService`) is gone: ui's host is
upstream's RootNodeOwner and scene now.

## What kotlinc 2.4.20 does

Settled by probing the pinned kotlinc; each shaped a check.

- It prints no warning of a compilation that has an error (the real
  `kotlinc` binary does the same), so `klio check` shows warnings only when
  there is no error.
- It holds `inc` and `dec` to no parameter count, and checks an operator's
  name (`illegal function name`) before its placement (`must be a member or
  an extension function`).
- It reports the abstract members a class leaves unimplemented in one
  diagnostic per class and kind (an interface's, a class's), and a member
  several supertypes implement once per member; a hidden (`@Deprecated`
  `HIDDEN`) member still overrides and implements.
- A data class's own `componentN` or `copy` is `CONFLICTING_OVERLOADS` at the
  function and at the class.
- `class D : O()` for an object `O` is `SINGLETON_IN_SUPERTYPE` and
  `UNRESOLVED_REFERENCE`.
- An annotation parameter cycle through an array is accepted; a direct one
  is `CYCLE_IN_ANNOTATION_PARAMETER_ERROR`. Only `kotlin.annotation.Repeatable`
  makes an annotation repeatable, not a class of that name elsewhere.
- A deprecated class is reported where a type or constructor call names it,
  not at its members' uses; an override of a deprecated member is
  `OVERRIDE_DEPRECATION`; a use inside a deprecated declaration is still
  reported. `@DeprecatedSinceKotlin` decides the level against the language
  version. The JVM's `String(CharArray)` is not deprecated where the common
  `expect` is, so sema leaves an `expect`'s deprecation to its `actual`.
- `abstract value class` and value classes of several properties need
  `-XXLanguage:+FullValueClasses`, which klio records per file.

## Measurements

Time: median 0.42 s a file against the old engine's 0.58 s. A compose
program's first check on a new binary bakes its base image (about 25 s);
after that it takes 3 s against the old engine's 18 s.

# Retiring the old checker

`klio check` still runs the resolver and the type checker (`src/resolver`,
`src/typeck`, with `src/cfa` and `src/types` under them); `klio run` runs
sema. This plan moves every diagnostic the old checker reports that kotlinc
also reports into sema, switches `klio check` to sema, and deletes the old
checker (about 29k lines).

The old checker is not the oracle: it reports errors in 211 of the 673
examples, which run and which kotlinc accepts. Every check is judged against
kotlinc 2.4.20 (the pinned dist in `target/parity-cache`).

## Rules the diff enforces

Per input and per line, over `examples/`, `tests/fixtures/typeck_negative`,
`tests/fixtures/*.kt`, the itests' inline diagnostic cases, the packs' own
sources and the box corpus's valid files:

1. Every old diagnostic that kotlinc also reports at that line has a sema
   diagnostic there with kotlinc's factory.
2. An old diagnostic may disappear only where kotlinc accepts the line.
3. Every sema diagnostic matches a kotlinc one.
4. The severity is kotlinc's.

## Order

A. Infrastructure; nothing changes for users.

- A1. Census sites carry a severity, kotlinc's factory name, related places
  and notes; warnings are kept apart and never counted. `@Suppress` is
  honored. `sema_diagnostics.collect` gives the renderers `Diagnostic`s.
  Done.
- A2. `klio check --engine sema`: the files analyzed as `klio run` analyzes
  them, over the cached base image, without lowering. The default stays the
  old engine. Done.
- A3. `tools/sema-oracle --diagnostics`: every diagnostic kotlinc reports
  for a file (factory, severity, line, column, message), warnings included,
  JVM backend signature clashes left out. Done.
- A4. `scripts/check-diff.py`: old engine, sema engine and kotlinc per input,
  with the four rules. Done.

B. Port the missing checks into sema by category, each category's errors
before its warnings, with sema unit tests; `typeck_negative` is the
acceptance list.

- B1. Declarations, modifiers and overrides (58).
- B2. Annotations, targets, opt-in and deprecation (14).
- B3. Visibility and names, context parameters (17).
- B4. Types: initializers, assignments, defaults, returns, accessors,
  equality, throw, bounds, variance (8).
- B5. Null safety and casts (12).
- B6. Control flow (7): a structured flow pass over the syntax and sema's
  records.
- B7. suspend, inline, tailrec (7).

C. Switch: `klio check` defaults to sema; `typeck_negative` asserts kotlinc
factory names; the 46 diagnostic rows of `annotation_targets`,
`context_parameters` and `explicit_backing_fields` move to sema;
`check_examples` covers every example kotlinc accepts; `legacy_code` goes.

D. Delete, each step building: the pack typeck section (and `types` from
pack's deps); the CLI's use; the itests' use (with `cfa_builder` and
`cfa_smartcast`); `src/typeck` and `src/resolver`; `src/cfa`; `src/types`,
then `ast.annotation_targets.expandAll` and `stdlib.isKnownPackage`.

## Where it stands

`scripts/check-diff.py` over the 807 inputs on 965e4ff5 (kotlinc judges 522
examples, every typeck_negative fixture and 4 fixtures; the rest import a
library the pinned kotlinc does not ship and are taken as valid):

| Rule | Count | What |
|------|------:|------|
| 1 kept | 9 kept, 121 missing | 11 missing in examples, all warnings (`USELESS_CAST`, `UNCHECKED_CAST`, `OPT_IN_USAGE`, `UNNECESSARY_SAFE_CALL`, `NON_TAIL_RECURSIVE_CALL`); 110 in typeck_negative: phase B |
| 2 dropped | 785 | the old engine's false positives: T0112 194, T0001 173, T0091 56, UNREACHABLE_CODE 32, T0003 31, UNRESOLVED_REFERENCE 29, ... |
| 3 matched | 8 matched, 9 not | all in typeck_negative and all a factory choice; see below |
| 4 severity | 0 | |

kotlinc also reports 90 diagnostics in the examples that neither engine
does, nearly all warnings (`USELESS_IS_CHECK` 36, `NOTHING_TO_INLINE` 12),
and 125 in typeck_negative. The old engine aborts on 5 inputs, sema on none.

Measured 2026-09-26 with `klio check --format=json` over 807 inputs, the old
engine against `--engine sema`:

| Inputs | Old: inputs with errors (errors) | Sema: inputs with errors (errors) | Same line |
|--------|---------------------------------:|----------------------------------:|----------:|
| examples (673) | 211 (656), 4 aborts | 0 (0) | 0 |
| typeck_negative (120) | 108 (122) | 17 (17) | 14 |
| tests/fixtures/*.kt (14) | 3, 1 abort | 1 (2) | 1 |

The old engine also reports 134 warnings in 67 inputs; sema reports none yet.
The old engine's example errors are T0112 opt-in 193, T0001 type mismatch
173, T0091 ambiguity 56, T0003 31, R0001 29.

What the sema engine's typeck_negative answers show for phase B:

- A call no single candidate accepts is `NONE_APPLICABLE`; kotlinc names the
  one candidate's problem (`TOO_MANY_ARGUMENTS`, `ARGUMENT_TYPE_MISMATCH`,
  `UPPER_BOUND_VIOLATED`).
- An operator convention whose function lacks `operator` is reported as a
  missing function (`NO_GET_METHOD`, `DELEGATE_SPECIAL_FUNCTION_MISSING`);
  kotlinc says `OPERATOR_MODIFIER_REQUIRED`.
- An infix call of a non-infix member is reported as `INVISIBLE_REFERENCE`;
  kotlinc says `INFIX_MODIFIER_REQUIRED`.
- A class inheriting from an object reports the object unresolved; kotlinc
  says `SINGLETON_IN_SUPERTYPE`.

Time: median 0.42 s a file against 0.58 s. A compose program's first check
on a new binary bakes its base image (about 25 s); after that it takes 3 s
against the old engine's 18 s.

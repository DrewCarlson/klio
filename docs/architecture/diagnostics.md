# Diagnostics

Every pass emits diagnostics through `diagnostics.DiagnosticSink`,
which renders to plain text, JSON, or SARIF.

## Codes

| Prefix | Origin                |
|--------|-----------------------|
| `L00xx`| Lexer                 |
| `P00xx`| Parser                |
| `R00xx`| Resolver              |
| `T00xx`| Typechecker           |
| `W00xx`| Typechecker warnings  |

The full catalog (with the source spans that emit each code) lives
at `docs/design/DIAGNOSTICS.md` in the repository.

## Sema's diagnostics

`klio run` and `klio check --engine sema` report what sema finds. Each
diagnostic carries kotlinc's factory name as its code (`UNRESOLVED_REFERENCE`,
`CONFLICTING_OVERLOADS`, ...) and kotlinc's severity for it; what kotlinc has
no diagnostic for, klio names `KLIO_*` (`KLIO_UNSUPPORTED` for a construct
klio does not model yet). `@Suppress("NAME")` on a file, a declaration or a
lambda silences that diagnostic over what it annotates, and
`@Suppress("warnings")` every warning there.

A census site (`src/sema/census.zig`) is one diagnostic: its reason names
the factory unless the site names its own, an error counts toward the
census and a warning does not. `src/cli/sema_diagnostics.zig` turns the
program's sites into `Diagnostic`s for the renderers.

## Wording rules

User-facing messages must not cite the Kotlin Language Specification.
Phrase the problem and the fix in user-actionable terms:

| Prefer                                              | Avoid                                              |
|-----------------------------------------------------|----------------------------------------------------|
| `` `f` cannot be both `private` and `open` ``       | `` `f` cannot be both `private` and `open` (spec §5.4) `` |
| `expected `;` after import, found `}` `             | `import declarations end with a newline per §10.2` |

Spec citations belong in the source comment above the diagnostic
emitter, never in the message text.

## Rendering formats

```sh
klio check src/Main.kt --format plain   # default, terminal-friendly
klio check src/Main.kt --format json    # structured for editors
klio check src/Main.kt --format sarif   # CI / GitHub annotations
```

The JSON shape is stable for tool integration; the plain renderer
is the default human form and the one parity tests assert against.

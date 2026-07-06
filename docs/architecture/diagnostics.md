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
at `plans/DIAGNOSTICS.md` in the repository.

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

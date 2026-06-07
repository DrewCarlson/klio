# Hello, world

Save this to `hello.kt`:

```kotlin
fun main() {
    println("Hello, klio!")
    val xs = listOf(1, 2, 3)
    println(xs.joinToString { "${it * it}" })
}
```

Run it:

```sh
klio run hello.kt
```

```
Hello, klio!
1, 4, 9
```

## Running a module

When `klio run` gets more than one file, every file's top-level
declarations are visible to every other file — single-module
semantics. Exactly one `fun main()` must exist across the module.

```sh
klio run app/Main.kt app/Util.kt
```

## Type-checking without running

```sh
klio check hello.kt
```

`klio check` resolves names and type-checks, emits diagnostics, and
exits non-zero on any error. It does not run the program. Pass
`--format json` or `--format sarif` to integrate with editors and
CI; the default is `plain`.

## What just happened?

`klio run` walked your source through:

1. **Lexer** — UTF-8 source → token stream.
2. **Parser** — tokens → AST (`klio_ast::KotlinFile`).
3. **Pack loading** — the embedded stdlib (and any installed packs
   your file imports) merge into the module.
4. **Lowering** — `klio-ir` lowers the AST to register IR.
5. **Vm** — `klio-interp-ir` builds the IR module and runs it.

`klio check` takes a different path after parsing: it runs the
resolver and type checker to produce diagnostics. Type-checking is
not part of `klio run`.

> The `klio repl` command is currently a placeholder that echoes
> input. Use `klio run` for execution.

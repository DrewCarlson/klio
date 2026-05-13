# Hello, world

Save the program below to `hello.kt`:

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

Expected output:

```
Hello, klio!
1, 4, 9
```

## Running a module

When `klio run` is invoked with more than one file, every file's
top-level declarations are visible to every other file — single
module semantics. The runner expects exactly one `fun main()` across
the module.

```sh
klio run app/Main.kt app/Util.kt
```

## Typecheck without running

```sh
klio check hello.kt
```

`klio check` emits plain-text diagnostics by default; pass
`--format json` or `--format sarif` to integrate with editors and CI.

## REPL

```sh
klio repl
```

The REPL accepts complete expressions and top-level declarations. It
shares the same pipeline as `run`, so error messages and stdlib
coverage are identical.

## What just happened?

`klio run` walked your source through:

1. **Lexer** — UTF-8 source → token stream.
2. **Parser** — token stream → AST (`klio_ast::KotlinFile`).
3. **Resolver** — name binding, import expansion, package recognition.
4. **Typechecker** — Kotlin type system, smart-casts, constraints.
5. **CFG analyses** — definite assignment, reachability, smart-cast
   narrowing.
6. **Interpreter** — walks the typed AST and runs your program.

The standard library is loaded automatically from the embedded
`stdlib.klio-pack`. Any user-installed packs in `~/.klio/packs/`
load on top.

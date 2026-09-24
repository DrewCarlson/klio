# sema-oracle

A resolution oracle: for each Kotlin file it is given, it prints what kotlinc
(K2/FIR, the pinned 2.4.20 in `target/parity-cache/kotlinc-2.4.20`) resolved at
every call and name site. KLIO's `sema` emits the same format, so the two can be
diffed site by site with `scripts/sema-oracle-diff.py`.

It is a FIR compiler plugin (a file checker that walks the resolved tree) plus a
driver that runs `K2JVMCompiler` in-process, one compilation per file, in a single
JVM. Every file is its own compilation because corpus programs share top-level
names. The pipeline stops once the frontend is done: no JVM lowering or class files.

## Running

```sh
scripts/sema-oracle.sh [options] <file.kt | dir>... > oracle.tsv
scripts/sema-oracle-diff.py oracle.tsv sema.tsv            # text report, exit 0 iff no differences
scripts/sema-oracle-diff.py --json oracle.tsv sema.tsv     # machine-readable summary
tools/sema-oracle/check.sh                                 # regenerate testdata/sample.kt, diff with the expected dump
```

`scripts/sema-oracle.sh` builds `target/sema-oracle/sema-oracle.jar` with
`tools/sema-oracle/build.sh` when the jar is missing or older than its sources (the
build installs the pinned kotlinc if `target/parity-cache` does not have it).
Directories are searched recursively for `*.kt`.

| Option | Meaning |
|--------|---------|
| `-o <file>` | write the TSV to a file instead of stdout |
| `-j <n>` | compile `n` files concurrently (default: half the cores, at most 4) |
| `-cp <paths>` | extra classpath for every compilation, e.g. `lib/kotlinx-coroutines-core-jvm.jar` of the kotlinc dist |
| `-X...`, `-language-version <v>` | passed to every compilation (e.g. `-Xname-based-destructuring=complete`) |
| `--keep-failed` | also print the sites of files that did not compile |
| `--jvm-names` | keep JVM class names instead of mapping them to their Kotlin alias (see Targets) |
| `--debug` | print the raw FIR detail behind every site to stderr |
| `--quiet` | no summary line on stderr |

A file that fails to compile is reported on stderr as
`[oracle-fail] <path>: <line>:<col>: [DIAGNOSTIC] <first error>` and its sites are
left out. `VALUE_CLASS_WITHOUT_JVM_INLINE_ANNOTATION` alone does not fail a file:
it is a JVM restriction and resolution is complete. The last stderr line is a
summary with the number of unresolved references skipped and the throughput.

Throughput on a 10-core development machine: about 21 files/s with `-j 1` and about
50 files/s with `-j 4` (the 591 files of `examples/` in 11.5 s, including JVM start;
more jobs do not help). Most of the per-file cost is kotlinc deserializing stdlib
metadata again for each new session.

## Format

One line per resolved reference, tab-separated, sorted by path, then start, end,
kind and target:

```
path  start  end  kind  target  dispatch  extension
```

- `path`: as given on the command line (or the directory argument joined with the
  path below it).
- `start`, `end`: UTF-8 byte offsets into the file as it is on disk. kotlinc works
  in UTF-16 offsets over text with `\r\n` folded to `\n` and a BOM removed; the
  driver maps back to bytes of the original file.
- The join key is `(path, start, end, kind)`. Several lines can share a key; the
  diff compares them as multisets.

### Kinds and anchors

| Kind | Site | Anchor span |
|------|------|-------------|
| `call` | named call `f(x)`, `a.f(x)`, infix `a f b` | the callee name `f` |
| `read` | property, variable or parameter read | the name |
| `write` | assignment target, `x += 1` / `x++` on a variable or property | the name |
| `ref` | callable reference `::f`, `A::f`, `a::f` | the referenced name `f` |
| `ctor` | constructor call `A(x)` | the class name `A` |
| `ctor` | `this(...)` / `super(...)` delegation | the `this` / `super` keyword |
| `ctor` | supertype call `class B : A(x)` | the type name `A` |
| `ctor` | enum entry with arguments `E1(x)` | the entry name `E1` |
| `plus`, `minus`, `times`, `div`, `rem`, `rangeTo`, `rangeUntil`, `compareTo` | `a + b`, `a..b`, `a..<b`, `a < b`, ... | the whole binary expression |
| `contains` | `x in c`, `x !in c` | the whole binary expression |
| `contains` | `when (s) { in c -> }` | the condition `in c` |
| `equals` | `a == b`, `a != b` | the whole binary expression |
| `equals` | `when (s) { v -> }` | the condition `v` |
| `unaryMinus`, `unaryPlus`, `not` | `-a`, `+a`, `!a` | the prefix expression |
| `inc`, `dec` | `++a`, `a++`, `--a`, `a--` | the prefix or postfix expression |
| `get`, `set` | `a[i]`, `a[i] = v`, and the get/set pair of `a[i] += v`, `a[i]++` | the array access `a[i]` |
| `plusAssign`, ... and `plus`, ... | `a += b` (either form), `a[i] += b` | the whole assignment |
| `invoke` | `f(x)` where `f` is a value, `obj(x)` with `operator fun invoke` | the callee expression (`f`, `obj`, `g()` in `g()(x)`) |
| `iterator`, `hasNext`, `next` | `for (x in r)` | the range expression `r` |
| `component1`, ... | `val (a, b) = p`, in `for` and lambda parameters too | the entry name `a` |
| `getValue`, `setValue`, `provideDelegate` | `val p by d` (members, top level and locals) | the delegate expression `d` |

A desugared site also produces the plain sites it is made of: `x += 1` on a `var`
is `read x` + `write x` (both on `x`) + `plus` (on `x += 1`); `f(x)` for a value
`f` is `read f` + `invoke` on the same span; `for (x in xs)` is `read xs` plus
the three loop calls on `xs`.

Not reported: `this`/`super` expressions; unresolved references (counted on
stderr); annotations and their arguments; implicit supertype and `this()`
delegation with no syntax; the `componentN` call of a `_` entry; the `not` that
`!in` adds; `x == null` and `===`; compiler temporaries (`<iterator>`,
`<destruct>`, `x$delegate`); the `thisRef`/`::p` arguments of delegate calls;
implicit context arguments; bodies the compiler generates (data class members,
property-from-parameter initializers); the subject re-reads of `when (s) {}`
branches; the implicit `toLong()` of an integer literal expression. A sign on an
integer literal without a suffix (`-1`, `+2`, `-(1)`, `-0x10`) is folded into the
literal by FIR and reports nothing, while `-1L`, `-1.5` and `-1.5f` are
`unaryMinus`/`unaryPlus` calls.

### Targets

The resolved declaration, with fake and substitution overrides unwrapped to the
declaration they come from, so an inherited member names the class that declares it.

- Callables: `<owner>.<name>|<extension receiver>|<parameters>`. The owner is
  `package/path/Class` for members (package with `/`, nested classes with `.`)
  and `package/path/` for top-level callables (nothing in the root package):
  `kotlin/collections/List.get||kotlin/Int`, `kotlin/io/println||kotlin/Any?`,
  `kotlin/collections/first|kotlin/collections/List|`, `area||Point`.
  Properties have an empty parameter list. Context parameters are not part of the
  parameter list.
- Constructors: `<Class>.<init>||<parameters>`. A constructor reached through a
  typealias names the class the alias expands to.
- Parameters and receivers are the declared, unsubstituted types, erased: a class
  type is its ClassId (`kotlin/collections/List`), a type parameter its name (`T`),
  a function type its class (`kotlin/Function1`, `kotlin/coroutines/SuspendFunction1`),
  `?` marks nullable, a trailing `...` a vararg element (`T...`), `T&Any` a
  definitely-non-null type, and `!` a Java platform type (`kotlin/String!`; the
  diff tool matches it against `T` or `T?`). Typealiases are expanded.
- Locals, parameters and local functions: `local:<name>@<byte offset of the declaration>`.
  The declaration starts where its PSI starts, so modifiers, annotations and a KDoc
  comment are included; the implicit `it` starts at the lambda's `{`.
- Local and anonymous classes: `local:<Name>@<offset>` wherever a class is named
  (`local:<anonymous>@<offset>` for `object :`), so their members are
  `local:Loc@120.twice||`.
- Objects and companions used as values, including as an explicit receiver
  (`Obj.f()`, `Outer.g()` through the companion): `object:<ClassId>`, kind `read`,
  on the qualifier's name.
- Enum entries: `enum:<ClassId>.<ENTRY>`. Backing fields: `field:<property>`.
  SAM constructors (`Runnable { }`): `sam:<interface ClassId>`.
- `==`: FIR does not bind `==` to a member, so the oracle reports the `equals(Any?)`
  that the left operand's type sees (`kotlin/Int.equals||kotlin/Any?`, a data
  class's own `equals`, else `kotlin/Any.equals`).

JVM classes that the stdlib declares as `actual typealias` are printed under the
Kotlin name (`java/util/ArrayList` as `kotlin/collections/ArrayList`,
`java/lang/IllegalStateException` as `kotlin/IllegalStateException`,
`java/lang/StringBuilder` as `kotlin/text/StringBuilder`). A member declared in a
JDK class with no Kotlin name is printed under the receiver's class
(`StringBuilder().length` is `kotlin/text/StringBuilder.length`, not
`java/lang/AbstractStringBuilder.length`). `--jvm-names` turns both off.

The oracle reflects the JVM stdlib, which is not the common one KLIO implements:
`println(1)` resolves to the JVM-only overload `kotlin/io/println||kotlin/Int`,
and Java members keep Java signatures (`StringBuilder.append(String!)`).
`--exclude-target` on the diff tool drops such known differences.

### Receivers

`dispatch` and `extension` say where each receiver came from:

| Value | Receiver |
|-------|----------|
| `-` | none (also static Java members and enum entries, where FIR keeps the class qualifier) |
| `expr` | an explicit receiver: `a.f()`, `this.f()`, `super.f()`, `a?.f()`, the object in `Obj.f()`, the operand of an operator, the value in an implicit `invoke` |
| `this@<ClassId>` | the implicit `this` of a class, including an outer class from an inner one |
| `obj@<ClassId>` | the implicit `this` of an object or companion (`make()` inside `companion object`, `K` from the class body) |
| `ext@<callable>` | the implicit receiver of an enclosing extension function or property (`ext@norm1`, `ext@demo/pkg/lastCh`) |
| `lambda@<offset>` | the implicit receiver of a lambda with receiver; the offset is the lambda's `{` (or `fun` of an anonymous function) |
| `ctx@<name>` | a context parameter standing in for a receiver (reserved: Kotlin 2.4 context parameters are passed as context arguments, never as a dispatch or extension receiver, so it does not appear) |

## The sema side

`klio sema --dump PATH` writes sema's resolution of the program files in this
format (`src/sema/dump.zig`, names from `render.Namer` in `src/sema/render.zig`).
`--each` analyzes every program file as its own program, the way the oracle
compiles each file on its own: the base set is parsed once, each program gets a
fresh analysis in a forked child (so a panic costs that file only and is reported
as `[sema-file] <path> failed: <panic line>`), several at a time (`-j N`).
`--unresolved PATH` writes the census sites of the program files
(`path start end reason detail`).

```sh
scripts/sema-oracle-compare.sh -o out examples            # oracle + klio sema --each + diff
scripts/sema-oracle-compare.sh --oracle out/oracle.tsv -o out examples   # reuse the oracle run
scripts/sema-oracle-triage.py out/oracle.tsv out/sema.tsv out/sema.unresolved.tsv
```

The compare script gives both tools the same sorted file list, leaves out the
files kotlinc could not compile and the programs sema did not finish, and keeps
`oracle.tsv`, `sema.tsv`, `sema.unresolved.tsv`, the census and the diff under
`-o DIR`. A program that needs a language version or an experimental feature
says so in its first lines as `// kotlinc: <flags>` (for example
`// kotlinc: -language-version 2.5`); the compare script runs the oracle once per
distinct flag set and merges the dumps. The triage script sorts every difference into a cause owned by `sema`
(resolution), `dump` (representation) or `oracle` (JVM answers).

### Kinds

`records.RefKind` maps to the oracle's kinds one to one (`has_next` is `hasNext`,
`get_value` is `getValue`, ...); `op`, `op_assign` and `component` print the
convention name they resolved (`plus`, `plusAssign`, `component2`), and `object`
(a classifier used as a value) prints `read`. Class literals are not printed: the
oracle reports none.

### Representation the dump corrects

Where sema and kotlinc agree on the declaration but model or span it
differently, the dump prints kotlinc's form. Each correction reads the program
file's text and tokens.

- Declaration offsets. The parser starts a declaration at its keyword or name;
  kotlinc's PSI starts it at its first modifier or annotation, and, for a local
  declaration, at the comments its comment binder attaches: the nearest doc
  comment for any declaration, and for a local function or class also the plain
  comments that start a line directly above it (up to a blank line). A local
  property binds doc comments only. A parameter includes `vararg`,
  `crossinline`, `val`/`var` and annotations but no comments. `val x by d` and
  `when (val v = s)` start at `val`.
- Backing fields. sema declares `field` as a local of the accessor; kotlinc names
  the property's field, `field:<property>`, read through the property's receiver
  (`this@Class` for a member).
- Template entries. `"$name"` and `$$"$$name"` are spanned from the `$`; kotlinc
  anchors the name.
- Parentheses. The parser keeps no node for `(e)`, so an operator whose operand is
  parenthesized is spanned inside the parentheses (`"a" + (b + c` without the
  `)`); the dump widens an expression anchor until its parentheses balance.
- Name anchors. A constructor call with type arguments (`ArrayList<String>()`) is
  anchored on the name alone; `constructor() : super(x)` is anchored on `super`;
  `when (x) { in c -> }` is anchored on `in c`.
- `invoke` through a value. sema records `this()` or `(::f)()` as a call of
  `FunctionN.invoke`; kotlinc as an implicit invoke. A call of `invoke` whose
  anchor is not the name `invoke` prints as `invoke`.
- Sites kotlinc has none for: the enum constructor an entry without arguments
  calls, and references to the parser's desugaring temporaries (`$`-named
  locals).
- Anonymous classes. An object expression and an enum entry's body are
  `local:<anonymous>@offset`; members of local classes are
  `local:Name@offset.member`, and a class nested in a local class is local too.

Differences the dump does not correct, because the record does not carry what
kotlinc's form needs: the anchor of an `invoke` whose callee is a call or a
parenthesized expression (`g()(x)`, `(f)(x)`: kotlinc anchors the callee
expression, sema its name), and nested prefix operators (`!!p`), which the parser
spans alike.

## Layout

- `src/Plugin.kt`: the plugin registrar, the FIR file checker, and the IR hook
  that ends the compilation after the frontend.
- `src/Walker.kt`: the FIR walk, site kinds, PSI anchors and receiver origins.
- `src/Renderer.kt`: target, type and receiver rendering.
- `src/Driver.kt`, `src/Collector.kt`: the in-process driver and offset mapping.
- `testdata/sample.kt`, `testdata/sample.expected.tsv`: the hand-checked sample
  behind `check.sh`.

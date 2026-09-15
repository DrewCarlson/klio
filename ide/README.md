# KLIO for IntelliJ IDEA

An IntelliJ plugin that makes a klio project work the way a Kotlin project works:
completion, go to definition, find usages, refactorings, and inspections, all served
by the official Kotlin plugin, plus run and test integration driven by the `klio`
binary.

The plugin analyses nothing itself. It builds a workspace from what `klio ide model`
prints and lets the Kotlin plugin do the rest.

## How it fits together

```
klio.toml + installed packs
          |
          |  klio ide model --project <dir>
          v
   project model JSON  ------>  IntelliJ modules, content roots,
   materialised .kt source      dependencies, Kotlin facets
          |                                   |
          v                                   v
   $KLIO_HOME/.klio/ide/**           official Kotlin plugin (K2)
```

The CLI answers every question about how a project composes. The plugin never parses
`klio.toml`, walks the pack cache, or decodes a `.klio-pack`.

Each klio source set becomes one module. A root that declares `expect` becomes its own
module, and the roots that actualise it refine it through `dependsOn`, which is the
same edge the Kotlin Gradle importer builds for a multiplatform project. No JVM, JDK,
Gradle, or kotlinc is involved in the project being edited.

Materialised pack sources are indexed, resolved and navigable, but not highlighted:
klio deliberately tolerates things the Kotlin frontend rejects, and a library the user
cannot edit has no business painting their project red.

## Building

The plugin itself is JVM code built with Gradle. That is developer-side only and never
reaches a klio user.

```sh
gradle -p ide compileKotlin   # compile
gradle -p ide buildPlugin     # a distributable zip under ide/build/distributions
gradle -p ide runIde          # a sandbox IDE with the plugin loaded
```

`runIde` puts `../zig-out/bin` on PATH, so the sandbox picks up a locally built klio.

## The self-check

`KlioSelfCheckStarter` runs the whole integration headlessly against a real project:
open, sync, resolve, navigate, and build run configurations. It is the fastest way to
tell whether a change to the model or the importer still works.

```sh
KLIO_IDE_SELFCHECK=/path/to/klio/project KLIO_HOME=/path/to/data/home \
  gradle -p ide runIde
```

Every assertion prints one `[selfcheck]` line and the process exits non-zero on the
first failure.

## Where the pieces live

| File | Role |
|------|------|
| `KlioCli.kt` | Finds and drives the klio binary. The only place that shells out. |
| `KlioModel.kt` | The `klio ide model` document, and the schema check. |
| `KlioProjectImporter.kt` | Modules, content roots, dependencies, Kotlin facets. |
| `KlioHighlightFilter.kt` | Keeps materialised library source out of the red. |
| `KlioRunConfiguration.kt` | Run and test configurations, and the console filter. |
| `KlioRunContext.kt` | Gutter icons, context producers, the test locator. |
| `KlioSyncNotification.kt` | The sync banner on an edited `klio.toml`. |
| `KlioManifestCompletion.kt` | Completion inside `klio.toml`, from the installed pack catalogue. |
| `KlioNewProjectWizard.kt` | New Project | KLIO, scaffolding through `klio pack new`. |
| `KlioSettingsConfigurable.kt` | Settings | Tools | KLIO: the binary, and the data home. |
| `KlioReadOnlyPackSources.kt` | Materialised pack sources are a view, not editable. |
| `KlioProjectState.kt` | The last model a sync produced, and the workspace watches. |
| `KlioStartupActivity.kt` | Syncs a project with a `klio.toml` when it opens. |
| `KlioSyncAction.kt` | Tools | Sync KLIO Project. |
| `KlioSelfCheck.kt` | The headless verification run. |

## Two findings worth keeping

**A klio `IdePlatformKind` is registrable but not usable.** klio code is not JVM, JS,
Wasm, or Native, and `org.jetbrains.kotlin.idePlatformKind` is an open extension point.
Registering one anyway breaks the IDE: `IdePlatformKindProjectStructure` switches over
a fixed set of kinds and throws for anything else, and `getDefaultTargetPlatform` walks
every registered kind, so one extra kind breaks facet defaults for every module, not
only klio's. klio modules analyse on the common (metadata) platform instead, which is
accurate, and the model still distinguishes `klio` from `common` per module.

**Packs have to be modules, not libraries.** A library whose roots hold Kotlin source
rather than compiled output resolves nothing, and source is all klio has. This was
measured against the real thing, not assumed — an early probe that left the pack
modules in place reported the opposite, because the lingering modules were answering.

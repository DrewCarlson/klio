# Pack distribution — native consolidation, application binaries, workspaces, dependency sources

Status: design. Continues [`PACK-ROADMAP.md`](./PACK-ROADMAP.md)
(phases 6–12) and builds on [`PACK-DESIGN.md`](./PACK-DESIGN.md). The
roadmap delivered the container format, the binding registry, the
embedded stdlib, and per-FQN native bindings. This document plans four
capabilities, numbered 13–16 to continue the roadmap, sharing its gate
(workspace tests green, `klio pack verify` over every shipped pack, one
example program per capability).

1. **Native consolidation** — collapse all native Rust into a generic
   stdlib primitive surface; every `kotlinx-*` pack becomes pure Kotlin
   built on it; the `klio-kotlinx-*` Rust crates are deleted.
2. **Application packs** — a pack runs as a single fast-start binary.
3. **Workspace packs and features** — kotlinx-style multi-module
   library groups with cargo-style feature selection.
4. **Dependency sources** — third-party packs fetched and run via
   `klio run`.

---

## Locked decisions

| Question | Decision |
|----------|----------|
| Third-party native Rust in packs | **Not supported.** No dynamic loading, no cdylib, no C-ABI, no signing/linking. Revisit in the far future only. All native code lives in the klio binary. |
| Shape of in-binary native code | A **generic, library-agnostic primitive surface in `klio-stdlib`** (e.g. `currentSystemMs()`), not named after any kotlinx library. `kotlinx-*` packs are pure Kotlin that *build on* these primitives. |
| Heavy deps (`chrono`, `ureq`+TLS) | **Always compiled into klio.** No build-feature matrix. |
| Meaning of "AOT" for application packs | **Embedded IR snapshot**: frozen lowered `klio-interp-ir` + runtime + packs in one executable. No native code generation. |
| Dependency-source transports | Path, git, and HTTP registry, behind one resolver and one lockfile. |
| Integrity / trust | Third-party packs are guaranteed pure-Kotlin, so integrity is the existing blake3 `pack_hash` pinned in a lockfile. The only signed artifact is the klio / klio-runner binary itself (one app, standard OS signing). |

Because no native code ever crosses a process boundary, the in-process
Rust ABI stays purely internal; `PackManifest::abi_version` remains the
only versioning knob (roadmap phase 12 policy unchanged).

---

## Native surface inventory (today)

Six `klio-kotlinx-*` crates register 59 FQNs, all already statically
linked into the klio binary via `merged_host_bindings()`
(`klio-cli/src/main.rs:1303`–`1313`). They split into four kinds:

| Pack | FQNs | Kind | Disposition |
|------|-----:|------|-------------|
| atomicfu | 24 | atomic / CAS (direct method bindings, `auto_bindings`) | generic atomic-cell primitives in stdlib |
| io | 4 | base64 / hex (perf only) | generic codec in stdlib (pure-Kotlin or intrinsic); drop `base64` dep |
| datetime | 9 | 3 clock/tz primitives + 6 chrono civil-time math | generic clock + civil-time primitives in stdlib (chrono) |
| coroutines | 19 | scheduler / suspension, coupled to klio-interp-ir | generic scheduler primitives in the runtime/stdlib layer |
| serialization | 3 | reflective `@Serializable` dispatch | generic reflection primitives in stdlib |
| ktor | 4 | HTTP via `ureq` (TLS/sockets) | generic HTTP primitive in stdlib (ureq) |

The datetime/coroutines/serialization/ktor crates already call
prefixed bridge intrinsics (`__kxdt_*`, `__kxco_*`, `__klsx_*`,
`__kktor_*`) from their Kotlin source — the consolidation re-expresses
those as a *generic, non-kotlinx* surface and rewrites the Kotlin to
call the generic names.

---

## Phase 13 — Generic stdlib native primitives; pure-Kotlin kotlinx packs

**Goal.** One generic native primitive surface in `klio-stdlib`. Every
`kotlinx-*` pack ships pure Kotlin that builds its public API on those
primitives. The six `klio-kotlinx-*` Rust crates are deleted;
`merged_host_bindings()` collapses to stdlib only.

### 13.1 Generic primitive surface and naming

- Native primitives are named for *what they do*, not for the library
  that first needed them. Where a real Kotlin home exists, use it
  (clock under `kotlin.time` / `kotlin.system`; reflection under
  `kotlin.reflect`; base64/hex under `kotlin.io.encoding`). Where
  Kotlin has no home (civil-time math, HTTP, coroutine scheduler), use
  a single internal stdlib intrinsic namespace.
- Registration moves into `klio-stdlib`'s host-binding registry
  (`HostBindings::with_stdlib_defaults`, `klio-stdlib/src/lib.rs:367`).
  No new crate; chrono/chrono-tz/iana-time-zone/ureq become
  `klio-stdlib` dependencies (always compiled).
- A `kotlinx-*` pack stays a pack: `klio.toml` + curated upstream
  Kotlin + a `klioMain`/`shim` layer whose actuals now call the
  generic stdlib functions. No `[bindings]` section, no Rust crate.

### 13.2 atomics → generic atomic-cell primitives

- Add generic int/long/bool/ref atomic-cell intrinsics (`cas`,
  `getAndSet`, `getAndAdd`, RMW) to stdlib.
- `kotlinx.atomicfu` `klioMain` actuals delegate to them. The 24
  direct method FQNs disappear from a kotlinx crate; the behavior is
  provided by the generic cells.
- Delete `klio-kotlinx-atomicfu/src` Rust; keep the pack.

### 13.3 reflection → generic introspection primitives

- Add generic primitives: primary-constructor parameter names,
  property get/set by name, construct by constructor + args.
- `kotlinx.serialization` `klioMain` (the compiler-plugin replacement)
  calls the generic reflection primitives. The reified-generic parser
  blocker (`klio.toml` note) is unchanged and orthogonal — the
  `klioMain` Kotlin shim stays.
- Delete `klio-kotlinx-serialization/src` Rust; keep the pack.

### 13.4 civil time → generic clock + civil-time primitives

- Add generic primitives: wall-clock millis + sub-second nanos, system
  default timezone id, and civil-time math backed by chrono
  ((epoch, tzId) ↔ Y-M-D-h-m-s+offset, tz validation, calendar-period
  add).
- `kotlinx.datetime` `klioMain` (Instant/LocalDateTime/TimeZone/Clock)
  builds on the generic primitives.
- Delete `klio-kotlinx-datetime/src` Rust; keep the pack.

### 13.5 base64 / hex → generic codec

- Provide generic base64/hex in stdlib under `kotlin.io.encoding`
  (pure-Kotlin acceptable; the perf intrinsic is not required).
  Removes the `base64` dependency.
- `kotlinx.io` uses the generic codec. Delete
  `klio-kotlinx-io/src` Rust; keep the pack.

### 13.6 HTTP → generic platform HTTP primitive

- Add one generic HTTP primitive: `request(method, url, headers, body)
  → response`, backed by `ureq` (TLS via rustls), always compiled.
- `io.ktor.client` `shim` builds the engine/DSL on the generic
  primitive. Delete `klio-ktor-client/src` Rust; keep the pack.

### 13.7 coroutine scheduler → generic runtime primitives

Deepest coupling and largest single piece — overlaps roadmap
phase 9.1; treat as its own effort.

- The 19 `__kxco_*` bindings are the coroutine runtime, not a library:
  consolidate them as generic scheduler/dispatch/cancellation/park
  primitives owned by the interpreter + stdlib runtime layer.
- `kotlinx.coroutines` `shim` (Dispatchers / launch / async / Job /
  channels / flow) builds on the generic scheduler primitives.
- Delete `klio-kotlinx-coroutines/src` Rust; keep the pack.

**Acceptance (per sub-phase).** Every existing example and parity
program that uses the pack produces byte-identical output; the
corresponding `klio-kotlinx-*` crate contains no Rust;
`merged_host_bindings()` no longer merges it; `cargo test --workspace`
green. When all sub-phases land, `merged_host_bindings()` is stdlib
only and no `klio-kotlinx-*` crate has a `src/lib.rs`.

**Dependencies.** None beyond the current tree; 13.7 pairs with roadmap
phase 9.1.

---

## Phase 14 — Application packs: one fast-start binary

**Goal.** Package an application as a single runnable binary with
optional embedded dependency packs, eliminating
parse/resolve/typecheck at startup. With phase 13 done, packs carry no
native blobs, so this is purely Kotlin/IR plus the runtime.

### 14.1 Application manifest and IR section

- `klio.toml` gains `[application]`: `entrypoint =
  "com.example.MainKt.main"`, `embed_deps = true|false`.
- `PackManifest` (`klio-pack/src/schema.rs:19`) gains
  `kind: PackKind { Library, Application }`.
- New optional section `ir` — the lowered `klio-interp-ir` module,
  serialized behind a `serde` feature flag exactly as roadmap 7.1 did
  for `ast`. Loading `ir` skips the front end entirely.

### 14.2 Self-contained binary

A prebuilt minimal `klio-runner` (runtime + a launcher that mmaps its
own trailing payload via an appended footer: magic + offset + length).
`klio build` / `klio pack bundle`:

1. Builds the application pack with the `ir` section.
2. Copies the `klio-runner` for `--target`.
3. Appends a multi-pack container: the application pack plus, when
   `embed_deps`, every non-core dependency pack. Core stdlib stays in
   `klio-runner` (as today via `klio-stdlib-pack`/`include_bytes!`).
4. Writes the footer; signs the binary on macOS (one app, standard).

Multi-platform here is an ordinary Rust cross-build of one binary
(Tier-1: `aarch64-apple-darwin`, `x86_64-unknown-linux-gnu`; Tier-2
outlined: `*-pc-windows-msvc`, `aarch64-unknown-linux-gnu`) — no
per-pack native, no plugin signing.

### 14.3 CLI

- `klio build [--target <triple>] [--out <path>] [--no-embed-deps]`.
- `klio pack bundle` — explicit form.
- `klio run <app.klio-pack>` detects `kind == Application` and executes
  the `ir` entrypoint directly.

**Acceptance.** `klio build` on an example with one non-core dependency
produces a binary that runs on a clean machine with no klio installed
and no source present; startup measurably drops versus running
sources; output byte-identical.

**Dependencies.** Roadmap phase 7 (frozen front-end sections; `ir`
follows the same serde-feature pattern). Phase 13 (packs are
native-free, so bundling is Kotlin/IR only).

---

## Phase 15 — Workspace packs and features

**Status: feature selection landed (15.2 + CLI); workspace members (15.1)
still open.** A pack's `klio.toml` now carries a `[features]` table:
`default = [...]` plus named features `{ sources, deps, requires }`.
`PackManifest` gained `default_features` + `features`; `PackDependency`
gained `features` + `default_features`. Feature-gated `[[source]]` roots
(by path prefix) load only when active — the pack's ungated files are the
always-loaded core. A consumer selects features with `klio run --feature
<pack>/<name>` (repeatable, also on `klio check`); an active feature's
`deps` pull in their packs and `requires` expand transitively. An import
of a gated package that isn't enabled prints an actionable
`--feature <pack>/<name>` hint, and `klio pack inspect` lists the
features. The on-disk format bumped to v2 (postcard is sequential, so
older packs are rejected on read and must be rebuilt). The ktor pack is
split along its Gradle modules: core (`io.ktor.http`) is default;
`client`, `server`, `client-serialization`, `server-serialization` are
opt-in. The kotlinx.serialization pack is likewise split: the reflective
serialization-core is the default; the JSON format is the opt-in `json`
feature. A feature's `deps` entry takes a `lib/feature` suffix so an
active feature can request features of the pack it pulls (ktor's
serialization layers activate `kotlinx.serialization/json` transitively).
Still open: 15.1 workspace members / one-command multi-artifact
builds (`--workspace`), and requesting a dependency's features when the
dependency loads before its dependent.

**Goal.** Manage kotlinx-style multi-module libraries (e.g.
`serialization-core` + `serialization-json`) as independent artifacts
under one project, with cargo-style feature selection downstream.

### 15.1 Workspace manifest

```toml
[workspace]
members = ["core", "json", "cbor"]
```

Each member is its own library with its own `klio.toml`, producing an
**independent `.klio-pack` artifact** (artifacts stay separable, not
fused). The top-level pack is the core/shared umbrella — possibly an
empty shell depending on `core`, giving downstream one stable id.

### 15.2 Features map to member artifacts

```toml
[features]
default = ["core"]
json    = { deps = ["kotlinx.serialization.json"] }
cbor    = { deps = ["kotlinx.serialization.cbor"] }
```

```toml
[[deps]]
id = "kotlinx.serialization"
features = ["json"]
default-features = true
```

The resolver expands requested features to the transitive set of
member packs. `PackManifest` gains `provides_features: Vec<String>`;
`PackDependency` gains `features: Vec<String>` and
`default_features: bool`. Feature-gated `[[source]]` roots within a
member are also supported, but feature → member artifact is the
recommended, default-documented shape (artifacts stay independent and
addressable by `pack_hash`).

### 15.3 CLI

- `klio pack build` learns `--workspace` (build all members, topo
  order) and `--feature <name>`.
- `klio pack list` / `inspect` show provided features and membership.

**Acceptance.** A two-member workspace builds two independent artifacts
in one command; a consumer requesting `features = ["json"]` loads
exactly core + json; no features loads only the umbrella/core.

**Dependencies.** Roadmap phase 8 (pack-to-pack deps + topo sort).

---

## Phase 16 — Dependency sources and `klio run` on a project

**Goal.** A manifest declares where third-party packs come from; `klio
run` on a project resolves, fetches, locks, and runs them. All
third-party packs are pure Kotlin (phase 13), so there is no native
trust problem.

### 16.1 Dependency source kinds

`[[deps]]` gains a `source` (default: registry):

```toml
[[deps]]
id = "myorg.crypto"
source = { registry = "https://packs.example.dev" }

[[deps]]
id = "myorg.util"
source = { git = "https://github.com/myorg/util", rev = "a1b2c3d" }

[[deps]]
id = "local.helpers"
source = { path = "../helpers" }
```

One `Resolver` trait, three transports together:

- **path** — read in place; never hash-locked (it is the source).
- **git** — clone/checkout into `~/.klio/git/<url-hash>/<rev>`, build,
  cache by `pack_hash`.
- **registry** — generalize the existing local-filesystem registry
  (`PackCmd::Publish/Search/Fetch`, `klio-cli/src/main.rs:153`–`176`)
  to an HTTP index + pack download, same Maven-like layout, verified
  against the lockfile hash.

### 16.2 Lockfile

`klio.lock` pins each resolved dependency as `(id, version, source,
pack_hash)` — `pack_hash` is the existing blake3 content address, so a
lock is a strong integrity guarantee. Resolution is offline if the
lock is satisfiable; `klio pack update` re-resolves. Path deps recorded
without a hash pin.

### 16.3 `klio run` project mode

| Argument | Behavior |
|----------|----------|
| `.kt` file(s) | unchanged — current single-module run |
| directory or `.` with `klio.toml` | project mode: read manifest + lock, resolve graph, fetch missing into cache, install in topo order, run `[application].entrypoint` (or `fun main`) |
| `<app.klio-pack>` | phase 14 application execution |

`--locked` (CI) refuses to mutate the lock; `--offline` forbids network
and requires a satisfiable lock; fetches print what they download.

### 16.4 Trust

Integrity is the blake3 `pack_hash` pinned in `klio.lock`; registry
downloads must match or fail. git/path are trust-on-first-use, pinned
by the lock thereafter. No native code is ever fetched, so there is no
code-signing requirement on dependencies; the only signed artifact is
the klio / klio-runner binary itself (phase 14, macOS, standard,
once).

**Acceptance.** A project with one path, one git, and one registry dep
runs via `klio run .` with no prior `pack install`; re-running offline
with the lock succeeds; a tampered registry pack (hash mismatch) fails
clearly; `--locked` fails when the manifest drifts from the lock.

**Dependencies.** Roadmap phase 8 (topo sort), phase 11 (registry
groundwork), phase 15 (feature-aware resolution), phase 14 (a resolved
project can also be `klio build`-bundled).

---

## Sequencing

```
roadmap  9 ──► 13 (native consolidation; 13.7 pairs with roadmap 9.1)
roadmap  7 ──► 14 (application binary)            [needs 13: packs are native-free]
roadmap  8 ──► 15 (workspace + features)
roadmap 8,11 ─► 16 (dep sources + run-a-project)  [needs 15, pairs with 14]
```

13 is the keystone: it removes every native special case the later
phases would otherwise have to handle (bundling, trust, multi-platform
all become Kotlin/IR-only). Its sub-phases are independent and can land
one library at a time; 13.7 (coroutines) is the largest and overlaps
roadmap phase 9.1. 14 and 15 are independent of each other once their
roadmap prerequisites are in. 16 closes the loop. Each phase ends on
the standard gate.

## Manifest schema delta (summary)

Additive, forward-compatible with the existing `LibraryToml` parse
(`klio-cli/src/main.rs:744`) and `PackManifest`
(`klio-pack/src/schema.rs:19`):

- `[application]` — `entrypoint`, `embed_deps`.
- `[workspace]` — `members`.
- `[features]` — named feature → `{ deps, sources }`.
- `[[deps]]` — `source = { path | git+rev | registry }`, `features`,
  `default-features`.
- `PackManifest` — `kind: PackKind`, `provides_features`.
- New sections — `ir`. New artifact — `klio.lock`.
- Removed — `[bindings]` sections and `auto_bindings` become unused for
  the kotlinx packs once phase 13 lands (no per-pack native).

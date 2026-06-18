# Memory audit — startup, ktor, and lifetime (measured)

All on the current binary, macOS, RSS = `maximum resident set size` (exiting
programs) or `ps -o rss` (the long-running server). ktor runs use the five
installed packs (`--feature io.ktor/...`).

## Startup (initial) RSS

| Program | arena | gc | free |
|---|---|---|---|
| `println("hi")` | 47.5 | **42.0** | 44.4 |
| collections (map/filter/groupBy) | 49.4 | **42.5** | 46.8 |
| parse-error (no stdlib decode) | — | **5.5** | — |
| ktor **server** (routing + ContentNegotiation + `@Serializable`) | — | **234.8** | 211.5 |
| ktor **client** (`HttpClient` + 1 GET, exits) | 601.9 | **129.8** | — |

Basic/stdlib are Node-parity (~42 MB gc, floor 5.5 MB). ktor is far heavier: the
ktor image is 14.4–14.7 MB on disk (vs 6.8 MB basic) and `image.decode` is
**+50.8 MB / 135 K allocs** (basic ~20.8 MB). The client allocates ~550 MB of
transient per-request data (arena 602 MB for one GET; gc reclaims to 130 MB).

The ktor-startup number is what the lazy/position-independent image
(`plans/LAZY-IMAGE.md`) targets — it would help ktor most, since a program uses
a small fraction of that 50 MB forest.

## Lifetime RSS — ktor server under sustained requests (BUG: per-request leak)

Mixed GET/POST(JSON) load, sampling the server PID's RSS:

| mode | start | trajectory | rate | drops on idle? |
|---|---|---|---|---|
| gc (default 8 MB threshold) | 235 | → 337 MB over 7,500 req | ~13.6 KB/req | no |
| gc (256 KB threshold) | 155 | → 2,715 MB over 3,000 req | ~850 KB/req | no |
| free | 211 | → 4,150+ MB over 1,500 req, then dies at the cap | ~2.7 MB/req | n/a |

RSS climbs **monotonically and never drops on idle** — genuine retention, not GC
sawtooth. It is **pathologically GC-frequency-sensitive**: collecting more often
makes it ~60× worse. That inversion (more GC → more retention) is the strongest
lead — request/connection state is being re-rooted or pinned across collections
in the serve path. Despite task #6 ("Flatten ktor RSS… eliminate residual
per-request leaks") being marked done, the real serving path is **not**
leak-free. OPEN.

## gc-as-default blocker (BUG: use-after-free on heavy coroutine I/O)

Flipping the default reclaim mode to `gc` (the only mode that bounds long-run
memory) surfaced a **deterministic use-after-free** that arena masks: a 1 MB+
channel write crashes under gc with `BinOp.Less on null and 0` in
`kotlinx.io.checkOffsetAndCount`. A collection fires *mid-write* in the writer
coroutine and reclaims a live `Long` that a host call still holds — a
host-keepalive gap (task #2, in_progress). The frame chain is GC-rooted, so the
collected value is held only by a host function across a re-entry into Kotlin
(the kotlinx.io Buffer/write path), not by `Frame.regs`.

Small programs never allocate enough (>8 MB) to trigger a mid-coroutine
collection, which is why the corpus passes under gc — but any heavy coroutine
I/O (channels, ktor request/response bodies) can hit it. A deterministically-
crashing default is worse than a leaky-but-correct one, so the default stays
`arena` until host-keepalive is complete; `KLIO_RECLAIM=gc` remains selectable.
Repro: `KLIO_RECLAIM=gc klio run --feature io.ktor/io <1MB-channel-write>`.

### Path to making gc the default
1. Complete host-keepalive (task #2): every host re-entry site that can trigger
   a collection while holding a `Value` must `keepalivePush` it. The channel/
   Buffer write path is the first confirmed gap.
2. Re-run the full suite + ktor itests under gc-as-default (the validation that
   found this); fix every UAF it surfaces (under-retention = crash, the
   dangerous direction).
3. Then flip `allocChoice()`'s unset default to `.gc` and re-validate.

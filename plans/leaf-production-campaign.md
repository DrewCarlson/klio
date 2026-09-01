# Leaf-production campaign: gate the compose-ui surface, bank the leaves

STATUS 2026-09-01: NOT STARTED. Successor to
plans/object-runtime-campaign.md (closed complete): the leaf vehicle
works but lives on scratchpad probes, and the compose-ui examples still
have no standing gate — the census-gap lesson fired twice on exactly
that surface.

## Measured starting facts (do not re-derive)

- Corpus 404/404 today; the window/draw family was bake-order-flaky
  until the file-scope class-pick fix and went 17 days unwatched
  because corpus_check has no standing gate.
- Leaf vehicle (KLIO_LEAVES): datetime census 119 -> 109-111s / 519-0;
  litmus 4.8x; companion wrapper shape 2.46x. Leaves must be emitted
  under the consumer's body-transforming env (KLIO_COMPOSE_PLUGIN
  trap) and are fqn#sig-keyed, bake-independent.
- The fromEpochDays census child's residue is assertEquals plumbing +
  LocalDate.equals + `next` — TEST-CLOSURE code, not in any pack
  surface leaves today.
- vpd logged 66,975 serves + 100,004 BAILS wall-neutral: each bail is
  marshal + partial body — a repeated-bail damper is a measured vein.
- The anon/companion invoker resolves through `funcAt`, which returns
  a Func COPY, so its leaf_route memo is discarded every call (the
  mutex+fqn lookup tax the memo exists to kill).
- Warm full stack 591-606s; the stack tail (after the census build
  drains, litmus window) has idle slack for a short example gate.

## Task 1 — standing compose-ui example gate

- A fast gate step running the bake-order-sensitive family
  (compose_window, compose_multiwindow, compose_material3_text,
  compose_foundation_draw, compose_foundation) against expected
  outputs on the warm local home: an itest step or script wired into
  stack.sh's quiet tail. Budget ~2-3 min warm; must not move the
  stack wall materially.
- The FULL corpus_check joins the pre-commit gate path
  (scripts/gate.sh) so the whole example surface can never go
  unwatched for weeks again.
- Cold-bake artifacts (material3's ~60s first run) must not flake the
  gate: warm the image cache first or budget for it.

## Task 2 — leaf packs in the standing verification path

- Build per-surface leaf libraries as artifacts (datetime first;
  kotlin/kotlinx wide second) at a defined point — pack install or a
  dedicated build step — under the consumer env, and wire KLIO_LEAVES
  into klio-census + the census suites in stack.sh. The datetime
  census win becomes the standing number, gates unchanged.
- Test-closure leaves: emit leaves from the suite's test source set
  too (assertEquals path, LocalDateTest's `next`), measured against
  the fromEpochDays child's wall.
- Repeated-bail damper: a per-(fn,shape?) sticky note after N
  consecutive bails stops re-attempting a leaf that always bails —
  measured on vpd's 100k-bail profile; must not disable leaves that
  serve other genre shapes.
- Anon-invoker route memo: resolve through the module's Func pointer
  so leaf_route persists; measure the companion-dispatch tax.

## Standing policy

- Measurement-first; every landed piece shows before/after on a named
  number (stack wall, census wall, serve/bail counters).
- Correctness gates never weaken; leaves stay fail-open (no leaf =
  interpreted, bail = exact re-run).
- Traps in force: leaf env match (KLIO_COMPOSE_PLUGIN), fqn#sig keys,
  installed packs shadow sources, cold-bake order flakes, never
  `zig build` while a battery runs.

Exit: the example gate is a standing part of stack.sh + gate.sh and
has caught-or-passed at least three full stacks; leaf packs serve in
the standing census path with the datetime number banked; the three
veins landed-with-measurement or closed by measurement recorded here.
Full battery green throughout.

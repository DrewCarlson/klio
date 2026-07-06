# P1 + P4 Current-State Map

Consolidated codebase map for the coupled change:

- **P1** — complete the canonical function/member signature index *during* class-body
  lowering (instead of after phase-1 top-level header registration), so bare calls in
  class method bodies resolve against the full header set.
- **P4** — decide member-vs-global (and member-shadowability) by the **receiver's
  declared type**, not by the program-wide `class_member_names` universe.

Every file:line below was read and verified against the tree at the time of writing.
Where a source reader left something unverified it is marked **UNKNOWN** with the exact
thing to inspect.

The two changes are coupled because P1 changes *when* the index is complete and P4
changes *what question* the member-preference sites ask. A prior attempt reordered
class lowering and regressed the `itest-stdlib_commontest` canonical by **16** ("−16")
because it moved the ordering (or flipped a subset of the member-preference sites)
without making **all** of them consistent. Section 2 is the definitive list of those
sites; section 8 is the ordered edit sequence that keeps them consistent.

---

## 1. Build ordering diagram

Driver: `buildModuleWithOverrides` in `src/interp_ir/build.zig` (spans ~842–2700).
Sequential phases, in execution order:

```
buildModuleWithOverrides (src/interp_ir/build.zig:842+)
│
│  [extending builds only] base pre-seed happens earlier, via
│  cloneBuiltForRun (build.zig:3020-3072) -> Module.cloneForExtend
│  (ir.zig:1133-1187): func_name_index (1159-1164), decl_user_params
│  (1170-1171), decl_user_arity (1174-1175), decl_user_sig (1178-1179),
│  decl_span (1182-1183) are SEEDED with BASE entries before user decls.
│
├─ A. hierarchy_methods population                       build.zig ~1205-1213
│
├─ B. class_member_names REGISTRY population              build.zig 1214-1232
│       collectClassMemberNamesInto (helper 732)          + "data" at 1232
│       ==> the member-name UNIVERSE is COMPLETE HERE, before any body lowers
│
├─ C. supertype-name chains (per-class)                  build.zig ~1234+
│
├─ D. class reservation (reserveClassFqn)                build.zig 1439-1445
│       every class reserved by FQN so ctor refs resolve order-independently
│
├─ E. type-alias head tags (setTypeAliasTags)            build.zig 1455-1460
│
├─ F. class primary-ctor params PRE-FILL                 build.zig 1467-1475
│       module.classes[cid].primary_params = classPrimaryParams(...)
│
├─ G. CLASS METHOD-BODY LOWERING loop                    build.zig 1479-1487
│       -> lowerClassWithExtrasFqnPkg -> lowerClassWithExtras
│          (src/ir/lower/decl.zig:432-575)
│       populates member_method_fids INCREMENTALLY (decl.zig:530-540)
│       populates own_members / own_member_arity per FuncBuilder
│          (decl.zig 469-485)
│       *** AT THIS POINT the top-level FUNCTION header index is NOT complete ***
│
├─ H. PHASE-1 top-level function HEADER registration      build.zig 1498-1570
│       func_index / func_name_index      1534-1537
│       decl_user_params                  1539
│       decl_user_arity                   1547
│       decl_user_sig (loweredTypeRef)    1555-1559
│       decl_span                         1561
│       registerInlineFnId (inline stub)  1565-1567
│
└─ I. PHASE-2 top-level BODY lowering loop                build.zig 1579-1649
        lowerFunctionBodyInto into reserved slots; resolves bare calls
        against the now-complete phase-1 header set (funcsBySimpleName safe)
```

### Index completeness when a class body lowers (phase G)

| Index | Complete at phase G (class-body lowering)? | Where populated |
|---|---|---|
| `class_member_names` (member-name universe) | **YES** — populated at B (1214-1232), before G | build.zig 1214-1232 |
| `own_members` / `own_member_arity` (enclosing class) | **YES** — installed per-class before its own methods lower | decl.zig 469-485 |
| `member_method_fids` (sibling methods) | **PARTIAL** — only classes already lowered in the G loop; incremental | decl.zig 530-540 |
| `class primary_params` | **YES** — pre-filled at F (1467-1475) | build.zig 1467-1475 |
| class reservations (`reserveClassFqn`) | **YES** — at D (1439-1445) | build.zig 1439-1445 |
| top-level `func_name_index` / `decl_user_arity` / `decl_user_sig` (USER fns) | **NO** — registered at H (1498-1570), after G | build.zig 1498-1570 |
| top-level function headers (BASE, extending builds) | **YES** — pre-seeded by `cloneForExtend` | ir.zig 1159-1184 |

**The one gap P1 closes:** user top-level function headers are not queryable when a
class body lowers (H runs after G). `funcsBySimpleName` (ir.zig:1290) returns nothing
for a user top-level function during phase G, so `lowerCallWithWritebackPath` falls
back to a `hasOwnMember`+`this` member dispatch (expr.zig:2765-2782, comment at 2772:
"The index never resolves members ... so without this it falls to an unresolved global
LoadGlobal"). Note this is the *function* index, **not** `class_member_names`, which is
already complete at G.

### run / test / check / cloneForExtend differences

| Path | Entry | Base pre-seed? | Notes |
|---|---|---|---|
| `run` | commands.zig:201-239 → `buildModuleFiles` (via runBuilt ~536) | No (base=null) | non-extending |
| `test` | commands.zig:356-471 → `buildModuleFiles` (~421) | No (base=null) | non-extending |
| `check` | commands.zig:73-163 | **N/A** | resolver + typeck only; IR build pipeline never invoked |
| pack/image (extending) | stdlib_image.zig → `buildModuleFilesExtend` → cloneBuiltForRun | **YES** | base headers queryable at phase G |

`buildModuleFiles` (build.zig:362-364) → `buildModuleFilesInner(base=null)`: no
pre-seed, so phase G sees an empty user function index.
`buildModuleFilesExtend` (build.zig:370-372) → `buildModuleFilesInner(base=*const
StdlibBase)`: triggers `cloneBuiltForRun`, so **base** function headers are queryable at
phase G but **new user** function headers still are not (they are registered at H).

---

## 2. THE DEFINITIVE member-preference-site list (the −16 surface)

Every site that decides member-vs-global or member-shadowability. All of these must be
made receiver-type-aware **together** for P4. Columns:

- **flips-if-index-complete?** — behavior changes if the top-level function header index
  is complete during class-body lowering (P1).
- **flips-if-receiver-type?** — behavior changes if the decision keys on the receiver's
  declared type instead of the global name universe (P4).

### Group 1 — `class_member_names.contains()` reads (the CORE P4 surface)

These currently ask "does **any** class declare this name?" P4 replaces each with "does
the **receiver's declared type** declare this name?". All 6 verified.

| Site | file:line | What it gates | flips-if-index-complete? | flips-if-receiver-type? |
|---|---|---|---|---|
| top-level property read gate | expr.zig:1181 | bare read → static prop bind vs `LoadFromThisOrGlobal` | No | **YES** |
| alias-intrinsic guard | expr.zig:4120 | intrinsic alias → direct `LoadGlobal` vs `CallMemberOrGlobal` redispatch | No | **YES** |
| out-of-scope verdict | expr.zig:4277 | bare ref is out-of-scope vs possible runtime member | No | **YES** |
| bare-call member-shadowable | expr.zig:4866 | **emit `CallMemberOrGlobal`** vs static `Call` | No | **YES (central call gate)** |
| container-creator typed | expr.zig:5323 | stdlib container creator direct bind (keeps type args) vs redispatch | No | **YES** |
| stdlib-alias direct bind | expr.zig:5371 | known alias direct `LoadGlobal` vs `CallMemberOrGlobal` (avoids vararg prepend) | No | **YES** |

Registry backing these reads: `ModuleRegistry.class_member_names`
(std.StringHashMap(void)) at **ir.zig:2271**; init 2361, deinit 2405, clone 2501-2502.
Write: build.zig 1214-1232 (helper `collectClassMemberNamesInto` at 732) + hard-coded
`"data"` at 1232. Serialized form: image.zig:576 (write 1211, read 1884).

### Group 2 — enclosing-class own-member gates (already receiver-scoped, but ONLY to `this`)

These already scope to the *enclosing* class via `own_members`. They do **not** flip for
`this`-receivers under P4, **but** they are the prior attempt's blind spot: they only
cover the *enclosing* class and never a *cross-class* explicit receiver's declared type.

| Site | file:line | What it gates | flips-if-index-complete? | flips-if-receiver-type? |
|---|---|---|---|---|
| `hasOwnMember` | build.zig:855-857 | name is enclosing-class member → member routing | No | No (already enclosing-scoped) |
| `ownMemberApplicable` (arity mask) | build.zig:869-874 | member can bind this arity → shadow global | **YES** (mask could be exact) | No |
| `prefer_member` | expr.zig:4028-4030 | skip heuristic bare-func lookup, defer to member | **YES** (arity deterministic) | No (uses hasOwnMember) |
| `lowerImplicitThisCall` entry gate | expr.zig:5164 | route bare call → `this.<name>` | Moderate | No |
| private-method static bind | expr.zig:5202-5231 | static `Call` to private sibling vs `CallMemberOrGlobal` | Moderate (member_method_fids) | No |
| `lowerCallWithWritebackPath` member gate | expr.zig:2765-2782 (**cmt 2772**) | `hasOwnMember`+`this` → `CallMember` vs unresolved `LoadGlobal` | **CRITICAL** (see below) | No |
| bare-name assignment gate | stmt.zig:686, 713-714 | `hasOwnMember`+`this` → `StoreToThisOrGlobal` | No | No |
| bare-name read own-member | expr.zig:1047 | member read routing | No | No |
| inline-splice `binds_this` | expr.zig:3025-3040, 3037 | `CallMember` on bound `this` vs `CallMemberOrGlobal` | No | No |
| `itc_broad` (broad-collection mask) | expr.zig:5176-5192 | trailing-lambda param broadening via `member_method_fids` | Moderate | No |

### Group 3 — class-vs-member shadowing gates

| Site | file:line | What it gates | flips-if-index-complete? | flips-if-receiver-type? |
|---|---|---|---|---|
| `enclosingMemberShadowsClass` | expr.zig:836-848 (used 1098, 1180) | enclosing member shadows a class reference | No | No (enclosing-scoped) |
| `shadowedByClass` | expr.zig:3215-3250 (used 3979, 4142) | bare name shadows by being a known class | No | No |

### Group 4 — the master gate + index resolution (P1 surface)

| Site | file:line | What it gates | flips-if-index-complete? | flips-if-receiver-type? |
|---|---|---|---|---|
| `inReceiverContext` (MASTER gate) | expr.zig:4505-4508 | whether ANY member-vs-global dispatch form is emitted at all | No | No — stays the gate; its fallback narrows |
| `resolveBareCallIndexed` | expr.zig:4091-4108 → ir.zig:1705 | exact bare-call pick vs deferred | **CRITICAL** (fewer deferrals) | No |
| bare-call heuristic arity rungs | expr.zig:4021-4058 | order-dependent overload pick when index defers | **CRITICAL** (becomes dead code) | No |

### Group 5 — runtime-dispatch emission consumers (must stay consistent; do not "flip" but must agree)

These emit the deferred forms. They do not decide member-vs-global themselves, but their
emission count changes when Groups 1/4 change, and their runtime walk (section 6) must
agree with the compile-time decision.

| Emitted form | emit sites (expr.zig / stmt.zig) |
|---|---|
| `CallMemberOrGlobal` | expr.zig 2710, 2724, 3075, 3091, 3296, 4881, 5071, 5248 |
| `LoadFromThisOrGlobal` | expr.zig 1104-1105, 1128-1129, 1258-1259, 1299-1300, 1453-1454 |
| `StoreToThisOrGlobal` | stmt.zig 714 |

### What the prior attempt (−16) likely MISSED

The −16 came from making the ordering/decision inconsistent across the surface. The
sites most likely skipped, because they are **not literal `class_member_names.contains`
calls** and so are invisible to a grep-driven flip:

1. **`lowerCallWithWritebackPath` member gate (expr.zig:2765-2782).** Its whole reason
   for existing is the comment at 2772: "The index never resolves members." If P1 makes
   the function header index complete at class-body time, `bound_id` can become non-null
   here and this branch's precondition silently changes — a bare call that used to route
   `CallMember` now resolves to a global `Call`. Missed → wrong dispatch.
2. **`resolveBareCallIndexed` + heuristic rungs (expr.zig:4021-4108).** Reordering
   headers to be complete at class-body time changes which bare calls resolve *exact*
   vs *deferred*, shifting emission between static `Call` and `CallMemberOrGlobal`. If
   only the `class_member_names` reads are flipped but the index-completion timing is
   also changed, these disagree.
3. **Group 2 arity gates keyed to the enclosing class only.** Flipping Group 1 to
   receiver-type without giving Group 2 a cross-class receiver-type query leaves
   explicit-receiver calls (`obj.foo()` where `obj`'s type differs from `this`) deciding
   on `this`'s members. The two groups must share one receiver-type query.
4. **`enclosingMemberShadowsClass` / `shadowedByClass` (Group 3).** They read the same
   name universe for class-vs-member precedence; if left global-scoped while Group 1 goes
   receiver-typed, class references shadow (or fail to shadow) inconsistently.
5. **Runtime `execCallMemberOrGlobal` walk (eval.zig:3412-3562) and the exact-flag
   bypass (host_call_func.zig:1278-1280).** A compile-time flip that emits fewer
   `CallMemberOrGlobal` (or marks more calls `exact`) must keep the runtime walk order
   and the `static_recv` filter (eval.zig 3465-3468) consistent, or a runtime subtype
   with a shadowing extension dispatches to the wrong target.

---

## 3. `class_member_names` — full write + read lifecycle and the receiver-type replacement

### Write lifecycle

| Step | file:line | Action |
|---|---|---|
| field def | ir.zig:2271 | `class_member_names: std.StringHashMap(void)` |
| init | ir.zig:2361 | `ModuleRegistry.init` |
| helper | build.zig:732 | `collectClassMemberNamesInto(out, primary_params, members)` — recurses into nested Class (740) / Object (741) |
| populate | build.zig:1214-1232 | walk top-level Class (1221) / Object (1223); add every member name |
| `"data"` inject | build.zig:1232 | unsigned value-class backing prop |
| clone | ir.zig:2501-2502 | key-by-key copy for extending builds |
| serialize (write) | image.zig:576 (field), 1211 (`setToSlice`) | image persistence |
| deserialize (read) | image.zig:1884 (`sliceToSet`) | image restore |
| deinit | ir.zig:2405 | teardown |

Population (build.zig:1214-1232) happens **before** class-body lowering (1479-1487), so
the universe is stable and complete during every expr.zig read. No writes occur during
body lowering.

### Read sites + receiver-type replacement

All reads happen during phase-2 (or method-body) lowering, gated by `inReceiverContext`.
The replacement for each is a query against the receiver's declared type's declared
members (for a `this`-receiver: `own_members`, already available; for an explicit
receiver: the receiver expression's static type's member set; for an erased/`Any`
receiver: fall back to `class_member_names` as the conservative default).

| Read | file:line | Current query | Receiver-type replacement |
|---|---|---|---|
| top-level prop read | expr.zig:1181 | `class_member_names.contains(name0)` (negated) | receiver type declares `name0`? if not, static prop bind is safe |
| alias-intrinsic guard | expr.zig:4120 | `!class_member_names.contains(name0)` | receiver type lacks `name0` → direct `LoadGlobal` |
| out-of-scope verdict | expr.zig:4277 | `class_member_names.contains(name)` | receiver type declares `name` → not out-of-scope; else truly out-of-scope |
| bare-call shadowable | expr.zig:4866 | `class_member_names.contains(name0)` | receiver type declares `name0` → emit `CallMemberOrGlobal`; else static `Call` |
| container creator | expr.zig:5323 | `!class_member_names.contains(name0)` | receiver type lacks `name0` → direct bind (keeps type args) |
| stdlib-alias bind | expr.zig:5371 | `!class_member_names.contains(name0)` | receiver type lacks `name0` → direct bind |

Once all 6 reads take a receiver-type query and Group 2 shares that query for explicit
receivers, `class_member_names` can be dropped entirely (retain only as the `Any`-erased
fallback, if any read still needs it). Related indices used in the same decisions:
`member_method_fids` (ir.zig:2265, keyed `Class\0name\0arity`, written decl.zig:534, read
expr.zig:5188) and `own_member_arity` (build.zig FuncBuilder field 256, written
decl.zig:485, read build.zig:870).

---

## 4. DeclSig gap — what exists vs what a full per-FuncId DeclSig must add

### Exists today (split across several structures)

| Piece | file:line | Scope |
|---|---|---|
| `Func.params` (`[]Param` w/ `ty` from `loweredTypeRef`) | ir.zig:666 | all lowered funcs (bodies) |
| `Func.kind` (plain/instance_method/top_level_extension/member_extension) | ir.zig:683 | all funcs |
| `Func.is_inline` | ir.zig:708 | all funcs; stub set build.zig:1529 |
| `Func.is_suspend` | ir.zig:678 | all funcs |
| `Func.has_receiver_param` | ir.zig:699 | all funcs |
| `Func.fqn` / `Func.package` | ir.zig:659 / 665 | all funcs; set phase-1 (1519-1520) |
| `decl_user_params` (u32 user param count) | ir.zig:892; write build.zig:1539 | **top-level only** |
| `decl_user_arity` (`DeclArity{required,total,has_vararg}`) | ir.zig:896 / 923; write build.zig:1547 | **top-level only** |
| `decl_user_sig` (`[]TypeRef`) | ir.zig:905; write build.zig:1555-1559 | **top-level only** |
| `decl_span` | ir.zig:910; write build.zig:1561 | **top-level only** |
| `member_method_fids` (`Class\0name\0arity` → FuncId) | ir.zig:2265; write decl.zig:534 | members (discovery only) |
| `member_ext_owner_class` (FuncId → class **name string**) | ir.zig:2284; write decl.zig:871, build.zig 2242/2273 | member extensions |
| `SigView` / `sigViewOf` / `sameUserSig` (identity proof) | ir.zig:1596 / 1618 / 1632 | top-level bare-call proof |
| `resolveBareCallIndexed` | ir.zig:1705 | top-level bare-call resolution |

`loweredTypeRef` (decl.zig:641) fills `params.ty`: recursive AST-TypeRef → structural
TypeRef; function types → `"Function{N}"` with args `[#suspend?, receiver?, params...,
return]`, regular types → name + nullable + generic_args. It is the **same** producer
used at phase-1 for `decl_user_sig` (build.zig:1557) and at phase-2 for lowered
`Func.params`, so the index proves signature identity identically for a stub and its
later-lowered body (that is what `SigView`/`sameUserSig` rely on).

### What a full per-FuncId DeclSig must ADD

| Missing | Needed for | How to fill |
|---|---|---|
| **Members: arity + full sig per FuncId** — instance methods, member extensions, member properties have NO `decl_user_arity` / `decl_user_sig` entry | P1 static member resolution; P4 receiver-type member proof | populate during **class-body lowering** (phase G), not phase-1 (members are not top-level); source from `f.params` via `loweredTypeRef` |
| **Enclosing class as ClassId (not string)** — `member_ext_owner_class` stores a name string | P4 receiver-type keying + inheritance walk | add `FuncId → ClassId`; resolve via `classIndexEntryByName` at lowering |
| **Constructors indexed by (Class, arity)** — primary params filled (build.zig:1467-1475) but secondary ctors unindexed; no arity entry | P1 exact-ctor static pick for `NewInstance` | per-ClassId secondary-ctor arity/sig side table |
| **Member inline sig** — member inlines never register a stub (`registerInlineFnId` only for top-level, build.zig:1565-1567) | P1 inline-splice arity validation | register member inline sig at class-body lowering |
| **Inheritance ordering** — `member_method_fids` keyed by `(Class,name,arity)` with no parent-chain order | P4 supertype member walk | order-by-class table or per-class supertype chain lookup |

Consequence: unify the split pieces into one `DeclSig` keyed by FuncId, **filled for
members at class-body lowering** (phase G), storing `enclosing_class: ?ClassId`,
`receiver_ty: ?TypeRef`, `arity: DeclArity`, `sig: []TypeRef`, `kind`, `is_inline`,
`is_suspend`. The lowering pass then queries `DeclSig` for signature validation at all
call sites, deferring only true receiver-dispatch shapes (`CallMember` where the receiver
type is unknown at lower time).

---

## 5. The `receiverRebindActive` / `own_this_scope` signal — exists vs must be added

### Exists today

| Symbol | file:line | Role |
|---|---|---|
| `inReceiverContext` (master gate) | expr.zig:4505-4508 | true if `capturesThisSlot()` OR `resolve("this")!=null` OR `ownerClass()!=null` OR `isParamThunk()` OR `recvTy()!=null` |
| `capturesThisSlot` | build.zig:692-694 | `is_lambda_body or is_anon_fn_body` (excludes named-local-fn) |
| `isParamThunk` | build.zig:903-905 | in a parameter default-value thunk |
| `ownerClass` | build.zig:788-790 | enclosing class simple name (method body) |
| `recvTy` | build.zig:794-796 | declared extension receiver type simple name |
| `resolve("this")` | build.zig:1048-1073 | walks scope chain; **can change** during inline splice (pushScope→bind("this")→popScope) |
| `scopeDepth` | build.zig:587-589 | `scopes.items.len`; needed for depth comparison |
| `bindParams` | decl.zig:92-113 | binds `"this"` at entry (scopeDepth==1); the natural record point |

### Must be ADDED

| Symbol | file:line | Requirement |
|---|---|---|
| `own_this_scope: ?usize` | build.zig — **DOES NOT EXIST YET** (add near FuncBuilder fields ~256) | record scope depth at which `this` is first bound; set in `bindParams` (decl.zig:92-113) when `"this"` is bound (value==1 at entry), or 0 for capture-arrival bodies |
| `receiverRebindActive()` | build.zig — **DOES NOT EXIST YET** | `capturesThisSlot() or isParamThunk() or (resolve("this")!=null and resolve_depth != own_this_scope)`; gate that forces runtime probe fallback when receiver identity is unstable (e.g. a method that inlines an extension which rebinds `this` at a deeper scope) |

Why P1+P4 need it: once member-vs-global is statically committed by receiver type, a late
rebinding of `this` at a scope depth other than `own_this_scope` (inline splice binding
its own receiver) must not silently change dispatch. `receiverRebindActive()` gates the
index-driven static commit off when `this` identity is unstable, forcing the runtime
probe until the refactor's guarantees hold.

Ordering: (1) `FuncBuilder.init` → scopes.len=1; (2) `bindParams` binds `this` at
scopes[0] (record `own_this_scope`=1 here); (3) body lowering push/pop scopes; (4) inline
splice pushScope + bind splice receiver as `this` at deeper depth → `resolve("this")`
finds the nested one. `own_members`/`own_member_arity`/`member_method_fids` are installed
**before** body lowering, so they are stable during member-call dispatch decisions.

---

## 6. Runtime dispatch surface the 3-tier IR must interoperate with

IR opcode struct definitions (ir.zig): `Call` 188-204, `CallValue` 218-229,
`CallValueOrMember` 266-274, `CallMemberOrValue` 279-287, `CallMember` 290-304,
`CallMemberOrGlobal` 405-428, `LoadGlobal` 375, `LoadFromThisOrGlobal` 384-390,
`StoreToThisOrGlobal` 395-399, `TailCallFunc` 574-578.

| Runtime surface | file:line | Behavior the 3-tier IR must respect |
|---|---|---|
| `Call` handler | eval.zig:2622-2753 | fast path exact-arity positional (2639-2646); named re-resolution 2676-2715 skipped iff `!call.exact` |
| `callFuncTyped` exact bypass | host_call_func.zig:1211-1280 (**1278-1280**) | `if (exact) func else pickOverloadCached(...) orelse func` — exact skips all re-resolution |
| `pickOverloadCached` | host_call_func.zig:636-646 | memoized on `(module_p, func_p, primitive_sig)`; **no invalidation on index change** |
| `pickOverload` → `overloadScore` → `overloadScoreArg` | host_call_func.zig:649-671 / 529-588 / 389-507 | runtime scorer; proof bonuses via `refineByDeclaredArgs` (overload_match.zig:520-532) |
| `CallMember` handler | eval.zig:2889-2950 | dispatch `callMemberNamed` w/ `static_recv` hint |
| `resolveInstanceMethod` / `pickMethodOverload` | host_call_member.zig:5607+ / 1990-2182 | class-hierarchy method lookup + overload scoring |
| `CallMemberOrGlobal` handler `execCallMemberOrGlobal` | eval.zig:3412-3562 | 3-phase probe: strict member+ext (3444-3489), lenient (3493-3513), global (3526-3559); `static_recv` filter at 3465-3468 |
| implicit-receiver candidate walk | eval.zig:3687-3726 / 3733-3767 / 3772-3785 | depth-ordered innermost-first: frame `this`, enclosing chain, companion tower |
| exact-cast bypass emit | expr.zig:5776-5790 | `Call.exact=true` only when a cast statically picks the overload |
| `TailCallFunc` handler | eval.zig:2089-2104 | **direct `funcById` bind, NO overload re-resolution, no extension handling** |
| `LoadGlobal` handler | eval.zig:3186-3227 | prefers lowering-resolved `func`/`class` id (`lookupGlobalById`), else name lookup |

Tiers today: **exact-resolved** (`Call.exact=true`, baked FuncId) / **virtual-resolved**
(`Call.exact=false` → `pickOverload` candidate set) / **deferred** (`CallMemberOrGlobal`,
`LoadFromThisOrGlobal`, `LoadGlobal` name-string). P1 shifts calls tier 2→1 (safe:
runtime already handles exact). P4 changes *how* tier 2/3 candidates are selected
(runtime receiver value → declared receiver type) — a correctness hazard if the implicit
walk and the `static_recv` filter are not kept consistent. **Cache hazard:**
`pickOverloadCached` (key `(module_p, func_p, sig)`) has no invalidation; if a
lowering-resolved target becomes stale after an index change, the cache serves the wrong
target. Verify cache-key stability when P1 changes baked identities.

---

## 7. IR instruction vocabulary today + the exact/virtual/deferred forms to add

### Today (ir.zig `Inst` union, 124-494)

Call family: `Call` (188-204, has `exact: bool`), `CallValue` (218-229),
`CallValueWithThis` (209-216), `CallSpread` (234-245), `CallSuper` (252-261),
`CallValueOrMember` (266-274), `CallMemberOrValue` (279-287), `CallMember` (290-304, has
`static_recv: ?ConstId`), `CallMemberOrGlobal` (405-428, has `this_idx`, `func:?FuncId`,
`class:?ClassId`, `recv:?Reg`).
Field/index: `GetField` (149-153), `SetField` (155-159), `CompoundField` (169-174),
`Index`, `IndexSet`.
Globals: `LoadGlobal` (375, `func:?FuncId`, `class:?ClassId`), `StoreGlobal` (433),
`LoadFromThisOrGlobal` (384-390), `StoreToThisOrGlobal` (395-399).
Type: `InstanceOf` (363), `Cast` (356-361, `safe: bool`), `NotNullAssert`.
Construction/refs: `NewInstance` (306-312), `NewList`, `MemberRef` (329-333),
`PropertyRef` (325), `QualifiedThis`.
Terminators (548-587): `Goto`, `Branch`, `Switch`, `Return`, `Throw`, `Unreachable`,
`TailJump`, `TailCallFunc` (574-578), `NonLocalReturn`, `LabeledReturn`.

### Forms to ADD for the 3-tier model

| Form | Tier | Purpose | Notes |
|---|---|---|---|
| **exact member call** (e.g. `CallMember` with a baked FuncId, or new `CallMemberExact`) | exact | statically-resolved member call by (receiver type, FuncId); skip runtime `pickMethodOverload` | requires per-member DeclSig (section 4); mirrors `Call.exact` for members |
| **virtual member call** (existing `CallMember`, made explicit) | virtual | receiver-type-known but overload still runtime-scored | keep `static_recv`; scored by `pickMethodOverload` |
| **deferred member-or-global** (existing `CallMemberOrGlobal`, receiver-type-tagged) | deferred | add a declared-receiver-type tag so `execCallMemberOrGlobal` filters candidates by type, not just value | extends `static_recv` semantics into the OrGlobal walk |

Keep `exact/virtual/deferred` orthogonal to `member/global`: the tier says *how much was
resolved at lower time*, the family says *what runtime dispatch shape*. P1 raises more
calls to the exact tier; P4 ensures virtual/deferred candidate selection keys on declared
receiver type.

---

## 8. Concrete, ordered edit sequence for the coupled P1+P4 change

The invariant: **no commit may leave the member-preference surface (section 2)
half-flipped.** Any state where some Group-1 reads are receiver-typed and others are
global-scoped, or where P1 timing has moved but Group-2 gates still assume "index never
resolves members," reproduces the −16. Land the substrate first (behavior-neutral), then
flip the whole surface in one coherent step, then remove the dead scaffolding.

### Stage 0 — instrument & baseline (no behavior change)

1. Record the baseline canonical: `zig build itest-stdlib_commontest` (expect the current
   passing count, e.g. 2003). Capture per-test names, not just the count.
2. Enable the existing `KLIO_OR_AUDIT` detector (expr.zig ~4510-4514 compile half +
   eval.zig runtime half) and snapshot every member-vs-global emission decision on the
   corpus. This is the diff oracle for stages 4-5.

### Stage 1 — DeclSig substrate (P1, additive, behavior-neutral)

3. Add a unified `DeclSig` keyed by FuncId (section 4): `enclosing_class:?ClassId`,
   `receiver_ty:?TypeRef`, `arity:DeclArity`, `sig:[]TypeRef`, `kind`, `is_inline`,
   `is_suspend`. Populate it **for top-level functions** at phase-1 (build.zig:1498-1570)
   from the same sources already there (`decl_user_arity`/`decl_user_sig`), so nothing
   reads it yet.
4. Populate `DeclSig` **for members** during class-body lowering (decl.zig:432-575,
   alongside `member_method_fids` write at 534), using `loweredTypeRef` on `f.params`.
   Change `member_ext_owner_class` (ir.zig:2284) to also store `ClassId` (resolve via
   `classIndexEntryByName`). Still read by nobody → behavior-neutral. Verify canonical
   unchanged.

### Stage 2 — complete the function index during class-body lowering (P1 timing)

5. Move (or duplicate) phase-1 top-level **header** registration (build.zig:1498-1570) so
   the header set — `func_name_index`, `decl_user_arity`, `decl_user_sig` — is complete
   **before** the class-body lowering loop (build.zig:1479-1487). Headers only (no bodies),
   exactly as `cloneForExtend` already pre-seeds base headers. `class_member_names` is
   already complete here (build.zig:1214-1232), so no move needed for it.
6. **Expected mid-flight canonical DIP here.** Now `funcsBySimpleName` returns user
   functions during class-body lowering, so `lowerCallWithWritebackPath` (expr.zig:2765-
   2782) and `resolveBareCallIndexed` (expr.zig:4091-4108) see a *different* (complete)
   index than before: some bare calls that fell to the `hasOwnMember`+`this` member branch
   now resolve to a global, and some deferred heuristic picks (expr.zig:4021-4058) become
   exact. This is the −16 region. Do **not** try to recover it by reverting the move —
   proceed to stage 3, which makes Group-2 gates consistent with the new timing.

### Stage 3 — reconcile Group-2 gates with the completed index (P1 correctness)

7. Rewrite the `lowerCallWithWritebackPath` member gate (expr.zig:2765-2782): its comment
   at 2772 ("index never resolves members") is now false. Gate on: DeclSig has an exact
   member for `(enclosing_class, name, arity)` → `CallMember`/exact member form; else the
   now-complete index → static `Call`; else deferred. Same reconciliation for
   `lowerImplicitThisCall` private static bind (expr.zig:5202-5231) and the heuristic
   rungs (expr.zig:4021-4058), which should now defer to the exact index and shrink to
   dead code.
8. Add `own_this_scope` + `receiverRebindActive()` (section 5) and gate every new
   *static member* commit (from step 7) behind `!receiverRebindActive()` so inline-splice
   receiver rebinding falls back to the runtime probe. Re-run canonical: the dip from
   step 6 should now recover to ≥ baseline. If not, the audit snapshot (step 2) pinpoints
   which emission decision changed unexpectedly.

### Stage 4 — flip the member-vs-global decision to receiver-type (P4), all at once

9. Introduce one shared helper `receiverTypeDeclaresMember(recv_ty, name, arity)` backed
   by DeclSig (per-class members + supertype walk). For a `this`-receiver it reduces to
   `own_members`/`own_member_arity`; for an explicit receiver it uses the receiver
   expression's static type; for an erased/`Any` receiver it falls back to
   `class_member_names`.
10. In a **single change**, replace **all six** Group-1 `class_member_names.contains`
    reads (expr.zig:1181, 4120, 4277, 4866, 5323, 5371) with
    `receiverTypeDeclaresMember(...)`, **and** route the Group-2 gates
    (`hasOwnMember`/`ownMemberApplicable` at their call sites) and Group-3 shadowing
    gates (expr.zig:836-848, 3215-3250) through the same helper so `this`-receivers and
    explicit receivers share one query. Do not split this across commits — a partial flip
    is the −16.
11. Reconcile the runtime side (section 6): extend `execCallMemberOrGlobal`
    (eval.zig:3412-3562) and its `static_recv` filter (3465-3468) so the strict pass keys
    on declared receiver type; verify the implicit-walk order (eval.zig:3687-3785) still
    matches the compile-time decision. Add the receiver-type tag to `CallMemberOrGlobal`
    (section 7) if the runtime needs the declared type it did not previously carry.

### Stage 5 — verify, then remove scaffolding

12. Run `zig build test` and the full canonical `zig build itest-stdlib_commontest`;
    diff the `KLIO_OR_AUDIT` snapshot against stage-0 baseline — every changed emission
    must be an intended receiver-type narrowing, not an accident. Confirm net canonical
    ≥ baseline (the −16 must be fully recovered).
13. Once green, drop `class_member_names` (ir.zig:2271 + build.zig 1214-1232 + image.zig
    576/1211/1884) if no read still needs the `Any`-erased fallback; otherwise keep it as
    the explicit erased-receiver fallback only. Delete the now-dead heuristic rungs
    (expr.zig:4021-4058) and any writeback member-branch made unreachable by the exact
    index.

### Cache caveat (verify during stage 4-5)

`pickOverloadCached` (host_call_func.zig:636-646, key `(module_p, func_p, sig)`) has no
invalidation. If P1 changes any baked lowering-resolved target, confirm the cache key
still distinguishes the new target; a stale entry serves the wrong overload silently.
**UNKNOWN:** whether any live path mutates the index *after* initial lowering — inspect
whether `buildModuleFilesExtend`/image reload can re-lower against an already-populated
cache; if so, add invalidation keyed on module identity.

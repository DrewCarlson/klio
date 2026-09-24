# lower/sema: work packages

This is the work breakdown for `lower/sema`, step 4 of
`docs/design/SEMA-LOWERING.md` and the `lower/sema` row of
`plans/resolved-interpreter.md`. It fixes the interfaces between the pieces
so that several engineers can build them at once and they fit together:
the record API lowering reads (section 1), the identities, calling
convention, instructions and run-time tables every package shares (section
2), the packages (section 3), the order of work (section 4), the decisions
the lead has to take (section 5), and the places where the accepted design
does not match the code (section 6).

The new lowering is written beside the old one and is not wired into the
pipeline. Its tests run small programs through parse, sema, bridge, the new
lowering and the VM, over an executable miniature base, inside
`zig build test`. File and line citations are as of commit 0e278928.

## Summary

| Pkg | Content | Code | Tests | Needs before its executing tests | Starts |
|-----|---------|-----:|------:|------------------------------|--------|
| S | Skeleton: record types, ids, `Inst` declarations, run-time table types, module wiring, a stub for every public function below | 0.9k | - | - | first, alone |
| A | New `Inst` variants' eval arms, run-time tables, VM glue, declines in the other engines | 1.7k | 0.6k | S | after S |
| B | `core/bridge`: every id from sema's symbols, the `ir.Module` skeleton, dispatch and ancestor tables, captures and cells, native binding | 1.4k | 0.5k | S | after S |
| E | Test driver, executable miniature base, its natives | 0.7k | 0.2k | S, B | after S (with B) |
| C1 | Spine: builder, record lookup, receiver and local environment, bodies, statements, names | 2.2k | 0.5k | S, R's first slice (4.1) | after S |
| C2 | Calls: argument order, defaults bridges, varargs, contexts, conversions, dispatch choice | 1.5k | 0.5k | C1 | after S |
| C3 | Control flow, operators, type tests | 1.8k | 0.6k | C1, C2 | after S |
| C4 | Classes, constructors, statics, objects, enums, lambdas, local functions, callable references, the program driver | 2.2k | 0.7k | C1, C2 | after S |
| D | Inline instantiation from IR | 1.5k | 0.5k | C1, C2, C4 | after S (copier first) |
| R | `sema/output` (the lead's item; its API is section 1) | 2.5k | | R0 in S | now |

Total for `lower/sema`: about 13.0k lines of code and 4.1k of tests (the
skeleton's declarations and stubs are filled by the packages and not counted
twice), against the +8.5k the plan carries. Section 6 explains the difference: the
statement, control-flow and body-entry code the design expects to reuse is
bound to today's `FuncBuilder` and its derivation helpers, and has to be
written again beside it (about 2.5k), and the VM arms (1.7k) and the driver
(0.7k) were not in the 8.5k.

Conventions for every package:

- New lowering files go in `src/ir/lower/sema/` (decision 2 in section 5),
  the bridge in `src/ir/core/bridge.zig`, the run-time tables in
  `src/ir/core/resolved.zig`, the new eval arms in `src/ir/eval/resolved.zig`,
  and the driver in a new module `lower_driver` at `src/lower_driver/`.
- Nothing the new lowering emits carries a name that execution reads. Display
  names go into `Func.name`/`fqn`, `ClassDef.name`/`fqn` and `Const` strings
  that are values (`LateinitCheck.name`, a property reference's `name`).
- A missing record is `error.Unrecorded`: the builder records one internal
  error naming the node's span and the body, the function fails to build,
  and nothing falls back.
- Every package's tests live in `src/lower_driver/tests/<pkg>.zig`, which only
  that package edits. The driver module's root imports all of them from the
  skeleton on.

## 1. The record API lowering reads

Sema's output today is one flat list of `Ref`s keyed by an anchor span
(`src/sema/records.zig:83-96`, appended by `Ctx.addRef`,
`src/sema/body.zig:94-106`). `sema/output` replaces the list with per-file
tables indexed by `ast.NodeId`, which landed in c6fd52ad (`src/ast/ast.zig`,
`src/ast/node_ids.zig`): a dense `u32` per file, 0 is `none`, carried on
every `Expr` payload (`Expr.id()`), `Block`, `AssignStmt`,
`DestructuringDeclStmt`, `Property`, `Catch`, every declaration and parameter
node, and `Ident.id` on a `$name` template part. `WhenBranch`,
`WhenPattern` and `TypeRef` carry no id, so their records hang off the
enclosing node's group.

### 1.1 Where records live

```zig
// src/sema/sema.zig (R)
pub const Sema = struct {
    // ...
    /// By file index (`files.items[i]`, base and program), the file's tables.
    file_records: std.ArrayList(records.FileRecords) = .empty,

    pub fn fileRecords(self: *const Sema, file: u32) *const records.FileRecords;
};
```

Records live in the sema arena and are complete once `resolveBodies` returns.
The bridge and lowering only read them.

### 1.2 Declarations

These replace nothing in step 4: `Ref`, `RefKind` and `refs` stay until
`--dump` prints from the tables. `Receiver` and `ImplicitKind`
(`records.zig:16-42`) are reused as they are.

```zig
// src/sema/records.zig (R0 in the skeleton; writers in R)
const ast = @import("ast");
pub const NodeId = ast.NodeId;

/// Index into one of a file's pools. Every pool keeps a sentinel at 0, so
/// 0 means "no record".
pub const RecIdx = u32;

pub const FileRecords = struct {
    /// Node id -> index into the pool the node's kind implies (1.3); 0 = none.
    /// For a `Return` node the entry is the integer of the target symbol.
    rec: []RecIdx,
    /// Node id -> the expression's type, closed after its declaration's
    /// inference (1.6); `.none` on nodes that are not expressions.
    ty: []TypeId,
    calls: std.ArrayList(CallRec) = .empty,
    names: std.ArrayList(NameRec) = .empty,
    recvs: std.ArrayList(RecvRec) = .empty,
    tests: std.ArrayList(TypeTestRec) = .empty,
    refs: std.ArrayList(RefRec) = .empty,
    groups: std.ArrayList(GroupRec) = .empty,
    decls: std.ArrayList(DeclRec) = .empty,
};

pub const CallForm = enum(u8) {
    /// A function, accessor or operator: static, virtual or interface is
    /// lowering's choice from the callee's declaration.
    plain,
    /// Through `super`, `super<T>` or `super@L`: the callee is the declaration
    /// that runs, called non-virtually on the enclosing instance.
    super_,
    /// `invoke` of a function-typed value; the callee is `FunctionN.invoke`
    /// or `SuspendFunctionN.invoke`. The call's callee node is the value.
    value_invoke,
    /// A constructor making a new instance.
    ctor,
    /// `this(...)` from a secondary constructor, on the same instance.
    this_delegation,
    /// `super(...)` from a secondary constructor, a supertype initializer
    /// `: Base(...)`, or an enum entry's arguments to its class's
    /// constructor, on the same instance.
    super_delegation,
    /// `Iface { ... }`: a fun interface's synthetic SAM constructor.
    sam_ctor,
};

pub const CallRec = struct {
    callee: Sym,
    form: CallForm,
    dispatch: Receiver = .none,
    extension: Receiver = .none,
    /// One entry per parameter the arguments map to, in declaration order:
    /// the callee's value parameters after the leading contexts an `invoke`
    /// of a contextual function type takes from the scope
    /// (`calls.candParams`, calls.zig:899).
    args: []const ArgSource = &.{},
    /// Where each context argument comes from: first the leading contexts of
    /// a contextual `invoke`, then the callee's own context parameters, the
    /// order `Applied.contexts` has (calls.zig:1017-1025).
    contexts: []const Receiver = &.{},
    /// The callee's type parameters, substituted: for a constructor the
    /// class's then its own (the class's also when called through a type
    /// alias), for a function its own. A reified argument is one whose
    /// parameter has `Flags.reified`.
    type_args: []const TypeId = &.{},
    /// Parallel to `args`.
    conv: []const Conv = &.{},
};

/// Where one parameter's value comes from.
pub const ArgSource = union(enum) {
    /// The construct's operand at this index (1.4).
    arg: u16,
    /// Omitted; the callee's defaults bridge supplies it.
    default,
    /// A vararg parameter's elements in source order; empty when none.
    vararg: []const VarargPart,
    /// The call's extension receiver fills this parameter: `invoke` of an
    /// extension function type called as `recv.f()` or with an implicit
    /// receiver (`Cand.recv_arg_ty`, calls.zig:924-931).
    receiver,
};

pub const VarargPart = packed struct(u32) { arg: u16, spread: bool, _pad: u15 = 0 };

pub const Conv = union(enum) {
    none,
    /// A function value passed for a fun interface parameter: wrapped in the
    /// interface's SAM class (a lambda literal included).
    sam: Sym,
    /// A non-suspend function value passed for a suspend function type.
    suspend_,
};

pub const NameKind = enum(u8) {
    /// `val`/`var`, `for` variable, catch binding, destructuring entry,
    /// lambda or anonymous-function parameter, `it`, `when` subject binding.
    local,
    /// A value parameter or a named context parameter.
    param,
    /// A member, top-level, extension or static property.
    property,
    /// `field` in an accessor: the storage of the property `target`.
    backing_field,
    /// An object or companion, or a classifier used as a value.
    object,
    enum_entry,
};

pub const NameRec = struct {
    kind: NameKind,
    write: bool = false,
    target: Sym,
    dispatch: Receiver = .none,
    extension: Receiver = .none,
    contexts: []const Receiver = &.{},
};

/// `this` / `this@L`: which implicit receiver.
pub const RecvRec = struct { kind: ImplicitKind, owner: Sym };

pub const TypeTestKind = enum(u8) { is_, not_is, as_, as_safe, catch_, class_literal, class_of };

pub const TypeTestRec = struct {
    kind: TypeTestKind,
    /// The written type resolved; for `class_of` the operand's static type.
    ty: TypeId,
    /// The erased class; `.none` when `ty` is a type parameter, tested
    /// through its reified value.
    class: Sym,
    /// `is T?` and `as T?` admit null.
    nullable: bool,
    /// `catch_`: the parameter's local.
    binding: Sym = .none,
};

pub const RefRec = struct {
    /// A function, a constructor (`::Cls`), or a property.
    target: Sym,
    /// `.expr` for `x::f`; `.implicit` for a member referenced bare inside
    /// its class; `.none` for an unbound reference.
    bound: Receiver = .none,
    /// The function type or `KProperty` type the reference has.
    ty: TypeId,
    adapt: RefAdapt = .{},
};

pub const RefAdapt = packed struct(u32) {
    /// Trailing parameters left to their defaults.
    defaults: u16 = 0,
    /// Vararg elements passed one by one.
    vararg_elems: bool = false,
    /// The expected type returns `Unit` and the target does not.
    drop_result: bool = false,
    /// Converted to a suspend function type.
    suspend_: bool = false,
    _pad: u13 = 0,
};

pub const DeclRec = struct {
    sym: Sym,
    /// Class, object or object expression: its `supers` group.
    /// Secondary constructor: its delegation `CallRec`.
    /// Enum entry: its constructor `CallRec`.
    /// Property with a delegate: its `delegate` group. 0 otherwise.
    extra: RecIdx = 0,
};

pub const GroupRec = union(enum) {
    for_: struct { iterator: RecIdx, has_next: RecIdx, next: RecIdx, variable: Sym = .none, destructure: RecIdx = 0 },
    destructure: struct { entries: []const DestructEntry },
    compound: Compound,
    inc_dec: Compound,
    when: struct { subject: Sym = .none, branches: []const WhenBranchRec },
    lambda: LambdaRec,
    /// A dotted `Path`: one `NameRec` per segment that yields a value, 0 for a
    /// package or classifier qualifier segment. As a call's callee it covers
    /// the prefix, and also the last segment for `value_invoke`.
    path: struct { segs: []const RecIdx },
    /// Per template part, the `toString` `CallRec`; 0 for text and for a part
    /// already a `String`.
    template: struct { to_string: []const RecIdx },
    delegate: struct { provide: RecIdx = 0, get: RecIdx, set: RecIdx = 0 },
    /// Per written supertype: its constructor `CallRec`, 0 for an interface.
    supers: struct { calls: []const RecIdx },
};

pub const DestructEntry = struct {
    /// `.none` for `_`.
    local: Sym,
    /// `componentN` `CallRec`, or for name-based destructuring the property
    /// `NameRec`.
    call: RecIdx = 0,
    name: RecIdx = 0,
};

/// `a op= b`, `++a`, `a--`: the target's receiver and index arguments are
/// evaluated once.
pub const Compound = struct {
    get: RecIdx = 0, // CallRec: an index target's `get`
    read: RecIdx = 0, // NameRec: a name or member target read
    op: RecIdx, // CallRec: `plusAssign` (nothing is written), `plus`, `inc`, `dec`
    assign_form: bool = false, // `op` is an `opAssign`
    set: RecIdx = 0, // CallRec: an index target's `set`
    write: RecIdx = 0, // NameRec: the name or member written
};

pub const WhenBranchRec = struct { patterns: []const WhenPatternRec };

pub const WhenPatternRec = union(enum) {
    else_,
    /// A subject-less condition, lowered as a Boolean expression.
    condition,
    /// `equals` `CallRec`; 0 for `null ->`, an identity test.
    equals: RecIdx,
    contains: RecIdx,
    not_contains: RecIdx,
    is_: RecIdx, // TypeTestRec
    not_is: RecIdx,
};

pub const LambdaRec = struct {
    /// The committed resolution's function symbol.
    func: Sym,
    /// The function type the literal has, after SAM unwrapping.
    fn_type: TypeId,
    /// The fun interface a SAM conversion wraps it in, else `.none`.
    sam: Sym = .none,
    /// Per written parameter; `.none` for `_` and for a destructured one.
    params: []const Sym = &.{},
    /// Parallel to `params`: the `destructure` group of `(a, b) ->`, else 0.
    destructured: []const RecIdx = &.{},
    it: Sym = .none,
    /// The locals standing for a contextual function type's contexts.
    contexts: []const Sym = &.{},
    has_receiver: bool = false,
    suspend_: bool = false,
};
```

`CallRec` has no `via` field, unlike design section 1: the callee node of a
`value_invoke` (a `Path`, a `Member`, or any expression) holds the read of the
value in its own record, so lowering evaluates the callee node as a value.
`Shape(3)` resolved to `Companion.invoke` is a `value_invoke` whose callee
`Path` holds an `object` `NameRec`.

### 1.3 Which pool a node's record is in

| Node | Pool | Record |
|------|------|--------|
| `Call` | calls | the call, every form |
| `Path`, one segment | names / recvs | the read or write; `$this` and a bare `this` go to recvs |
| `Path`, several segments | groups `path` | per segment |
| `Member` | names | property, object or enum entry; 0 when it is a call's callee or a qualifier |
| `Index` | calls | `get` |
| `Binary` arithmetic, `..`, `..<`, `<` `<=` `>` `>=`, `in`/`!in`, `==`/`!=` | calls | `op`, `rangeTo`/`rangeUntil`, `compareTo`, `contains`, `equals` (0 when either side is the `null` literal) |
| `Binary` `&&` `\|\|` `?:` `===` `!==` | - | none |
| `Binary` `=` | calls / names | `set` when the left side is an `Index`; else the write `NameRec` on this node (the left side is resolved as a write target, not entered as an expression) |
| `Unary` `-` `+` `!` | calls | 0 when sema folded a literal (`-1`) |
| `Unary` `++`/`--`, `Postfix` `++`/`--` | groups `inc_dec` | |
| `Postfix` `!!`, `If`, `While`, `DoWhile`, `Throw`, `Labeled`, `Spread`, `Block`, `Break`, `Continue`, `Try` | - | none |
| `This` | recvs | |
| `IsCheck`, `As` | tests | |
| `For` | groups `for_` | |
| `When` | groups `when` | |
| `Lambda`, `AnonFun` | groups `lambda` | |
| `ObjectExpr` | decls | the anonymous class, `extra` = its `supers` |
| `StringTemplate` | groups `template` | the `$name` parts' reads are on their `Ident.id` |
| `Return` | `rec` holds the target `Sym` | the function or lambda it leaves |
| `PropertyRef`, `MemberRef` | refs; tests for `::class` | |
| `AssignStmt` `=` | calls / names | `set` for an `Index` target; else the write `NameRec` on this node, as for `Binary` `=` |
| `AssignStmt` `op=` | groups `compound` | |
| `DestructuringDeclStmt` | groups `destructure` | |
| `Catch` | tests | `catch_` with `binding` |
| Local `Property`, local `Function`, local `Class`/`Object` | decls | `extra` = delegate group or `supers` |
| `Class`, `Object`, `EnumEntry`, `SecondaryCtor` anywhere | decls | for their calls |

### 1.4 Operands: what `ArgSource.arg` counts

| Construct | Operand list |
|-----------|--------------|
| `Call`, not infix | `Call.args` in source order, a trailing lambda last |
| infix `a f b` (`Call.is_infix`) | `Call.args[1..]`; `Call.args[0]` is the receiver (`dispatch`/`extension` `.expr`) |
| binary operator, `compareTo`, `rangeTo`, `rangeUntil`, `equals` | `[rhs]`; `lhs` is the receiver |
| `in` / `!in` | `[lhs]`; `rhs` is the receiver |
| `when` `in` pattern | `[subject]`; the pattern value is the receiver |
| `when` value pattern `equals` | `[pattern value]`; the subject is the receiver |
| `Index` `get` | `Index.args` |
| `a[i] = v` | `Index.args ++ [v]` |
| compound `set` | `Index.args ++ [the op's result]` |
| unary, `inc`, `dec`, `iterator`, `hasNext`, `next`, `componentN`, `toString` | `[]` |
| `provideDelegate`, `getValue` | `[thisRef, property]`: `this` or `null`, and the `KProperty` value |
| `setValue` | `[thisRef, property, value]` |
| supertype initializer, enum entry, delegation | the written arguments |

### 1.5 How sema fills each record from what it computes today

| Field | Source in sema today |
|-------|----------------------|
| `callee`, `dispatch`, `extension` | `Cand.sym`, `.dispatch`, `.extension`, or `.recv_arg_src` for an extension-function-type invoke (`complete`, calls.zig:1433-1479) |
| `args` | `Applied.slots` (calls.zig:109-121), per argument the parameter; inverted per parameter. `slot.vararg_elem` and `Arg.spread` give `VarargPart`; the placeholder receiver argument at index 0 when `recv_arg_ty != .none` (calls.zig:924-931) becomes `.receiver` and shifts the rest down by one; an infix call's right operand is argument 0 |
| `contexts` | `Applied.contexts` (calls.zig:120, filled at 1017-1025). `operatorCall` records none (calls.zig:1881) and `propertyAccess` computes none (calls.zig:1806-1828): both must |
| `type_args` | `app.sys` solution over `candTypeParams` (calls.zig:905-918), closed; for a constructor through an alias, the class's parameters (`candTypeParams` returns the alias's) |
| `conv.sam` | decided in `check` (calls.zig:994-998) and in `lambda` (`sam_ret`, calls.zig:1515-1521), not kept |
| `form` | `superCall` → `super_`; `Cand.via != .none` → `value_invoke`; constructor → `ctor`; `delegationCall(is_super)` → `this_delegation`/`super_delegation`; `superTypeCall` → `super_delegation`; `samConstructor` → `sam_ctor` |
| `NameRec` | `nameAccess` (body.zig:1887-1950), `propertyAccess`, `staticMember` (body.zig:2139-2172), `classifierAsValue`, `memberAccess`; `backing_field` from `accessorBody` (body.zig:458-474), which declares `field` as a local today |
| `RecvRec` | `thisReceiver` (body.zig:1434); `thisExpr` (body.zig:1424) records nothing today |
| `TypeTestRec` | `IsCheck`/`As` (body.zig:1192-1201), `when` `is` patterns (`whenExpr`), catch (body.zig:1168-1180) resolve the type and record nothing today |
| `for_` | `iteration` (calls.zig:2071-2078) records three calls at one span |
| `destructure` | `destructure` (body.zig:758-771) |
| `compound`, `inc_dec` | `compoundAssign`, `readTarget`, `writeTarget`, `incDec` (calls.zig:1912-2047) |
| `when` | `whenExpr` (body.zig:1330+) records `equals` at the pattern's span, the same span as the pattern value's own record |
| `lambda` | `lambda` (calls.zig:1505-1594) and `anonymousFunction` (1673-1746) create the symbol and locals and record none of them |
| `template` | nothing today: sema resolves the parts only (body.zig:1097-1109) |
| `delegate` | `delegateAccess` (calls.zig:2088-2107), three calls at one span |
| `supers`, enum entry, secondary delegation | `superCalls` (body.zig:684-702), `enumEntry` (704-711), `secondaryCtor` (654-671) |
| decl records | `localDecl` (body.zig:785-818), `localFunction` (820), `localClass` (903), `objectExpr` (1417) |
| `Return` target | `returnTarget` (body.zig:1287-1301) finds the scope and records nothing |
| `RefRec` | `callableRef` (calls.zig:2244-2399) records the target, its dispatch and the extension receiver it binds; adaptation is not computed |
| `ty` | the return value of `body.expr` (body.zig:1084); not kept |

### 1.6 Write rules

- Writes follow `Ctx.addRef`'s rules (body.zig:94-106): nothing while
  `census.muted != 0`; while a buffer is open the write goes to the buffer;
  `commit` (body.zig:117-131) copies a buffer's writes into its parent or the
  tables; `drop` discards them. The buffer type grows from `refs` to a list
  of `(file, node, pool, record)` writes.
- In Debug, a second committed write to one `(file, node)` asserts.
- `ty[id]` is written raw and closed once the top-level declaration that
  owns the body finishes resolving: each entry is zonked, and an `int_lit`
  nobody constrained takes its default (`infer.intLitDefault`). Lowering
  picks a literal's `Const` kind from `ty`.
- A symbol made by a resolution that was dropped or muted (a lambda resolved
  twice, calls.zig:1301 and 1523; locals in a dropped buffer) is named by no
  committed record. The bridge allocates ids for local symbols only from
  committed records (B), so such symbols never get one.
- `inferReturnType` and `inferPropertyType` (body.zig:375, 484) resolve
  another declaration's body unmuted and unbuffered even while the caller
  speculates; their writes are committed writes, as their `Ref`s are today.

### 1.7 What lowering calls

C1 declares these in `src/ir/lower/sema/records.zig` and re-exports them as
`Builder` declarations, so a body writes `b.call(id)`. The design's
`b.test(id)` cannot be spelled: `test` is a Zig keyword.

```zig
pub const Error = error{ OutOfMemory, Unrecorded, Unsupported };

pub fn call(b: *Builder, id: NodeId) Error!*const CallRec;
pub fn name(b: *Builder, id: NodeId) Error!*const NameRec;
pub fn recv(b: *Builder, id: NodeId) Error!RecvRec;
pub fn typeTest(b: *Builder, id: NodeId) Error!*const TypeTestRec;
pub fn ref(b: *Builder, id: NodeId) Error!*const RefRec;
pub fn group(b: *Builder, id: NodeId) Error!*const GroupRec;
pub fn decl(b: *Builder, id: NodeId) Error!*const DeclRec;
pub fn returnTarget(b: *Builder, id: NodeId) Error!Sym;
pub fn exprType(b: *Builder, id: NodeId) TypeId; // .none tolerated only where 1.3 allows
/// Group members by pool index.
pub fn callAt(b: *Builder, i: RecIdx) Error!*const CallRec;
pub fn nameAt(b: *Builder, i: RecIdx) Error!*const NameRec;
pub fn testAt(b: *Builder, i: RecIdx) Error!*const TypeTestRec;
```

A lookup on id 0 (a node a later pass built) or on a pool index of 0 fails
with `error.Unrecorded`, naming the span.

### 1.8 Records sema does not compute yet

Everything in 1.2 is new storage. Beyond storing what sema already decides,
these facts are not computed today and `R` (or `sema/facts`) has to add
them:

1. Context arguments for operator conventions and for property reads with
   context parameters (calls.zig:1881; calls.zig:1806).
2. SAM and suspend conversions of arguments (`Conv`).
3. Records for `this`, type tests, catch parameters, lambdas, templates and
   `return` targets.
4. Lambda labels. `lambdaLabel` returns `.empty` (calls.zig:1604-1609), so
   `return@forEach` and `this@let` do not resolve through the callee's name,
   which an acceptance fact needs (`this@let` names the innermost `let`).
5. Destructured lambda parameters: `lambda` skips `(a, b)` parameters
   (calls.zig:1580).
6. Callable-reference adaptation (`RefAdapt`).
7. Whether a property's accessors read `field`, which decides whether it has
   a backing field (B). Either a flag on `PropertyInfo` set when a
   `backing_field` record commits, or B derives it from the records.
8. Accessor identities: `collectProperty` (decls.zig:220-248) never makes
   accessor symbols, and `PropertyInfo.getter`/`.setter` stay `.none`. B keys
   accessor `FuncId`s by property (decision 7).
9. A `NativeId` per native-bound declaration (`sema/facts`). Until then B
   binds bodyless declarations through a resolver by FQN, once, at bridge
   time (decision 11).

## 2. The shared contract

### 2.1 Identities (A, in the skeleton)

```zig
// src/ir/core/ids.zig, added
pub const NativeId = enum(u32) {
    none = std.math.maxInt(u32),
    _,
    pub fn from(v: u32) NativeId { return @enumFromInt(v); }
    pub fn int(self: NativeId) u32 { return @intFromEnum(self); }
};
pub const StaticId = enum(u32) {
    _,
    pub fn from(v: u32) StaticId { return @enumFromInt(v); }
    pub fn int(self: StaticId) u32 { return @intFromEnum(self); }
};
/// A `FuncId` field left empty (a property reference with no setter).
pub const NO_FUNC: u32 = std.math.maxInt(u32);
```

Unchanged: `FuncId`, `ClassId`, `MethodSlotId` (ids.zig:79, 127, 114). A
method slot is the root declaration's `FuncId` (`MethodSlotId.fromFunc`,
ids.zig:119), and `Module.method_dispatch` (ir.zig:450, key
`(class << 32) | slot`, `methodSlotTarget` at module_methods.zig:29) maps a
class and slot to the implementation. A field slot is a `u32` index into an
instance's `fields`.

### 2.2 Calling convention

Every frame the new instructions build receives its arguments in this order
(`LoadParam idx` counts from 0). A suspend function takes no continuation:
the VM suspends by snapshotting frames (`src/ir/eval/snapshot.zig:88-115`,
`resumeContinuation` at activation.zig:128), so `Func.is_suspend` is the
whole of it.

| Body | Parameters |
|------|------------|
| top-level or static function | contexts, extension receiver, value parameters, reified type values |
| member function | `this`, contexts, extension receiver (member extension), value parameters, reified type values |
| getter / setter | `this` (member), contexts, extension receiver, then the new value for a setter |
| constructor | `this`, the outer instance (inner class), `name` and `ordinal` (enum class), captured values (local class or object expression), value parameters. Returns `this` |
| defaults bridge | the target's parameters, then one `Int` mask per 32 value parameters (bit i: parameter i omitted); an omitted slot holds `Unit` |
| lambda or anonymous function (closure body) | contexts, receiver, value parameters; captures through `LoadCapture` |
| local function | captured values, then as a top-level function (decision 5) |
| init unit (a file's statics, an enum class's entries) | none |
| SAM class method | `this`, the interface method's parameters; calls the function value in field 0 |
| callable-reference adapter | the reference's function type parameters; the bound receiver is capture 0 |

`args[0]` of a member call is its receiver; `RCallValue` passes contexts,
receiver and parameters in the function type's order
(`Sema.contextFunctionType`, sema.zig:330).

### 2.3 The new instructions (A, declared in the skeleton)

Appended at the end of `Inst` (inst.zig:397-717), after `Lambda`, so no
existing tag renumbers. Six of the design's surviving variants change shape
and cannot share a name with the variant beside them; they carry an `R`
prefix until `cut/switch` deletes the old ones and renames these (decision
1). The union stays 64 bytes (the size test at inst.zig:913-919).

```zig
CallStatic: struct { dst: Reg, func: FuncId, args: Reg, n_args: u32 },
RCallVirtual: struct { dst: Reg, slot: MethodSlotId, args: Reg, n_args: u32 },
CallInterface: struct { dst: Reg, iface: ClassId, slot: MethodSlotId, args: Reg, n_args: u32 },
CallNative: struct { dst: Reg, native: NativeId, args: Reg, n_args: u32 },
RCallValue: struct { dst: Reg, callee: Reg, args: Reg, n_args: u32 },
RNewInstance: struct { dst: Reg, class: ClassId, ctor: FuncId, args: Reg, n_args: u32 },
GetFieldSlot: struct { dst: Reg, obj: Reg, slot: u32 },
SetFieldSlot: struct { obj: Reg, slot: u32, value: Reg },
LoadStatic: struct { dst: Reg, static: StaticId },
StoreStatic: struct { static: StaticId, value: Reg },
LoadObject: struct { dst: Reg, class: ClassId },
MakeClosure: struct { dst: Reg, func: FuncId, captures: []const Reg },
FunctionRef: struct { dst: Reg, adapter: FuncId, target: FuncId, bound: ?Reg },
RPropertyRef: struct { dst: Reg, getter: FuncId, setter: u32 = NO_FUNC, bound: ?Reg, name: ConstId },
ClassLiteral: struct { dst: Reg, class: ClassId },
ClassOf: struct { dst: Reg, src: Reg },
RInstanceOf: struct { dst: Reg, src: Reg, class: ClassId, nullable: bool },
RCast: struct { dst: Reg, src: Reg, class: ClassId, nullable: bool, safe: bool },
InstanceOfDyn: struct { dst: Reg, src: Reg, ty: Reg, nullable: bool },
CastDyn: struct { dst: Reg, src: Reg, ty: Reg, nullable: bool, safe: bool },
ArrayGet: struct { dst: Reg, array: Reg, index: Reg },
ArraySet: struct { array: Reg, index: Reg, value: Reg },
NewArray: struct { dst: Reg, class: ClassId, args: Reg, n_args: u32 },
```

Reused as they are: `Const`, `LoadParam`, `LoadCapture`, `Move`, `MakeCell`,
`CellGet`, `CellSet`, `BinOp` (with `compound = false`), `UnOp`, `Not`,
`NotNullAssert`, `LateinitCheck`, `Trace`, and the terminators `Goto`,
`Branch`, `Switch`, `Return`, `Throw`, `Unreachable`, `TailJump`,
`TailCallFunc`. `CatchHandler` (inst.zig:898-902) gains
`class_raw: u32 = NO_CLASS`; a handler with a class matches by
`Module.classIsA` and ignores `type_name`. `SuspendResumePoint`,
`NonLocalReturn`, `LabeledReturn` and `LrAbsorb` are never emitted by the new
lowering.

Semantics the arms implement:

| Variant | Meaning |
|---------|---------|
| `CallStatic` | Run `func` with the run as its parameters: its native when `func_native[func] != .none`, else its body. No overload pick, no host route |
| `RCallVirtual`, `CallInterface` | `c = classOf(args[0])` (null receiver throws `NullPointerException`); `f = methodSlotTarget(c, slot)`; a miss is an internal error, never a name lookup; then as `CallStatic`. `iface` is unused until `cut/objects` |
| `CallNative` | `natives[native].func` with a `CallCtx` over the run |
| `RCallValue` | A closure from `MakeClosure`/`FunctionRef`: its body with the run as parameters and its captures. Any other value (an instance of a class implementing a function type): `invoke` through the root slot of `FunctionN.invoke` for `n_args`, as `RCallVirtual` |
| `RNewInstance` | Allocate an instance of `class` with its slots seeded, then call `ctor` with the instance prepended; `dst` receives the constructor's result, which is `this` |
| `GetFieldSlot`/`SetFieldSlot` | `fields.items[slot].value`, no name check |
| `LoadStatic`/`StoreStatic` | Run the static's init unit on first touch (a touch during the unit reads the seed), then read or write the value |
| `LoadObject` | The singleton; on first use allocate it, publish it, then run its constructor |
| `MakeClosure` | A closure over `func` capturing the registers' values |
| `FunctionRef` | A closure over `adapter` with `bound` as capture 0; equality and `name` answer from `target` |
| `RPropertyRef` | A property reference value: `get` calls `getter`, `set` calls `setter`, `name` is the constant |
| `ClassLiteral`, `ClassOf` | The `KClass` value of `class`, or of the value's run-time class |
| `RInstanceOf`, `RCast` | `classIsA(classOf(src), class)`; null passes when `nullable`; a failed cast throws `ClassCastException`, or gives null when `safe` |
| `InstanceOfDyn`, `CastDyn` | As above with the class taken from the reified type value in `ty` |
| `ArrayGet`, `ArraySet` | Element access on an array value (bounds-checked), or on a `String` for `get` |
| `NewArray` | An array of `class` holding the run |

### 2.4 Run-time tables (A declares, B fills)

```zig
// src/ir/core/resolved.zig
pub const Resolved = struct {
    /// By ClassId.
    classes: []ClassRt,
    /// By StaticId.
    statics: []StaticRt,
    init_units: []InitUnitRt,
    /// By NativeId.
    natives: []NativeRt,
    /// By FuncId: the native a bodyless declaration is bound to, else `.none`.
    func_native: []NativeId,
    /// The class of each host value kind: `Int`, `Long`, ..., `String`,
    /// `Array`, the `FunctionN` of a closure of each arity, and the root
    /// slot of each `FunctionN.invoke`.
    host_class: HostClasses,
};
pub const ClassRt = struct {
    def: runtime.ObjRef(runtime.ClassDef), // ClassDef.ir_class == this ClassId
    seeds: []const ir.class.SlotSeed,       // one per field slot (class.zig:191-201)
    object_ctor: u32 = NO_FUNC,             // objects and companions
};
pub const StaticRt = struct { unit: u32, seed: ir.class.SlotSeed, name: []const u8 };
pub const InitUnitRt = struct { func: FuncId };
pub const NativeRt = struct { func: runtime.StdlibFn, name: []const u8 };

/// Per VM run: owned by the host, reached by `host.resolvedState()`.
pub const ResolvedState = struct {
    statics: []Value,
    unit_state: []enum(u8) { idle, running, done },
    singletons: []?Value, // by ClassId
};

pub fn classOf(r: *const Resolved, v: *const Value) ?ClassId;
pub fn declineTiers(f: *ir.Func) void; // see A
```

`ir.Module` gains `resolved: ?*Resolved = null`. `runtime.ClassDef`
(runtime/class.zig:35) gains `ir_class: u32 = std.math.maxInt(u32)`, which
`classOf` reads for an instance. `Module.method_dispatch` and
`Module.class_ancestors` (ir.zig:450-453) are reused, filled by B directly.

## 3. Packages

### S. Skeleton

One commit before anyone else starts, because it is the only one that
touches files every package reads. Written by the lead or by the C1 engineer
under the lead's review (decision 13).

- `src/sema/records.zig`: the declarations of 1.2 (no writers);
  `Sema.file_records` and `fileRecords` returning empty tables.
- `src/ir/core/ids.zig`, `inst.zig`, `resolved.zig`: 2.1, 2.3, 2.4 declared;
  `execInst` arms for the new variants return an internal error;
  `site_census.classify` (site_census.zig:358, exhaustive) maps every new
  variant to `.plain_inst`; `FORMAT_VERSION` 85 to 86 (image.zig:53).
- `src/ir/ir.zig`: `Module.resolved`; `pub const bridge`, `pub const resolved`,
  `pub const lower_sema` exports.
- `build.zig` `mod_list`: `ir` gains `sema`; a new module
  `.{ .name = "lower_driver", .deps = &.{ "span", "ast", "lexer", "parser", "sema", "ir", "runtime", "stdlib", "interp_ir" }, .tested = true }`.
- Every file of sections A to E with its public declarations and stub
  bodies, the `Builder` struct with all of C1's fields and D's `regions`,
  `body.zig`'s expression and statement switches routing to the other
  packages' functions, and the empty test files the driver root imports.

Acceptance: `zig build` and `zig build test` pass; nothing the old pipeline
runs changes. Size about 0.9k.

### A. Instructions and the VM

Purpose: execute the new variants in the frame interpreter, and keep every
other engine from running them wrongly.

**Which engine.** The frame interpreter's `execInst` (eval/inst.zig:116,
exhaustive switch at 124) runs them. The other engines decline:

| Engine | Where | What a new variant gets today | A's change |
|--------|-------|------------------------------|------------|
| Frame interpreter | eval/inst.zig:124 | compile error | one arm per variant calling into `src/ir/eval/resolved.zig` |
| Bytecode streams | bc.zig:240 (`else` at 322) | `Op.escape` to `execInst` (exec.zig:491-500) | none |
| Fused tier | fused.zig:295 `fusedClassify` (`else` at 357: heavy, verdict 4, materialize) | partial run, then a frame | explicit reject in `ClassifyReject` (fused.zig:201), as `suspend_resume_point` is at 356 |
| Leaf tier | leaf.zig:364 `leafRunOne` (`else` at 517) | abandon, `leaf_hopeless = 1` | none; B's shells start hopeless (`declineTiers`) |
| Function JIT | compile_func.zig:582 (`else` at 610), `execEscapable` loop_shape.zig:215 | declines unless `KLIO_FJ_ESCAPE=1`, then escapes to `execInst` | none; `declineTiers` sets `PROBE_DECLINED` |
| Loop JIT | compile_loop.zig:320 `rejectsLoopShape` | `unsupported_shape` | none |
| cgen | cgen/eligible.zig:324 (`else` at 387) | the function is refused | none |
| C leaf library | commands.zig:1653 `leafEligible` | not eligible | none |
| Site census | site_census.zig:358 (exhaustive) | compile error | `.plain_inst` (in S) |

Switches that must learn the variants:

| File | Function | Change |
|------|----------|--------|
| eval/exec.zig:1045 | `instDst` (`else` → null at 1057) | the six call variants, `RNewInstance`, `LoadObject`, `LoadStatic`: without it a suspension inside them loses its resume register |
| eval/exec.zig:1037 | `findCatch` | `class_raw` first |
| ir/disasm.zig:96 | `dumpInst` | print ids and display names |
| core/func.zig:293 | `freeBuilt` | nothing is boxed; `MakeClosure.captures` follows `Lambda.captures` |
| interp_ir/image.zig:53 | `FORMAT_VERSION` | bumped in S with the appended variants (the encoder is generic, image.zig:299-311) |

`Module.resolved` is not serialized in step 4; `sema/image` owns that.

Files: `src/ir/core/inst.zig`, `ids.zig`, `resolved.zig`,
`src/ir/eval/resolved.zig` (new, the arms), `src/ir/eval/inst.zig`,
`exec.zig`, `fused.zig`, `src/ir/disasm.zig`, `src/ir/core/func.zig`,
`src/ir/site_census.zig`, `src/runtime/class.zig`,
`src/interp_ir/vm/vmhost.zig`, `run.zig`, `host_call_value.zig`.

Public API:

```zig
// src/ir/core/resolved.zig
pub fn classOf(r: *const Resolved, v: *const Value) ?ClassId;
pub fn declineTiers(f: *ir.Func) void; // leaf_hopeless = 1, fuse_state = 2, func_jit_probe |= PROBE_DECLINED
pub fn stateInit(a: Allocator, r: *const Resolved) Allocator.Error!ResolvedState;

// src/ir/eval/resolved.zig: one entry per variant, called from execInst
pub fn execCallStatic(comptime H: type, a: Allocator, frame: *Frame, x: anytype, host: *H) Allocator.Error!Step;
// ... execRCallVirtual, execCallInterface, execCallNative, execRCallValue,
// execRNewInstance, execGetFieldSlot, execSetFieldSlot, execLoadStatic,
// execStoreStatic, execLoadObject, execMakeClosure, execFunctionRef,
// execRPropertyRef, execClassLiteral, execClassOf, execRInstanceOf, execRCast,
// execInstanceOfDyn, execCastDyn, execArrayGet, execArraySet, execNewArray

// Host hooks the arms call (VmHost implements; NullHost returns an error)
pub fn resolvedState(self: *VmHost) *ResolvedState;
pub fn callNative(self: *VmHost, a: Allocator, id: NativeId, args: []const Value) Allocator.Error!EvalResult;
pub fn runResolved(self: *VmHost, a: Allocator, f: FuncId, args: []const Value) Allocator.Error!EvalResult; // init units
```

How the arms call: `CallStatic`, the virtual and interface calls,
`RCallValue` and `RNewInstance` set `frame.flat_call` (`FlatCallReq`,
flow.zig:39) and return `.flat_call`, so the call pushes an activation
without recursion; a closure passes its captures in `FlatCallReq.captures`.
`LoadStatic`'s init unit and `LoadObject`'s constructor run through
`runResolved` (recursive), because the instruction needs the result before
it continues. `RNewInstance` builds an `InstanceData` (runtime/class.zig:503)
with `fields` sized and seeded from `ClassRt.seeds`, `reserved` set to the
slot count and display names from the class def, and needs no
`ProgramImage` table. `MakeClosure` may reuse `buildClosure`
(host_call_value.zig:2014) as long as `RCallValue` invokes the result
exactly: no receiver prepend, no `this` capture override (today's arm does
both, exec_call.zig:731-751).

Consumes: S only. Its tests build modules by hand.

Tests (`src/lower_driver/tests/vm.zig`, and unit tests in
`src/ir/eval/resolved.zig`): one hand-built module per variant run through
`Vm.new` and `vm.run` (the pattern of run.zig:989-1016): a static call
chain, virtual dispatch through two overrides and a diamond through
interfaces, a native call writing output, a closure with a captured cell,
construction with seeds read before the constructor writes, statics with
an init unit reading its own static, a singleton that reads itself in its
constructor, casts and tests including `nullable`, a catch handler by
class, array access out of bounds, a call that suspends inside a
`CallStatic` and resumes into its `dst`.

Acceptance: every variant has an arm and a test; no new arm reads a name;
the declines in the table hold (a test asserts `fuse_state` and
`leaf_hopeless` after a run); the `lower_driver` test binary passes run with
`KLIO_JIT=0` and with `KLIO_FJ_ESCAPE=1`; `zig build test` and
`zig build klio-harness` pass.

Size: 1.7k code, 0.6k tests.

### B. core/bridge

Purpose: allocate every identity from sema's symbols, serially and in symbol
order, and build the `ir.Module` skeleton and run-time tables the VM runs.

Files: `src/ir/core/bridge.zig` (new).

What it allocates, walking symbols `1 .. syms.count()` in order, then local
symbols named by committed records (below), in order:

| Id | For |
|----|-----|
| `ClassId` | every class symbol (classes, interfaces, objects, companions, enum classes, enum entries with bodies, annotation classes, local classes, object expressions, `FunctionN`/`SuspendFunctionN`), plus one SAM class per fun interface |
| `FuncId` | every function and constructor symbol that is not `superseded`, abstract ones included (their id is the slot of the family they root), and the synthetic members sema makes for `: I by d` (`FunctionInfo.forwards`, `PropertyInfo.forwards`, symbols.zig:192, 214; made by `synthesizeDelegation`, decls.zig:541); per property a getter and, for a `var`, a setter; per declaration with a defaulted parameter its defaults bridge; per committed lambda, anonymous function and local function; per SAM class its constructor and method; per init unit; per callable reference an adapter, one per `(target, type, bound kind)` |
| `StaticId` | top-level properties with storage or a delegate, enum entries |
| init unit | per file with a static, per enum class |
| field slot | per class: the superclass's slots, then (inner) the outer instance, then backing fields of constructor properties, then body properties in source order, then `$delegate` storage, then a local class's or object expression's captured values |
| `NativeId` | per bodyless, non-abstract function the resolver binds |

A property has a backing field when it is not abstract, not in an interface,
not an extension, not delegated, and it is a constructor property, has an
initializer, is `lateinit`, has a default getter or (for a `var`) a default
setter, or an accessor reads `field` (1.8 item 7). An accessor-only override
gets no slot. A property that overrides a property with a slot and declares
its own storage gets its own slot; a read takes the nearest owner's.

Local symbols: B scans each file's committed `decls` (local declarations,
object expressions) and `lambda` groups, collects their symbols and every
member of a collected local class, sorts by symbol, and allocates after the
global walk. A symbol no committed record names gets no id. The layer order
from `Sema.addFiles` (sema.zig:188-203) keeps the base prefix stable.

Captures and cells: before any body lowers, B walks every nested body (a
lambda, anonymous function or local function, and every member of a local
class or object expression) and collects, from the records of its nodes,
each local, parameter or implicit receiver it reads whose owner is outside
the nested body, adding the captures of the local functions it calls and the
local classes it constructs. The result is each nested function's capture
list and each local class's captured-value slots, in first-reference order.
A local `var` (or a `val` assigned after its declaration) that any nested
body reads or writes is a cell. With captures known in advance, every body
lowers on its own, in any order, and a recursive local function has its
capture list before its body lowers.

Tables it fills:

- `module.funcs`: a shell per `FuncId` with `id` equal to its index
  (`funcById`, module_lookup.zig:150), display `name`/`fqn`, `params` of the
  right length with display names, `return_ty = .{ .name = "", .nullable = true, .args = &.{} }`
  (so `coerceIntToLongTy`, enter.zig:602, never applies), `is_suspend`, and
  `declineTiers`. Lowering fills `blocks`, `entry`, `n_locals`.
- `module.classes`: one `ir.Class` per `ClassId` with display names and
  `supertypes` as `ClassId`s, for disassembly.
- `module.method_dispatch`: for each class in an order where supertypes come
  first: inherit every entry of each supertype (the class supertype last, so
  a class implementation wins over an interface default); then for each own
  non-private, non-static member function or accessor `m`, for every root of
  `m`'s override chain (`members.overridden`, members.zig, followed to
  members that override nothing), set `(class, slot(root)) = func(m)`. A
  member overriding two roots gets both entries. Abstract members add no
  entry.
- `module.class_ancestors`: the sorted closure of supertypes, `Any` included,
  for `classIsA` (module_props.zig:621).
- `Resolved`: `ClassRt` with a minimal `runtime.ClassDef` per class
  (`ir_class` set, display names, empty member lists), seeds by the
  property's type (`Int` 0, `Boolean` false, ..., others null), statics,
  init units, natives through the injected resolver, `func_native`,
  `host_class`.

Public API:

```zig
pub const NativeResolver = *const fn (fqn: []const u8) ?runtime.StdlibFn;

pub const Options = struct {
    /// The files whose declarations get bodies (all of them in a test run).
    files: []const u32,
    natives: NativeResolver,
};

pub const FuncOrigin = union(enum) {
    decl: Sym, // function or constructor with a body, or synthetic member
    getter: Sym, // property
    setter: Sym,
    defaults: Sym, // the declaration whose defaults it evaluates
    init_unit: u32,
    lambda: Sym, // lambda, anonymous function, local function
    sam_ctor: Sym, // fun interface
    sam_method: Sym,
    adapter: u32, // index into `adapters`
    abstract: Sym, // slot only; never runs
};

pub const Bridge = struct {
    s: *sema.Sema,
    m: *ir.Module,
    origin: []FuncOrigin, // by FuncId
    // by Sym index; a sentinel where the symbol has none
    func_of: []FuncId,
    getter_of: []FuncId,
    setter_of: []FuncId,
    defaults_of: []FuncId, // for an override: the bridge of the declaration that declares the defaults
    class_of: []ClassId,
    static_of: []StaticId,
    field_of: []u32, // by property: its slot in the owning class
    delegate_field_of: []u32,
    native_of: []NativeId,
    sam_class_of: []ClassId, // by fun interface
    // by ClassId
    outer_slot: []u32,
    /// Local classes and object expressions: the captured values, stored from
    /// slot `capture_base[class]` on, in this order.
    class_captures: []const []const CaptureKey,
    capture_base: []u32,
    // by FuncId
    slot_of: []MethodSlotId, // the root's id, for a virtual or interface call
    /// Lambdas, anonymous functions, local functions: what each captures, in order.
    captures_of: []const []const CaptureKey,
    // by Sym
    cells: std.DynamicBitSetUnmanaged, // locals that live in a cell

    pub fn funcOf(self: *const Bridge, s: Sym) FuncId; // asserts allocated
    pub fn classOf(self: *const Bridge, s: Sym) ClassId;
    pub fn getterOf(self: *const Bridge, prop: Sym) FuncId;
    pub fn setterOf(self: *const Bridge, prop: Sym) ?FuncId;
    pub fn fieldOf(self: *const Bridge, prop: Sym) ?u32; // null: no backing field
    pub fn staticOf(self: *const Bridge, s: Sym) ?StaticId;
    pub fn nativeOf(self: *const Bridge, f: Sym) NativeId;
    pub fn defaultsOf(self: *const Bridge, f: Sym) ?FuncId;
    pub fn adapterFor(self: *const Bridge, file: u32, ref: RecIdx) FuncId;
    pub fn isCell(self: *const Bridge, local: Sym) bool;
};

pub const CaptureKey = union(enum) { local: Sym, receiver: struct { kind: ImplicitKind, owner: Sym } };

pub fn build(a: Allocator, s: *sema.Sema, opts: Options) Allocator.Error!*Bridge;
```

Consumes: sema symbols (`symbols.zig`), `headers.supertypes`,
`members.overridden`, the committed records and the AST of nested bodies
(for local symbols, captures, cells, adapters, `field` reads), the
`Resolved` types from S.

Tests (`src/lower_driver/tests/bridge.zig`): over the executable base plus a
program: every symbol that needs an id has one; building twice gives equal
arrays (determinism); dispatch entries for an override chain, a diamond, an
interface default, and an abstract root; ancestors include `Any`; layout of
an inner class, a subclass of an open class with body properties, an
accessor-only override (no slot), a constructor `override val`, a
delegated property; a lambda resolved speculatively and then committed gets
exactly one `FuncId`; the captures of a lambda nested in a lambda, of a
recursive local function and of a local class calling a local function; a
`var` read by a lambda is a cell and a captured `val` is not.

Acceptance: the tests pass; the arrays do not depend on the order lowering
later runs in (lowering never allocates).

Size: 1.4k code, 0.5k tests.

As built (`src/ir/core/bridge.zig`):

- **Order per layer.** `Options.layers` gives the symbol and file counts
  after each `Sema.addFiles`. For each layer: its declarations in symbol
  order, its init units (files in file order, then enum classes), the local
  declarations of its files, then its adapters. Symbols sema made after the
  last layer (a `FunctionN` above the eager arity) follow. `layer_ends`
  holds the id counts at the end of each layer, so the base's ids, locals
  included, do not depend on the program.
- **What is a declaration.** Reachable from a package's member index
  through class member indexes (not superseded), plus sema's SAM
  constructors; local ones are named by a committed `decl` record, with
  every member of a local class. A function a body declares while a class
  scope is innermost (an `init` block) is local, not a member.
- **Captures** are computed per file from the records whose anchor lies in
  a nested body's source range (lambda, anonymous or local function, local
  class or object expression, innermost first). A key is added to that body
  and each enclosing one it is foreign to (`within` by owner chain); a read
  of `field` captures the class's `this` and `super` is `class_this`. Calls
  of local functions, constructions of local classes and references to
  either add the callee's captures, closed to a fixpoint. A local class's
  members read captures from its slots, so they have none of their own; a
  local function's defaults bridge and an adapter of a reference to a local
  function or class share its captures.
- **Natives.** A bodyless function binds by FQN; so does the getter of a
  bodyless, non-abstract property outside an interface (`String.length`),
  which then has no field. `native_of` is keyed by the function or, for a
  getter, the property.
- **Extra API**: `ClassOrigin` (declaration or SAM class) by `ClassId`,
  `layout` (slot names and seeds), `by_slots` and `delegateSlot` for
  `: I by d`, `samCtorOf`/`samMethodOf`, `units`, `lowersFile`, and the
  optional lookups `funcOfOpt`/`classOfOpt`. Each `ClassDef` gets
  `layout_slots` with display names and seeds.

### E. Test driver and executable base

Purpose: one call that runs Kotlin source through parse, sema, bridge, the
new lowering and the VM, and returns what it printed.

Files: `src/lower_driver/lower_driver.zig`, `mini_base.zig`, `natives.zig`,
and the test files (created in S, each owned by its package).

`src/sema/tests.zig`'s `mini_kotlin` (tests.zig:19-58) cannot be executed:
every body is a placeholder (`= this`, `= ""`, `TODO()`) and it declares no
`println`. E writes an executable miniature base in the same style
(`package kotlin` declarations, `public` modifiers) with real bodies, leaving
sema's tests untouched:

- `Any` (`toString`, `equals`, `hashCode` bodyless, bound to E's natives),
  `Unit`, `Nothing`, `Boolean`, `Char`, `Int`, `Long`, `Short`, `Byte`,
  `Double`, `Float` with bodyless operators (bound by C3's primitive table),
  `Number`, `Comparable`, `CharSequence`, `String` (`length`, `get`, `plus`,
  `compareTo`, `equals`, `hashCode`), `Array<T>` and `IntArray` (`get`,
  `set`, `size`), `arrayOf`, `arrayOfNulls`.
- `Throwable(message)`, `Exception`, `RuntimeException`,
  `IllegalStateException`, `IllegalArgumentException`,
  `NullPointerException`, `ClassCastException`, `IndexOutOfBoundsException`,
  `UninitializedPropertyAccessException`.
- `Enum<E>(name, ordinal)`, `Function<R>`, `KClass<T>`, `KProperty0`,
  `KProperty1`, `KMutableProperty0`, `Lazy` and `lazy` with its `getValue`.
- `kotlin.collections`: `Iterator`, `Iterable`, `Collection`, `List`,
  `MutableList`, `ArrayList` written in Kotlin over an `Array`, `listOf`,
  `mutableListOf`; `kotlin.ranges`: `IntRange`, `IntProgression`,
  `IntIterator`, `until`, `downTo`, `step`.
- `kotlin.io.println(Any?)` and `print(Any?)` whose bodies call
  `message.toString()` and a bodyless `__writeLine(String)`/`__write(String)`,
  so no native ever converts an instance to text by name.
- Scope functions (`let`, `also`, `apply`, `run`, `with`, `takeIf`),
  `repeat`, `TODO`, `error`, `check`, `require`, `Pair`, `to`,
  `Any?.toString()`, `String?.plus`.

Natives (`natives.zig`): `__writeLine`, `__write`, `Any.toString`
(`Class@hex identity`), `Any.hashCode` and `Any.equals` (identity), array
access and allocation, `String` members; the numeric `toString`s reuse
`stdlib.implementations` entries (`"kotlin.Int.toString"`,
implementations.zig:327, found with `lookup`, implementations.zig:1772).
The resolver checks E's table first, then `stdlib.implementation`
(stdlib.zig:522).

Public API:

```zig
pub const Outcome = struct {
    output: []const u8, // joined lines, "\n"-terminated
    result: enum { ok, threw, failed },
    /// Census sites in the program, lowering errors, or the uncaught throwable.
    diag: []const u8,
};

/// Parses the executable base (one layer) and `sources` (the next layer),
/// resolves, bridges, lowers every body with an id and runs `main`.
pub fn run(a: Allocator, sources: []const []const u8) anyerror!Outcome;
/// `run`, then expects `result == .ok`, no census site, and `want` exactly.
pub fn expectOutput(sources: []const []const u8, want: []const u8) !void;
pub fn expectThrows(sources: []const []const u8, class_fqn: []const u8) !void;
```

`run` uses `interp_ir.Vm.new` (run.zig:45) and `vm.run` (run.zig:439) with
a `runtime.CaptureOutput` (output.zig:103), after installing
`Module.resolved` and letting the VM allocate a `ResolvedState` (A).

Tests: the base resolves with zero census sites; a program with no `main`
reports it; a lowering error reaches `diag` with its span.

Acceptance: `expectOutput(&.{"fun main() { println(\"hi\") }"}, "hi\n")`
passes once A, B, C1 and C2 have landed.

Size: 0.7k code (the base about 0.35k of Kotlin text), 0.2k tests.

As built: `lower_driver.analyze` stops before lowering (parse, both layers,
`output.build`, the bridge) and is what the bridge tests use; `run` adds
lowering and runs `main` through `Vm.runCalls` and `callNoArg`, so an
uncaught throwable is reported by its class's FQN. An error out of
`lowerProgram` itself propagates, which the packages' executing tests skip
on until the lowering is built. The numeric classes of the base are
generated: every arithmetic operator and `compareTo` against every numeric
type with Kotlin's result types, conversions, `inc`/`dec`, unary operators,
bitwise members on `Int` and `Long`, and `MIN_VALUE`/`MAX_VALUE`
companions. Operators are bodyless for the primitive table; `equals`,
`hashCode`, conversions and `toString` are natives. A test asserts every
bodyless function is bound or an operator.

### C. The translation layers

The new builder does not reuse today's `FuncBuilder` (build.zig:462-3276,
141 fields). About 100 of those fields exist for name derivation or the AST
splice, its scopes are name-keyed maps (`scopes`, build.zig:483; `resolve`,
2758), and its loop and finally helpers replay `finally` blocks through the
old `lowerExpr` (`replayFinallysForJump`, lower/expr/control.zig:92-125).
The reusable part is about 20 fields and 30 methods (blocks, registers,
`push`, `emitConst`, `terminate`, handler setters, `finish`); C1 copies that
behaviour into its own builder, which `cut/switch` keeps when it deletes
`FuncBuilder`.

| | Today's `FuncBuilder` | New `Builder` |
|--|------------------------|---------------|
| Locals | name → register on a scope stack, type metadata in flat name maps | `Sym` → home; no scopes (sema resolved scoping) |
| Cells | `boxed_vars` by name for the whole function (`ast_scan.computeBoxedVars`, ast_scan.zig:661) | the local `var`s (and `val`s assigned after their declaration) that a nested body reads or writes, found from the nested bodies' records |
| Captures | names recorded on first reference, resolved afterwards (build.zig:1310, 1326); nested bodies lower inside their parent | B's `captures_of` and `class_captures`, computed before lowering; the creating body materializes each key when it emits `MakeClosure`, calls a local function or constructs a local class; every body lowers on its own |
| Receivers | `this` register plus the enclosing chain and tower fields | `Env`: `{kind, owner}` → location |
| Calls | ladders that pick the callee | `CallRec` |
| Inline | AST splice state (25 fields) | `regions` (D) |
| Lambda context | about 25 `Module.pending_lambda_*` channels (ir.zig:277-338) | none: the record has it |

Shared shape of every C package: a function per construct taking the builder
and the node, returning the result register.

#### C1. Spine

Purpose: the builder, record lookup, the local and receiver environment, body
entry for every `FuncOrigin`, statements, the expression switch, names.

Files: `src/ir/lower/sema/builder.zig`, `records.zig`, `env.zig`,
`body.zig`, `name.zig`, `mod.zig`.

```zig
// builder.zig
pub const Program = struct {
    a: Allocator,
    s: *sema.Sema,
    br: *bridge.Bridge,
    m: *ir.Module,
    prims: *const operator.PrimTable,
    errors: std.ArrayList(LowerError),
    lowered: std.DynamicBitSetUnmanaged, // by FuncId: body written
};
pub const LowerError = struct { func: FuncId, span: span.Span, msg: []const u8 };

pub const BodyKind = enum { function, ctor, getter, setter, defaults, lambda, local_fun, init_unit, sam_ctor, sam_method, delegated, adapter };

pub const Home = union(enum) { reg: Reg, cell: Reg };

pub const Builder = struct {
    p: *Program,
    recs: *const sema.records.FileRecords,
    file: u32,
    owner: Sym, // function, constructor, property or lambda symbol
    func: FuncId,
    kind: BodyKind,
    blocks: std.ArrayList(BlockBuf),
    cur: BlockId,
    next_reg: u32,
    locals: std.AutoHashMapUnmanaged(Sym, Home),
    env: env.Env,
    /// This body's captures (`br.captures_of[func]`), read-only.
    captures: []const bridge.CaptureKey,
    loops: std.ArrayList(Loop),
    finallys: std.ArrayList(Finally),
    regions: std.ArrayList(inline_mod.Region), // D

    pub fn init(p: *Program, file: u32, owner: Sym, func: FuncId, kind: BodyKind) Error!Builder;
    pub fn newReg(b: *Builder) Reg;
    pub fn newBlock(b: *Builder) Error!BlockId;
    pub fn switchTo(b: *Builder, id: BlockId) void;
    pub fn emit(b: *Builder, inst: Inst) Error!void;
    pub fn emitConst(b: *Builder, c: ir.Const) Error!Reg;
    pub fn terminate(b: *Builder, t: Terminator) void;
    pub fn terminated(b: *const Builder) bool;
    /// Moves `regs` into a fresh contiguous run and returns its first register.
    pub fn run(b: *Builder, regs: []const Reg) Error!Reg;
    pub fn fail(b: *Builder, sp: span.Span, comptime fmt: []const u8, args: anytype) Error;
    /// Writes blocks, entry and n_locals into `p.m.funcs[func]`.
    pub fn finish(b: *Builder) Error!void;
    // records.zig re-exported: call, name, recv, typeTest, ref, group, decl,
    // returnTarget, exprType, callAt, nameAt, testAt
};

// env.zig
pub const Env = struct { ... };
pub fn receiver(b: *Builder, kind: ImplicitKind, owner: Sym) Error!Reg;
pub fn receiverOf(b: *Builder, r: Receiver, expr_reg: ?Reg) Error!?Reg;
pub fn bindLocal(b: *Builder, s: Sym, value: Reg) Error!void; // a cell when `br.isCell(s)`
pub fn readLocal(b: *Builder, s: Sym) Error!Reg;
pub fn writeLocal(b: *Builder, s: Sym, value: Reg) Error!void;
/// The registers holding `keys` in this body, in order: a home, a receiver,
/// or this body's own capture (a cell stays a cell).
pub fn materializeCaptures(b: *Builder, keys: []const bridge.CaptureKey) Error![]Reg;

// body.zig
pub fn lowerBody(p: *Program, f: FuncId) Error!void; // every non-nested FuncOrigin
pub fn lowerExpr(b: *Builder, e: *const ast.Expr) Error!Reg;
pub fn lowerStmt(b: *Builder, st: *const ast.Stmt) Error!void;
pub fn lowerBlock(b: *Builder, blk: *const ast.Block) Error!Reg;
pub fn lowerFunctionBody(b: *Builder, body: *const ast.FunctionBody) Error!void;

// name.zig
pub fn lowerName(b: *Builder, e: *const ast.Expr) Error!Reg; // Path, Member, $name
pub fn read(b: *Builder, rec: *const NameRec, recv: ?Reg) Error!Reg;
pub fn write(b: *Builder, rec: *const NameRec, recv: ?Reg, value: Reg) Error!void;
```

Env locations: the current class's `this` is `LoadParam 0`; an outer class's
`this` is `GetFieldSlot` along `outer_slot`s from it; an extension receiver,
a lambda receiver or a context parameter is its owner's parameter; any of
them from an enclosing body is this body's capture (`LoadCapture` in a
closure, `LoadParam` in a lifted local function, `GetFieldSlot` on `this`
from `capture_base` in a member of a local class); an object or companion is
`LoadObject` (also inside its own body, where it returns the instance being
built); `super_` is the enclosing class's `this`.

Names (`read`/`write`): a local reads its home (`CellGet` for a cell); a
parameter `LoadParam`; a property is `GetFieldSlot` when it has a backing
field and the site may read it directly (the property is final, or private
to the reading class, or it is `field`), else a getter call (`CallStatic`
for a final or top-level property, `RCallVirtual`/`CallInterface` through
`slot_of[getter]` otherwise); a top-level property with storage is
`LoadStatic`; an object `LoadObject`; an enum entry `LoadStatic`. Writes
mirror reads. A `lateinit` property's read adds `LateinitCheck`.

Statements: local `val`/`var` (bind), assignment through `name.write` or
C3's index `set`, destructuring through its group, local functions and
classes routed to C4.

Consumes: S, B's arrays, the records. `body.zig`'s switch calls C2, C3, C4,
D entry points declared in S.

Tests (`tests/spine.zig`): hello world; locals and reassignment; parameters;
a top-level property read before and after its initializer; member property
through field and through a getter; `field` in a custom accessor; a read and
a write of one property resolving differently (plain read, setter write); a
class that stores a property while a base declares a getter answers from its
slot; an extension receiver; `this@Outer` in an inner class; an implicit
receiver from a `with` block; `x.let { p -> }` whose subject is a parameter;
`with(other) { 5.scaled() }` taking the spliced subject; a captured `var`
mutated by a lambda.

Acceptance: those tests; every expression kind in 1.3 reaches a function
(no stub left in `body.zig`).

Size: 2.2k code, 0.5k tests.

#### C2. Calls and dispatch

Purpose: turn a `CallRec` and its operands into instructions.

Files: `src/ir/lower/sema/call.zig`, `dispatch.zig`.

```zig
// call.zig
pub const Operands = struct {
    /// Source operand expressions per 1.4, in order; null for an operand the
    /// caller already lowered into `regs`.
    exprs: []const ?*const ast.Expr,
    regs: []const ?Reg,
    receiver: ?Reg, // the `.expr` receiver, already lowered
};
pub fn lowerCall(b: *Builder, e: *const ast.Expr) Error!Reg; // Expr.Call
pub fn emitCall(b: *Builder, rec: *const CallRec, ops: Operands) Error!Reg; // every desugared call
pub fn lowerDefaultsBridge(b: *Builder, target: Sym) Error!void; // body of a defaults bridge
pub fn lowerDelegation(b: *Builder, rec: *const CallRec, ops: Operands) Error!void; // same instance

// dispatch.zig
pub const How = union(enum) {
    static: FuncId,
    virtual: MethodSlotId,
    interface: struct { iface: ClassId, slot: MethodSlotId },
    native: NativeId,
    prim: operator.PrimOp, // C3's table
    array_get,
    array_set,
    inline_: FuncId, // D instantiates
    value, // RCallValue
    ctor: struct { class: ClassId, ctor: FuncId },
};
pub fn choose(p: *Program, rec: *const CallRec) How;
pub fn emitHow(b: *Builder, how: How, dst: Reg, run: Reg, n: u32) Error!void;
```

Order of work at a call: evaluate the receiver and the operands in source
order into registers; build the argument run in the callee's declared order
(2.2): receiver or `this`, contexts (`env.receiverOf` per `contexts`),
extension receiver, value parameters per `args` (`default` slots get
`Unit` and a mask bit; `vararg` builds a `NewArray`, with spreads copied by a
native helper), reified type values per `type_args` whose parameter is
reified (C3's `typeValue`); apply `conv` (`sam`: C4's `samWrap`); then
`choose`:

| Callee | How |
|--------|-----|
| bound by the primitive table (C3) | `prim`, `array_get`/`array_set` |
| an omitted defaulted argument | `static` to `defaults_of`, with the masks |
| `inline_` flag, not called as a value | `inline_` (D) |
| `native_of != .none` and not overridable | `native` |
| top-level, local (lifted), private, final member, `super_` form, a member of a final class, a constructor delegation | `static` |
| member of an interface | `interface` |
| other member | `virtual` |
| `FunctionN.invoke` on a value | `value` |
| constructor form | `ctor` |

`super_` calls the named declaration statically on the enclosing `this`;
`this_delegation`/`super_delegation` call the constructor statically on the
instance being built.

Consumes: C1, B, C3's `PrimTable` and `typeValue`, C4's `samWrap`, D's
`instantiate`.

Tests (`tests/calls.zig`): arguments evaluated in source order with named
arguments permuted; defaults using earlier parameters and `this`; a default
declared on an overridden member used by an override; varargs with spreads;
a trailing lambda; a context parameter passed by the caller; a member
extension with both receivers; `super.f()` non-virtual, `super<A>.f()`, and
`super@Outer.f()`; a class supertype preferred over an interface default; a
non-`operator` member not serving a convention; `Shape(3)` reaching
`Companion.invoke` when no one-argument constructor exists; a `suspend
R.() -> T` invoked with the receiver first; a host-bound native call.

Acceptance: those tests; no call is emitted without a `How` from `choose`.

Size: 1.5k code, 0.5k tests.

#### C3. Control flow, operators, type tests

Purpose: every construct whose meaning is fixed control flow or a primitive
operation, and the type tests.

Files: `src/ir/lower/sema/control.zig`, `operator.zig`, `types.zig`.

```zig
// control.zig
pub fn lowerIf(b: *Builder, e: *const ast.Expr) Error!Reg;
pub fn lowerWhen(b: *Builder, e: *const ast.Expr) Error!Reg;
pub fn lowerWhile(b: *Builder, e: *const ast.Expr) Error!Reg;
pub fn lowerDoWhile(b: *Builder, e: *const ast.Expr) Error!Reg;
pub fn lowerFor(b: *Builder, e: *const ast.Expr) Error!Reg;
pub fn lowerTry(b: *Builder, e: *const ast.Expr) Error!Reg;
pub fn lowerThrow(b: *Builder, e: *const ast.Expr) Error!Reg;
pub fn lowerReturn(b: *Builder, e: *const ast.Expr) Error!Reg; // asks D's regions first
pub fn lowerBreak(b: *Builder, e: *const ast.Expr) Error!Reg;
pub fn lowerContinue(b: *Builder, e: *const ast.Expr) Error!Reg;
pub fn lowerTemplate(b: *Builder, e: *const ast.Expr) Error!Reg;
pub fn lowerLiteral(b: *Builder, e: *const ast.Expr) Error!Reg; // kind from exprType
pub fn lowerNotNull(b: *Builder, e: *const ast.Expr) Error!Reg;
pub fn lowerSafe(b: *Builder, recv: Reg, then: anytype) Error!Reg; // `?.`

// operator.zig
pub const PrimOp = union(enum) { bin: ir.BinOp, un: ir.UnOp, not, identity, native: NativeId };
pub const PrimTable = struct {
    map: std.AutoHashMapUnmanaged(Sym, PrimOp),
    pub fn init(a: Allocator, s: *sema.Sema) Allocator.Error!PrimTable; // by FQN and signature, once
    pub fn get(self: *const PrimTable, callee: Sym) ?PrimOp;
};
pub fn lowerBinary(b: *Builder, e: *const ast.Expr) Error!Reg; // arithmetic, compare, ==, in, ranges, &&, ||, ?:, ===
pub fn lowerUnary(b: *Builder, e: *const ast.Expr) Error!Reg;
pub fn lowerIndex(b: *Builder, e: *const ast.Expr) Error!Reg;
pub fn lowerIndexSet(b: *Builder, target: *const ast.Expr, value: *const ast.Expr, node: NodeId) Error!void;
pub fn lowerCompound(b: *Builder, a: *const ast.AssignStmt) Error!void;
pub fn lowerIncDec(b: *Builder, e: *const ast.Expr) Error!Reg;
/// A body for each function the table binds, so a virtual or interface call
/// reaches the operation (`Comparable<Int>.compareTo` on an `Int`).
pub fn lowerPrimBody(b: *Builder, callee: Sym) Error!void;

// types.zig
pub fn lowerIsCheck(b: *Builder, e: *const ast.Expr) Error!Reg;
pub fn lowerAs(b: *Builder, e: *const ast.Expr) Error!Reg;
pub fn testAgainst(b: *Builder, rec: *const TypeTestRec, v: Reg) Error!Reg; // `when` patterns
pub fn catchClass(b: *Builder, c: *const ast.Catch) Error!ClassId;
/// The run-time type value of `t`: a static class, or the reified parameter's register.
pub fn typeValue(b: *Builder, t: TypeId) Error!Reg;
```

`==`: both static types the same primitive → `BinOp.Eq` (IEEE on
`Double`/`Float`); either side the `null` literal → an identity test;
otherwise `a?.equals(b) ?: (b === null)` with the recorded `equals` through
its slot. `&&`, `||`, `?:`, `?.` and `!!` are branches. Templates convert
each part through its recorded `toString` call and join with
`BinOp.StringConcat` on strings and primitives only. `try` follows today's
handler protocol (lower/expr/control.zig:214-296: catches, finally sentinel,
catch join, pop-on-exit lists), with `CatchHandler.class_raw` set; a
`finally` is replayed on every exit by lowering its block again through C1.
`break`/`continue` find their loop on the builder's loop stack by label or
innermost, replaying the `finally` blocks they cross.

Consumes: C1, C2's `emitCall`, B.

Tests (`tests/control.zig`): `when` with subject, binding, `in`, `is`,
`null ->` narrowing later branches, and `else`; loops with labels, `break`
and `continue` through `finally`; a labeled `do-while` whose `continue`
checks the condition (today's lowering jumps to the body,
lower/expr/control.zig:486); `try`/`catch` by class, rethrow, `finally` on
return; `is T?` admitting null; `is List<String>` erased; `as` failing with
`ClassCastException`; a missing ancestor edge making `is` false; primitive
arithmetic in every numeric type; `==` on `Double` NaN against boxed
`equals`; `+=` choosing `plusAssign` or `plus`; `a[i]++`; `x in range`;
templates of an instance, a nullable and a primitive.

Acceptance: those tests; no `BinOp` is emitted except from the table or
the rules above.

Size: 1.8k code, 0.6k tests.

#### C4. Classes, statics, lambdas, references, the program driver

Purpose: every body that belongs to a class or makes a value of a function
type, and the loop that lowers the program.

Files: `src/ir/lower/sema/classes.zig`, `lambda.zig`, `refs.zig`,
`lower.zig`.

```zig
// lower.zig
pub fn lowerProgram(a: Allocator, s: *sema.Sema, br: *bridge.Bridge) Error!Program;
// classes.zig
pub fn lowerCtor(b: *Builder, ctor: Sym) Error!void;
pub fn lowerInitUnit(b: *Builder, unit: u32) Error!void;
pub fn lowerSynthetic(b: *Builder, f: Sym) Error!void; // data, enum, value-class members; SAM ctor and method; `by` members
pub fn lowerObjectExpr(b: *Builder, e: *const ast.Expr) Error!Reg;
pub fn lowerLocalClass(b: *Builder, d: *const ast.Decl) Error!void;
pub fn lowerAccessor(b: *Builder, prop: Sym, setter: bool) Error!void; // default and custom
// lambda.zig
pub fn lowerLambda(b: *Builder, e: *const ast.Expr) Error!Reg; // MakeClosure at the literal
pub fn lowerAnonFun(b: *Builder, e: *const ast.Expr) Error!Reg;
pub fn lowerClosureBody(b: *Builder, f: Sym) Error!void; // lambda, anonymous or local function body
/// Lowers a lambda literal's body into `b` at the current block (D).
pub fn lowerInPlace(b: *Builder, lambda: *const ast.Expr, args: []const Reg) Error!Reg;
pub fn samWrap(b: *Builder, value: Reg, iface: Sym) Error!Reg;
// refs.zig
pub fn lowerCallableRef(b: *Builder, e: *const ast.Expr) Error!Reg;
pub fn lowerAdapter(b: *Builder, adapter: u32) Error!void;
```

`lowerProgram` visits `FuncId`s in order and lowers every origin except
`abstract`, each body on its own builder; an inline function is lowered
before its first instantiation (`Program.lowered`). A local function or
local class declaration statement emits nothing: the function is lowered
from the program and its calls pass its captures, the class's members are
lowered like any member and its construction passes its captures.

Constructors: `this` from `LoadParam 0`; the outer instance, enum `name` and
`ordinal`, and a local class's captures stored into their slots; the
supertype initializer or delegation (`CallStatic` on `this`); then, for a
primary constructor, property initializers and `init` blocks in source
order; then a secondary constructor's body; `Return this`. Slots hold their
seeds until written. Enum entries are made by the enum class's init unit in
order: `RNewInstance` of the entry's body class or the enum class with the
entry's `CallRec`, stored with `StoreStatic`. `values()`, `valueOf()` and
`entries` read those statics. Data classes get `componentN`, `copy` (its
defaults read `this`'s properties), `equals`, `hashCode` and `toString` as
IR. A `by` supertype stores its delegate in a slot, and each member sema
synthesized for it (`forwards` set) gets a body that calls the interface
member on that slot's value through its interface slot. A fun interface's
SAM class holds the function value in slot 0 and its method calls it with
`RCallValue`.

Lambdas: `MakeClosure` over the lambda's `FuncId` with the registers
`materializeCaptures` gives for `captures_of[func]`. A receiver lambda takes
its receiver as parameter 0 (2.2). A local function is lifted: its captured
values become its leading parameters and every call passes them (decision
5).

References: `FunctionRef` with the adapter from `adapterFor`; property
references `RPropertyRef` from `getter_of`/`setter_of`; `::Cls` a
constructor reference; `C::class` and `x::class` go through C3's type records
and `ClassLiteral`/`ClassOf`.

Consumes: C1, C2, C3, B.

Tests (`tests/classes.zig`): construction order with an open base's body
property read by an override during the base constructor; a secondary
constructor delegating to the primary; an inner class's constructor binding
the outer instance and a nested class having none; an object and a
companion initialized once on first use; `Color.Unspecified` read from the
companion's slot; enums with bodies, `values()`, `valueOf`, `ordinal`;
data class equality, `copy` with one argument, destructuring; `by`
delegation forwarding; a local class reading a captured `val` and `var`;
an object expression implementing an interface and capturing `this`; a
lambda with a captured `var`; a receiver lambda; a lambda used as an untyped
initializer having no receiver; a fun interface lambda whose `this` is the
interface; a member-extension SAM receiving its extension receiver; a local
recursive function; references to a function, a bound member, a property,
a constructor, and `::Char` used as `Int.() -> Char`; two references to one
function comparing equal.

Acceptance: those tests; every `FuncOrigin` kind has a lowering.

Size: 2.2k code, 0.7k tests.

### D. Inline instantiation

Purpose: at each call of an inline function, copy the function's own IR
into the caller, with lambda-literal arguments lowered in place. This
replaces the AST splice (`lower/inline_call.zig`, 4.8k lines, and
`inline_state.zig`) at the switch.

Files: `src/ir/lower/sema/inline.zig`.

```zig
pub const Region = union(enum) {
    /// One instantiation: where its returns go.
    instance: struct { callee: FuncId, result: Reg, join: BlockId },
    /// A lambda literal lowered in place: where `return@label` goes.
    lambda: struct { func: Sym, result: Reg, end: BlockId },
};
pub fn instantiate(b: *Builder, rec: *const CallRec, callee: FuncId, run: []const Reg, lambdas: []const ?*const ast.Expr) Error!Reg;
/// For `lowerReturn`: the region a `return` to `target` leaves, if any.
pub fn returnRegion(b: *Builder, target: Sym) ?*Region;
```

Contract with C1 and C2 for the callee's ordinary body: a call of an inline
functional parameter `p` (not `noinline`) is an `RCallValue` whose `callee`
is the register of the single `LoadParam` of `p`, which is never
reassigned; a reified type parameter's value is the register of its
`LoadParam`, read by `InstanceOfDyn`, `CastDyn`, `ClassLiteral`-style uses
and passed on to nested reified calls.

Instantiation: `p.lowered` must hold for the callee (lower it first); copy
every block into new blocks of `b`, offsetting registers by `b.next_reg` and
remapping block ids everywhere they appear (terminators, `BlockHandlers`
catches, finally, `finally_done`, `finally_done_for`, `catch_done_for`,
`pop_on_exit`); replace each `LoadParam i` with a `Move` from `run[i]`;
replace each `Return v` with `Move result, v; Goto join`; replace each
`RCallValue` on an inline lambda parameter bound to a literal with
`lambda.lowerInPlace` inside a `lambda` region (its `return` leaves the
caller's function, its `return@label` goes to the region end, its `break`
and `continue` reach the caller's loops because the copied IR adds none to
the loop stack, its suspend calls suspend the caller's frame); replace each
dynamic test on a reified value bound to a concrete class with
`RInstanceOf`/`RCast`, and pass reified values on otherwise. A `noinline`
parameter, a `crossinline` parameter used inside a nested closure, and an
argument that is not a literal are passed as values, so the copied
`RCallValue` stays. There are no suspend states to renumber (section 6).

Inline properties (`Int.dp`) are instantiated from their getter the same
way.

Consumes: C1, C2 (the call site), C4 (`lowerInPlace`), C3 (returns, loops).
The IR copier needs only A's variants and can be built and tested first on
hand-built `Func`s.

Tests (`tests/inline.zig`): `return` from a lambda passed to `forEach`
leaving the caller; `return@forEach`; `break` and `continue` inside an inline
lambda in a caller's loop; nested inline calls; an inline function with
`try`/`finally` around the lambda call, with a non-local return through it;
`reified T` used in `is T`, `as T` and `T::class`, passed on to a nested
reified call; a `crossinline` lambda called from a nested closure; a
`noinline` parameter stored in a list; an inline function referenced with
`::f` running its ordinary body; an inline extension property; a
`suspend inline` function called from `suspend fun main`.

Acceptance: those tests, whose expected outputs are what kotlinc 2.4.20
prints for the same programs, checked when each test is written.

Size: 1.5k code, 0.5k tests.

As built (`src/ir/lower/sema/inline.zig`):

- **Which calls go in place.** A parameter's registers are its `LoadParam`
  and every single-assignment `Move` copy of it, so a literal passed through
  another inline call or a defaults bridge is still found. When every read
  of them is an `RCallValue`'s callee, each call becomes the literal lowered
  in place; any other read (stored, captured by a closure, passed on to a
  non-inline call) makes the literal a closure passed as the value.
- **`try` frames.** The copy knows which of the callee's frames are armed
  in each block by simulating the VM's arming and popping (entry blocks
  with handlers, finally entries, catch-only joins, sentinels,
  `pop_on_exit`). A `return` of the callee pops the armed frames innermost
  first, replaying each one's finally from the callee's IR (the blocks
  from its entry to its sentinel, copied again), then jumps to the join. A
  literal lowered in place sees those frames on `Builder.finallys` with a
  `FinallyReplay`, so `control.jumpOut` pops and replays them for a
  `break`, `continue` or `return@label` that leaves them; a plain `return`
  is the caller's own `Return`, which the VM routes through them.
- **Literal bodies.** A literal's closure body is lowered only when a
  closure is made of it (`body.lowerClosure`, from `lambda.closureOf`); one
  only lowered in place has no body, since its `break` or non-local
  `return` means nothing outside the caller. A callee is lowered on demand
  when an instantiation reaches it first (`Program.attempted` makes each
  body lower once).
- **Reified values.** A dynamic test or cast on a reified value the caller
  made with `ClassLiteral` becomes `RInstanceOf`/`RCast` on that class.
- **Inline accessors** (`val Int.dp inline get()`) are instantiated from
  their getter or setter by `name.zig`.

## 4. Order and parallelism

### 4.1 Dependencies

```
R0 (in S) ──> R (sema/output writers) ─────────────────────────┐
S ──> A ──────────────────────────────────────────────────────┤
S ──> B ──> E ────────────────────────────────────────────────┤──> executing tests
S ──> C1 ──> C2 ──> C3 ──┐                                     │
              └────> C4 ─┴──> D ───────────────────────────────┘
```

- Immediately after S, without records: A entirely (hand-built modules); B
  for every non-local symbol (sema symbols exist today); E's base and
  natives (the base must resolve with zero census sites through today's
  sema); C1's builder core and env against hand-made states; C2's argument
  ordering as pure functions tested with hand-built `CallRec`s; C3's
  `PrimTable` over the executable base's symbols; D's IR copier on
  hand-built `Func`s.
- The first executing test (`println("hi")`) needs A, B, E, C1, C2 and the
  first slice of R: `calls` with `args`, `names`, `decls`, `Return` targets
  and `ty`.
- R should land in three slices so tests come online in order: (1) the
  tables, write rules, `ty`, calls (plain, ctor, super, value_invoke) with
  `args`, `contexts` and `type_args`, names, decls, `Return` targets; (2)
  recvs, tests, and the groups (`for_`, `when`, `destructure`, `compound`,
  `inc_dec`, `lambda`, `template`, `delegate`, `supers`, `path`); (3) refs,
  `conv`, adaptation, lambda labels.

### 4.2 Assignment

Seven roles. Each file has one owner; nobody edits another package's file.
An interface change is a request to the owner, landed by the owner.

| Engineer | Packages | Files owned |
|----------|----------|-------------|
| 1 | A | `src/ir/core/inst.zig`, `ids.zig`, `resolved.zig`, `func.zig`, `src/ir/eval/*`, `src/ir/exec_call.zig`, `src/ir/site_census.zig`, `src/ir/disasm.zig`, `src/interp_ir/vm/*`, `src/interp_ir/image.zig`, `src/runtime/class.zig`, `tests/vm.zig` |
| 2 | B, E | `src/ir/core/bridge.zig`, `src/lower_driver/lower_driver.zig`, `mini_base.zig`, `natives.zig`, `tests/bridge.zig` |
| 3 | S, C1 | `build.zig` (S only), `src/ir/ir.zig` (S only), `src/ir/lower/sema/{mod,builder,records,env,body,name}.zig`, `tests/spine.zig` |
| 4 | C2 | `call.zig`, `dispatch.zig`, `tests/calls.zig` |
| 5 | C3 | `control.zig`, `operator.zig`, `types.zig`, `tests/control.zig` |
| 6 | C4 | `classes.zig`, `lambda.zig`, `refs.zig`, `lower.zig`, `tests/classes.zig` |
| 7 | D | `inline.zig`, `tests/inline.zig` |
| lead | R | `src/sema/*` |

With five engineers: engineer 4 takes C3 after C2, and engineer 7 takes D
after helping with C4.

### 4.3 Files several packages need

| File | Who needs it | How it is split |
|------|--------------|-----------------|
| `src/sema/records.zig` | R writes, everyone reads | types in S; only the lead edits after |
| `src/ir/core/inst.zig` | A implements, B/C/D emit | declared in S; A owns |
| `src/ir/ir.zig` | A (`Module.resolved`), S (exports) | all edits in S |
| `build.zig` | S | all edits in S |
| `src/ir/lower/sema/body.zig` | C1; routes to C2, C3, C4, D | the switch is fixed in S; its targets are the other packages' declared functions |
| `Builder` struct | C1; D pushes and reads `regions`, C4 reads `captures` | every field declared in S |
| `src/lower_driver/lower_driver.zig` root | E; imports every package's tests | the imports are written in S |
| `src/sema/calls.zig`, `body.zig`, `decls.zig` | the lead is changing them daily (`sema/tail`, `sema/facts`) | lowering engineers never edit them; a missing record is a request to the lead |

## 5. Decisions for the lead

1. **Names of the reshaped variants.** `CallVirtual`, `CallValue`,
   `NewInstance`, `PropertyRef`, `InstanceOf` and `Cast` keep their names in
   the design but change shape, and step 4 needs both beside each other.
   Recommendation: the new ones are `RCallVirtual`, `RCallValue`,
   `RNewInstance`, `RPropertyRef`, `RInstanceOf`, `RCast` until `cut/switch`,
   which deletes the old ones and renames these mechanically.
2. **Where the new lowering lives.** Recommendation:
   `src/ir/lower/sema/`, inside the `ir` module, which gains `sema` as a
   dependency (no cycle: `sema` depends on `span`, `ast`, `lexer`, `parser`).
   The old lowering has files with the same base names (`expr/call.zig`,
   `expr/refs.zig`, `expr/lambda.zig`), and a directory makes the switch's
   deletion a path.
3. **Where the executing tests live.** Recommendation: a new module
   `lower_driver` depending on `sema`, `ir`, `interp_ir`, `stdlib`,
   `runtime`, `parser`, `lexer`, `ast`, `span`, tested under
   `zig build test`. It links the VM, so its test binary costs about as much
   to build as `interp_ir`'s; if that hurts, it gets its own step.
4. **The executable base.** Recommendation: E writes its own, leaving
   sema's `mini_kotlin` and its tests alone.
5. **Local functions.** Recommendation: lift them (captured values as
   leading parameters, `CallStatic` at every call), rather than making each
   a closure value. References to a local function make a closure over an
   adapter that binds the captures.
6. **Suspension.** Recommendation: no continuation parameter and no state
   numbering; `Func.is_suspend` and the VM's frame snapshots, as today.
   `SuspendResumePoint` stays unused.
7. **Accessor identity.** Recommendation: B keys getter and setter `FuncId`s
   by the property symbol instead of sema adding accessor symbols; slots for
   accessors come from the property's override roots.
8. **Local symbols.** Recommendation: B takes local symbols from committed
   records instead of a new flag on `Symbol` (two spare flag bits remain,
   symbols.zig:87).
9. **Constructors return `this`.** Recommendation: yes, so `RNewInstance` is
   one flat call writing its `dst`.
10. **Statics and singletons.** Recommendation: init units and object
    constructors run through a recursive host call; a touch during
    initialization reads the seed or the partly built instance, as on the
    JVM.
11. **Native binding before `sema/facts`.** Recommendation: B binds each
    bodyless, non-abstract function once, by FQN, through the resolver the
    driver passes (E's table, then `stdlib.implementation`); `sema/facts`'
    `NativeId` table replaces the resolver. A declaration with a body is
    never bound in step 4, so "a host intrinsic supersedes the source
    getter" (`COROUTINE_SUSPENDED`) waits for `sema/facts`.
12. **Fused tier.** Recommendation: an explicit reject for every new variant
    rather than the partial-then-materialize default.
13. **Who writes S.** Recommendation: the lead, from sections 1 and 2, since
    it edits `src/sema/records.zig`; otherwise engineer 3 with the lead's
    review.
14. **`FORMAT_VERSION`.** Recommendation: append the variants at the end of
    `Inst` and bump once in S (85 to 86, image.zig:53), so no existing tag
    renumbers and an image baked before S is refused.
15. **Tests that need real suspension.** A test that actually suspends
    needs a suspending native in the executable base. Recommendation: E
    binds one small yield native from the coroutine tables if one fits,
    otherwise suspension tests move to the sweep after `cut/switch`.
16. **The plan's size bound.** Recommendation: raise `lower/sema` from +8.5k
    to about +13.0k code and +4.1k tests (section 6, item 2).
17. **Captures.** Recommendation: B computes every nested body's captures
    and every cell from the records before any body lowers, so each body
    lowers on its own builder, in any order, and a recursive local function
    knows its captures before its body lowers. The alternative, today's
    recording on first reference while the enclosing body lowers
    (build.zig:1310, 1326), makes nested bodies lower inside their parent and
    ties lowering order to nesting.

## 6. Where the design differs from the code

1. **Suspension.** Design section 4 has `SuspendResumePoint` per suspend
   call, a continuation among the hidden arguments, and "suspend state
   renumbering" in instantiation. Nothing emits `SuspendResumePoint`
   (its only uses are the no-op arm at eval/inst.zig:125-127, the fused
   reject at fused.zig:356 and census and JIT classifiers), the "entry
   dispatch table" its comment names (inst.zig:399) does not exist, and no
   lowered function takes a continuation (`buildLoweredParams`,
   lower/decl.zig:3200-3230). The VM suspends by returning
   `EvalError.Suspended`, parking the caller at the next instruction with the
   call's `dst` as resume register (eval/exec.zig:1104-1111), snapshotting
   frames (eval/snapshot.zig:88-115) and rebuilding them on resume
   (activation.zig:128). Inline instantiation therefore has nothing to
   renumber, and suspend calls are ordinary calls.
2. **What survives in step 4.** Section 5 keeps `when_expr.zig`,
   `expr/block.zig`, `literals.zig`, `control.zig`, `for_loop.zig`,
   `stmt.zig` and `decl.zig`'s translating parts. They are bound to
   `FuncBuilder` and call derivation helpers (a `when` `is` pattern calls
   `loweredCheckTypeName`, `lower/expr/paths.zig:350`; `$x` runs the name
   ladder, paths.zig:1624-1709; `for` probes static types,
   `for_loop.zig:236-800`; `stmt.zig:435` reads `eagerTypeOf`). Beside the
   old lowering they cannot be shared, so C1 and C3 write about 2.5k lines
   the 8.5k does not count. The table also omits `expr/lambda.zig` (2.3k
   lines of shape probes and trailing-lambda pickers), which belongs with
   the deleted files.
3. **Surviving variants.** "19 of today's survive" counts `CallVirtual`,
   `CallValue`, `NewInstance`, `InstanceOf` and `Cast`, all of which change
   shape (memo words, `arg_names`, `TypeRef`, a constructor operand), so
   they cannot coexist with their old forms under one name (decision 1).
4. **Records sema does not produce.** Section 1 says sema must add the
   argument map, type arguments, conversions, context arguments and
   `backing_field`. Context arguments exist for calls since the design was
   written (`Applied.contexts`, calls.zig:120; `Ref.contexts`,
   records.zig:95), but not for operator conventions or property reads.
   Missing from its list: `this` records, type tests, catch parameters,
   lambda symbols and parameters, templates, `return` targets, lambda
   labels, destructured lambda parameters and reference adaptation (1.8).
5. **`via`.** Not needed: the callee node of an `invoke` holds the value's
   read (1.2).
6. **Override links.** Present since commit 2f6fee14
   (`members.overridden`, cached in `FunctionInfo.overrides` and
   `PropertyInfo.overrides`). A member can override several roots
   (a diamond through interfaces); the design's "a slot is the root
   declaration's `FuncId`" needs one dispatch entry per root.
7. **Accessors.** "A `FuncId` per ... accessor" assumes accessor symbols;
   sema makes none (1.8 item 8).
8. **The driver's base.** "Over `mini_kotlin`" cannot execute: its bodies
   are placeholders and it has no `println` (E).
9. **`b.test(id)`** is not valid Zig; the lookup is `typeTest`.
10. **What the VM needs to construct.** Section 4 says `NewInstance`
    allocates and calls the constructor. Today's construction needs a
    `ClassDef` found by name and name-keyed `ProgramImage` tables
    (`parent_ctor_args`, `init_blocks`, `body_prop_inits`,
    host_instances/ctor_select.zig:353-942), and `CallVirtual` maps an
    instance to its `ClassId` by FQN (`classIdByFqn`,
    host_call_member/virtual_tail.zig:431-447). The new arms need
    `ClassDef.ir_class` and `Module.resolved` (2.4), which the design does
    not mention.

Found along the way, outside this work: a labeled `do-while` pushes its body
block as the `continue` target where the unlabeled form uses the condition
(lower/expr/control.zig:486 against lower/expr.zig:618-623), so
`continue@l` skips the condition; C3's tests cover the new lowering's
behaviour there.

## 7. Decisions taken

All seventeen recommendations in section 5 are accepted as written, with one
change to section 1's storage:

- Sema keeps its records as one list per analysis, each record stamped with
  the node that made it, indexed per file by `sema.output.build` (commit
  74cb8d2e): a node's records in the order they were made, and every
  expression's type, solved. A record carries a typed detail where its kind
  needs more than a target and receivers: the `CallRec` fields for a call
  (argument map, contexts, type arguments, conversions, form), a
  `TypeTestRec`, a `LambdaRec`, a `RefRec`. New record kinds cover `this`,
  type tests, lambdas and `return` targets.
- The typed lookups of 1.7 are functions of `src/sema/output.zig` over a
  file's index (`output.call(fr, id)`, `output.name`, `output.recv`,
  `output.typeTest`, `output.ref`, `output.group`, `output.decl`,
  `output.returnTarget`, `output.exprType`), returning the record types of
  1.2 (declared in `src/sema/records.zig`). Groups (`for_`, `compound`,
  `when`, `destructure`, `path`, `template`, `delegate`, `supers`) are built
  from the node's records by kind and anchor. C1's `records.zig` wraps these
  as `Builder` methods; the pool indices of 1.2 (`RecIdx`) become the record
  values themselves, so `callAt`/`nameAt`/`testAt` are not needed.
- `lower/sema`'s bound in the plan is raised to about +13k code and +4k
  tests.

# Stdlib commonTest remaining-failure fix plan (from triage workflow wf_0d596714)

Ranked by impact x tractability. Implement + full-sweep-verify one at a time.

## 1. null-tostring-member [high] — 1 fails, 1 files
**Files:** src/interp_ir/vm/host_call_member.zig

**Root:** An explicit member call null.toString() on a nullable receiver returns kotlin.Unit instead of 'null'. callMemberRec has Null-receiver handling only for equals (host_call_member.zig:2459); there is no Null toString branch, so it falls to the bodyless Any?.toString() JVM-intrinsic actual which evaluates to Unit. The println/template path is unaffected (uses stringify). Hits ReversedViewsTest.testNullToString.

**Fix:** In callMemberRec, after the Null equals branch (~2459), add: if receiver is .Null and name=='toString' and args.len==0 return strVal('null'). ~1-2 lines, no regression risk.

## 2. unsigned-mixed-width-eq [high] — 1 fails, 1 files
**Files:** src/ir/eval.zig

**Root:** applyBinop's .Eq/.NotEq path calls structuralEq which requires identical numeric tags, but there is no UInt->ULong widening on the equality path (unlike the UByte/UShort->UInt promotion at eval.zig:4053 and the relational compareValues unsigned reconciliation). So UInt(0) == ULong(0) returns false even though magnitudes match. Specific to .Eq/.NotEq for mixed unsigned widths. Hits UNumbersTest.ulongBits.

**Fix:** In applyBinop, before the equality arms (~eval.zig:4213), when op is Eq/NotEq/BoxedEq/BoxedNotEq and both asUnsigned(l) and asUnsigned(r) are non-null but tags differ, compare by magnitude: eq = asUnsigned(l).? == asUnsigned(r).?; return Bool (negated for NotEq). ~6-8 lines, self-contained.

## 3. probe-swallows-throw [high] — 2 fails, 2 files
**Files:** src/ir/eval.zig, src/interp_ir/vm/host_fields.zig

**Root:** The LoadFromThisOrGlobal candidate-probe loop (eval.zig:3044-3058) treats EVERY .err from getMemberField as a member-not-found miss and continues, swallowing genuine thrown exceptions (NoSuchElementException from a delegated property's getValue) and falling through to 'unresolved global d'. EvalError already distinguishes the dispatch-miss sentinel (.Unimplemented) from real throws (.Throw/.CalleeFailed/.StackOverflow). Hits MapAccessorsTest.

**Fix:** In the probe loop, only swallow .Unimplemented (freeMissErr) and re-raise everything else via raiseStep(frame, e). Replace `.err => |e| freeMissErr(allocator, e)` with a check on e==.Unimplemented. Review the same pattern at the class-delegation forwarding loop in host_fields.zig:889. Verified to pass MapAccessorsTest 2/2.

## 4. map-entry-and-pair-triple-members [high] — 5 fails, 2 files
**Files:** src/runtime/value.zig, src/interp_ir/vm/host_call_member.zig

**Root:** Native composite Value shapes (MapEntry, Pair, Triple) lack proper equals/hashCode bridging. structuralEqBoxed matches MapEntry only vs MapEntry, never vs a user Map.Entry Instance, so entries.contains(mapEntryOf) is false. Pair/Triple are native values, so dataClassAutoMembers never runs; componentMembers (host_call_member.zig:4029) has no equals/hashCode/toString, so p.equals(null) returns Unit ('Not on non-bool') and every Pair/Triple hashes to the same constant. Hits MapTest and TuplesTest.

**Fix:** (1) value.zig structuralEqBoxed: bridge MapEntry vs a Map.Entry Instance by comparing key and value fields. (2) host_call_member.zig componentMembers .Pair/.Triple arms: add equals (reuse Value.structuralEq) and toString; (3) kotlinHashCode (host_call_member.zig:464): add .Pair/.Triple cases using Kotlin's first*31+second (and *31+third) formula with element hashCodes (Null=>0). Small localized edits.

## 5. string-compareto-ignorecase [high] — 3 fails, 1 files
**Files:** src/stdlib/implementations/string.zig

**Root:** The intrinsic string_compare_to (src/stdlib/implementations/string.zig:1082-1100) reads only args[0]/args[1] and unconditionally does case-sensitive text.compareUtf16, ignoring the optional ignoreCase Boolean at args[2]. String.CASE_INSENSITIVE_ORDER is Comparator { a, b -> a.compareTo(b, ignoreCase = true) }, so case-insensitive ordering is silently case-sensitive. 'a'(97) vs 'B'(66) returns +1, flipping min/max. Hits MinMaxArrayTest.minMaxWith, MinMaxSequenceTest.minMaxWith, and the secondary minMaxWith in MinMaxIterableTest.

**Fix:** In string_compare_to, detect ignore_case = ctx.args.len > 2 and ctx.args[2] == .Bool and ctx.args[2].Bool. When true, compare unit-by-unit using the existing fold helpers (charUnitToScalar, scalarToUpper/scalarToLower) per Kotlin's compareToIgnoreCase rule (fold via upper-then-lower, length as tiebreak); otherwise keep text.compareUtf16. Add a Zig unit test ('a'/'B' lt, 'ABX'/'ABc' gt, '['/'AA' lt). ~20 lines, one function.

## 6. float-minmax-promotion [high] — 8 fails, 2 files
**Files:** src/stdlib/implementations/math.zig, src/stdlib/implementations/collections.zig

**Root:** num_extreme in src/stdlib/implementations/math.zig (the floating branch ~lines 108-121) unconditionally returns .Double for any min/max result, even when both operands are Float. This is the shared backend for minOf/maxOf (kotlin.comparisons -> cmp_extreme -> num_extreme) and kotlin.math.min/max. Kotlin's Float,Float->Float overload must keep Float, so assertEquals(1.0F, <Double 1.0>) fails type-strict numeric equality even though display strings match. Hits CollectionTest minOf/maxOf, MinMaxFloatArrayTest, and the floating part of MinMaxIterableTest. The minMaxOfFloat/Double NaN-propagation variant in MinMaxIterableTest is a closely related defect in iterMaxMinOfOrNull (collections.zig:855) using kotlinFloatTotalCmp instead of Math.min/max NaN-poisoning.

**Fix:** In num_extreme's floating branch, when neither operand is .Double (both Float, or Float+integral) return .{ .Float = @floatCast(r) } before the Double return, computing the @min/@max/NaN in f32. Update the stale doc comment. Separately, in iterMaxMinOfOrNull (collections.zig:855) replace the kotlinFloatTotalCmp-based selection with NaN-poisoning IEEE min/max semantics when both compared values are floating (any NaN wins) and -0.0<+0.0 tie-break for the non-NaN case. ~25 lines total.

## 7. fqn-path-and-implicit-this [high] — 14 fails, 3 files
**Files:** src/ir/lower/expr.zig, src/ir/eval.zig, src/ir/lower/literals.zig

**Root:** Inside a class method (this in scope), bare-name and FQN value-position reads mis-resolve to this-field reads instead of globals. (a) A fully-qualified package path used as a value (kotlin.math.PI) is gated out of the FQN-flatten branch in lowerMember (expr.zig:1366-1372) when b.resolve('this')!=null, so it lowers to GetField('kotlin') on the class; the call path already has the head_is_real_pkg escape hatch. (b) A bare implicit-this call to a name with intrinsic global namesakes (isFinite) emits CallMemberOrGlobal in lowerImplicitThisCall (expr.zig:4485) WITHOUT setting the recv register, so the synthesized getter frame has empty this_idx and the member probe misses, falling to a failing global lookup. Hits NumbersTest and DurationTest.

**Fix:** (a) In lowerMember (expr.zig:1362), compute head_is_real_pkg = isPkgRoot(head) and change the gate's final conjunct to (head_is_real_pkg or b.resolve('this')==null), mirroring the call path at expr.zig:4719-4720, so kotlin.* FQNs resolve to LoadGlobal even with this in scope. (b) In lowerImplicitThisCall's CallMemberOrGlobal branch (expr.zig:4485-4495), set the emitted instruction's recv = this_reg (the existing optional Reg field, ir.zig:398), mirroring the sibling CallMember branch. Both are ~1-line changes. The if/when-tail Long widening for longBits is a smaller follow-up in literals.zig.

## 8. type-error-not-catchable-throwable [high] — 56 fails, 3 files
**Files:** src/stdlib/implementations/atomics.zig, src/stdlib/implementations/collections.zig, src/interp_ir/vm/host_classes.zig

**Root:** Out-of-bounds / negative-size / range guards return a Zig-side RuntimeError{.Type} instead of a thrown Kotlin Value. The IR try/catch (findCatch / the eval.zig catch loop) only routes .Thrown/.Throw Values through host.instanceOf; a bare .Type unwinds as a fatal interpreter error, so assertFailsWith<...>/assertFails never catches it and the raw text prints. Same mechanism across: atomic-array *At OOB ops (atomics.zig withArrayElemMut:167), the array constructor negative-size guard (collections.zig arraySizeArg:1611, shared by IntArray etc. and AtomicIntArray/AtomicLongArray ctors), and the array sort/copyOfRange/fill range checks that also conflate from>to (should be IllegalArgumentException) with out-of-bounds (IndexOutOfBoundsException).

**Fix:** Add/reuse a thrown helper (mirror collections.zig:262 thrown()) that builds .{ .err = .{ .Thrown = makeException(...) } }. (1) atomics.zig: make withArrayElemMut Error!EvalResult and at :167/:159 throw kotlin.IndexOutOfBoundsException with a formatted message. (2) collections.zig arraySizeArg:1611: throw kotlin.NegativeArraySizeException (also fixes the stringbuilder.zig:423 site). (3) Add NegativeArraySizeException to the runtime_exc array in host_classes.zig:417-425 so it is recognized as a RuntimeException subtype. (4) For the array range ops (collections.zig:5658/5681/5702/5728) split the check: from>to -> IllegalArgumentException, else IndexOutOfBoundsException. Each piece independently testable.

## 9. numeric-mod-and-any-eq [high] — 3 fails, 3 files
**Files:** src/ir/eval.zig, src/stdlib/implementations/numeric.zig, src/ir/lower/decl.zig

**Root:** Numeric mod/% handling has three gaps: (1) the .Mod arm of evalBinOp (eval.zig:4160) has NO Float cases (the .Div arm does), so Float%Float errors 'BinOp.Mod'; (2) num_mod (numeric.zig:1178) returns the wider type but Kotlin's mod result type is the DIVISOR's type (Long.mod(Int)->Int); (3) NaN==NaN through Any?-typed params evaluates false because Any/Any? params are never markAnyTyped (decl.zig only marks generic type-params), so == uses primitive Eq instead of BoxedEq. Hits FloorDivModTest.

**Fix:** (1) eval.zig: add Float cases to the .Mod arm mirroring .Div (@rem). (2) numeric.zig num_mod: return a value whose tag matches rhs (the divisor) rather than 'wide'. (3) decl.zig: in param-binding, markAnyTyped params whose declared type name is 'Any' (regardless of nullable) with no function type, so == lowers to BoxedEq. ~17 lines across three independent spots.

## 10. math-intrinsic-ieee-edge-cases [high] — 10 fails, 2 files
**Files:** src/stdlib/implementations/math.zig, src/stdlib/implementations.zig

**Root:** Math intrinsics delegate to Zig std.math without Kotlin/Java IEEE special cases or Float narrowing: pow(1.0, +-Inf) returns 1 not NaN; log(x, base<=0||==1) returns non-NaN; ulp at Double.MAX_VALUE returns Infinity; and Float trig/exp/log have no Float-result binding so they return f64. Hits MathTest. (The float pow/min/max Float-narrowing overlaps the float-minmax-promotion cluster but the pow/log/ulp/trig cases are distinct.)

**Fix:** In math.zig: (1) double_pow/float_pow: NaN when abs(base)==1.0 and exp is +-Inf/NaN before std.math.pow. (2) math_log: return NaN when base<=0.0 or base==1.0. (3) double_ulp: when nextUp(x) is +Inf use x - nextDown(x). (4) Add Float-result intrinsic bindings (unaryFloat helper, compute f64 then @floatCast f32) for kotlin.math sin/cos/tan/asin/acos/atan/atan2/exp/expm1/ln/log10/log2/log when arg is Float, bound in implementations.zig. The assertEquals(Double,Double,Double) tolerance-overload selection is a separate overload-resolution follow-up.

## 11. unsigned-range-signed-compare [high] — 19 fails, 3 files
**Files:** src/stdlib/implementations/ranges.zig, src/runtime/value.zig, src/interp_ir/vm/host_call_member.zig

**Root:** Range views store endpoints as i64 (bitcast from u64 for ULong/UInt) and every emptiness/containment/display computation uses SIGNED i64 ordering regardless of RangeKind. So ULong.MAX reads as -1, etc. rangeViewEmpty/range_is_empty (ranges.zig:199/300), range_contains (ranges.zig:280), the duplicate inline Range contains in host_call_member.zig:2552, rangeIsEmptyVal and range display in value.zig all misorder unsigned bounds. ULongRange.EMPTY reports non-empty, '9uL..(-5).toULong()' reports empty, large unsigned containment fails, and displays show '0..-2'. Hits URangeTest and the dominant cluster of RandomTest.

**Fix:** Add a kind-aware order helper in ranges.zig that reinterprets bounds as u64/u32 when kind is .ULong/.UInt and compares unsigned; otherwise signed. Rewrite rangeViewEmpty and range_is_empty (have range_is_empty call rangeViewEmpty), and range_contains (read candidate+bounds as u64 for unsigned kinds) to use it. Make rangeIsEmptyVal (value.zig:1822) kind-aware and fix the range display branch (value.zig:1969) to print u64/u32 for unsigned kinds. Fix or delete the duplicate inline contains in host_call_member.zig:2552 (prefer routing to ranges.range_contains). ~25-30 lines, localized. Add Zig unit tests.

## 12. unsigned-arith-and-storage [high] — 50 fails, 4 files
**Files:** src/stdlib/implementations.zig, src/stdlib/implementations/numeric.zig, src/stdlib/implementations/collections.zig, src/stdlib/implementations/value.zig

**Root:** Two related unsigned gaps. (1) UInt/ULong (and UByte/UShort) floorDiv/mod have NO native intrinsic binding; only operators (BinOp path) and bitwise ops are bound. The method-call forms fall through to the Kotlin inline body whose expect uintDivide/ulongDivide actuals are unmined, producing a boxed signed Int/value-class Instance of the wrong shape, so assertEquals against a primitive .UInt/.ULong fails. (2) Unsigned-array storage-wrapping constructors UByteArray(ByteArray)/UIntArray(IntArray)/etc. are not handled: kotlin.UByteArray binds to array_ctor_ubyte which always treats arg0 as a size via arraySizeArg, so asUByteArray() (inlined as UByteArray(this)) errors 'UByteArray expects an Int size'. (3) Double/Float.toUInt/toULong truncate via signed toLong instead of saturating. Hits UIntTest, ULongTest, the unsigned-array clusters in RandomTest/UuidTest, and unsigned compareValues in UnsignedArraysTest.

**Fix:** (1) Add native uint_div/uint_rem/ulong_div/ulong_rem in numeric.zig (u32/u64 arith with /-by-zero ArithmeticException guard, returning the receiver's unsigned kind; floorDiv==div and mod==rem for unsigned) and bind kotlin.{UInt,ULong,UByte,UShort}.{div,rem,floorDiv,mod} in implementations.zig. (2) In arrayCtorImpl (collections.zig:1615), when prim is set and the single arg is a .Array of the matching backing kind, reinterpret its packed bytes into a fresh unsigned PrimBuf (mirror the reverse path in host_fields.zig:818). (3) Rewrite double_to_uint/double_to_ulong (numeric.zig:834) to saturate (NaN->0, <=0->0, >=max->max, else trunc). (4) In compareValues (collections.zig:~416) add an unsigned branch using asU64 before the signed compare. Several independent edits; do the floorDiv/mod + storage-ctor + saturation together as the unsigned intrinsic sweep.

## 13. nested-class-companion-value [high] — 70 fails, 5 files
**Files:** src/ir/lower/expr.zig, src/ir/lower/decl.zig, src/interp_ir/vm/host_globals.zig, src/interp_ir/vm/host_fields.zig, src/interp_ir/build/lift.zig

**Root:** A class name in value position must resolve to its companion-object instance (Kotlin: C with a companion yields C.Companion). KLIO returns the bare Value.Class instead. Two related sites: (a) for top-level/by-id resolution, lookupGlobalById/lookupGlobal (host_globals.zig:611/736) only substitute the singleton for an `object`, never for a companioned non-object class; (b) for a NESTED class referenced bare from inside the enclosing class, addVisibleMemberNames (decl.zig:330) folds nested-class names into own_members so lowerPath's hasOwnMember branch (expr.zig:934) emits GetField(this, sgetter) and never reaches the classId companion-or-self sentinel branch (expr.zig:961). This breaks polymorphic-key === checks and `is AbstractCoroutineContextKey` tests. Hits AbstractCoroutineContextElementTest, ContinuationInterceptorKeyTest, CoroutineContextTest, and the enclosing-companion-member variant in BytesHexFormatTest/NumberHexFormatTest (where a nested Builder reads the enclosing companion property `Default` that collides with global Random.Default/Base64.Default).

**Fix:** Two layers. (1) lowerPath own-member branch (expr.zig:934): skip it when name0 is a known class with a registered companion (b.module.classId(name0)!=null and registry.companion_singletons.contains(name0)) OR when it names an enclosing-companion member, so it falls through to the classId companion-or-self sentinel (already handled by host_fields.zig:514-544). (2) host_globals.zig lookupGlobalById/lookupGlobal: before returning .Class, if registry.companion_singletons has the class's simple name, return the companion singleton via ensureObjectSingleton. (3) For the enclosing-companion-member (HexFormat Default) case, also fold enclosing-class companion members into the nested class's enclosing set (lift.zig collectEnclosingMemberNames + thread enclosing members through body-property-init lowering) and guard the runtime instanceField class/global fallback (host_fields.zig) to defer to an enclosingCompanionDeclares walk. Gate strictly on companion-singleton hits so C::class / C(args) construction is preserved.

## 14. nested-class-lift-and-fqn [high] — 8 fails, 3 files
**Files:** src/interp_ir/build/lift.zig, src/interp_ir/build.zig, src/ir/ir.zig

**Root:** The AST lift pass does not fully handle classifiers nested inside nested objects. liftClassRecursive's .Object branch did not recurse into the synthesized class, so a value class nested in an object nested in an interface (ValueTimeMark in TimeSource.Monotonic) never registered in class_index. collectClassFqns's .Object arm did not recurse into object members, so even when lifted the class got the wrong (bare) FQN and qualified-ctor resolution (classIdIndexed/classIdByFqn) failed. Hits MeasureTimeTest and TimeMarkTest with 'unresolved global ValueTimeMark'.

**Fix:** (1) lift.zig liftClassRecursive .Object branch: recurse liftClassRecursive into the synthesized class with the appended enclosing chain, mirroring the .Class branches (already applied/validated). (2) build.zig collectClassFqns .Object arm: recurse into the object's members threading the qualified prefix (pkg.ObjectName) so the lifted classifier gets its correct FQN override and classIdIndexed/classIdByFqn resolve it (already applied/validated). Both small and confirmed.

## 15. mutable-bulk-ops-iterable-predicate [high] — 8 fails, 2 files
**Files:** src/stdlib/implementations/collections.zig, src/interp_ir/vm/host_call_member.zig

**Root:** Two mechanisms in the mutable collection intrinsics. (1) General (anonymous/object-backed) Iterable args are rejected: coll_mut_set_add_all and mutCollRemoveRetain (collections.zig:4020/4032) only snapshot .List/.Set/.Array/.Sequence and typeErr on a .Instance Iterable (e.g. asIterable()), while the List addAll path correctly drains via iterableItemsCtx. (2) Predicate (function) overloads removeAll{}/retainAll{} are mis-routed to the collection-form intrinsic by name (host_call_member.zig:5071), which typeErrs the lambda instead of falling through to the MutableIterable predicate extension. Also drives the addAll(index, elements) indexed overload (coll_mut_list_add_all reads args[1] as the collection). Hits MutableCollectionsTest, ArrayDeque insertAll, and part of AbstractCollectionsTest.abstractMutableList.

**Fix:** (1) collections.zig: route the else arm of coll_mut_set_add_all and the else arm of mutCollRemoveRetain through iterableItemsCtx (drain via iterator()) instead of typeErr. (2) host_call_member.zig stdlibMemberDispatchUncached: when name is removeAll/retainAll and the sole arg isCallable, skip the intrinsic probe (cache the miss) so extensionFnFallback binds the predicate extension. (3) coll_mut_list_add_all: detect arity==3 with args[1]==.Int as addAll(index, elements) and insert at index. Independent, small edits.

## 16. reified-builtin-class-binding [high] — 3 fails, 3 files
**Files:** src/interp_ir/vm/host_globals.zig, src/interp_ir/vm/host_call_member.zig, src/interp_ir/vm/host_call_func.zig

**Root:** When a reified type param is bound at runtime (non-inlined assertFailsWith nested inside a user inline fun), a builtin exception type name resolves via lookupGlobal to the constructor .Intrinsic, not a .Class, because builtin exceptions aren't in the class table. T::class.isInstance(e) then misses (only matches .Class), returns the exception value, and `if (...isInstance(e))` branches on a non-Bool -> 'non-bool in branch'. Hits InstantIsoStringsTest.

**Fix:** In host_globals.zig lookupGlobal (~837, alongside the isPrimitiveTypeName path), when host_classes.isBuiltinTypeName(name) and not a user/pack class, return a synthetic .Class (like primitiveClassDef). This fixes reified binding so T::class.isInstance reaches the intrinsic; also fixes non-inlined `x is T`/`x as T` for builtin type args. Alternative localized fix: accept a constructor-.Intrinsic receiver in the isInstance site (host_call_member.zig:2422).

## 17. char-case-mapping [high] — 6 fails, 3 files
**Files:** src/stdlib/implementations/char.zig, src/stdlib/stdlib_sources.zig, src/stdlib/implementations.zig

**Root:** Char case ops in char.zig use the FULL (SpecialCasing) tables where Kotlin needs SIMPLE one-to-one mappings, have no titlecase table, miss fullwidth digit ranges in toDigit, and lack the Char(UShort) actual. singleCaseChar returns the original for multi-scalar full mappings (U+0130 lowercase wrong), char_titlecase reuses uppercase_map, toDigit only handles ASCII, and Char(code: UShort) has no actual so it returns Unit. Hits CharTest.

**Fix:** In char.zig: add simple-lowercase overrides (U+0130->0x69) consulted before the full-map fallback; add a titlecase_map (Lt mappings U+01C4-01CC/01F1-01F3 region, plus string titlecase ss/Ss etc.) and route char_titlecase_char/char_titlecase through it; extend toDigit for fullwidth ranges U+FF10-19/FF21-3A/FF41-5A; update the U+0130 unit test. Supply the Char(code: UShort) actual (add a baked klio actuals source or bind kotlin.Char UShort overload as an intrinsic). Independent sub-fixes.

## 18. stringbuilder-range-and-members [high] — 9 fails, 3 files
**Files:** src/stdlib/implementations/stringbuilder.zig, src/stdlib/implementations.zig, src/runtime/output.zig

**Root:** StringBuilder range/member intrinsics deviate from java.lang.StringBuilder: delete/replace do not clamp endIndex to length (deleteRange/setRange throw IOOBE on valid no-op calls), toCharArray/getChars and capacity()/ensureCapacity() are unbound, and the UTF-8 backing store cannot hold unpaired UTF-16 surrogates (append(Char) round-trips through U+FFFD). Hits StringBuilderTest.

**Fix:** Tractable part: clamp end_c=@min(end,len) in string_builder_delete_range (~783) and string_builder_set_range (~467), dropping the end>len check while keeping start<0/start>end/start>len throwing. Add string_builder_to_char_array/getChars bodies and bind kotlin.text.StringBuilder.toCharArray/getChars; add capacity()/ensureCapacity() with a tracked capacity field. The surrogate round-trip (switch backing to ArrayList(u16)) is a deep out-of-scope change.

## 19. named-args-on-class-receiver [high] — 1 fails, 1 files
**Files:** src/interp_ir/vm/host_call_member.zig

**Root:** A member call whose receiver is a bare class name (a .Class value carrying the companion) binds named args positionally: callMemberNamedInner only honors named args for .Instance receivers, so the .Class path re-dispatches via the companion singleton DROPPING arg_names, binding endIndex=3 to the first defaulted param. Hits Base64Test.index.

**Fix:** In callMemberNamedInner (host_call_member.zig:5938), after the nested-class probe declines, when any_named and receiver is .Class, resolve the class's companion singleton (as classCompanionAndEnum does) and re-dispatch the named call on that .Instance with names intact (self.callMemberNamed). Guard to fire only when a companion owning the name exists. The secondary local-fn-vs-member overload recursion is separate.

## 20. generic-literal-coercion [medium] — 30 fails, 4 files
**Files:** src/ir/lower/helpers.zig, src/ir/lower/expr.zig, src/ir/lower/inline_call.zig, src/ir/lower/decl.zig

**Root:** An integer/float literal passed where the declared parameter is a generic type variable T (or, for inline functions, any param at the splice site) is never re-typed to the type T unifies to, keeping its natural Int tag. structuralEqBoxed/structuralEq require identical numeric tags, so assertEquals(0, longExpr) / assertEquals(11u, ulongExpr) compare Int(0) vs Long(0) as unequal ('Expected <0>, actual <0>'). coerceNumericLiteralArg (helpers.zig:165) only matches concrete primitive param type names, not 'T'; the inline-splice arg binding (inline_call.zig:683) does no coercion at all; if/when branch tails are not widened. This is the single most pervasive cluster: kotlin.test assertEquals<@OnlyInputTypes T> drives it everywhere. Covers AtomicCommonTest, the secondary clusters in AtomicArrayCommonTest/SetOperationsTest/RandomTest/ULongTest/UNumbersTest, MinMaxLongArrayTest, InstantTest.toEpochMilliseconds, TimeSourceClockTest, and contributes to UuidTest/DurationTest.

**Fix:** Two coordinated changes. (A) Non-inline generic calls: in the param_ty_names build (expr.zig:4263) / lowerArgRunFull (helpers.zig:202-233), when a param's ty.name is one of the callee's own type-parameter names (via module.registry.func_type_params), unify T from a sibling argument with a statically-determinable concrete numeric type (sibling literal suffix kind, or a sibling member/getter/func return type that is a numeric primitive) and pass that concrete name into coerceNumericLiteralArg for the literal arg. (B) Inline path: make coerceNumericLiteralArg pub and call it in inline_call.zig's param-binding loop (~683) for non-function, non-generic concrete primitive params (already validated to fix MinMaxLongArrayTest.minMaxBy). The if/when-branch-tail widening (literals.zig) is a smaller add-on. Touch typeck/lowering only; do not change structuralEqBoxed.

## 21. callable-ref-overload-dispatch [medium] — 73 fails, 4 files
**Files:** src/interp_ir/vm/host_call_func.zig, src/interp_ir/vm/host_call_value.zig, src/ir/lower/expr.zig, src/interp_ir/vm/host_call_member.zig

**Root:** Callable references (bound refs, method refs, ::name) and constructor references are not recognized as callable function values during overload scoring and dispatch. overloadScoreArg (host_call_func.zig:374) returns null for a bound-ref synth Instance ($bound_ref$) against a FunctionN param, so the wrong arity-1 overload wins (enumEntries -> Unit). The lowering overload picker keys on lastArgIsLambda and never treats a ::name MemberRef/Function value as filling a function-typed param, so a Char/vararg-Char sibling beats a (Char)->Boolean predicate (StringTest trim family). Constructor refs as .Class values don't respond to invoke/call (ExceptionTest). The bound-ref member-miss fallback in host_call_value.zig:92 only accepted .Function/.IrClosure, excluding .Intrinsic (NaNPropagationTest minOf/maxOf, already fixed).

**Fix:** (1) overloadScoreArg (host_call_func.zig:374): treat an Instance whose class name starts with '$bound_ref$' as callable (OR into is_callable) so FunctionN params score (fixes enumEntries family in EnumEntriesListTest + EnumEntriesFactoryTest reified hook). (2) host_call_member.zig .Class block (~2505): for invoke/call route to callValueRec (constructor invoke) — fixes ExceptionTest ctor-ref-invoke. (3) Lowering picker in expr.zig: add a 'function-shaped argument' predicate covering ::name refs and Function-typed values, used everywhere lastArgIsLambda is keyed and to down-rank non-function (Char/vararg Char) sibling params — fixes StringTest trim family. (4) host_call_value.zig:94 accept .Intrinsic (done). Items (1)/(2) are tiny and high-value; (3) is the larger lowering change.

## 22. trailing-lambda-overload-scoring [medium] — 4 fails, 1 files
**Files:** src/interp_ir/vm/host_call_member.zig

**Root:** Extension-overload selection (scoreExtCandidates, host_call_member.zig:5676) maps args[i] to params[i+1] strictly by position and ignores Kotlin's trailing-lambda alignment (an unnamed trailing callable binds the LAST function-typed param with intervening defaulted params), even though the call executor (host_call_func.zig:766) and memberApplicableForWalk (6189) already realign correctly. So binarySearch(element) and binarySearch{comparison} pick the wrong overload. Hits ListBinarySearchTest.

**Fix:** Add a paramIndexForArg helper that returns the lowered param slot the i-th arg binds to (normally i+1, but the last unnamed callable binds the last function-shaped param with the gap defaulted), reusing the existing trailing-lambda detection. Use it in the scoreExtCandidates loop (5676) and the unique_exact precheck (5509), treating now-defaulted gap params as satisfied. Localized to one file.

## 23. sequence-flatmap-iterable [medium] — 33 fails, 2 files
**Files:** src/stdlib/implementations/sequence.zig, src/stdlib/implementations/collections.zig

**Root:** The .FlatMap sequence Op's buffered handler (sequence.zig:886-926) only expands .List/.Set/.Sequence transform results; every other shape (notably .Range from flatMap { 0..it }, also .Array/.Map/user .Instance Iterable) hits the else branch and is appended as a single element, yielding [0..1, 0..2] instead of the flattened list. Hits SequenceTest flatMap/flatMapWithEmptyItems (dominant cluster of that file).

**Fix:** Replace the non-expanding else branch with a generic iterable expansion mirroring collections.zig iterableItems: handle .Array (snapshot), .Range (enumerate via the existing range iterators for all kinds), .Map (MapEntry pairs), and .Instance (drain via host iterator()/hasNext()/next()). Factor a flatMapExpand helper. ~20-30 lines, no overload-resolution change.

## 24. kclass-reflection-and-typeof [medium] — 4 fails, 6 files
**Files:** src/interp_ir/vm/host_call_member.zig, src/runtime/value.zig, src/interp_ir/vm/host_fields.zig, src/ir/lower/inline_call.zig, src/stdlib/stdlib_sources.zig, src/interp_ir/vm/host_instances.zig

**Root:** KClass-value reflection has gaps: cast/safeCast unimplemented on .Class receivers, isRuntimeType for .Class omits KClassifier, anonymous-object simpleName returns the synthetic $anon$N instead of null; and typeOf<T>() (inline, body throws) is spliced verbatim with no intrinsic interception so it raises UnsupportedOperationException. Hits KClassTest and KTypeProjectionTest.

**Fix:** host_call_member.zig: add .Class safeCast/cast (return arg or null, or throw ClassCastException) alongside isInstance. value.zig:1773: add KClassifier/kotlin.reflect.KClassifier to the .Class matchesAny set. host_fields.zig:1255: return Null for simpleName when class name startsWith '$anon$'. For typeOf: intercept at inline_call.zig tryInlineCallWithTypeArgs (name=='typeOf', one reified param, KType return) to construct a KTypeImpl from the type-arg classifier; add KTypeImpl.kt to stdlib_sources.zig. KClass items are tiny; typeOf is the medium part.

## 25. abstract-collections-skeleton [medium] — 3 fails, 3 files
**Files:** src/interp_ir/vm/host_call_member.zig, src/ir/lower/expr.zig, src/interp_ir/vm/host_fields.zig

**Root:** Multiple distinct gaps in the AbstractList/AbstractMutableList skeleton, but the one cleanly tractable shared sub-issue is the listIterator(index) intrinsic (host_call_member.zig:2325) not bounds-checking (clamps with @max(n,0), ignores upper bound) where Kotlin throws IndexOutOfBoundsException for index<0||index>size. The others (companion bare-member call from CallMember not consulting companionWithMember; inner-class outer getter returning raw Null slot before the getter; predicate filterInPlace recursion) are separate deeper mechanisms also touched by other clusters. Hits AbstractCollectionsTest.

**Fix:** Primary: fix the listIterator intrinsic (host_call_member.zig:2325) to extract idx as i64, compute size, throw kotlin.IndexOutOfBoundsException when idx<0||idx>size, else use @intCast(idx) with no @max clamp (~8 lines, fixes abstractList). Secondary (separate): route bare companion-member calls in CallMember through companionWithMember (expr.zig:4498 emit CallMemberOrGlobal, or a companion fallback before the dispatch-miss); fix outerInstanceChain (host_fields.zig:1888) to prefer the getter path when the raw slot is absent/Null; route predicate removeAll/retainAll to the extension (covered by mutable-bulk-ops cluster).

## 26. collection-builder-semantics [medium] — 7 fails, 3 files
**Files:** src/stdlib/implementations/control.zig, src/runtime/value.zig, src/stdlib/implementations/collections.zig

**Root:** buildList/buildSet/buildMap intrinsics (control.zig:26-115) deviate from ListBuilder/SetBuilder/MapBuilder.build(): they always allocate a fresh backing (so assertSame(emptyList(), buildList{}) fails — no shared empty singleton; referenceEq has no structural fallback for empty collections), and they never inspect the capacity arg (so buildList(-1){} doesn't throw IllegalArgumentException). Hits ContainerBuilderTest.

**Fix:** In control.zig builders_build_*: when args.len==2 read args[0] as capacity and throw IllegalArgumentException if negative; after running the block, if the produced collection is empty return a canonical thread-local empty backing (add empty_list_items/empty_set_items/empty_map_entries to value.zig pinned as GC roots, also routing coll_empty_list/set/map through them) so assertSame holds. Add unit tests.

## 27. grouping-synth-instance [medium] — 5 fails, 2 files
**Files:** src/stdlib/implementations.zig, src/stdlib/implementations/collections.zig

**Root:** groupingBy builds a synthetic Grouping instance carrying only __grouping_src/__grouping_key with no sourceIterator/keyOf members, so any Grouping terminal that falls through to the upstream stdlib (foldTo/reduceTo/eachCountTo/aggregate, which iterate via sourceIterator()/keyOf()) misses dispatch. Array/Sequence/CharSequence.groupingBy aren't bound at all and fall through to an incompatible anon-object representation. Hits GroupingTest.

**Fix:** Bind kotlin.collections.Grouping.sourceIterator and .keyOf to native bodies in implementations.zig that read __grouping_src (return its iterator) and __grouping_key (invoke on the element). Also bind Array/Sequence/CharSequence.groupingBy to produce the same synth-instance shape so all paths unify. The secondary bound-callable-ref-to-local-extension (String::countVowels) is a separate smaller follow-up.

## 28. suppressed-and-throwable-identity [medium] — 17 fails, 5 files
**Files:** src/runtime/value.zig, src/stdlib/implementations/exceptions.zig, src/interp_ir/vm/host_fields.zig, src/stdlib/stdlib_sources.zig, src/ir/lower/expr.zig

**Root:** Throwable suppressed-exception chains and exception identity equality are not modeled. addSuppressed is a no-op and suppressedExceptions always returns empty (exceptions.zig:177-187); ExceptionData (value.zig:1060) has no suppressed field. Neither structuralEq nor referenceEq has an .Exception arm, so two copies of the same logical exception (sharing ObjRef handles) compare unequal, breaking assertEquals(cause, e.cause). The `use` actual (kotlin-klio Closeable.kt) also uses a Native-shaped finally that replaces the in-flight exception instead of suppressing the close exception. Plus CancellationException's full ctor set/factories are not in the manifest. Hits UseAutoCloseableResourceTest, CancellationExceptionTest, and the secondary suppressed/message clusters in ExceptionTest.

**Fix:** (1) value.zig: add a shared suppressed ValueList field to ExceptionData (visit/deinit like cause) and add an .Exception arm to structuralEq/referenceEq comparing fqn/message/cause/stack by ObjRef ptr-eq (Java reference identity). (2) exceptions.zig: rewrite throwable_add_suppressed to lazily init+append on the receiver and throwable_suppressed to return a frozen view. (3) Fix the `use` actual to the JVM-shaped body (try/catch{exception=e;throw e}/finally{closeFinally}) + closeFinally that addSuppressed. (4) stdlib_sources.zig: add the common-non-jvm CancellationException actual; expr.zig shadowedByClass: skip low_priority factories so HIDDEN factories don't self-recurse. Multiple coordinated edits.

## 29. encode-decode-range-and-float-parse [medium] — 6 fails, 3 files
**Files:** src/stdlib/implementations.zig, src/stdlib/implementations/string.zig, src/interp_ir/vm/host_call_member.zig

**Root:** Two string-conversion intrinsic gaps. (1) encodeToByteArray/decodeToString have no PARAM_NAMES rows so stdlibNamedDispatch can't bind named-arg calls (resolve to Unit), and the bodies ignore startIndex/endIndex and use wrong bounds-check semantics (collapse from>to into IOOBE instead of IAE). (2) parseDouble/parseFloat (string.zig:2681) delegate to std.fmt.parseFloat after exact-spelling checks, but std.fmt.parseFloat is case-insensitive and accepts abbreviated nan/inf and f/F/d/D suffixes and hex-without-p, so 'naN' is wrongly accepted (should throw). Hits StringEncodingTest and StringNumberConversionTest.

**Fix:** (1) Add PARAM_NAMES rows for kotlin.String.encodeToByteArray and kotlin.ByteArray.decodeToString (startIndex,endIndex,throwOnInvalidSequence); rewrite string_to_byte_array/byte_array_decode_to_string to read the range (gated on isIntLike since defaulted slots reorder to Null), apply checkBoundsIndexes semantics (IOOBE for start<0/end>len, IAE for start>end), map char->byte offsets, and throw CharacterCodingException on malformed decode. (2) parseDouble/parseFloat: after stripping one optional sign, reject bodies starting with an ASCII letter (kills naN/nan/inf), strip a trailing f/F/d/D suffix, and require a p exponent for 0x hex bodies. Edits confined to string.zig + implementations.zig.

## 30. iterable-plus-minus-static-dispatch [medium] — 36 fails, 4 files
**Files:** src/ir/lower/expr.zig, src/stdlib/implementations.zig, src/interp_ir/vm/host_call_member.zig, src/ir/lower/lambda_body.zig

**Root:** The +/- operators on a collection lower to a bare BinOp carrying no static type; at runtime they dispatch purely on the runtime value's typeFqn, so a Set-valued receiver statically typed Iterable/Collection/generic-bounded picks Set.plus (returns Set) instead of the Iterable.plus/Collection.plus extension (returns List). Kotlin resolves these against the static receiver type, and a Set never equals a List, so 30 plus/minus tests fail. stdlibMemberDispatch ignores static_recv and the BinOp path never sets it. Hits IterableTests/SetTest/LinkedSetTest/StringSetTest.

**Fix:** Bind kotlin.collections.{Iterable,Collection}.{plus,minus} to the existing coll_list_plus/minus bodies. In lowerBinary, when the LHS static head is Iterable/Collection/MutableIterable/MutableCollection or a generic param bounded by one, emit CallMember{plus/minus, static_recv='Iterable'} instead of a bare BinOp. Thread static_recv into stdlibMemberDispatch so it probes Iterable/Collection.<name> ahead of Set.<name>. Propagate expected functional-type param types into lambda lowering (lambda_body.zig) so `it: Iterable<String>` is known. Larger lowering change; the secondary zipWithNext/chunked/flatten/mapIndexed/withIndex clusters in the same file are distinct.

## 31. anon-object-captured-var [medium] — 1 fails, 3 files
**Files:** src/ir/lower/ast_scan.zig, src/ir/lower/decl.zig, src/interp_ir/vm/host_instances.zig

**Root:** A var of the enclosing frame captured-and-written inside an anonymous object member body is not boxed into a shared Cell, because the capture/boxing analysis (ast_scan.zig assignedInLambdasExpr/scanLambdaRefsExpr) has no .ObjectExpr arm, and lowerMethod (used by buildObject) is not told captured names are cells. So the write inside the method never reaches the enclosing frame (it falls to a global store). Hits CoroutinesReferenceValuesTest.testBadClass (and any anon-object mutating an enclosing var).

**Fix:** ast_scan.zig: add .ObjectExpr arms to assignedInLambdasExpr and scanLambdaRefsExpr that walk the object's member function/property bodies collecting assignment targets and referenced idents (so computeBoxedVars marks the var, emitting MakeCell). host_instances.zig buildObject: thread the enclosing-boxed set into a new lowerMethod param so the method builder marks captured names boxed (read=CellGet, write=CellSet), mirroring lambda_body.zig outer_boxed folding.

## 32. callmemberorvalue-ctor-param-shadow [medium] — 1 fails, 3 files
**Files:** src/interp_ir/vm/host_call_member.zig, src/interp_ir/vm/host_call_func.zig, src/interp_ir/vm/coroutines.zig

**Root:** hostHasMember/hostHasProperty (host_call_member.zig:1281/1344) match ANY primary-ctor param by name without checking p.property, so a plain (non-val/var) ctor param like DeepRecursiveScopeImpl.block wrongly reports as an instance member, making CallMemberOrValue take the member branch instead of the local-value fallback -> 'call_member block' miss. The sibling member-walk at :418 already gates on p.property!=null. Hits DeepRecursiveTest (dominant). The remaining 7 tests then hit a separate Suspended-trampoline issue.

**Fix:** Gate the primary_params name match on p.property != null in both hostHasMember and hostHasProperty (matching :419). Already applied/validated: flips testSimpleReturn to PASS and advances the rest. The secondary fix (startCoroutineUninterceptedOrReturn/startBlock must catch the body park and return COROUTINE_SUSPENDED instead of unwinding EvalError.Suspended, handled at the host dispatch layer) is a separate lower-tractability follow-up.

## 33. regex-engine-gaps [medium] — 29 fails, 3 files
**Files:** src/stdlib/implementations/regexp.zig, src/runtime/value.zig, src/stdlib/implementations.zig

**Root:** The host-synthesized Regex/RegexOption/MatchResult family is incomplete across several mechanisms: RegexOption flags are dropped entirely (regex_ctor reads only the pattern; RegexData/Program have no flags; matcher is always case-sensitive and only anchors at absolute string bounds), find/findAll ignore startIndex and mishandle zero-width matches, MatchResult.destructured / named-group get(name) / backreferences / lookaround are unbound, and splitToSequence is not bound. The upstream Regex source is not loaded. Hits RegexTest.

**Fix:** Land the RegexOption flags first (highest ratio): add flags bitset to RegexData and Program, decode args[1] (RegexOption or Set) in regex_ctor, apply ignore_case (case-fold compare) and multiline (anchor at \n) in Matcher.match, bind kotlin.text.Regex.options and RegexOption.value/ordinal. Then as separate follow-ups in the same file: startIndex in regex_find_all + zero-width handling; MatchResult.destructured + named-group get(name) + backreferences + lookaround parsing + duplicate-name rejection + replacement validation; bind splitToSequence; add the supports*InRegex test actuals.

## 34. eager-sequence-builder [low] — 5 fails, 5 files
**Files:** src/stdlib/implementations/sequence.zig, src/runtime/value.zig, src/stdlib/implementations/collections.zig, src/interp_ir/vm/intrinsic_host.zig, src/interp_ir/vm/host_call_member.zig

**Root:** sequence{}/iterator{} builders run the suspend block eagerly to completion and buffer every yield, rather than driving it lazily (suspending at each yield). runSeqBuilder invokes the whole body; yield/yieldAll append to __seq_buffer without suspending. This breaks laziness, parallel iteration, side-effect interleaving, and infinite builders. The suspend/resume engine exists but SequenceSource has no coroutine-backed variant. Hits SequenceBuilderTest.

**Fix:** Add a Coroutine SequenceSource variant (value.zig) holding the SuspendState/block/scope; rewrite seq_builder/seq_iterator_builder to NOT run the block but return a lazily-started coroutine source; make yield/yieldAll return EvalError.Suspended (allocate a SuspendState) instead of buffering; drive resume on demand in the iterator-next/advance path via host.resumeRaw. Reuses existing suspend primitives but is a non-trivial value-shape + dispatch change across several files.

## 35. arraydeque-internal-structure [low] — 6 fails, 3 files
**Files:** src/stdlib/implementations/collections.zig, src/interp_ir/vm/host_instances.zig, src/stdlib/implementations.zig

**Root:** ArrayDeque is constructed as a flat native mutable List with no backing class instance and no ring-buffer model (head/elementData/modCount). The test-only members internalStructure/testToArray/testRemoveRange exist only in source and miss dispatch; listIterator returns a read-only iterator lacking MutableListIterator.add. The tractable sub-part is the indexed addAll(index, elements) overload (coll_mut_list_add_all reads args[1] as the collection). Hits ArrayDequeTest.

**Fix:** Tractable: fix coll_mut_list_add_all to handle addAll(index, elements) when args.len==3 and args[1]==.Int, inserting at the index (covered by mutable-bulk-ops cluster). The dominant blocker requires either making ArrayDeque a real source-backed instance (remove from isIntrinsicClass and the ctor binding, run the source class's ring-buffer/internalStructure) or adding native intrinsics for internalStructure/testToArray/testRemoveRange plus a mutable list-iterator value shape — both substantial.


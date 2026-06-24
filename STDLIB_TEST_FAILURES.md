# KLIO stdlib commonTest — full failure accounting

Run: `klio test` over every test file in `kotlin/libraries/stdlib/test` (102 files, js/ source set excluded), against the installed `kotlin.test` pack.

**1693 passed · 457 failed · 1 skipped** (2151 tests across 102 files; 0 build-blocked).

Counts are individual failing test cases. Categories are grouped by likely root cause (classification is heuristic, by error signature).

## Category summary

| # | Category | Failing tests |
|---|---|---|
| A | DeepRecursiveFunction (suspend trampoline) unimplemented | 7 |
| B | Stack overflow (native recursion limit; no trampoline) | 8 |
| C | Missing stdlib member: HexFormat config properties | 33 |
| D | Missing stdlib member: Regex / MatchResult | 6 |
| E | Extension/member on a test-local type not resolved | 26 |
| H | Extension/member on a kotlin.* host type not resolved | 45 |
| I | Iterator used as callable (call_value gap) | 6 |
| J | call_value/invoke on Nothing/String/instance | 12 |
| K | Unresolved top-level stdlib function | 11 |
| L | Internal Arity error (indexed-lambda: mapIndexed/withIndex) | 13 |
| M | Internal Type error (builtin arg-type / generic variance) | 48 |
| N | Internal Unbound error | 1 |
| O | Wrong exception type thrown | 3 |
| P | Missing validation/throw (completed where Kotlin throws) | 20 |
| Q | Spurious NullPointerException | 5 |
| R | Unsigned-array constructor: size-type bug | 2 |
| S | Unsigned/overflow arithmetic (BinOp.Add) | 2 |
| T | min/max non-numeric arg | 2 |
| U | Char(code) constructor type gap | 2 |
| V | Comparable dispatch for user/Pair types | 2 |
| W | String.split edge delimiters | 2 |
| X | mutableMapOf/builder arg-shape gap | 1 |
| Y | sequence{}/builder shape gap | 1 |
| Z | Boolean op on non-bool | 1 |
| AA | ClassCastException in test | 2 |
| AB | Spurious IndexOutOfBounds | 5 |
| AC | Other spurious runtime exception | 8 |
| AD | Predicate/boolean assertion mismatch | 25 |
| AE | Behavioral value mismatch (Expected/actual) | 158 |

---

## Full per-category listing

### A. DeepRecursiveFunction (suspend trampoline) unimplemented — 7

- `utils/DeepRecursiveTest.kt` · **DeepRecursiveTest.testBadClass** — Suspended
- `utils/DeepRecursiveTest.kt` · **DeepRecursiveTest.testBinaryTreeDepth** — Suspended
- `utils/DeepRecursiveTest.kt` · **DeepRecursiveTest.testBinaryTreeOddEvenNodesMutual** — Suspended
- `utils/DeepRecursiveTest.kt` · **DeepRecursiveTest.testDeepTreeDepth** — Suspended
- `utils/DeepRecursiveTest.kt` · **DeepRecursiveTest.testDeepTreeOddEvenNodesMutual** — Suspended
- `utils/DeepRecursiveTest.kt` · **DeepRecursiveTest.testEqualToAnythingClass** — Suspended
- `utils/DeepRecursiveTest.kt` · **DeepRecursiveTest.testMutualAndDirectMix** — Suspended

### B. Stack overflow (native recursion limit; no trampoline) — 8

- `collections/AbstractCollectionsTest.kt` · **AbstractCollectionsTest.abstractMutableList** — Stack overflow: evaluation recursion exceeded the configured depth (raise KLIO_MAX_EVAL_DEPTH if intentional)
- `collections/GroupingTest.kt` · **GroupingTest.groupingProducers** — Stack overflow: evaluation recursion exceeded the configured depth (raise KLIO_MAX_EVAL_DEPTH if intentional)
- `collections/ReversedViewsTest.kt` · **ReversedViewsTest.testMutableDoubleReverse** — Stack overflow: evaluation recursion exceeded the configured depth (raise KLIO_MAX_EVAL_DEPTH if intentional)
- `io.encoding/Base64Test.kt` · **Base64Test.common** — Stack overflow: evaluation recursion exceeded the configured depth (raise KLIO_MAX_EVAL_DEPTH if intentional)
- `text/StringTest.kt` · **StringTest.compareToIgnoreCase** — Stack overflow: evaluation recursion exceeded the configured depth (raise KLIO_MAX_EVAL_DEPTH if intentional)
- `text/StringTest.kt` · **StringTest.removeRange** — Stack overflow: evaluation recursion exceeded the configured depth (raise KLIO_MAX_EVAL_DEPTH if intentional)
- `text/StringTest.kt` · **StringTest.replaceDelimited** — Stack overflow: evaluation recursion exceeded the configured depth (raise KLIO_MAX_EVAL_DEPTH if intentional)
- `text/StringTest.kt` · **StringTest.replaceRange** — Stack overflow: evaluation recursion exceeded the configured depth (raise KLIO_MAX_EVAL_DEPTH if intentional)

### C. Missing stdlib member: HexFormat config properties — 33

- `text/BytesHexFormatTest.kt` · **BytesHexFormatTest.bytePrefixWithNewLine** — Vm::get_field `bytesPerLine` on `kotlin.text.HexFormat`
- `text/BytesHexFormatTest.kt` · **BytesHexFormatTest.byteSeparatorPrefixSuffix** — Vm::get_field `bytesPerLine` on `kotlin.text.HexFormat`
- `text/BytesHexFormatTest.kt` · **BytesHexFormatTest.byteSeparatorWithNewLine** — Vm::get_field `bytesPerLine` on `kotlin.text.HexFormat`
- `text/BytesHexFormatTest.kt` · **BytesHexFormatTest.byteSuffixWithNewLine** — Vm::get_field `bytesPerLine` on `kotlin.text.HexFormat`
- `text/BytesHexFormatTest.kt` · **BytesHexFormatTest.bytesPerGroup** — Vm::get_field `bytesPerLine` on `kotlin.text.HexFormat`
- `text/BytesHexFormatTest.kt` · **BytesHexFormatTest.bytesPerGroupBiggerThanBytesPerLine** — Vm::get_field `bytesPerLine` on `kotlin.text.HexFormat`
- `text/BytesHexFormatTest.kt` · **BytesHexFormatTest.bytesPerLine** — Vm::get_field `bytesPerLine` on `kotlin.text.HexFormat`
- `text/BytesHexFormatTest.kt` · **BytesHexFormatTest.bytesPerLineAndBytesPerGroup** — Vm::get_field `bytesPerLine` on `kotlin.text.HexFormat`
- `text/BytesHexFormatTest.kt` · **BytesHexFormatTest.createOnDemand** — Vm::get_field `bytesPerLine` on `kotlin.text.HexFormat`
- `text/BytesHexFormatTest.kt` · **BytesHexFormatTest.emptyGroupSeparator** — Vm::get_field `bytesPerLine` on `kotlin.text.HexFormat`
- `text/BytesHexFormatTest.kt` · **BytesHexFormatTest.formatToString** — Vm::get_field `bytesPerLine` on `kotlin.text.HexFormat`
- `text/BytesHexFormatTest.kt` · **BytesHexFormatTest.groupSeparatorWithNewLine** — Vm::get_field `bytesPerLine` on `kotlin.text.HexFormat`
- `text/BytesHexFormatTest.kt` · **BytesHexFormatTest.ignoreNumberFormat** — Vm::get_field `prefix` on `kotlin.text.HexFormat`
- `text/BytesHexFormatTest.kt` · **BytesHexFormatTest.macAddress** — Vm::get_field `bytesPerLine` on `kotlin.text.HexFormat`
- `text/BytesHexFormatTest.kt` · **BytesHexFormatTest.nonPositiveBytesPerGroup** — Vm::get_field `bytesPerLine` on `kotlin.text.HexFormat`
- `text/BytesHexFormatTest.kt` · **BytesHexFormatTest.nonPositiveBytesPerLine** — Vm::get_field `bytesPerLine` on `kotlin.text.HexFormat`
- `text/BytesHexFormatTest.kt` · **BytesHexFormatTest.parseAcceptsAllNewLineSequences** — Vm::get_field `bytesPerLine` on `kotlin.text.HexFormat`
- `text/BytesHexFormatTest.kt` · **BytesHexFormatTest.parseIgnoresCase** — Vm::get_field `bytesPerLine` on `kotlin.text.HexFormat`
- `text/BytesHexFormatTest.kt` · **BytesHexFormatTest.parseMultipleNewLines** — Vm::get_field `bytesPerLine` on `kotlin.text.HexFormat`
- `text/BytesHexFormatTest.kt` · **BytesHexFormatTest.parseNewLineAtEnd** — Vm::get_field `bytesPerLine` on `kotlin.text.HexFormat`
- `text/BytesHexFormatTest.kt` · **BytesHexFormatTest.parseRequiresTwoDigitsPerByte** — Vm::get_field `bytesPerLine` on `kotlin.text.HexFormat`
- `text/NumberHexFormatTest.kt` · **NumberHexFormatTest.formatAndParsePrefixSuffix** — Vm::get_field `prefix` on `kotlin.text.HexFormat`
- `text/NumberHexFormatTest.kt` · **NumberHexFormatTest.formatMinLength** — Vm::get_field `prefix` on `kotlin.text.HexFormat`
- `text/NumberHexFormatTest.kt` · **NumberHexFormatTest.ignoreBytesFormat** — Vm::get_field `bytesPerLine` on `kotlin.text.HexFormat`
- `text/NumberHexFormatTest.kt` · **NumberHexFormatTest.minLengthNonPositive** — Vm::get_field `prefix` on `kotlin.text.HexFormat`
- `text/NumberHexFormatTest.kt` · **NumberHexFormatTest.parseIgnoresCase** — Vm::get_field `prefix` on `kotlin.text.HexFormat`
- `text/NumberHexFormatTest.kt` · **NumberHexFormatTest.parseIgnoresMinLength** — Vm::get_field `prefix` on `kotlin.text.HexFormat`
- `text/NumberHexFormatTest.kt` · **NumberHexFormatTest.parseIgnoresRemoveLeadingZeros** — Vm::get_field `prefix` on `kotlin.text.HexFormat`
- `text/NumberHexFormatTest.kt` · **NumberHexFormatTest.parseRequiresAtLeastOneHexDigit** — Vm::get_field `prefix` on `kotlin.text.HexFormat`
- `text/NumberHexFormatTest.kt` · **NumberHexFormatTest.parseRequiresPrefixSuffix** — Vm::get_field `prefix` on `kotlin.text.HexFormat`
- `text/NumberHexFormatTest.kt` · **NumberHexFormatTest.prefixWithNewLine** — Vm::get_field `prefix` on `kotlin.text.HexFormat`
- `text/NumberHexFormatTest.kt` · **NumberHexFormatTest.removeLeadingZeros** — Vm::get_field `prefix` on `kotlin.text.HexFormat`
- `text/NumberHexFormatTest.kt` · **NumberHexFormatTest.suffixWithNewLine** — Vm::get_field `prefix` on `kotlin.text.HexFormat`

### D. Missing stdlib member: Regex / MatchResult — 6

- `text/RegexTest.kt` · **RegexTest.findAllAndSplitToSequence** — Vm::get_field `length` on `kotlin.text.Regex`
- `text/RegexTest.kt` · **RegexTest.matchGroups** — Vm::get_field `destructured` on `kotlin.text.MatchResult`
- `text/RegexTest.kt` · **RegexTest.properties** — Vm::get_field `options` on `kotlin.text.Regex`
- `text/RegexTest.kt` · **RegexTest.split** — Vm::get_field `length` on `kotlin.text.Regex`
- `text/RegexTest.kt` · **RegexTest.splitByNoMatch** — Vm::get_field `length` on `kotlin.text.Regex`
- `text/RegexTest.kt` · **RegexTest.splitWithLimitOne** — Vm::get_field `length` on `kotlin.text.Regex`

### E. Extension/member on a test-local type not resolved — 26

- `autoCloseable/UseAutoCloseableResourceTest.kt` · **UseAutoCloseableResourceTest.opFailsCloseFails** — Vm::get_field `suppressedExceptions` on `test.autoCloseable.UseAutoCloseableResourceTest.ResourceCloseException`
- `autoCloseable/UseAutoCloseableResourceTest.kt` · **UseAutoCloseableResourceTest.opFailsCloseFailsTwice** — Vm::get_field `suppressedExceptions` on `test.autoCloseable.UseAutoCloseableResourceTest.ResourceCloseException`
- `collections/ArraysTest.kt` · **ArraysTest.maxWithOrNull** — Vm::get_field `STRING_CASE_INSENSITIVE_ORDER` on `test.collections.ArraysTest`
- `collections/ArraysTest.kt` · **ArraysTest.minWithOrNull** — Vm::get_field `STRING_CASE_INSENSITIVE_ORDER` on `test.collections.ArraysTest`
- `collections/CollectionTest.kt` · **CollectionTest.takeLast** — Vm::get_field `size` on `$anon$1`
- `collections/ContainerBuilderTest.kt` · **ContainerBuilderTest.buildList** — Vm::call_member `buildList` on `test.collections.ContainerBuilderTest`
- `collections/GroupingTest.kt` · **GroupingTest.countEach** — Vm::call_member `iterator` on `$anon$0`
- `collections/SequenceTest.kt` · **SequenceTest.sequenceOfCanBeUsedWithMethodReferences** — Vm::call_member `sequenceOf` on `test.collections.SequenceTest`
- `coroutines/AbstractCoroutineContextElementTest.kt` · **AbstractCoroutineContextElementTest.testSubDerivedOverrides** — Vm::call_member `DerivedWithoutKey` on `test.coroutines.AbstractCoroutineContextElementTest`
- `coroutines/AbstractCoroutineContextElementTest.kt` · **AbstractCoroutineContextElementTest.testSubDerivedWithDifferentBaseOverrides** — Vm::call_member `DerivedWithoutKey` on `test.coroutines.AbstractCoroutineContextElementTest`
- `coroutines/CoroutineContextTest.kt` · **CoroutineContextTest.testInterceptor** — Vm::get_field `checkContents` on `test.coroutines.CoroutineContextTest`
- `enums/EnumEntriesFactoryTest.kt` · **EnumEntriesFactoryTest.testSanity** — Vm::get_field `EnumEntriesListTest` on `test.enums.EnumEntriesFactoryTest`
- `numbers/NaNPropagationTest.kt` · **NaNPropagationTest.maxOf** — Vm::call_member `maxOf` on `test.numbers.NaNPropagationTest`
- `numbers/NaNPropagationTest.kt` · **NaNPropagationTest.minOf** — Vm::call_member `minOf` on `test.numbers.NaNPropagationTest`
- `numbers/NaNPropagationTest.kt` · **NaNTotalOrderTest.maxOfT** — Vm::call_member `maxOf` on `test.numbers.NaNTotalOrderTest`
- `numbers/NaNPropagationTest.kt` · **NaNTotalOrderTest.minOfT** — Vm::call_member `minOf` on `test.numbers.NaNTotalOrderTest`
- `numbers/NumbersTest.kt` · **NumbersTest.floatMinMaxValues** — Vm::get_field `isFloat32RangeEnforced` on `test.numbers.NumbersTest`
- `numbers/NumbersTest.kt` · **NumbersTest.floatToBits** — Vm::get_field `isFloat32RangeEnforced` on `test.numbers.NumbersTest`
- `properties/delegation/PropertyReferenceTest.kt` · **PropertyReferenceTest.extensionProperties** — Vm::call_member `extValBoundVal` on `test.properties.delegation.references.Data`
- `properties/delegation/PropertyReferenceTest.kt` · **PropertyReferenceTest.memberProperties** — Vm::call_member `stringVal` on `test.properties.delegation.references.DataExt`
- `text/RegexTest.kt` · **RegexTest.matchCharWithOctalValue** — Vm::get_field `supportsOctalLiteralInRegex` on `test.text.RegexTest`
- `text/RegexTest.kt` · **RegexTest.matchEscapeRandomChar** — Vm::get_field `supportsEscapeAnyCharInRegex` on `test.text.RegexTest`
- `text/RegexTest.kt` · **RegexTest.matchEscapeSurrogatePair** — Vm::get_field `supportsEscapeAnyCharInRegex` on `test.text.RegexTest`
- `text/StringTest.kt` · **StringTest.isEmptyAndBlank** — Vm::get_field `isBlank` on `Case`
- `time/TimeMarkTest.kt` · **TimeMarkTest.defaultTimeMarkAdjustment** — Vm::get_field `MeasureTimeTest` on `test.time.TimeMarkTest`
- `utils/PreconditionsTest.kt` · **PreconditionsTest.requireNotNullWithLazyMessage** — Vm::call_member `requireNotNull` on `test.utils.PreconditionsTest`

### H. Extension/member on a kotlin.* host type not resolved — 45

- `collections/ArrayDequeTest.kt` · **ArrayDequeTest.insert** — Vm::call_member `internalStructure` on `kotlin.collections.MutableList`
- `collections/ArrayDequeTest.kt` · **ArrayDequeTest.removeAt** — Vm::call_member `internalStructure` on `kotlin.collections.MutableList`
- `collections/ArrayDequeTest.kt` · **ArrayDequeTest.toArray** — Vm::call_member `testToArray` on `kotlin.collections.MutableList`
- `collections/ArraysTest.kt` · **ArraysTest.copyRangeInto** — Vm::get_field `qualifiedName` on `kotlin.Array`
- `collections/ArraysTest.kt` · **ArraysTest.fill** — Vm::call_member `arrayTransform` on `kotlin.IntArray`
- `collections/ArraysTest.kt` · **ArraysTest.runningFoldIndexed** — Vm::call_member `isAsciiLetter` on `kotlin.Char`
- `collections/ArraysTest.kt` · **ArraysTest.runningReduceIndexed** — Vm::call_member `invoke` on `kotlin.Char.Companion`
- `collections/ArraysTest.kt` · **ArraysTest.scanIndexed** — Vm::call_member `isAsciiLetter` on `kotlin.Char`
- `collections/ArraysTest.kt` · **ArraysTest.shuffle** — Vm::call_member `toInt` on `kotlin.Int.Companion`
- `collections/ArraysTest.kt` · **ArraysTest.shufflePredictably** — Vm::call_member `toInt` on `kotlin.Int.Companion`
- `collections/ArraysTest.kt` · **ArraysTest.sortedNullableBy** — Vm::get_field `entries` on `kotlin.Nothing`
- `collections/ArraysTest.kt` · **ArraysTest.sortedTests** — Vm::call_member `toArray` on `kotlin.String`
- `collections/ArraysTest.kt` · **ArraysTest.sortedWith** — Vm::call_member `assertSorted` on `kotlin.collections.Iterator`
- `collections/CollectionTest.kt` · **CollectionTest.contains** — Vm::call_member `toIterable` on `kotlin.collections.MutableSet`
- `collections/CollectionTest.kt` · **CollectionTest.sortedNullableBy** — Vm::get_field `entries` on `kotlin.Nothing`
- `collections/GroupingTest.kt` · **GroupingTest.reduce** — Vm::call_member `countVowels` on `kotlin.String`
- `collections/IterableTests.kt` · **ArrayListTest.withIndex** — Vm::get_field `value` on `kotlin.Pair`
- `collections/IterableTests.kt` · **LinkedSetTest.withIndex** — Vm::get_field `value` on `kotlin.Pair`
- `collections/IterableTests.kt` · **LinkedStringSetTest.withIndex** — Vm::get_field `value` on `kotlin.Pair`
- `collections/IterableTests.kt` · **ListTest.withIndex** — Vm::get_field `value` on `kotlin.Pair`
- `collections/IterableTests.kt` · **SetTest.withIndex** — Vm::get_field `value` on `kotlin.Pair`
- `collections/MapTest.kt` · **MapTest.flatMap** — Vm::get_field `list` on `kotlin.collections.Map.Entry`
- `collections/MapTest.kt` · **MapTest.minMaxWith** — Vm::call_member `invoke` on `kotlin.Comparator`
- `collections/SequenceTest.kt` · **SequenceTest.scanIndexed** — Vm::call_member `iterator` on `kotlin.sequences.SequenceScope`
- `collections/SequenceTest.kt` · **SequenceTest.sequenceFromIterator** — Vm::call_member `iterator` on `kotlin.sequences.ConstrainedOnceSequence`
- `collections/SequenceTest.kt` · **SequenceTest.sorted** — Vm::call_member `assertSorted` on `kotlin.collections.Iterator`
- `collections/SequenceTest.kt` · **SequenceTest.sortedBy** — Vm::call_member `assertSorted` on `kotlin.collections.Iterator`
- `coroutines/SequenceBuilderTest.kt` · **SequenceBuilderTest.testInfiniteYieldAll** — Vm::get_field `entries` on `kotlin.Function`
- `enums/EnumEntriesListTest.kt` · **EnumEntriesListTest.testEmptyEnumBehaviour** — Vm::get_field `ordinal` on `kotlin.enums.EnumEntriesList`
- `reflection/KClassTest.kt` · **KClassTest.isInstanceCastSafeCast** — Vm::call_member `safeCast` on `kotlin.reflect.KClass`
- `text/NumberHexFormatTest.kt` · **NumberHexFormatTest.parseRequiresValueFitTheType** — Vm::call_member `toType` on `kotlin.Long`
- `text/StringBuilderTest.kt` · **StringBuilderTest.capacityTest** — Vm::call_member `capacity` on `kotlin.text.StringBuilder`
- `text/StringTest.kt` · **StringTest.indexOfChar** — Vm::call_member `nativeIndexOf` on `kotlin.String`
- `text/StringTest.kt` · **StringTest.testSplitByChar** — Vm::get_field `size` on `kotlin.Char`
- `text/StringTest.kt` · **StringTest.trimIndent** — Vm::call_member `isNotBlank` on `kotlin.String.Companion`
- `time/DurationTest.kt` · **DurationTest.nanosecondsRounding** — Vm::call_member `isNegative` on `kotlin.text.StringBuilder`
- `time/DurationTest.kt` · **DurationTest.parseAndFormatDefault** — Vm::call_member `isNegative` on `kotlin.text.StringBuilder`
- `time/InstantIsoStringsTest.kt` · **InstantIsoStringsTest.nonParseableInstantStrings** — Vm::get_field `size` on `kotlin.Nothing`
- `time/InstantIsoStringsTest.kt` · **InstantIsoStringsTest.parseStringsWithOffsets** — Vm::get_field `size` on `kotlin.Nothing`
- `time/MeasureTimeTest.kt` · **MeasureTimeTest.measureTimeOfCalc** — Vm::call_member `isNegative` on `kotlin.text.StringBuilder`
- `time/TestTimeSourceTest.kt` · **TestTimeSourceTest.overflows** — Vm::call_member `isNegative` on `kotlin.text.StringBuilder`
- `time/TimeMarkTest.kt` · **TimeMarkTest.adjustment** — Vm::call_member `isNegative` on `kotlin.text.StringBuilder`
- `time/TimeMarkTest.kt` · **TimeMarkTest.adjustmentTestTimeSource** — Vm::call_member `isNegative` on `kotlin.text.StringBuilder`
- `time/TimeMarkTest.kt` · **TimeMarkTest.longDisplacement** — Vm::call_member `isNegative` on `kotlin.text.StringBuilder`
- `time/TimeMarkTest.kt` · **TimeMarkTest.longTimeMarkRoundingEqualHashCode** — Vm::call_member `isNegative` on `kotlin.text.StringBuilder`

### I. Iterator used as callable (call_value gap) — 6

- `collections/IterableTests.kt` · **IterableTest.chunked** — Vm::call_value on `kotlin.collections.Iterator`
- `collections/IterableTests.kt` · **IterableTest.windowed** — Vm::call_value on `kotlin.collections.Iterator`
- `collections/IterableTests.kt` · **LinkedSetTest.chunked** — Vm::call_value on `kotlin.collections.Iterator`
- `collections/IterableTests.kt` · **LinkedSetTest.windowed** — Vm::call_value on `kotlin.collections.Iterator`
- `collections/IterableTests.kt` · **LinkedStringSetTest.chunked** — Vm::call_value on `kotlin.collections.Iterator`
- `collections/IterableTests.kt` · **LinkedStringSetTest.windowed** — Vm::call_value on `kotlin.collections.Iterator`

### J. call_value/invoke on Nothing/String/instance — 12

- `collections/ArraysTest.kt` · **ArraysTest.contentDeepEquals** — Vm::call_value on `kotlin.Nothing`
- `collections/ListBinarySearchTest.kt` · **ListBinarySearchTest.binarySearchByElement** — Vm::call_value on `kotlin.Nothing`
- `collections/ListBinarySearchTest.kt` · **ListBinarySearchTest.binarySearchByElementNullable** — Vm::call_value on `kotlin.Nothing`
- `collections/SequenceTest.kt` · **SequenceTest.flatMapIndexed** — Vm::invoke_callable_with_this on `<instance>`
- `collections/UnsignedArraysTest.kt` · **UnsignedArraysTest.contentEquals** — Vm::call_value on `kotlin.Nothing`
- `coroutines/CoroutinesReferenceValuesTest.kt` · **CoroutinesReferenceValuesTest.testBadClass** — Vm::call_value on `kotlin.Nothing`
- `text/StringTest.kt` · **StringTest.contentEquals** — Vm::call_value on `kotlin.Nothing`
- `text/StringTest.kt` · **StringTest.contentEqualsIgnoreCase** — Vm::call_value on `kotlin.Nothing`
- `text/StringTest.kt` · **StringTest.equalsIgnoreCase** — Vm::call_value on `kotlin.Nothing`
- `text/StringTest.kt` · **StringTest.regionMatchesForCharSequence** — Vm::call_value on `kotlin.Nothing`
- `text/StringTest.kt` · **StringTest.trimStartAndEnd** — Vm::call_value on `kotlin.String`
- `uuid/UuidTest.kt` · **UuidTest.parseInvalid** — Vm::call_value on `kotlin.Nothing`

### K. Unresolved top-level stdlib function — 11

- `collections/ArrayDequeTest.kt` · **ArrayDequeTest.removeRange** — unresolved global `testRemoveRange`
- `collections/ArraysTest.kt` · **ArraysTest.contentEquals** — unresolved global `toList`
- `collections/ArraysTest.kt` · **ArraysTest.sortByStable** — unresolved global `Sortable`
- `collections/ArraysTest.kt` · **ArraysTest.sortStable** — unresolved global `Sortable`
- `collections/CollectionTest.kt` · **CollectionTest.filterIsInstanceArray** — unresolved global `filterIsInstanceTo`
- `collections/CollectionTest.kt` · **CollectionTest.filterIsInstanceList** — unresolved global `filterIsInstanceTo`
- `collections/CollectionTest.kt` · **CollectionTest.maxWithOrNull** — unresolved global `STRING_CASE_INSENSITIVE_ORDER`
- `collections/CollectionTest.kt` · **CollectionTest.minWithOrNull** — unresolved global `STRING_CASE_INSENSITIVE_ORDER`
- `collections/CollectionTest.kt` · **CollectionTest.sortByStable** — unresolved global `Sortable`
- `collections/CollectionTest.kt` · **CollectionTest.sortStable** — unresolved global `Sortable`
- `numbers/NumbersTest.kt` · **NumbersTest.floatFitsInFloatArray** — unresolved global `assertAlmostEquals`

### L. Internal Arity error (indexed-lambda: mapIndexed/withIndex) — 13

- `collections/CollectionTest.kt` · **CollectionTest.groupByKeysAndValues** — Arity
- `collections/IterableTests.kt` · **ArrayListTest.mapIndexed** — Arity
- `collections/IterableTests.kt` · **IterableTest.mapIndexed** — Arity
- `collections/IterableTests.kt` · **IterableTest.withIndex** — Arity
- `collections/IterableTests.kt` · **LinkedSetTest.mapIndexed** — Arity
- `collections/IterableTests.kt` · **LinkedStringSetTest.mapIndexed** — Arity
- `collections/IterableTests.kt` · **ListTest.mapIndexed** — Arity
- `collections/IterableTests.kt` · **SetTest.mapIndexed** — Arity
- `collections/MapTest.kt` · **MapTest.createWithSelectorForKeyAndValue** — Arity
- `collections/SequenceTest.kt` · **SequenceTest.withIndex** — Arity
- `text/StringEncodingTest.kt` · **StringEncodingTest.encodeToByteArray** — Arity
- `text/StringTest.kt` · **StringTest.slice** — Arity
- `text/StringTest.kt` · **StringTest.sliceCharSequence** — Arity

### M. Internal Type error (builtin arg-type / generic variance) — 48

- `collections/ArrayDequeTest.kt` · **ArrayDequeTest.insertAll** — Type
- `collections/ArraysTest.kt` · **ArraysTest.copyAndResize** — Type
- `collections/ArraysTest.kt` · **ArraysTest.sliceArray** — Type
- `collections/CollectionTest.kt` · **CollectionTest.abstractCollectionToArray** — Type
- `collections/CollectionTest.kt` · **CollectionTest.minusAssign** — Type
- `collections/CollectionTest.kt` · **CollectionTest.sortedByNullable** — Type
- `collections/IterableTests.kt` · **ArrayListTest.flatten** — Type
- `collections/IterableTests.kt` · **ArrayListTest.windowed** — Type
- `collections/IterableTests.kt` · **IterableTest.flatten** — Type
- `collections/IterableTests.kt` · **LinkedSetTest.flatten** — Type
- `collections/IterableTests.kt` · **LinkedStringSetTest.flatten** — Type
- `collections/IterableTests.kt` · **ListTest.flatten** — Type
- `collections/IterableTests.kt` · **ListTest.windowed** — Type
- `collections/IterableTests.kt` · **SetTest.flatten** — Type
- `collections/MapTest.kt` · **MapTest.createFrom** — Type
- `collections/MapTest.kt` · **MapTest.populateTo** — Type
- `collections/MutableCollectionsTest.kt` · **MutableCollectionTest.addAll** — Type
- `collections/MutableCollectionsTest.kt` · **MutableCollectionTest.addAllAtIndex** — Type
- `collections/MutableCollectionsTest.kt` · **MutableCollectionTest.removeAll** — Type
- `collections/MutableCollectionsTest.kt` · **MutableCollectionTest.retainAll** — Type
- `collections/SequenceTest.kt` · **SequenceTest.chunked** — Type
- `collections/SequenceTest.kt` · **SequenceTest.drop** — Type
- `collections/SequenceTest.kt` · **SequenceTest.firstNotNullOf** — Type
- `collections/SequenceTest.kt` · **SequenceTest.joinConcatenatesTheFirstNElementsAboveAThreshold** — Type
- `collections/SequenceTest.kt` · **SequenceTest.mapAndJoinToString** — Type
- `collections/SequenceTest.kt` · **SequenceTest.mapIndexedNotNull** — Type
- `collections/SequenceTest.kt` · **SequenceTest.mapNotNull** — Type
- `collections/SequenceTest.kt` · **SequenceTest.runningReduce** — Type
- `collections/SequenceTest.kt` · **SequenceTest.scan** — Type
- `collections/SequenceTest.kt` · **SequenceTest.sequenceFromFunctionWithLazyInitialValue** — Type
- `collections/SequenceTest.kt` · **SequenceTest.toStringJoinsNoMoreThanTheFirstTenElements** — Type
- `collections/SequenceTest.kt` · **SequenceTest.windowed** — Type
- `collections/SequenceTest.kt` · **SequenceTest.zipWithNext** — Type
- `collections/UnsignedArraysTest.kt` · **UnsignedArraysTest.copyAndResize** — Type
- `collections/UnsignedArraysTest.kt` · **UnsignedArraysTest.sliceArray** — Type
- `text/BytesHexFormatTest.kt` · **BytesHexFormatTest.defaultCase** — Type
- `text/BytesHexFormatTest.kt` · **BytesHexFormatTest.emptyByteArray** — Type
- `text/BytesHexFormatTest.kt` · **BytesHexFormatTest.lowerCase** — Type
- `text/BytesHexFormatTest.kt` · **BytesHexFormatTest.upperCase** — Type
- `text/RegexTest.kt` · **RegexTest.matchEntireLazyQuantor** — Type
- `text/RegexTest.kt` · **RegexTest.matchNamedGroups** — Type
- `text/RegexTest.kt` · **RegexTest.matchResult** — Type
- `text/StringEncodingTest.kt` · **StringEncodingTest.decodeToString** — Type
- `text/StringTest.kt` · **StringTest.testReplaceAllClosure** — Type
- `text/StringTest.kt` · **StringTest.testReplaceAllClosureAtEnd** — Type
- `text/StringTest.kt` · **StringTest.testReplaceAllClosureAtStart** — Type
- `text/StringTest.kt` · **StringTest.testReplaceAllClosureEmpty** — Type
- `text/StringTest.kt` · **StringTest.windowed** — Type

### N. Internal Unbound error — 1

- `collections/GroupingTest.kt` · **GroupingTest.foldWithComputedInitialValue** — Unbound

### O. Wrong exception type thrown — 3

- `reflection/KTypeProjectionTest.kt` · **KTypeProjectionTest.constructorArgumentsValidation** — kotlin.AssertionError: Expected an exception of IllegalArgumentException to be thrown, but was kotlin.UnsupportedOperationException: This fu
- `text/StringTest.kt` · **StringTest.subsequenceWithInvalidIndices** — kotlin.AssertionError: Expected an exception of IndexOutOfBoundsException to be thrown, but was kotlin.IllegalArgumentException: startIndex:
- `text/StringTest.kt` · **StringTest.substringWithInvalidIndices** — kotlin.AssertionError: Expected an exception of IndexOutOfBoundsException to be thrown, but was kotlin.IllegalArgumentException: startIndex:

### P. Missing validation/throw (completed where Kotlin throws) — 20

- `collections/CollectionTest.kt` · **CollectionTest.constructorWithCapacity** — kotlin.AssertionError: Expected an exception of IllegalArgumentException to be thrown, but was completed successfully with the result: <[]>.
- `collections/ConcurrentModificationTest.kt` · **ConcurrentModificationTest.mutableList** — kotlin.AssertionError: listOp: add(), iteratorOp: next(). Expected an exception of ConcurrentModificationException to be thrown, but was com
- `collections/ConcurrentModificationTest.kt` · **ConcurrentModificationTest.subList** — kotlin.AssertionError: subListOp: isEmpty(). Expected an exception of ConcurrentModificationException to be thrown, but was completed succes
- `collections/ContainerBuilderTest.kt` · **ContainerBuilderTest.buildMap** — kotlin.AssertionError: y.entries.first().setValue(v). Expected an exception of UnsupportedOperationException to be thrown, but was completed
- `collections/ContainerBuilderTest.kt` · **ContainerBuilderTest.buildSet** — kotlin.AssertionError: y.iterator().apply { next() }.remove(). Expected an exception of UnsupportedOperationException to be thrown, but was 
- `collections/MapTest.kt` · **MapTest.constructorWithCapacity** — kotlin.AssertionError: Expected an exception of IllegalArgumentException to be thrown, but was completed successfully with the result: <{}>.
- `collections/ReversedViewsTest.kt` · **ReversedViewsTest.testIteratorRemove** — kotlin.AssertionError: Expected an exception of IllegalStateException to be thrown, but was completed successfully.
- `collections/SequenceTest.kt` · **SequenceTest.makeSequenceOneTimeConstrained** — kotlin.AssertionError: Expected an exception to be thrown, but was completed successfully with the result: <[1, 2, 3, 4]>.
- `collections/SequenceTest.kt` · **SequenceTest.sequenceFromFunction** — kotlin.AssertionError: Expected an exception to be thrown, but was completed successfully with the result: <[]>.
- `collections/SequenceTest.kt` · **SequenceTest.sequenceOfVararg** — kotlin.AssertionError: Expected an exception of IllegalStateException to be thrown, but was completed successfully with the result: <kotlin.
- `collections/SequenceTest.kt` · **SequenceTest.take** — kotlin.AssertionError: Expected an exception of IllegalArgumentException to be thrown, but was completed successfully with the result: <kotl
- `text/RegexTest.kt` · **RegexTest.invalidNamedGroupDeclaration** — kotlin.AssertionError: Expected an exception to be thrown, but was completed successfully with the result: <(?<>\w+), yes \k<>>.
- `text/RegexTest.kt` · **RegexTest.matchDuplicateGroupName** — kotlin.AssertionError: Expected an exception to be thrown, but was completed successfully with the result: <(?<hi>hi)\|(?<hi>bye)>.
- `text/RegexTest.kt` · **RegexTest.replace** — kotlin.AssertionError: $$. Expected an exception of IllegalArgumentException to be thrown, but was completed successfully with the result: <
- `text/StringBuilderTest.kt` · **StringBuilderTest.deprecatedAppend** — kotlin.AssertionError: Expected an exception of NotImplementedError to be thrown, but was completed successfully with the result: <b>.
- `text/StringBuilderTest.kt` · **StringBuilderTest.overflow** — kotlin.AssertionError: Expected an exception of Error to be thrown, but was completed successfully with the result: <aaaaaaaaaaaaaaaaaaaaCha
- `text/StringEncodingTest.kt` · **StringEncodingTest.encodeToByteArraySlice** — kotlin.AssertionError: Expected an exception of CharacterCodingException to be thrown, but was completed successfully with the result: <kotl
- `text/StringNumberConversionTest.kt` · **StringNumberConversionTest.toDouble** — kotlin.AssertionError: Expected to fail on input "naN". Expected an exception of NumberFormatException to be thrown, but was completed succe
- `text/StringNumberConversionTest.kt` · **StringNumberConversionTest.toFloat** — kotlin.AssertionError: Expected to fail on input "naN". Expected an exception of NumberFormatException to be thrown, but was completed succe
- `text/StringTest.kt` · **StringTest.stringFromCharArrayOutOfBounds** — kotlin.AssertionError: Expected an exception of IndexOutOfBoundsException to be thrown, but was completed successfully with the result: <k>.

### Q. Spurious NullPointerException — 5

- `text/RegexTest.kt` · **RegexTest.matchNamedGroupCollection** — kotlin.NullPointerException
- `text/RegexTest.kt` · **RegexTest.matchNamedGroupsWithBackReference** — kotlin.NullPointerException
- `text/RegexTest.kt` · **RegexTest.matchOptionalGroup** — kotlin.NullPointerException
- `text/RegexTest.kt` · **RegexTest.matchOptionalNamedGroup** — kotlin.NullPointerException
- `text/RegexTest.kt` · **RegexTest.matchWithBackReference** — kotlin.NullPointerException

### R. Unsigned-array constructor: size-type bug — 2

- `collections/MapTest.kt` · **MapTest.kClassAsMapKey** — ULongArray expects an Int size
- `collections/UnsignedArraysTest.kt` · **UnsignedArraysTest.fill** — UByteArray expects an Int size

### S. Unsigned/overflow arithmetic (BinOp.Add) — 2

- `collections/UnsignedArraysTest.kt` · **UnsignedArraysTest.sum** — BinOp.Add on 0 and 2
- `collections/UnsignedArraysTest.kt` · **UnsignedArraysTest.sumInUnsignedArrays** — BinOp.Add on 0.0 and 200

### T. min/max non-numeric arg — 2

- `comparisons/OrderingTest.kt` · **OrderingTest.maxOfWith** — max: non-numeric arg
- `comparisons/OrderingTest.kt` · **OrderingTest.minOfWith** — min: non-numeric arg

### U. Char(code) constructor type gap — 2

- `numbers/BuiltinCompanionTest.kt` · **BuiltinCompanionTest.charTest** — Char requires an Int or UShort code
- `numbers/NumbersTest.kt` · **NumbersTest.sizeInBitsAndBytes** — Char requires an Int or UShort code

### V. Comparable dispatch for user/Pair types — 2

- `collections/ListBinarySearchTest.kt` · **ListBinarySearchTest.binarySearchByKeyWithComparator** — values are not comparable: IncomparableDataItem(value=IncomparableDataItem(value=10)), {ir-closure#355}
- `collections/ListBinarySearchTest.kt` · **ListBinarySearchTest.binarySearchByMultipleKeys** — values are not comparable: (10, 45), {ir-closure#368}

### W. String.split edge delimiters — 2

- `text/StringTest.kt` · **StringTest.split** — String.split requires at least one delimiter
- `text/StringTest.kt` · **StringTest.splitIllegalLimit** — String.split requires at least one delimiter

### X. mutableMapOf/builder arg-shape gap — 1

- `collections/MapTest.kt` · **MapTest.modifiedBackingMapOfEntry** — mutableMapOf expects Pair arguments (use `key to value` or `Pair(k, v)`)

### Y. sequence{}/builder shape gap — 1

- `collections/SequenceTest.kt` · **SequenceTest.runningReduceIndexed** — sequence builder expects a block

### Z. Boolean op on non-bool — 1

- `text/StringTest.kt` · **StringTest.findAnyOfStrings** — Not on non-bool

### AA. ClassCastException in test — 2

- `properties/delegation/PropertyReferenceTest.kt` · **PropertyReferenceTest.covariantProperties** — kotlin.ClassCastException: cast to `Map` failed
- `properties/delegation/PropertyReferenceTest.kt` · **PropertyReferenceTest.topLevelProperties** — kotlin.ClassCastException: cast to `Map` failed

### AB. Spurious IndexOutOfBounds — 5

- `collections/UnsignedArraysTest.kt` · **UnsignedArraysTest.foldRight** — kotlin.ArrayIndexOutOfBoundsException: Index -1 out of bounds for length 3
- `collections/UnsignedArraysTest.kt` · **UnsignedArraysTest.reduceRight** — kotlin.ArrayIndexOutOfBoundsException: Index -1 out of bounds for length 3
- `collections/UnsignedArraysTest.kt` · **UnsignedArraysTest.reduceRightOrNull** — kotlin.ArrayIndexOutOfBoundsException: Index -1 out of bounds for length 3
- `text/StringBuilderTest.kt` · **StringBuilderTest.deleteSubstring** — kotlin.IndexOutOfBoundsException: startIndex: 8, endIndex: 12, length: 8
- `text/StringBuilderTest.kt` · **StringBuilderTest.setRange** — kotlin.IndexOutOfBoundsException: startIndex: 20, endIndex: 25, length: 20

### AC. Other spurious runtime exception — 8

- `collections/ArraysTest.kt` · **ArraysTest.reverseRangeInPlace** — kotlin.UnsupportedOperationException
- `collections/ArraysTest.kt` · **ArraysTest.sortDescendingRangeInPlace** — kotlin.UnsupportedOperationException
- `collections/ArraysTest.kt` · **ArraysTest.sortRange** — kotlin.UnsupportedOperationException
- `collections/ReversedViewsTest.kt` · **ReversedViewsTest.testIteratorSet** — kotlin.IllegalStateException: set() called before next()/previous()
- `coroutines/SequenceBuilderTest.kt` · **SequenceBuilderTest.testExceptionInCoroutine** — kotlin.UnsupportedOperationException: -2 is unsupported
- `coroutines/SequenceBuilderTest.kt` · **SequenceBuilderTest.testLaziness** — kotlin.IllegalStateException: Invalid state: -2
- `coroutines/cancellation/CancellationExceptionTest.kt` · **CancellationExceptionTest.testAllConstructors** — CancellationException() expects 0 args, got 2
- `text/RegexTest.kt` · **RegexTest.matchAllSequence** — kotlin.IllegalArgumentException: Sequence has more than one element.

### AD. Predicate/boolean assertion mismatch — 25

- `collections/CollectionTest.kt` · **CollectionTest.plusAssign** — kotlin.AssertionError: Expected value to be true.
- `collections/MapTest.kt` · **MapTest.minMaxOfDouble** — kotlin.AssertionError: Expected value to be true.
- `collections/MapTest.kt` · **MapTest.minMaxOfFloat** — kotlin.AssertionError: Expected value to be true.
- `collections/SetOperationsTest.kt` · **SetOperationsTest.plusAssign** — kotlin.AssertionError: Expected value to be true.
- `collections/UnsignedArraysTest.kt` · **UnsignedArraysTest.asArray** — kotlin.AssertionError: Expected value to be true.
- `collections/UnsignedArraysTest.kt` · **UnsignedArraysTest.copyOfWithInitializer** — kotlin.AssertionError: Expected value to be true.
- `collections/UnsignedArraysTest.kt` · **UnsignedArraysTest.sortDescending** — kotlin.AssertionError: Expected value to be true.
- `collections/UnsignedArraysTest.kt` · **UnsignedArraysTest.sortedArrayDescending** — kotlin.AssertionError: Expected value to be true.
- `concurrent/atomics/AtomicArrayCommonTest.kt` · **AtomicArrayTest.compareAndSetComparingByReference** — kotlin.AssertionError: Expected value to be false.
- `concurrent/atomics/AtomicCommonTest.kt` · **AtomicLongTest.compareAndSet** — kotlin.AssertionError: Expected value to be true.
- `concurrent/atomics/AtomicCommonTest.kt` · **AtomicReferenceTest.compareAndSetComparingByReference** — kotlin.AssertionError: Expected value to be false.
- `generated/minmax/MinMaxIterableTest.kt` · **MinMaxIterableTest.minMaxOfDouble** — kotlin.AssertionError: Expected value to be true.
- `generated/minmax/MinMaxIterableTest.kt` · **MinMaxIterableTest.minMaxOfFloat** — kotlin.AssertionError: Expected value to be true.
- `numbers/MathTest.kt` · **FloatMathTest.powers** — kotlin.AssertionError: Expected value to be true.
- `random/RandomTest.kt` · **DefaultRandomSmokeTest.nextUBytes** — kotlin.AssertionError: Expected value to be true.
- `random/RandomTest.kt` · **SeededRandomSmokeTest.nextUBytes** — kotlin.AssertionError: Expected value to be true.
- `ranges/URangeTest.kt` · **URangeTest.ulongRange** — kotlin.AssertionError: Expected value to be true.
- `text/RegexTest.kt` · **RegexTest.matchEntireNext** — kotlin.AssertionError: Expected value to be null, but was: <>.
- `text/RegexTest.kt` · **RegexTest.matchIgnoreCase** — kotlin.AssertionError: Expected value to be true.
- `text/StringTest.kt` · **StringTest.compareToUnicode** — kotlin.AssertionError: Expected value to be true.
- `text/StringTest.kt` · **StringTest.contains** — kotlin.AssertionError: Expected value to be true.
- `text/StringTest.kt` · **StringTest.endsWithStringForCharSequence** — kotlin.AssertionError: Expected value to be true.
- `text/StringTest.kt` · **StringTest.onEach** — kotlin.AssertionError: Expected value to be true.
- `text/StringTest.kt` · **StringTest.startsWithStringForCharSequence** — kotlin.AssertionError: Expected value to be true.
- `text/StringTest.kt` · **StringTest.toCharArray** — kotlin.AssertionError: Expected value to be true.

### AE. Behavioral value mismatch (Expected/actual) — 158

- `collections/ArraysTest.kt` · **ArraysTest.asList** — kotlin.AssertionError: Should reflect changes in original array. Expected <10>, actual <5>.
- `collections/ArraysTest.kt` · **ArraysTest.asListObjects** — kotlin.AssertionError: Expected <[a, b, c, d, b, e]>, actual <[a, b, xx, d, b, e]>.
- `collections/ArraysTest.kt` · **ArraysTest.asListPrimitives** — kotlin.AssertionError: Expected <[1, 2, 3, 4, 2, 5]>, actual <[1, 2, 4, 4, 2, 5]>.
- `collections/ArraysTest.kt` · **ArraysTest.contentDeepHashCode** — kotlin.AssertionError: Expected <29887>, actual <29822>.
- `collections/ArraysTest.kt` · **ArraysTest.contentDeepToString** — kotlin.AssertionError: Expected <null>, actual <kotlin.Unit>.
- `collections/ArraysTest.kt` · **ArraysTest.contentHashCode** — kotlin.AssertionError: Expected <-1678509196>, actual <3814209>.
- `collections/ArraysTest.kt` · **ArraysTest.contentToString** — kotlin.AssertionError: Expected <null>, actual <kotlin.Unit>.
- `collections/ArraysTest.kt` · **ArraysTest.copyOfWithInitializer** — kotlin.AssertionError: 
- `collections/ArraysTest.kt` · **ArraysTest.reverseInPlace** — kotlin.AssertionError: Expected <[2, 1]>, actual <[1, 2]>.
- `collections/CollectionTest.kt` · **CollectionTest.minOf** — kotlin.AssertionError: Expected <NaN>, actual <NaN>.
- `collections/CollectionTest.kt` · **CollectionTest.plusCollectionInference** — kotlin.AssertionError: should be list + element. Expected <[[s], [a]]>, actual <[[s], a]>.
- `collections/CollectionTest.kt` · **CollectionTest.sumOf** — kotlin.AssertionError: Expected <0>, actual <0>.
- `collections/ContainerBuilderTest.kt` · **ContainerBuilderTest.buildEmptyList** — kotlin.AssertionError: Expected <[]>, actual <[]> is not same.
- `collections/ContainerBuilderTest.kt` · **ContainerBuilderTest.buildEmptySet** — kotlin.AssertionError: Expected <[]>, actual <[]> is not same.
- `collections/ContainerBuilderTest.kt` · **ContainerBuilderTest.listBuilderSubList** — kotlin.AssertionError: . Expected <[b, 1, d]>, actual <[b, c, d]>.
- `collections/ContainerBuilderTest.kt` · **ContainerBuilderTest.testBuildEmptyMap** — kotlin.AssertionError: Expected <{}>, actual <{}> is not same.
- `collections/IterableTests.kt` · **LinkedSetTest.minusArray** — kotlin.AssertionError: Expected <[bar]>, actual <[bar]>.
- `collections/IterableTests.kt` · **LinkedSetTest.minusAssign** — kotlin.AssertionError: Expected <[bar]>, actual <null>.
- `collections/IterableTests.kt` · **LinkedSetTest.minusCollection** — kotlin.AssertionError: Expected <[bar]>, actual <[bar]>.
- `collections/IterableTests.kt` · **LinkedSetTest.minusElement** — kotlin.AssertionError: Expected <[bar]>, actual <[bar]>.
- `collections/IterableTests.kt` · **LinkedSetTest.minusSequence** — kotlin.AssertionError: Expected <[bar]>, actual <[bar]>.
- `collections/IterableTests.kt` · **LinkedSetTest.plusArray** — kotlin.AssertionError: Expected <[foo, bar, zoo, g]>, actual <[foo, bar, zoo, g]>.
- `collections/IterableTests.kt` · **LinkedSetTest.plusAssign** — kotlin.AssertionError: Expected <[foo, bar, foo, beer, cheese, wine, zoo, g]>, actual <[foo, bar, beer, cheese, wine, zoo, g]>.
- `collections/IterableTests.kt` · **LinkedSetTest.plusCollection** — kotlin.AssertionError: Expected <[foo, bar, zoo, g]>, actual <[foo, bar, zoo, g]>.
- `collections/IterableTests.kt` · **LinkedSetTest.plusElement** — kotlin.AssertionError: Expected <[foo, bar, zoo, g]>, actual <[foo, bar, zoo, g]>.
- `collections/IterableTests.kt` · **LinkedSetTest.plusSequence** — kotlin.AssertionError: Expected <[foo, bar, zoo, g]>, actual <[foo, bar, zoo, g]>.
- `collections/IterableTests.kt` · **LinkedStringSetTest.minusArray** — kotlin.AssertionError: Expected <[bar]>, actual <[bar]>.
- `collections/IterableTests.kt` · **LinkedStringSetTest.minusAssign** — kotlin.AssertionError: Expected <[bar]>, actual <null>.
- `collections/IterableTests.kt` · **LinkedStringSetTest.minusCollection** — kotlin.AssertionError: Expected <[bar]>, actual <[bar]>.
- `collections/IterableTests.kt` · **LinkedStringSetTest.minusElement** — kotlin.AssertionError: Expected <[bar]>, actual <[bar]>.
- `collections/IterableTests.kt` · **LinkedStringSetTest.minusSequence** — kotlin.AssertionError: Expected <[bar]>, actual <[bar]>.
- `collections/IterableTests.kt` · **LinkedStringSetTest.plusArray** — kotlin.AssertionError: Expected <[foo, bar, zoo, g]>, actual <[foo, bar, zoo, g]>.
- `collections/IterableTests.kt` · **LinkedStringSetTest.plusAssign** — kotlin.AssertionError: Expected <[foo, bar, foo, beer, cheese, wine, zoo, g]>, actual <[foo, bar, beer, cheese, wine, zoo, g]>.
- `collections/IterableTests.kt` · **LinkedStringSetTest.plusCollection** — kotlin.AssertionError: Expected <[foo, bar, zoo, g]>, actual <[foo, bar, zoo, g]>.
- `collections/IterableTests.kt` · **LinkedStringSetTest.plusElement** — kotlin.AssertionError: Expected <[foo, bar, zoo, g]>, actual <[foo, bar, zoo, g]>.
- `collections/IterableTests.kt` · **LinkedStringSetTest.plusSequence** — kotlin.AssertionError: Expected <[foo, bar, zoo, g]>, actual <[foo, bar, zoo, g]>.
- `collections/IterableTests.kt` · **SetTest.minusArray** — kotlin.AssertionError: Expected <[bar]>, actual <[bar]>.
- `collections/IterableTests.kt` · **SetTest.minusAssign** — kotlin.AssertionError: Expected <[bar]>, actual <null>.
- `collections/IterableTests.kt` · **SetTest.minusCollection** — kotlin.AssertionError: Expected <[bar]>, actual <[bar]>.
- `collections/IterableTests.kt` · **SetTest.minusElement** — kotlin.AssertionError: Expected <[bar]>, actual <[bar]>.
- `collections/IterableTests.kt` · **SetTest.minusSequence** — kotlin.AssertionError: Expected <[bar]>, actual <[bar]>.
- `collections/IterableTests.kt` · **SetTest.plusArray** — kotlin.AssertionError: Expected <[foo, bar, zoo, g]>, actual <[foo, bar, zoo, g]>.
- `collections/IterableTests.kt` · **SetTest.plusAssign** — kotlin.AssertionError: Expected <[foo, bar, foo, beer, cheese, wine, zoo, g]>, actual <[foo, bar, beer, cheese, wine, zoo, g]>.
- `collections/IterableTests.kt` · **SetTest.plusCollection** — kotlin.AssertionError: Expected <[foo, bar, zoo, g]>, actual <[foo, bar, zoo, g]>.
- `collections/IterableTests.kt` · **SetTest.plusElement** — kotlin.AssertionError: Expected <[foo, bar, zoo, g]>, actual <[foo, bar, zoo, g]>.
- `collections/IterableTests.kt` · **SetTest.plusSequence** — kotlin.AssertionError: Expected <[foo, bar, zoo, g]>, actual <[foo, bar, zoo, g]>.
- `collections/MapTest.kt` · **MapTest.entriesCovariantContains** — kotlin.AssertionError: default read-only: {a=0, b=1, c=2, d=3, e=4, f=5, g=6, h=7, i=8, j=9, k=10, l=11, m=12, n=13, o=14, p=15, q=16, r=17,
- `collections/MapTest.kt` · **MapTest.entriesCovariantRemove** — kotlin.AssertionError: default mutable: {a=0, b=1, c=2, d=3, e=4, f=5, g=6, h=7, i=8, j=9, k=10, l=11, m=12, n=13, o=14, p=15, q=16, r=17, s
- `collections/MapTest.kt` · **MapTest.iterateAndMutate** — kotlin.AssertionError: Expected <{beverage=juice, name=James}>, actual <{beverage=beer, location=Mells, name=James}>.
- `collections/MapTest.kt` · **MapTest.mapEntryCopy** — kotlin.AssertionError: Expected <0>, actual <2>.
- `collections/MapTest.kt` · **MapTest.nullKeyAndValue** — kotlin.AssertionError: default mutable: {a=0, b=1, c=2, d=3, e=4, f=5, g=6, h=7, i=8, j=9, k=10, l=11, m=12, n=13, o=14, p=15, q=16, r=17, s
- `collections/MapTest.kt` · **MapTest.plusAssignArray** — kotlin.AssertionError: Expected <3>, actual <2>.
- `collections/MapTest.kt` · **MapTest.plusAssignSequence** — kotlin.AssertionError: Expected <3>, actual <2>.
- `collections/ReversedViewsTest.kt` · **ReversedViewsTest.testMutableRemoveByObj** — kotlin.AssertionError: Expected <[a, b]>, actual <[a, c]>.
- `collections/ReversedViewsTest.kt` · **ReversedViewsTest.testMutableSubList** — kotlin.AssertionError: Expected <[1, 4]>, actual <[1, 3, 4]>.
- `collections/SequenceTest.kt` · **SequenceTest.minusIsLazyIterated** — kotlin.AssertionError: Expected <[bar]>, actual <[foo, bar]>.
- `collections/SequenceTest.kt` · **SequenceTest.orEmpty** — kotlin.AssertionError: Expected <kotlin.sequences.Sequence>, actual <[]>.
- `collections/SequenceTest.kt` · **SequenceTest.shuffled** — kotlin.AssertionError: Each run returns new shuffle. Illegal value: <[22, 46, 35, 50, 47, 34, 6, 18, 48, 87, 62, 4, 68, 26, 66, 43, 93, 7, 3
- `collections/SequenceTest.kt` · **SequenceTest.shuffledPartially** — kotlin.AssertionError: Expected <0>, actual <100>.
- `collections/SequenceTest.kt` · **SequenceTest.shuffledPredictably** — kotlin.AssertionError: Each run returns new shuffle. Illegal value: <[5, 3, 7, 9, 8, 2, 6, 0, 4, 1]>.
- `collections/SequenceTest.kt` · **SequenceTest.zipWithNextPairs** — kotlin.AssertionError: Source should not be iterated before the result is
- `collections/SetOperationsTest.kt` · **SetOperationsTest.intersectByteArray** — kotlin.AssertionError: Expected <[5]>, actual <[]>.
- `collections/SetOperationsTest.kt` · **SetOperationsTest.intersectShortArray** — kotlin.AssertionError: Expected <[5]>, actual <[]>.
- `collections/UnsignedArraysTest.kt` · **UnsignedArraysTest.asList** — kotlin.AssertionError: Should reflect changes in original array. Expected <10>, actual <5>.
- `collections/UnsignedArraysTest.kt` · **UnsignedArraysTest.contentHashCode** — kotlin.AssertionError: Expected <0>, actual <kotlin.Unit>.
- `collections/UnsignedArraysTest.kt` · **UnsignedArraysTest.contentToString** — kotlin.AssertionError: Expected <null>, actual <kotlin.Unit>.
- `collections/UnsignedArraysTest.kt` · **UnsignedArraysTest.reduceRightIndexed** — kotlin.AssertionError: Expected <1>, actual <4294967295>.
- `collections/UnsignedArraysTest.kt` · **UnsignedArraysTest.reduceRightIndexedOrNull** — kotlin.AssertionError: Expected <1>, actual <4294967295>.
- `collections/UnsignedArraysTest.kt` · **UnsignedArraysTest.toArray** — kotlin.AssertionError: Expected <0>, actual <0>.
- `collections/UnsignedArraysTest.kt` · **UnsignedArraysTest.toUnsignedArray** — kotlin.AssertionError: Expected <[1, 2, 3]>, actual <[1, 2, 3]>.
- `comparisons/OrderingTest.kt` · **OrderingTest.reversedComparator** — kotlin.AssertionError: Expected <Comparator>, actual <Comparator>.
- `concurrent/atomics/AtomicArrayCommonTest.kt` · **AtomicArrayTest.fetchAndUpdateAt** — kotlin.AssertionError: Expected <[Data(value=1), Data(value=6), Data(value=3)]>, actual <[AtomicArrayTest$Data(value=1), AtomicArrayTest$Dat
- `concurrent/atomics/AtomicArrayCommonTest.kt` · **AtomicArrayTest.toStringTest** — kotlin.AssertionError: Expected <[Data(value=0), Data(value=1), Data(value=2)]>, actual <[AtomicArrayTest$Data(value=0), AtomicArrayTest$Dat
- `concurrent/atomics/AtomicArrayCommonTest.kt` · **AtomicArrayTest.updateAndFetchAt** — kotlin.AssertionError: Expected <[Data(value=1), Data(value=6), Data(value=3)]>, actual <[AtomicArrayTest$Data(value=1), AtomicArrayTest$Dat
- `concurrent/atomics/AtomicArrayCommonTest.kt` · **AtomicArrayTest.updateAt** — kotlin.AssertionError: Expected <[Data(value=1), Data(value=6), Data(value=3)]>, actual <[AtomicArrayTest$Data(value=1), AtomicArrayTest$Dat
- `concurrent/atomics/AtomicArrayCommonTest.kt` · **AtomicLongArrayTest.fetchAndUpdateAt** — kotlin.AssertionError: Expected <2>, actual <2>.
- `concurrent/atomics/AtomicArrayCommonTest.kt` · **AtomicLongArrayTest.updateAndFetchAt** — kotlin.AssertionError: Expected <6>, actual <6>.
- `concurrent/atomics/AtomicCommonTest.kt` · **AtomicLongTest.addAndGet** — kotlin.AssertionError: Expected <3>, actual <3>.
- `concurrent/atomics/AtomicCommonTest.kt` · **AtomicLongTest.compareAndExchange** — kotlin.AssertionError: Expected <0>, actual <0>.
- `concurrent/atomics/AtomicCommonTest.kt` · **AtomicLongTest.ctor** — kotlin.AssertionError: Expected <0>, actual <0>.
- `concurrent/atomics/AtomicCommonTest.kt` · **AtomicLongTest.setter** — kotlin.AssertionError: Expected <1>, actual <1>.
- `concurrent/atomics/AtomicCommonTest.kt` · **AtomicReferenceTest.toStringTest** — kotlin.AssertionError: Expected <Data(value=42)>, actual <AtomicReferenceTest$Data(value=42)>.
- `coroutines/SequenceBuilderTest.kt` · **SequenceBuilderTest.testParallelIteration** — kotlin.AssertionError: Expected <[(1, 2), (6, 8), (15, 18)]>, actual <[(1, 1), (4, 4), (9, 9)]>.
- `coroutines/SequenceBuilderTest.kt` · **SequenceBuilderTest.testYieldAllSideEffects** — kotlin.AssertionError: Expected <[a, (, 1, ), (, 2, ), b, c, (, 3, ), d, (, 4, ), e, f, (, 5, )]>, actual <[a, b, c, d, e, f, (, 1, ), (, 2,
- `enums/EnumEntriesFactoryTest.kt` · **EnumEntriesFactoryTest.testByCallableReference** — kotlin.AssertionError: Expected <[]>, actual <kotlin.Unit>.
- `enums/EnumEntriesFactoryTest.kt` · **EnumEntriesFactoryTest.testEquality** — kotlin.AssertionError: Expected <[]>, actual <kotlin.Unit>.
- `enums/EnumEntriesListTest.kt` · **EnumEntriesListTest.testyEnumBehaviour** — kotlin.AssertionError: hashCode. Expected <195166770>, actual <114229>.
- `exceptions/ExceptionTest.kt` · **ExceptionTest.circularSuppressedDetailedTrace** — kotlin.AssertionError: Expected to find kotlin.RuntimeException: e1 3 times, but found 1 times in kotlin.RuntimeException: e1
- `exceptions/ExceptionTest.kt` · **ExceptionTest.exceptionDetailedTrace** — kotlin.AssertionError: Expected top level trace: kotlin.RuntimeException: Induced
- `exceptions/ExceptionTest.kt` · **ExceptionTest.uninitializedPropertyAccessException** — kotlin.AssertionError: Expected <message>, actual <null>.
- `generated/minmax/MinMaxLongArrayTest.kt` · **MinMaxLongArrayTest.minMaxOf** — kotlin.AssertionError: Expected <-1>, actual <-1>.
- `generated/minmax/MinMaxLongArrayTest.kt` · **MinMaxLongArrayTest.minMaxOfWith** — kotlin.AssertionError: Expected <-1>, actual <-1>.
- `numbers/FloorDivModTest.kt` · **FloorDivModTest.doubleMod** — kotlin.AssertionError: a: 1.0, b: NaN, rem: NaN, mod: NaN
- `numbers/FloorDivModTest.kt` · **FloorDivModTest.floatMod** — kotlin.AssertionError: a: 1.0, b: NaN, rem: NaN, mod: NaN
- `numbers/FloorDivModTest.kt` · **FloorDivModTest.longIntMod** — kotlin.AssertionError: a: 9223372036854775807, b: 2, div: 4611686018427387903, rem: 1, floorDiv: 4611686018427387903, mod: 1
- `numbers/MathTest.kt` · **DoubleMathTest.cubeRoots** — kotlin.AssertionError: Expected <NaN>, actual <NaN>.
- `numbers/MathTest.kt` · **DoubleMathTest.nextAndPrev** — kotlin.AssertionError: Expected <1.99584030953472E292>, actual <Infinity>.
- `numbers/MathTest.kt` · **DoubleMathTest.rounding** — kotlin.AssertionError: Expected <NaN>, actual <NaN>.
- `numbers/MathTest.kt` · **FloatMathTest.cubeRoots** — kotlin.AssertionError: Expected <NaN>, actual <NaN>.
- `numbers/MathTest.kt` · **FloatMathTest.rounding** — kotlin.AssertionError: Expected <NaN>, actual <NaN>.
- `numbers/NaNPropagationTest.kt` · **NaNTotalOrderTest.arrayTMinOrNull** — kotlin.AssertionError: arrayOf().minOrNull()(0, NaN). Expected <0.0>, actual <NaN>.
- `numbers/NaNPropagationTest.kt` · **NaNTotalOrderTest.listTMinOrNull** — kotlin.AssertionError: listOf().minOrNull()(0, NaN). Expected <0.0>, actual <NaN>.
- `numbers/NaNPropagationTest.kt` · **NaNTotalOrderTest.sequenceTMinOrNull** — kotlin.AssertionError: sequenceOf().minOrNull()(0, NaN). Expected <0.0>, actual <NaN>.
- `numbers/NumbersTest.kt` · **NumbersTest.doubleToBits** — kotlin.AssertionError: Expected <9221120237041090560>, actual <-2251799813685248>.
- `numbers/NumbersTest.kt` · **NumbersTest.longBits** — kotlin.AssertionError: Expected <0>, actual <0>.
- `random/RandomTest.kt` · **DefaultRandomSmokeTest.nextLong** — kotlin.AssertionError: All one bits should present. Expected <-1>, actual <-1>.
- `random/RandomTest.kt` · **DefaultRandomSmokeTest.nextUBytesRange** — kotlin.AssertionError: Something should have changed in array after subrange [96, 97) randomization (5 times: [34]
- `random/RandomTest.kt` · **DefaultRandomSmokeTest.nextULongFromUntil** — kotlin.AssertionError: Value 15598648909837301477 must be in range [0, 18446744073709551615)
- `random/RandomTest.kt` · **DefaultRandomSmokeTest.nextULongInULongRange** — kotlin.AssertionError: Value 13171701960225333507 must be in range 0..-2
- `random/RandomTest.kt` · **DefaultRandomSmokeTest.nextULongUntil** — kotlin.AssertionError: Value 772047628145590320 must be in range [0, 18446744073709551615)
- `random/RandomTest.kt` · **SeededRandomSmokeTest.nextLong** — kotlin.AssertionError: All one bits should present. Expected <-1>, actual <-1>.
- `random/RandomTest.kt` · **SeededRandomSmokeTest.nextUBytesRange** — kotlin.AssertionError: Something should have changed in array after subrange [57, 65) randomization (1 times: [215, 226, 96, 80, 30, 152, 20
- `random/RandomTest.kt` · **SeededRandomSmokeTest.nextULongFromUntil** — kotlin.AssertionError: Value 14630229335728632109 must be in range [0, 18446744073709551615)
- `random/RandomTest.kt` · **SeededRandomSmokeTest.nextULongInULongRange** — kotlin.AssertionError: Value 16362033673418216185 must be in range 0..-2
- `random/RandomTest.kt` · **SeededRandomSmokeTest.nextULongUntil** — kotlin.AssertionError: Value 16939324396845005737 must be in range [0, 18446744073709551615)
- `ranges/RangeIterationTest.kt` · **RangeIterationTest.overflowZeroDownToMaxValue** — kotlin.AssertionError: Expected <0>, actual <0>.
- `ranges/RangeIterationTest.kt` · **RangeIterationTest.overflowZeroToMinValue** — kotlin.AssertionError: Expected <0>, actual <0>.
- `reflection/KClassTest.kt` · **KClassTest.className** — kotlin.AssertionError: Expected <null>, actual <$anon$0>.
- `reflection/KClassTest.kt` · **KClassTest.extendsKClassifier** — kotlin.AssertionError: Expected value class KClassTest to have class KClassifier type
- `text/CharTest.kt` · **CharTest.titlecase** — kotlin.AssertionError: Expected <ʼN>, actual <ʼn>.
- `text/RegexTest.kt` · **RegexTest.matchAt** — kotlin.AssertionError: Expected <[3, 8]>, actual <[3]>.
- `text/RegexTest.kt` · **RegexTest.matchMultiline** — kotlin.AssertionError: Expected <[test, , Line]>, actual <[]>.
- `text/RegexTest.kt` · **RegexTest.matchSequence** — kotlin.AssertionError: Expected <[456, 789]>, actual <[123, 456, 789]>.
- `text/RegexTest.kt` · **RegexTest.replaceWithNamedGroups** — kotlin.AssertionError: Expected <1230+456>, actual <+456>.
- `text/RegexTest.kt` · **RegexTest.replaceWithNamedOptionalGroups** — kotlin.AssertionError: Expected <[Hi, ]gh wall>, actual <High wall>.
- `text/RegexTest.kt` · **RegexTest.splitByEmptyMatch** — kotlin.AssertionError: Expected <[, t, e, s, t, ]>, actual <[t, e, s, t, ]>.
- `text/StringBuilderTest.kt` · **StringBuilderTest.appendChar** — kotlin.AssertionError: Expected <aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa𐀀>, 
- `text/StringBuilderTest.kt` · **StringBuilderTest.appendLine** — kotlin.AssertionError: Expected <c
- `text/StringBuilderTest.kt` · **StringBuilderTest.reverse** — kotlin.AssertionError: Expected <𐀀my re𐐁verse test𐠂>, actual <��my re��verse test𐠂>.
- `text/StringBuilderTest.kt` · **StringBuilderTest.toCharArray** — kotlin.AssertionError: Expected <________my>, actual <__________>.
- `text/StringEncodingTest.kt` · **StringEncodingTest.decodeToStringSlice** — kotlin.AssertionError: Expected <�>, actual <��>.
- `text/StringTest.kt` · **StringTest.commonPrefix** — kotlin.AssertionError: Expected <🁘>, actual <🁘🁘>.
- `text/StringTest.kt` · **StringTest.commonSuffix** — kotlin.AssertionError: Expected <🁘>, actual <>.
- `text/StringTest.kt` · **StringTest.indexOfCharIgnoreCase** — kotlin.AssertionError: Expected <2>, actual <4>.
- `text/StringTest.kt` · **StringTest.indexOfStringIgnoreCase** — kotlin.AssertionError: Expected <1>, actual <0>.
- `text/StringTest.kt` · **StringTest.lowercase** — kotlin.AssertionError: Expected <�𐑏���>, actual <�𐐧���>.
- `text/StringTest.kt` · **StringTest.onEachIndexed** — kotlin.AssertionError: Expected <abcd>, actual <abcd> is not same.
- `text/StringTest.kt` · **StringTest.orEmpty** — kotlin.AssertionError: Expected <>, actual <[]>.
- `text/StringTest.kt` · **StringTest.removePrefixCharSequence** — kotlin.AssertionError: Removes prefix. Expected <fix>, actual <prefix>.
- `text/StringTest.kt` · **StringTest.removeSuffixCharSequence** — kotlin.AssertionError: Removes suffix. Expected <suf>, actual <suffix>.
- `text/StringTest.kt` · **StringTest.removeSurroundingCharSequence** — kotlin.AssertionError: Expected <value>, actual <<value>>.
- `text/StringTest.kt` · **StringTest.replace** — kotlin.AssertionError: Expected </bb/b>, actual <abb/b>.
- `text/StringTest.kt` · **StringTest.replaceFirst** — kotlin.AssertionError: Expected <$bbabA>, actual <kotlin.Unit>.
- `text/StringTest.kt` · **StringTest.stringFromCharArraySlice** — kotlin.AssertionError: Expected <rule>, actual <Kotlin rules>.
- `text/StringTest.kt` · **StringTest.stringFromCharArrayUnicodeSurrogatePairs** — kotlin.AssertionError: Expected <月>, actual <Ц月語Ŭᎍ🀺>.
- `text/StringTest.kt` · **StringTest.trimEnd** — kotlin.AssertionError: Expected <a>, actual <a >.
- `text/StringTest.kt` · **StringTest.trimMargin** — kotlin.AssertionError: Expected <>, actual <                            >.
- `text/StringTest.kt` · **StringTest.trimStart** — kotlin.AssertionError: Expected <a>, actual < a>.
- `text/StringTest.kt` · **StringTest.uppercase** — kotlin.AssertionError: Expected <𐪼𐐀>, actual <𐪼𐐨>.
- `time/DurationTest.kt` · **DurationTest.componentsOfCarriedSum** — kotlin.AssertionError: Expected <1>, actual <1>.
- `time/DurationTest.kt` · **DurationTest.conversionToNumber** — kotlin.AssertionError: Expected <24>, actual <24>.
- `time/DurationTest.kt` · **DurationTest.parseAndFormatInUnits** — kotlin.AssertionError: Expected <[2, d]>, actual <[2d, 1.6d]>.
- `time/DurationTest.kt` · **DurationTest.parseAndFormatIsoString** — kotlin.AssertionError: Expected <P>, actual <PT0S>.
- `time/InstantTest.kt` · **InstantTest.toEpochMilliseconds** — kotlin.AssertionError: Expected <1>, actual <1>.
- `time/TimeMarkTest.kt` · **TimeMarkTest.defaultTimeMarkAdjustmentInfinite** — kotlin.AssertionError: Expected <ValueTimeMark(reading=9223372036854775807)>, actual <ValueTimeMark(reading=9223372036854775807)>.
- `time/TimeSourceClockTest.kt` · **TimeSourceClockTest.syncMultipleClocksFromTimeSource** — kotlin.AssertionError: Expected <0>, actual <0>.
- `uuid/UuidTest.kt` · **UuidTest.testV7UuidGenerationForNonMonotonicClock** — kotlin.AssertionError: Expected <1>, actual <1>.
- `uuid/UuidTest.kt` · **UuidTest.toLongs** — kotlin.AssertionError: Expected <0>, actual <0>.

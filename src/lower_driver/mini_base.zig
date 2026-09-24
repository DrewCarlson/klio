//! The executable miniature base: `package kotlin` declarations in the
//! style of the base library, with real bodies and bodyless declarations
//! bound to `natives`, so a test program runs end to end.
//!
//! Bodyless members of the primitive classes are either primitive
//! operations lowering binds from its operator table (`plus`, `not`, ...)
//! or natives (`equals`, `toString`, conversions). Everything that can be
//! written in Kotlin is: `println` converts its argument with a `toString`
//! call before a native writes the text, so no native renders an instance.

pub const File = struct { path: []const u8, source: []const u8 };

/// The base layer's files, in the order sema adds them.
pub const files: []const File = &.{
    .{ .path = "mini/kotlin/Core.kt", .source = core },
    .{ .path = "mini/kotlin/Primitives.kt", .source = primitives },
    .{ .path = "mini/kotlin/Throwable.kt", .source = throwables },
    .{ .path = "mini/kotlin/Standard.kt", .source = standard },
    .{ .path = "mini/kotlin/collections/Collections.kt", .source = collections },
    .{ .path = "mini/kotlin/ranges/Ranges.kt", .source = ranges },
    .{ .path = "mini/kotlin/io/Console.kt", .source = io },
    .{ .path = "mini/kotlin/reflect/Reflect.kt", .source = reflect },
    .{ .path = "mini/kotlin/coroutines/Continuation.kt", .source = coroutines },
    .{ .path = "mini/klio/Throwables.kt", .source = klio_throwables },
    .{ .path = "mini/klio/test/HostBound.kt", .source = host_bound },
};

pub const core =
    \\package kotlin
    \\
    \\public open class Any {
    \\    public open operator fun equals(other: Any?): Boolean
    \\    public open fun hashCode(): Int
    \\    public open fun toString(): String
    \\}
    \\
    \\public class Nothing private constructor()
    \\
    \\public object Unit {
    \\    override fun toString(): String = "kotlin.Unit"
    \\}
    \\
    \\public interface Annotation
    \\public annotation class UnsafeVariance
    \\
    \\public annotation class Suppress(vararg val names: String)
    \\
    \\public interface Comparable<in T> {
    \\    public operator fun compareTo(other: T): Int
    \\}
    \\
    \\public interface CharSequence {
    \\    public val length: Int
    \\    public operator fun get(index: Int): Char
    \\}
    \\
    \\public class String private constructor() : Comparable<String>, CharSequence {
    \\    public operator fun plus(other: Any?): String = __concat(this, other.toString())
    \\    public override val length: Int
    \\    public override fun get(index: Int): Char
    \\    public override fun compareTo(other: String): Int
    \\    public override fun equals(other: Any?): Boolean
    \\    public override fun hashCode(): Int
    \\    public override fun toString(): String = this
    \\}
    \\
    \\internal fun __concat(a: String, b: String): String
    \\internal fun __className(value: Any): String
    \\
    \\public fun Any?.toString(): String = this?.toString() ?: "null"
    \\public fun Any?.hashCode(): Int = this?.hashCode() ?: 0
    \\public operator fun String?.plus(other: Any?): String = (this ?: "null") + other
    \\
    \\public interface Function<out R>
    \\
    \\public class Array<T> private constructor() {
    \\    public val size: Int
    \\    public operator fun get(index: Int): T
    \\    public operator fun set(index: Int, value: T): Unit
    \\    public operator fun iterator(): Iterator<T> = ArrayIterator(this)
    \\}
    \\
    \\internal class ArrayIterator<T>(private val array: Array<T>) : Iterator<T> {
    \\    private var index = 0
    \\    override fun hasNext(): Boolean = index < array.size
    \\    override fun next(): T {
    \\        val i = index
    \\        index = i + 1
    \\        return array[i]
    \\    }
    \\}
    \\
    \\public class IntArray private constructor() {
    \\    public val size: Int
    \\    public operator fun get(index: Int): Int
    \\    public operator fun set(index: Int, value: Int): Unit
    \\    public operator fun iterator(): IntIterator = IntArrayIterator(this)
    \\}
    \\
    \\internal class IntArrayIterator(private val array: IntArray) : IntIterator() {
    \\    private var index = 0
    \\    override fun hasNext(): Boolean = index < array.size
    \\    override fun nextInt(): Int {
    \\        val i = index
    \\        index = i + 1
    \\        return array[i]
    \\    }
    \\}
    \\
    \\public fun <T> arrayOf(vararg elements: T): Array<T>
    \\public fun <T> arrayOfNulls(size: Int): Array<T?>
    \\public fun intArrayOf(vararg elements: Int): IntArray
    \\/** Joins arrays of one kind into a new one: a call's `*spread` arguments. */
    \\public fun __klio_arrayConcat(parts: Array<out Any>): Any
    \\
    \\public abstract class Enum<E : Enum<E>>(name: String, ordinal: Int) : Comparable<E> {
    \\    public val name: String = name
    \\    public val ordinal: Int = ordinal
    \\    public final override fun compareTo(other: E): Int = ordinal - other.ordinal
    \\    public final override fun equals(other: Any?): Boolean = this === other
    \\    public final override fun hashCode(): Int = super.hashCode()
    \\    public override fun toString(): String = name
    \\}
    \\
    \\public data class Pair<out A, out B>(public val first: A, public val second: B) {
    \\    public override fun toString(): String = "(" + first + ", " + second + ")"
    \\}
    \\
    \\public infix fun <A, B> A.to(that: B): Pair<A, B> = Pair(this, that)
    \\
    \\/** The compiler's: `T`'s own `values()` and `valueOf(name)`. */
    \\public inline fun <reified T : Enum<T>> enumValues(): Array<T> = throw IllegalStateException("an intrinsic")
    \\public inline fun <reified T : Enum<T>> enumValueOf(name: String): T = throw IllegalStateException("an intrinsic")
    \\
;

/// `Boolean`, `Char`, `Number`, the six numeric classes and the unsigned
/// classes. The numeric classes are generated: every arithmetic operator
/// and `compareTo` against every numeric type, with Kotlin's result types.
pub const primitives = primitives_head ++ numbers ++ unsigned;

const primitives_head =
    \\package kotlin
    \\
    \\public class Boolean private constructor() : Comparable<Boolean> {
    \\    public operator fun not(): Boolean
    \\    public infix fun and(other: Boolean): Boolean
    \\    public infix fun or(other: Boolean): Boolean
    \\    public infix fun xor(other: Boolean): Boolean
    \\    public override fun compareTo(other: Boolean): Int
    \\    public override fun toString(): String
    \\    public override fun equals(other: Any?): Boolean
    \\    public override fun hashCode(): Int
    \\}
    \\
    \\public class Char private constructor() : Comparable<Char> {
    \\    public val code: Int
    \\    public operator fun plus(other: Int): Char
    \\    public operator fun minus(other: Char): Int
    \\    public operator fun minus(other: Int): Char
    \\    public operator fun inc(): Char
    \\    public operator fun dec(): Char
    \\    public override fun compareTo(other: Char): Int
    \\    public override fun toString(): String
    \\    public override fun equals(other: Any?): Boolean
    \\    public override fun hashCode(): Int
    \\}
    \\
    \\public abstract class Number {
    \\    public abstract fun toDouble(): Double
    \\    public abstract fun toFloat(): Float
    \\    public abstract fun toLong(): Long
    \\    public abstract fun toInt(): Int
    \\    public abstract fun toShort(): Short
    \\    public abstract fun toByte(): Byte
    \\}
    \\
;

const unsigned =
    \\public class UByte private constructor()
    \\public class UShort private constructor()
    \\public class UInt private constructor()
    \\public class ULong private constructor()
    \\
;

const Num = struct { name: []const u8, rank: u8, integral: bool };

const nums = [_]Num{
    .{ .name = "Byte", .rank = 0, .integral = true },
    .{ .name = "Short", .rank = 1, .integral = true },
    .{ .name = "Int", .rank = 2, .integral = true },
    .{ .name = "Long", .rank = 3, .integral = true },
    .{ .name = "Float", .rank = 4, .integral = false },
    .{ .name = "Double", .rank = 5, .integral = false },
};

/// The result of `a op b`: at least `Int`, else the wider operand.
fn resultOf(a: Num, b: Num) []const u8 {
    const r = @max(@as(u8, 2), @max(a.rank, b.rank));
    return nums[r].name;
}

const numbers = blk: {
    @setEvalBranchQuota(200_000);
    var out: []const u8 = "";
    for (nums) |t| {
        out = out ++ "public class " ++ t.name ++ " private constructor() : Number(), Comparable<" ++ t.name ++ "> {\n";
        for (nums) |u| {
            const other = if (std.mem.eql(u8, t.name, u.name)) "public override operator fun" else "public operator fun";
            out = out ++ "    " ++ other ++ " compareTo(other: " ++ u.name ++ "): Int\n";
        }
        for ([_][]const u8{ "plus", "minus", "times", "div", "rem" }) |op| {
            for (nums) |u| {
                out = out ++ "    public operator fun " ++ op ++ "(other: " ++ u.name ++ "): " ++ resultOf(t, u) ++ "\n";
            }
        }
        const promoted = if (t.rank < 2) "Int" else t.name;
        out = out ++ "    public operator fun inc(): " ++ t.name ++ "\n";
        out = out ++ "    public operator fun dec(): " ++ t.name ++ "\n";
        out = out ++ "    public operator fun unaryPlus(): " ++ promoted ++ "\n";
        out = out ++ "    public operator fun unaryMinus(): " ++ promoted ++ "\n";
        for (nums) |u| {
            out = out ++ "    public override fun to" ++ u.name ++ "(): " ++ u.name ++ "\n";
        }
        if (std.mem.eql(u8, t.name, "Int")) {
            out = out ++
                \\    public fun toChar(): Char
                \\    public operator fun rangeTo(other: Int): IntRange = IntRange(this, other)
                \\    public operator fun rangeUntil(other: Int): IntRange = IntRange(this, other - 1)
                \\    public companion object {
                \\        public const val MIN_VALUE: Int = -2147483647 - 1
                \\        public const val MAX_VALUE: Int = 2147483647
                \\    }
                \\
            ;
        }
        if (std.mem.eql(u8, t.name, "Long")) {
            out = out ++
                \\    public companion object {
                \\        public const val MIN_VALUE: Long = -9223372036854775807L - 1L
                \\        public const val MAX_VALUE: Long = 9223372036854775807L
                \\    }
                \\
            ;
        }
        if (t.rank == 2 or t.rank == 3) {
            out = out ++ "    public infix fun shl(bitCount: Int): " ++ t.name ++ "\n";
            out = out ++ "    public infix fun shr(bitCount: Int): " ++ t.name ++ "\n";
            out = out ++ "    public infix fun ushr(bitCount: Int): " ++ t.name ++ "\n";
            out = out ++ "    public infix fun and(other: " ++ t.name ++ "): " ++ t.name ++ "\n";
            out = out ++ "    public infix fun or(other: " ++ t.name ++ "): " ++ t.name ++ "\n";
            out = out ++ "    public infix fun xor(other: " ++ t.name ++ "): " ++ t.name ++ "\n";
            out = out ++ "    public fun inv(): " ++ t.name ++ "\n";
        }
        out = out ++
            \\    public override fun toString(): String
            \\    public override fun equals(other: Any?): Boolean
            \\    public override fun hashCode(): Int
            \\}
            \\
            \\
        ;
    }
    break :blk out;
};

pub const throwables =
    \\package kotlin
    \\
    \\public open class Throwable(public open val message: String?, public open val cause: Throwable?) {
    \\    public constructor(message: String?) : this(message, null)
    \\    public constructor() : this(null, null)
    \\    public override fun toString(): String {
    \\        val m = message
    \\        val n = __className(this)
    \\        return if (m == null) n else n + ": " + m
    \\    }
    \\}
    \\
    \\public open class Exception : Throwable {
    \\    public constructor() : super()
    \\    public constructor(message: String?) : super(message)
    \\    public constructor(message: String?, cause: Throwable?) : super(message, cause)
    \\}
    \\
    \\public open class Error : Throwable {
    \\    public constructor() : super()
    \\    public constructor(message: String?) : super(message)
    \\    public constructor(message: String?, cause: Throwable?) : super(message, cause)
    \\}
    \\
    \\public open class RuntimeException : Exception {
    \\    public constructor() : super()
    \\    public constructor(message: String?) : super(message)
    \\    public constructor(message: String?, cause: Throwable?) : super(message, cause)
    \\}
    \\
    \\public open class IllegalStateException : RuntimeException {
    \\    public constructor() : super()
    \\    public constructor(message: String?) : super(message)
    \\}
    \\
    \\public open class IllegalArgumentException : RuntimeException {
    \\    public constructor() : super()
    \\    public constructor(message: String?) : super(message)
    \\}
    \\
    \\public open class NullPointerException : RuntimeException {
    \\    public constructor() : super()
    \\    public constructor(message: String?) : super(message)
    \\}
    \\
    \\public open class ClassCastException : RuntimeException {
    \\    public constructor() : super()
    \\    public constructor(message: String?) : super(message)
    \\}
    \\
    \\public open class IndexOutOfBoundsException : RuntimeException {
    \\    public constructor() : super()
    \\    public constructor(message: String?) : super(message)
    \\}
    \\
    \\public open class ArithmeticException : RuntimeException {
    \\    public constructor() : super()
    \\    public constructor(message: String?) : super(message)
    \\}
    \\
    \\public open class NoSuchElementException : RuntimeException {
    \\    public constructor() : super()
    \\    public constructor(message: String?) : super(message)
    \\}
    \\
    \\public open class UnsupportedOperationException : RuntimeException {
    \\    public constructor() : super()
    \\    public constructor(message: String?) : super(message)
    \\}
    \\
    \\public class UninitializedPropertyAccessException : RuntimeException {
    \\    public constructor() : super()
    \\    public constructor(message: String?) : super(message)
    \\}
    \\
    \\public open class NoWhenBranchMatchedException : RuntimeException {
    \\    public constructor() : super()
    \\    public constructor(message: String?) : super(message)
    \\}
    \\
    \\public class NotImplementedError : Error {
    \\    public constructor() : super("An operation is not implemented.")
    \\    public constructor(message: String) : super(message)
    \\}
    \\
;

/// A library's `expect` the host implements, as a pack's
/// `io.ktor.util.date.getTimeMillis` is.
pub const host_bound =
    \\package klio.test
    \\
    \\public expect val hostAnswer: Int
    \\
;

/// The throwables klio raises that Kotlin has no common name for: a failed
/// object's or file's initialization, an array or string index out of range.
pub const klio_throwables =
    \\package klio
    \\
    \\public open class LinkageError(message: String?, cause: Throwable?) : Error(message, cause)
    \\
    \\public open class ExceptionInInitializerError(message: String?, thrown: Throwable?) : LinkageError(message, thrown)
    \\
    \\public open class NoClassDefFoundError(message: String?, cause: Throwable?) : LinkageError(message, cause)
    \\
    \\public open class ArrayIndexOutOfBoundsException : IndexOutOfBoundsException {
    \\    public constructor() : super()
    \\    public constructor(message: String?) : super(message)
    \\}
    \\
    \\public open class StringIndexOutOfBoundsException : IndexOutOfBoundsException {
    \\    public constructor() : super()
    \\    public constructor(message: String?) : super(message)
    \\}
    \\
;

pub const standard =
    \\package kotlin
    \\
    \\import kotlin.reflect.KProperty
    \\import kotlin.reflect.KProperty0
    \\
    \\/** A compiler intrinsic: the body never runs. */
    \\public inline val KProperty0<*>.isInitialized: Boolean
    \\    get() = false
    \\
    \\public inline fun <T, R> T.let(block: (T) -> R): R = block(this)
    \\
    \\public inline fun <T> T.also(block: (T) -> Unit): T {
    \\    block(this)
    \\    return this
    \\}
    \\
    \\public inline fun <T> T.apply(block: T.() -> Unit): T {
    \\    block()
    \\    return this
    \\}
    \\
    \\public inline fun <R> run(block: () -> R): R = block()
    \\
    \\public inline fun <T, R> T.run(block: T.() -> R): R = block()
    \\
    \\public inline fun <T, R> with(receiver: T, block: T.() -> R): R = receiver.block()
    \\
    \\public inline fun <T> T.takeIf(predicate: (T) -> Boolean): T? = if (predicate(this)) this else null
    \\
    \\public inline fun <T> T.takeUnless(predicate: (T) -> Boolean): T? = if (!predicate(this)) this else null
    \\
    \\public inline fun repeat(times: Int, action: (Int) -> Unit) {
    \\    var index = 0
    \\    while (index < times) {
    \\        action(index)
    \\        index = index + 1
    \\    }
    \\}
    \\
    \\public fun TODO(): Nothing = throw NotImplementedError()
    \\
    \\public fun TODO(reason: String): Nothing = throw NotImplementedError("An operation is not implemented: " + reason)
    \\
    \\public fun error(message: Any): Nothing = throw IllegalStateException(message.toString())
    \\
    \\public fun check(value: Boolean) {
    \\    if (!value) throw IllegalStateException("Check failed.")
    \\}
    \\
    \\public inline fun check(value: Boolean, lazyMessage: () -> Any) {
    \\    if (!value) throw IllegalStateException(lazyMessage().toString())
    \\}
    \\
    \\public fun require(value: Boolean) {
    \\    if (!value) throw IllegalArgumentException("Failed requirement.")
    \\}
    \\
    \\public inline fun require(value: Boolean, lazyMessage: () -> Any) {
    \\    if (!value) throw IllegalArgumentException(lazyMessage().toString())
    \\}
    \\
    \\public fun <T : Any> requireNotNull(value: T?): T {
    \\    if (value == null) throw IllegalArgumentException("Required value was null.")
    \\    return value
    \\}
    \\
    \\public fun <T : Any> checkNotNull(value: T?): T {
    \\    if (value == null) throw IllegalStateException("Required value was null.")
    \\    return value
    \\}
    \\
    \\public interface Lazy<out T> {
    \\    public val value: T
    \\    public fun isInitialized(): Boolean
    \\}
    \\
    \\public fun <T> lazy(initializer: () -> T): Lazy<T> = UnsafeLazyImpl(initializer)
    \\
    \\internal object UNINITIALIZED_VALUE
    \\
    \\internal class UnsafeLazyImpl<out T>(init: () -> T) : Lazy<T> {
    \\    private var initializer: (() -> T)? = init
    \\    private var stored: Any? = UNINITIALIZED_VALUE
    \\    override val value: T
    \\        get() {
    \\            if (stored === UNINITIALIZED_VALUE) {
    \\                stored = initializer!!()
    \\                initializer = null
    \\            }
    \\            return stored as T
    \\        }
    \\    override fun isInitialized(): Boolean = stored !== UNINITIALIZED_VALUE
    \\    override fun toString(): String = if (isInitialized()) value.toString() else "Lazy value not initialized yet."
    \\}
    \\
    \\public inline operator fun <T> Lazy<T>.getValue(thisRef: Any?, property: KProperty<*>): T = value
    \\
;

pub const collections =
    \\package kotlin.collections
    \\
    \\public interface Iterator<out T> {
    \\    public operator fun next(): T
    \\    public operator fun hasNext(): Boolean
    \\}
    \\
    \\public interface MutableIterator<out T> : Iterator<T> {
    \\    public fun remove(): Unit
    \\}
    \\
    \\public abstract class IntIterator : Iterator<Int> {
    \\    public final override fun next(): Int = nextInt()
    \\    public abstract fun nextInt(): Int
    \\}
    \\
    \\public interface Iterable<out T> {
    \\    public operator fun iterator(): Iterator<T>
    \\}
    \\
    \\public interface MutableIterable<out T> : Iterable<T> {
    \\    override fun iterator(): MutableIterator<T>
    \\}
    \\
    \\public fun IntArray?.contentToString(): String {
    \\    if (this == null) return "null"
    \\    var s = "["
    \\    var i = 0
    \\    while (i < size) {
    \\        if (i != 0) s = s + ", "
    \\        s = s + this[i].toString()
    \\        i = i + 1
    \\    }
    \\    return s + "]"
    \\}
    \\
    \\public interface Collection<out E> : Iterable<E> {
    \\    public val size: Int
    \\    public fun isEmpty(): Boolean
    \\    public operator fun contains(element: @UnsafeVariance E): Boolean
    \\}
    \\
    \\public interface MutableCollection<E> : Collection<E>, MutableIterable<E> {
    \\    public fun add(element: E): Boolean
    \\}
    \\
    \\public interface List<out E> : Collection<E> {
    \\    public operator fun get(index: Int): E
    \\    public fun indexOf(element: @UnsafeVariance E): Int
    \\}
    \\
    \\public interface MutableList<E> : List<E>, MutableCollection<E> {
    \\    public operator fun set(index: Int, element: E): E
    \\    public fun removeAt(index: Int): E
    \\}
    \\
    \\public interface Map<K, out V> {
    \\    public val size: Int
    \\    public operator fun get(key: K): V?
    \\    public interface Entry<out K, out V> {
    \\        public val key: K
    \\        public val value: V
    \\    }
    \\}
    \\
    \\public open class ArrayList<E> : MutableList<E> {
    \\    private var elements: Array<Any?> = arrayOfNulls<Any?>(8)
    \\    private var count: Int = 0
    \\
    \\    override val size: Int get() = count
    \\
    \\    override fun isEmpty(): Boolean = count == 0
    \\
    \\    override fun get(index: Int): E {
    \\        if (index < 0 || index >= count) throw IndexOutOfBoundsException("Index " + index + " out of bounds for length " + count)
    \\        return elements[index] as E
    \\    }
    \\
    \\    override fun set(index: Int, element: E): E {
    \\        val old = get(index)
    \\        elements[index] = element
    \\        return old
    \\    }
    \\
    \\    override fun add(element: E): Boolean {
    \\        if (count == elements.size) grow()
    \\        elements[count] = element
    \\        count = count + 1
    \\        return true
    \\    }
    \\
    \\    override fun removeAt(index: Int): E {
    \\        val old = get(index)
    \\        var i = index
    \\        while (i < count - 1) {
    \\            elements[i] = elements[i + 1]
    \\            i = i + 1
    \\        }
    \\        count = count - 1
    \\        elements[count] = null
    \\        return old
    \\    }
    \\
    \\    override fun contains(element: E): Boolean = indexOf(element) >= 0
    \\
    \\    override fun indexOf(element: E): Int {
    \\        var i = 0
    \\        while (i < count) {
    \\            if (elements[i] == element) return i
    \\            i = i + 1
    \\        }
    \\        return -1
    \\    }
    \\
    \\    override fun iterator(): MutableIterator<E> = Itr()
    \\
    \\    private fun grow() {
    \\        val bigger = arrayOfNulls<Any?>(elements.size * 2)
    \\        var i = 0
    \\        while (i < count) {
    \\            bigger[i] = elements[i]
    \\            i = i + 1
    \\        }
    \\        elements = bigger
    \\    }
    \\
    \\    override fun toString(): String {
    \\        var s = "["
    \\        var i = 0
    \\        while (i < count) {
    \\            if (i > 0) s = s + ", "
    \\            s = s + elements[i]
    \\            i = i + 1
    \\        }
    \\        return s + "]"
    \\    }
    \\
    \\    private inner class Itr : MutableIterator<E> {
    \\        private var index = 0
    \\        override fun hasNext(): Boolean = index < count
    \\        override fun next(): E {
    \\            val i = index
    \\            index = i + 1
    \\            return get(i)
    \\        }
    \\        override fun remove() {
    \\            index = index - 1
    \\            removeAt(index)
    \\        }
    \\    }
    \\}
    \\
    \\public fun <T> listOf(vararg elements: T): List<T> {
    \\    val list = ArrayList<T>()
    \\    for (e in elements) list.add(e)
    \\    return list
    \\}
    \\
    \\public fun <T> mutableListOf(vararg elements: T): MutableList<T> {
    \\    val list = ArrayList<T>()
    \\    for (e in elements) list.add(e)
    \\    return list
    \\}
    \\
    \\public fun <T> emptyList(): List<T> = ArrayList<T>()
    \\
    \\public inline fun <T> Iterable<T>.forEach(action: (T) -> Unit) {
    \\    for (element in this) action(element)
    \\}
    \\
    \\public inline fun <T, R> Iterable<T>.map(transform: (T) -> R): List<R> {
    \\    val out = ArrayList<R>()
    \\    for (element in this) out.add(transform(element))
    \\    return out
    \\}
    \\
    \\public inline fun <T> Iterable<T>.filter(predicate: (T) -> Boolean): List<T> {
    \\    val out = ArrayList<T>()
    \\    for (element in this) if (predicate(element)) out.add(element)
    \\    return out
    \\}
    \\
    \\public val <T> List<T>.lastIndex: Int get() = size - 1
    \\
;

pub const ranges =
    \\package kotlin.ranges
    \\
    \\public interface ClosedRange<T : Comparable<T>> {
    \\    public val start: T
    \\    public val endInclusive: T
    \\    public operator fun contains(value: T): Boolean = start <= value && value <= endInclusive
    \\    public fun isEmpty(): Boolean = start > endInclusive
    \\}
    \\
    \\public open class IntProgression internal constructor(start: Int, endInclusive: Int, step: Int) : Iterable<Int> {
    \\    public val first: Int = start
    \\    public val last: Int = getProgressionLastElement(start, endInclusive, step)
    \\    public val step: Int = step
    \\
    \\    override fun iterator(): IntIterator = IntProgressionIterator(first, last, step)
    \\
    \\    public open fun isEmpty(): Boolean = if (step > 0) first > last else first < last
    \\
    \\    override fun toString(): String =
    \\        if (step > 0) "" + first + ".." + last + " step " + step else "" + first + " downTo " + last + " step " + (-step)
    \\
    \\    public companion object {
    \\        public fun fromClosedRange(rangeStart: Int, rangeEnd: Int, step: Int): IntProgression = IntProgression(rangeStart, rangeEnd, step)
    \\    }
    \\}
    \\
    \\public class IntRange(start: Int, endInclusive: Int) : IntProgression(start, endInclusive, 1), ClosedRange<Int> {
    \\    override val start: Int get() = first
    \\    override val endInclusive: Int get() = last
    \\    override fun contains(value: Int): Boolean = first <= value && value <= last
    \\    override fun isEmpty(): Boolean = first > last
    \\    override fun toString(): String = "" + first + ".." + last
    \\}
    \\
    \\internal class IntProgressionIterator(first: Int, last: Int, private val step: Int) : IntIterator() {
    \\    private val finalElement: Int = last
    \\    private var more: Boolean = if (step > 0) first <= last else first >= last
    \\    private var next: Int = if (more) first else finalElement
    \\
    \\    override fun hasNext(): Boolean = more
    \\
    \\    override fun nextInt(): Int {
    \\        val value = next
    \\        if (value == finalElement) {
    \\            if (!more) throw NoSuchElementException()
    \\            more = false
    \\        } else {
    \\            next = next + step
    \\        }
    \\        return value
    \\    }
    \\}
    \\
    \\private fun mod(a: Int, b: Int): Int {
    \\    val m = a % b
    \\    return if (m >= 0) m else m + b
    \\}
    \\
    \\private fun differenceModulo(a: Int, b: Int, c: Int): Int = mod(mod(a, c) - mod(b, c), c)
    \\
    \\internal fun getProgressionLastElement(start: Int, end: Int, step: Int): Int = when {
    \\    step > 0 -> if (start >= end) end else end - differenceModulo(end, start, step)
    \\    step < 0 -> if (start <= end) end else end + differenceModulo(start, end, -step)
    \\    else -> throw IllegalArgumentException("Step is zero.")
    \\}
    \\
    \\public infix fun Int.until(to: Int): IntRange = IntRange(this, to - 1)
    \\
    \\public infix fun Int.downTo(to: Int): IntProgression = IntProgression.fromClosedRange(this, to, -1)
    \\
    \\public infix fun IntProgression.step(step: Int): IntProgression {
    \\    if (step <= 0) throw IllegalArgumentException("Step must be positive, was: " + step + ".")
    \\    return IntProgression.fromClosedRange(first, last, if (this.step > 0) step else -step)
    \\}
    \\
    \\public fun IntProgression.reversed(): IntProgression = IntProgression.fromClosedRange(last, first, -step)
    \\
;

pub const io =
    \\package kotlin.io
    \\
    \\public fun println(message: Any?) {
    \\    __writeLine(message.toString())
    \\}
    \\
    \\public fun println() {
    \\    __writeLine("")
    \\}
    \\
    \\public fun print(message: Any?) {
    \\    __write(message.toString())
    \\}
    \\
    \\internal fun __writeLine(message: String)
    \\internal fun __write(message: String)
    \\
;

pub const reflect =
    \\package kotlin.reflect
    \\
    \\public interface KClass<T : Any> {
    \\    public val simpleName: String?
    \\    public val qualifiedName: String?
    \\}
    \\
    \\public interface KCallable<out R> {
    \\    public val name: String
    \\}
    \\
    \\public interface KFunction<out R> : KCallable<R>, Function<R>
    \\
    \\public interface KProperty<out V> : KCallable<V>
    \\
    \\public interface KMutableProperty<V> : KProperty<V>
    \\
    \\public interface KProperty0<out V> : KProperty<V>, () -> V {
    \\    public fun get(): V
    \\}
    \\
    \\public interface KProperty1<T, out V> : KProperty<V>, (T) -> V {
    \\    public fun get(receiver: T): V
    \\}
    \\
    \\public interface KProperty2<D, E, out V> : KProperty<V>, (D, E) -> V {
    \\    public fun get(receiver1: D, receiver2: E): V
    \\}
    \\
    \\public interface KMutableProperty0<V> : KProperty0<V>, KMutableProperty<V> {
    \\    public fun set(value: V)
    \\}
    \\
    \\public interface KMutableProperty1<T, V> : KProperty1<T, V>, KMutableProperty<V> {
    \\    public fun set(receiver: T, value: V)
    \\}
    \\
    \\public interface KMutableProperty2<D, E, V> : KProperty2<D, E, V>, KMutableProperty<V> {
    \\    public fun set(receiver1: D, receiver2: E, value: V)
    \\}
    \\
;

pub const coroutines =
    \\package kotlin.coroutines
    \\
    \\public interface Continuation<in T>
    \\
;

const std = @import("std");

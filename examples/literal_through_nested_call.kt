// A type argument inferred through a nested call is what the values give
// it: `bounded(Holder(123))` for `T : Any` is a `T` of `Int`, not the bound,
// `long(Holder(4))` for `T : Long` makes the literal a `Long`, and
// `listOf(1, 3)` inside `Holder(...)` gives `List<Int>`. A reified type
// argument that only `Nothing` flows into takes the type an expected type
// gives it: `val p: String? by delegate { fail() }` delegates a `String?`.
import kotlin.properties.ReadOnlyProperty
import kotlin.reflect.KClass
import kotlin.reflect.typeOf

class Holder<T>(val v: T)

inline fun <reified T : Any> bounded(value: Holder<T>) = println("bounded: " + T::class.simpleName + " " + value.v)

fun <T : Long> long(value: Holder<T>) = println("long: " + value.v::class.simpleName + " " + value.v)

inline fun <reified T : Comparable<T>> comparable(value: Holder<T>) = println("comparable: " + T::class.simpleName + " " + value.v)

inline fun <reified T : Number> number(value: Holder<T>) = println("number: " + T::class.simpleName + " " + value.v)

inline fun <reified T : Any> elements(value: Holder<T>) {
    val t = typeOf<T>()
    val arg = t.arguments.firstOrNull()?.type?.classifier as KClass<*>?
    println("elements: " + (t.classifier as KClass<*>).simpleName + "<" + arg?.simpleName + "> " + value.v)
}

inline fun <reified T> delegate(noinline init: () -> T): ReadOnlyProperty<Any?, T> {
    val t = typeOf<T>()
    println("delegate of " + (t.classifier as KClass<*>).simpleName + ", nullable " + t.isMarkedNullable)
    return ReadOnlyProperty { _, _ -> init() }
}

fun fail(): Nothing = throw IllegalStateException("never read")

fun main() {
    bounded(Holder(123))
    long(Holder(4))
    comparable(Holder(5))
    number(Holder(6))
    bounded(Holder(3_000_000_000))
    elements(Holder(listOf(1, 3)))
    elements(Holder(mapOf("a" to 1)))
    val nullable: String? by delegate { fail() }
    val list: List<Int> by delegate { fail() }
    val text: String by delegate { "text" }
    println(text)
}

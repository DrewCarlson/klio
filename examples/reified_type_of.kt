// `typeOf<T>()` inside an inline function with a reified `T` describes the
// STATIC type the call bound, never the runtime class of the value: an
// argument declared `Number` binds `T := Number` whatever number it holds,
// and a `List<Int>` keeps its argument. The `KType` it yields compares by
// structure (classifier, arguments, nullability), hashes consistently, and
// renders as the qualified type.
import kotlin.reflect.typeOf

inline fun <reified T> describe(value: T) = typeOf<T>()
inline fun <reified T : Number> numberType(n: T) = typeOf<T>()

fun main() {
    println(describe("text"))
    println(describe(listOf(1, 2)))
    println(describe("text") == typeOf<String>())
    println(describe("text") == describe("other"))
    println(describe("text") == describe(42))
    println(describe("text").hashCode() == typeOf<String>().hashCode())
    val n: Number = 42
    println(numberType(n) == typeOf<Number>())
    println(numberType(n))
    val numbers = listOf<Number>(1, 2.5, 3L)
    println(numbers.all { numberType(it) == typeOf<Number>() })
    println(typeOf<Map<String, List<Int>>>())
    println(typeOf<Map<String, List<Int>>>() == typeOf<Map<String, List<Int>>>())
}

// `null as T` for a non-null `T` throws NullPointerException (not
// ClassCastException); `as?` against an unrelated class answers null even
// when the class has a one-letter name; a definitely-non-null cast
// `t as (T & Any)` throws on null; and a file's own `fun println(String)`
// shadows the stdlib one for bare calls.
class A
class B

fun <T> unchecked(x: Any?) = x as T
fun <T> definitely(t: T) = t as (T & Any)

fun println(s: String) {
    kotlin.io.println("shadowed: $s")
}

fun main() {
    val a = A()
    kotlin.io.println(a as? B)
    kotlin.io.println((a as? B) ?: "none")
    try {
        unchecked<String>(null) as Any
        kotlin.io.println("no exception")
    } catch (e: NullPointerException) {
        kotlin.io.println("NPE")
    }
    try {
        definitely<Any?>(null)
        kotlin.io.println("no exception")
    } catch (e: NullPointerException) {
        kotlin.io.println("NPE")
    }
    kotlin.io.println(definitely("value"))
    println("hi")
}

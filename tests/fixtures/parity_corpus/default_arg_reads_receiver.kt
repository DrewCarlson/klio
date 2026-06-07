// A default argument that reads the extension receiver
// (`fun String.f(end: Int = length)` — `length` is `this.length`) must
// resolve `this` even when the default thunk runs via the named-argument
// fill path. ktor's `String.decodeURLQueryComponent(end: Int = length, …)`
// depends on this — a call passing only `plusIsSpace = …` defaults `end`.
fun String.span(start: Int = 0, end: Int = length): String = substring(start, end)
fun String.tail(from: Int = length - 1): String = substring(from)

fun main() {
    println("hello".span())
    println("hello".span(1))
    println("hello".span(end = 3))
    println("hello".span(start = 2))
    println("world".tail())
}

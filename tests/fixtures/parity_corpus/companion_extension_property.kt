// An extension property on a class's companion (`val C.Companion.tag`) must be
// resolvable from a bare reference inside the companion's own initializers —
// `companion object { val derived = tag }`. ktor's `URLBuilder.Companion`
// reads its `expect val URLBuilder.Companion.origin` extension this way
// (`private val originUrl = Url(origin)`).
class Greeter {
    companion object {
        val greeting: String = prefix + ", world"
        val shout: String = prefix.uppercase() + "!"
    }
}

val Greeter.Companion.prefix: String get() = "hello"

fun main() {
    println(Greeter.greeting)
    println(Greeter.shout)
}

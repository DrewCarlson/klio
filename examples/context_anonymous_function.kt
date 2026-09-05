// An anonymous function can declare context parameters: its type is the
// contextual function type, whose leading parameters are the contexts, so
// `context(x: String) fun (): String { … }` is called as `f("ctx")`, and a
// parameter typed `suspend context(Int) () -> Unit` is invoked the same way.
class Greeter(val greeting: String)

fun greetAll(greeter: Greeter, action: context(Greeter) (String) -> String): String =
    action(greeter, "Kotlin")

typealias Step = suspend context(Int) () -> Unit

fun main() {
    val a = context(x: String) fun (): String { return x + "!" }
    println(a("hello"))
    val b = context(g: Greeter) fun (name: String): String = g.greeting + ", " + name
    println(greetAll(Greeter("Hi"), b))
    println(greetAll(Greeter("Yo"), fun(g: Greeter, name: String) = "${g.greeting} $name"))
    val c = context(n: Int) fun (): Int { return n + 1 }
    println(c(41))
}

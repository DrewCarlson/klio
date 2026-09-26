// A callable reference picks among overloads by what it can be:
// `provide(::Teller)` is never the `KClass` overload, a reference is no
// class; `map(String::trim)` is `String.trim()`, more specific than
// `CharSequence.trim()`, and taken over `trim(vararg chars)` with no chars.
import kotlin.reflect.KClass

class Teller(val name: String)

class Registry {
    inline fun <reified T : Any> provide(kClass: KClass<out T>): String = "kclass " + kClass.simpleName
}

inline fun <reified E, reified I1> Registry.provide(crossinline f: suspend (I1) -> E): String =
    "function " + E::class.simpleName + "(" + I1::class.simpleName + ")"

fun take(name: String, value: String) = println("[$name]=[$value]")

fun main() {
    println(Registry().provide(::Teller))
    println(Registry().provide(Teller::class))

    val (name, value) = " a : b ".split(":").map(String::trim)
    take(name, value)
    val trimmed: List<String> = listOf(" x ", "y ").map(String::trim)
    println(trimmed)
    println(listOf(" z ").map(String::trim).first().length)
}

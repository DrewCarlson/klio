// A reified type argument whose own argument is an intersection: `In<A>` and
// `In<B>` join to `In<A & B>`, and `typeOf` gives the intersection as
// `Nothing`. Arguments no class could satisfy together (`Int` and `String`)
// join to a star.

import kotlin.reflect.KClass
import kotlin.reflect.typeOf

class In<in T>
class Box<T>(val v: T)
interface A
interface B
open class C
class AB : A, B
class BA : B, A

inline fun <reified K> show(label: String, x: K, y: K) {
    val t = typeOf<K>()
    val arg = t.arguments.single().type
    val argName = when {
        arg == null -> "*"
        arg.classifier == Nothing::class -> "Nothing"
        else -> (arg.classifier as? KClass<*>)?.simpleName
    }
    val arr = arrayOf(x, y)
    println("$label: class=${K::class.simpleName} argument=$argName array=${arr is Array<*>} ${arr[0] is In<*>}")
}

fun main() {
    show("In<A>, In<B>", In<A>(), In<B>())
    show("In<B>, In<A>", In<B>(), In<A>())
    show("In<Int>, In<String>", In<Int>(), In<String>())
    show("In<String>, In<Int>", In<String>(), In<Int>())
    show("In<C>, In<A>", In<C>(), In<A>())
    show("Box<A>, Box<A>", Box<A>(AB()), Box<A>(BA()))
}

// A class literal's `toString()` names the class by its qualified name,
// whether it is called directly, reached through `Any`, or rendered by a
// string template or concatenation.
//
// Run with: klio run examples/class_literal_to_string.kt

package demo.reflect

import kotlin.reflect.KClass

open class Shape
class Circle : Shape()

fun describe(k: KClass<*>): String = "$k (${k.simpleName})"

fun main() {
    println(Any::class.toString())
    println(String::class.toString())
    println(Circle::class.toString())

    val k: KClass<*> = Circle::class
    val asAny: Any = k
    println(asAny.toString())

    println("template: $k")
    println("concat: " + Any::class)
    println(describe(Int::class))
    println(describe(List::class))

    val s: Shape = Circle()
    println(describe(s::class))
    println("${Shape::class} and ${s::class}")
}

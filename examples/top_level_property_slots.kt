// A plain stored top-level property is a numbered slot in the root scope: a
// read addresses it by index and a write of a `var` lands in it directly. The
// other shapes keep their own protocol and must read exactly as before: a
// `const val` inlines, a custom getter runs per read, a custom setter runs per
// write, a delegate answers through `getValue`/`setValue`, and a `lateinit`
// throws until it is assigned.

import kotlin.properties.Delegates

const val LIMIT = 3

val greeting = "hello"
var counter = 0
var total: Long = 10L

val computed: Int
    get() = counter * 10

var guarded: Int = 0
    set(value) {
        field = if (value < 0) 0 else value
    }

var observed: String by Delegates.observable("start") { _, old, new ->
    println("observed: $old -> $new")
}

lateinit var late: String

fun bump(): Int {
    counter += 1
    total += counter
    return counter
}

fun readAll(): String = "$greeting $counter $total $computed $guarded $observed"

fun main() {
    println(readAll())
    repeat(LIMIT) { bump() }
    println(readAll())
    guarded = -5
    guarded = 7
    observed = "next"
    val f = { counter += 100; counter }
    println(f())
    println(readAll())
    try {
        println(late.length)
    } catch (e: UninitializedPropertyAccessException) {
        println("late unset")
    }
    late = "set"
    println(late.length)
    println(greeting.length + counter + total.toInt())
}

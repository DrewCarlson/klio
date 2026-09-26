// Each object expression and each local class is a class of its own: two of
// them never share a KClass, while the instances one expression makes do. A
// cache keyed by class (as Compose's node kind cache is) keeps an entry for
// each.
interface Node
open class Base

fun first(): Any = object : Node {}
fun second(): Any = object : Base(), Node {}
fun local1(): Any { class Local; return Local() }
fun local2(): Any { class Local; return Local() }

fun main() {
    println(first()::class == second()::class)
    println(first()::class == first()::class)
    println(local1()::class == local2()::class)
    println(local1()::class == local1()::class)
    println(first()::class.hashCode() == first()::class.hashCode())

    val kinds = HashMap<Any, String>()
    kinds.getOrPut(first()::class) { "node" }
    kinds.getOrPut(second()::class) { "base node" }
    kinds.getOrPut(local1()::class) { "local" }
    println(kinds.size)
    println(kinds[second()::class])
    println(kinds[local2()::class])
}

// `kotlin.Unit` is the singleton `object Unit`; its `Any` methods
// are well-defined. Upstream kotlinx-coroutines' JobSupport state
// machine compares state slots with `==`, and a slot can be `Unit`,
// so `Unit.equals` / `hashCode` / `toString` must resolve.
fun produceUnit(): Any {
    val x: Any = Unit
    return x
}

fun main() {
    val a = produceUnit()
    println(a == Unit)
    println(Unit == Unit)
    println(a.toString())
    println(Unit.hashCode() == Unit.hashCode())
    val notUnit: Any = 5
    println(Unit == notUnit)
    println(notUnit == Unit)
}

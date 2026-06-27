// (c) parent field shadowed by subclass field (same name, separate storage)
open class Base {
    val x: Int = 1
    fun baseX(): Int = x        // resolves to Base.x
}
class Sub : Base() {
    val x: Int = 2              // shadows Base.x
    fun subX(): Int = x         // resolves to Sub.x
    fun superX(): Int = super.x // explicit parent field via super
}

fun main() {
    val s = Sub()
    println("baseX=" + s.baseX())   // 1
    println("subX=" + s.subX())     // 2
    println("superX=" + s.superX()) // 1
    val b: Base = s
    println("asBase.x=" + b.x)      // 1 (static type Base -> Base.x)
}

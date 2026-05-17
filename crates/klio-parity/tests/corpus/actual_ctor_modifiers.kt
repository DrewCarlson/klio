// An explicit primary constructor may combine a visibility modifier
// and delegate to a superclass constructor, including on an abstract
// class. (The `actual`/`expect` modifier variants this also enables
// are exercised by the kotlinx-coroutines bespoke klioMain, which
// kotlinc cannot compile standalone.)
open class B(val tag: String)

class Holder internal constructor(val n: Int) : B("h") {
    fun show(): String = tag + ":" + n
}

abstract class AbsA protected constructor() : B("a") {
    fun who(): String = tag
}
class ConcreteA : AbsA()

fun main() {
    println(Holder(7).show())
    println(ConcreteA().who())
}

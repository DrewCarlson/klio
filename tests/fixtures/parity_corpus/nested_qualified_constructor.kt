class Outer {
    class Inner(val v: Int) {
        class Deep(val w: Int) { fun show(): String = "d$w" }
        fun show(): String = "i$v"
    }
    class Builder {
        fun buildInner(): String = Inner(1).show()
        fun buildDeep(): String = Inner.Deep(2).show()
    }
    fun make(): String = Builder().buildInner() + "/" + Builder().buildDeep()
}
fun main() { println(Outer().make()) }

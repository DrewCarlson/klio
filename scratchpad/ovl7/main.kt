package demo

fun dump(c: Collector) { c.reg(KCls<Int>("A"), SerImpl<Int>("s") as Ser<Any>) }

fun main() {
    val b = Builder()
    dump(b)
    println(b.out)
}

fun main() {
    val xs = buildList {
        add(1)
        add(2)
        add(3)
    }
    println(xs)
    println(xs.sum())
    val s = buildSet {
        add(1.0)
        add(2.0)
    }
    println(s)
}

fun main() {
    val xs = buildList {
        add(1)
        add(2)
        add(3)
    }
    println(xs)
    val s = buildString {
        append("hello")
        append(" ")
        append("world")
    }
    println(s)
    val m = buildMap<String, Int> {
        put("a", 1)
        put("b", 2)
    }
    println(m)
    val st = buildSet {
        add(1)
        add(2)
        add(1)
    }
    println(st)
}

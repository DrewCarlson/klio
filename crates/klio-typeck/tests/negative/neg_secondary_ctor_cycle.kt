class Loopy {
    constructor(a: Int) : this(a, 0)
    constructor(a: Int, b: Int) : this(a)
}

fun main() {
    val l = Loopy(1)
    println(l)
}

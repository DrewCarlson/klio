class Point(val x: Int, val y: Int) {
    constructor(both: Int) : this(both, both)
    constructor() : this(0)

    fun show(): String = "($x, $y)"
}

fun main() {
    println(Point(3, 4).show())
    println(Point(7).show())
    println(Point().show())
}

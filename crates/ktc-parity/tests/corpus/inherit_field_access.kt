open class Point(val x: Int, val y: Int)

class Labeled(x: Int, y: Int, val label: String) : Point(x, y) {
    fun describe(): String = "$label@($x, $y)"
}

fun main() {
    val p = Labeled(3, 4, "origin")
    println(p.x)
    println(p.y)
    println(p.label)
    println(p.describe())
}

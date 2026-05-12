class Box(val x: Int, val y: Int) {
    fun area(): Int = x * y
    fun describe(): String = "Box($x,$y) area=${area()}"
}

fun main() {
    val b = Box(3, 4)
    println(b.x)
    println(b.y)
    println(b.area())
    println(b.describe())
}

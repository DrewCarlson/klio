class Box(val width: Int, val height: Int) {
    val area: Int
        get(): Int = width * height
    val label: String
        get(): String = "$width x $height"
}

fun main() {
    val b = Box(3, 4)
    println(b.area)
    println(b.label)
}

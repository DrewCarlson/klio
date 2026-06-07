class Box(val n: Int) {
    override fun toString(): String = "Box($n)"
}

operator fun Box.plus(other: Box): Box = Box(n + other.n)
operator fun Box.times(k: Int): Box = Box(n * k)

fun main() {
    println(Box(2) + Box(3))
    println(Box(4) * 5)
}

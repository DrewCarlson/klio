// Classes & objects tour.
//
// Demonstrates plain classes, data classes, companion objects, standalone
// object singletons, and a user-defined `operator fun compareTo` used by
// `sortedWith`. Output is deterministic so the parity harness can compare
// it byte-for-byte against kotlinc-native.

class Box(val w: Int, val h: Int) {
    fun area(): Int = w * h
    fun describe(): String = "Box(${w}x$h) area=${area()}"
}

data class Point(val x: Int, val y: Int)

class Circle(val r: Double) {
    fun area(): Double = PI * r * r
    companion object {
        val PI = 3.14
        fun unit(): Circle = Circle(1.0)
    }
}

object Registry {
    var count = 0
    fun bump() { count = count + 1 }
}

class Weight(val grams: Int) : Comparable<Weight> {
    override operator fun compareTo(other: Weight): Int = grams - other.grams
    override fun toString(): String = "${grams}g"
}

fun main() {
    val b = Box(3, 4)
    println(b.describe())
    println(b.area())

    val p = Point(1, 2)
    val q = Point(1, 2)
    val r = p.copy(y = 99)
    println(p)
    println(p == q)
    println(r)
    println(p.component1())
    println(p.component2())

    println(Circle.PI)
    println(Circle.unit().area())
    println(Circle(2.0).area())

    Registry.bump()
    Registry.bump()
    Registry.bump()
    println(Registry.count)

    val xs = listOf(Weight(300), Weight(100), Weight(200))
    for (w in xs.sortedWith(compareBy { it.grams })) {
        println(w)
    }
    for (w in xs.sorted()) {
        println(w)
    }
}

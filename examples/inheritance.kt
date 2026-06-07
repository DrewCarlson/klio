open class Shape(val name: String) {
    open fun area(): Double = 0.0
    open fun describe(): String = "$name area=${area()}"
}

open class Rectangle(val width: Double, val height: Double) : Shape("rectangle") {
    override fun area(): Double = width * height
}

class Square(side: Double) : Rectangle(side, side) {
    override fun describe(): String = "square side=$width ${super.describe()}"
}

open class Counter {
    var count: Int = 0
    open fun bump() {
        count += 1
    }
}

class LoggingCounter : Counter() {
    val log = mutableListOf<Int>()
    override fun bump() {
        super.bump()
        log.add(this.count)
    }
}

class SnapshotCounter : Counter() {
    // After `super.bump()`, the bare-name `count` reads the live instance
    // value rather than a frame-local snapshot captured at method entry.
    fun bumpAndRead(): Int {
        super.bump()
        val now = count
        return now
    }
}

fun main() {
    val r = Rectangle(3.0, 4.0)
    println(r.describe())

    val s = Square(5.0)
    println(s.describe())
    println(s.area())

    val shapes: List<Shape> = listOf(r, s, Shape("blank"))
    for (sh in shapes) {
        println(sh.area())
    }

    val c = LoggingCounter()
    c.bump()
    c.bump()
    c.bump()
    println(c.count)
    println(c.log)

    val sc = SnapshotCounter()
    println(sc.bumpAndRead())
    println(sc.bumpAndRead())
    println(sc.count)
}

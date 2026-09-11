// Properties the source left unannotated, compiled to C. A property's type is
// what its initializer computes, and asking the initializer needs the layouts
// resolved so far — including the fields of its own class ahead of it — so the
// class table is built to a fixed point rather than in one pass.
class Stats(val values: List<Int>) {
    // No annotation: the property's type is what its initializer computes.
    val count = values.size
    val label = "n=" + values.size
    var running = 0
}

class Point(val x: Int, val y: Int) {
    val sum = x + y
    val scaled = sum * 2
}

fun main() {
    val s = Stats(listOf(1, 2, 3))
    println(s.count)
    println(s.label)
    s.running = s.running + 5
    println(s.running)
    val p = Point(3, 4)
    println(p.sum)
    println(p.scaled)
}

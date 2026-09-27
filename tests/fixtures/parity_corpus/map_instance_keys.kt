// HashMap lookups by instance keys: a class's own hashCode and equals,
// identity for a class without them, a key whose hash changes after it
// went in, and removals among many entries.

class Id(val n: Int) {
    override fun equals(other: Any?) = other is Id && other.n == n
    override fun hashCode() = n % 7
}

class Plain(val n: Int)

data class Point(val x: Int, val y: Int)

class Mutable(var n: Int) {
    override fun equals(other: Any?) = other is Mutable && other.n == n
    override fun hashCode() = n
}

class Loud(val n: Int) {
    override fun equals(other: Any?): Boolean {
        if (n < 0 || (other is Loud && other.n < 0)) throw IllegalStateException("equals of a negative")
        return other is Loud && other.n == n
    }
    override fun hashCode() = if (n < 0) 5 else n
}

fun main() {
    val byId = HashMap<Id, String>()
    for (i in 0 until 200) byId[Id(i)] = "v$i"
    println("size ${byId.size}, ${byId[Id(5)]}, ${byId[Id(199)]}, ${byId[Id(200)]}")
    for (i in 0 until 200 step 3) byId.remove(Id(i))
    println("after removes ${byId.size}, ${byId[Id(3)]}, ${byId[Id(4)]}, ${byId.containsKey(Id(198))}, ${byId.containsKey(Id(197))}")
    byId[Id(3)] = "back"
    println("${byId[Id(3)]} ${byId.size} ${byId.keys.sumOf { it.n }}")
    val linked = LinkedHashMap<Id, Int>()
    for (i in 50 downTo 0) linked[Id(i)] = i
    linked.remove(Id(50))
    linked.remove(Id(20))
    linked[Id(50)] = 50
    println("linked ${linked.size} ${linked.keys.first().n} ${linked.keys.last().n} ${linked.keys.take(4).map { it.n }} ${linked[Id(21)]} ${linked[Id(20)]}")
    println("replaced ${byId.put(Id(4), "four")} now ${byId[Id(4)]}")

    val plains = (0 until 40).map { Plain(it) }
    val byPlain = mutableMapOf<Plain, Int>()
    for (p in plains) byPlain[p] = p.n * 2
    println("plain ${byPlain[plains[17]]} ${byPlain[Plain(17)]} ${byPlain.size}")

    val points = HashMap<Point, Int>()
    for (x in 0 until 10) for (y in 0 until 10) points[Point(x, y)] = x * 10 + y
    println("points ${points[Point(3, 4)]} ${points[Point(9, 9)]} ${points[Point(10, 0)]}")
    points.remove(Point(3, 4))
    println("points ${points[Point(3, 4)]} ${points.size} ${points.getOrPut(Point(3, 4)) { -1 }} ${points.size}")

    val muts = HashMap<Mutable, String>()
    val ms = (0 until 30).map { Mutable(it) }
    for (m in ms) muts[m] = "m${m.n}"
    ms[10].n = 1000
    println("moved ${muts[Mutable(10)]} ${muts[Mutable(1000)]} ${muts[ms[10]]} ${muts.size}")

    val loud = HashMap<Loud, Int>()
    for (i in 0 until 20) loud[Loud(i)] = i
    try {
        println(loud[Loud(7)])
        println(loud[Loud(-1)])
    } catch (e: IllegalStateException) {
        println("threw ${e.message}")
    }

    val mixed = HashMap<Any, String>()
    for (i in 0 until 20) { mixed[i] = "int$i"; mixed["s$i"] = "str$i"; mixed[Id(i)] = "id$i" }
    println("mixed ${mixed.size} ${mixed[7]} ${mixed["s7"]} ${mixed[Id(7)]} ${mixed[Id(27)]}")
}

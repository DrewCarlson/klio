// Instances as keys of hash maps and sets and as elements lists search: a
// class that keeps Any's equals and hashCode is found only by the same
// instance; a class overriding them, or inheriting an override, is found by
// an equal one. Maps large enough to index their keys behave as small ones.

class Plain(val id: Int)

data class Point(val x: Int, val y: Int)

open class ById(val id: Int) {
    override fun equals(other: Any?): Boolean = other is ById && other.id == id
    override fun hashCode(): Int = id % 3
}

class Tagged(id: Int, val tag: String) : ById(id)

class HashOnly(val id: Int) {
    override fun hashCode(): Int = 7
}

class CountingHash(val id: Int) {
    override fun hashCode(): Int {
        calls++
        return id
    }
    override fun equals(other: Any?): Boolean = other is CountingHash && other.id == id
    companion object {
        var calls = 0
    }
}

fun <K> probe(name: String, keys: List<K>, lookups: List<K>) {
    for (size in listOf(3, 40)) {
        val m = HashMap<K, Int>()
        val s = HashSet<K>()
        for (i in 0 until size) {
            val k = keys[i % keys.size]
            m[k] = i
            s.add(k)
        }
        val found = lookups.map { m[it] }
        val inSet = lookups.map { it in s }
        val inList = lookups.map { keys.indexOf(it) }
        println("$name/$size: size=${m.size} ${s.size} get=$found set=$inSet index=$inList")
        for (k in lookups) m.remove(k)
        println("$name/$size: after remove ${m.size}")
    }
}

fun main() {
    val plains = List(50) { Plain(it) }
    probe("plain", plains, listOf(plains[0], plains[49], Plain(0)))
    val points = List(50) { Point(it, -it) }
    probe("point", points, listOf(Point(0, 0), Point(49, -49), Point(1, 1)))
    val byIds = List(50) { ById(it) }
    probe("byId", byIds, listOf(ById(4), Tagged(4, "t"), ById(99)))
    val tagged = List(50) { Tagged(it, "x$it") }
    probe("tagged", tagged, listOf(Tagged(2, "other"), ById(2), Tagged(77, "")))
    val hashOnly = List(50) { HashOnly(it) }
    probe("hashOnly", hashOnly, listOf(hashOnly[5], HashOnly(5)))

    val mixed = HashMap<Any, String>()
    val p = Plain(1)
    mixed[p] = "plain"
    mixed[Point(1, 2)] = "point"
    mixed["text"] = "string"
    mixed[1] = "int"
    println("${mixed[p]} ${mixed[Plain(1)]} ${mixed[Point(1, 2)]} ${mixed["text"]} ${mixed[1]}")

    val counted = HashMap<CountingHash, Int>()
    for (i in 0 until 30) counted[CountingHash(i)] = i
    CountingHash.calls = 0
    println("${counted[CountingHash(3)]} ${counted[CountingHash(31)]} hashCode calls=${CountingHash.calls}")

    val identity = HashMap<Plain, Int>()
    for (k in plains) identity[k] = k.id
    var total = 0L
    for (round in 0 until 200) for (k in plains) total += identity[k]!!
    println(total)
}

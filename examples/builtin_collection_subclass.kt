// A class extending a builtin collection class holds the host collection
// as its base: members it does not declare forward to it, and an override
// calls the base's implementation through `super<ArrayList>` / `super`.
//
// Run with: klio run examples/builtin_collection_subclass.kt

class Log : ArrayList<String>() {
    var adds = 0

    override fun add(element: String): Boolean {
        adds++
        return super<ArrayList>.add("[$adds] $element")
    }
}

class Counts : HashMap<String, Int>() {
    fun bump(key: String) {
        put(key, (get(key) ?: 0) + 1)
    }
}

fun main() {
    val log = Log()
    println(log.add("start"))
    log.add("stop")
    println(log.size)
    println(log[0])
    println(log.get(1))
    println(log.adds)

    val counts = Counts()
    counts.bump("a")
    counts.bump("a")
    counts.bump("b")
    println(counts["a"])
    println(counts.size)
}

// Verifies that mutable instance state survives crossing function
// boundaries and IR register Moves (mutation in a callee is visible
// to the caller because Value::Instance holds an Rc<RefCell<…>>).

class Counter(var n: Int = 0) {
    fun bump() { n += 1 }
}

fun bumpTwice(c: Counter) {
    c.bump()
    c.bump()
}

fun main() {
    val c = Counter()
    bumpTwice(c)
    bumpTwice(c)
    println(c.n)

    val list = mutableListOf(1, 2)
    appendThree(list)
    println(list)

    val map = mutableMapOf("a" to 1)
    appendKey(map)
    println(map)
}

fun appendThree(xs: MutableList<Int>) { xs.add(3) }
fun appendKey(m: MutableMap<String, Int>) { m["b"] = 2 }

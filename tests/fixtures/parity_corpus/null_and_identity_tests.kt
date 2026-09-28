// Tests against null and identity tests: `== null`, `!= null`, `===` and
// `!==` over instances, strings, lambdas, Unit and a variable a lambda
// captures and changes, negated equality over Doubles with NaN, and a data
// class's `==` beside its `===`.

class Node(val v: Int, val next: Node?)

data class Pt(val x: Int, val y: Int)

fun length(n: Node?): Int {
    var c = 0
    var p = n
    while (p != null) {
        c++
        p = p.next
    }
    return c
}

fun describe(x: Any?): String = when {
    x == null -> "null"
    x === Unit -> "unit"
    else -> "value"
}

fun notEqual(a: Double, b: Double): Boolean = !(a == b)

fun notBelow(a: Double, b: Double): Boolean = !(a < b)

fun main() {
    var head: Node? = null
    for (i in 0 until 6) head = Node(i, head)
    println("length ${length(head)} ${length(null)} ${length(head?.next)}")

    val a = Node(1, null)
    val b = Node(1, null)
    val c = a
    println("identity ${a === b} ${a === c} ${a !== b} ${a !== c}")
    println("null ${a == null} ${a != null} ${head?.next?.next == null}")

    val things: List<Any?> = listOf(null, "s", 1, Unit, a, { 1 }, Pt(1, 2))
    println("describe " + things.map { describe(it) })
    println("nullness " + things.map { it == null } + " " + things.map { it != null })

    var captured: Any? = null
    val set = { v: Any? -> captured = v }
    println("captured ${captured == null} ${captured === null}")
    set("now")
    println("captured ${captured == null} ${captured !== null} $captured")
    set(null)
    println("captured ${captured == null}")

    val nan = Double.NaN
    println("negated ${notEqual(nan, nan)} ${notEqual(1.0, 1.0)} ${notEqual(0.0, -0.0)}")
    println("not below ${notBelow(nan, 1.0)} ${notBelow(2.0, 1.0)} ${notBelow(1.0, 2.0)}")

    val p = Pt(1, 2)
    val q = Pt(1, 2)
    println("data ${p == q} ${p === q} ${p != q} ${p !== q}")
    val s1 = "klio"
    val s2 = "kl" + "io".lowercase()
    println("strings ${s1 == s2} ${s1 != s2}")
}

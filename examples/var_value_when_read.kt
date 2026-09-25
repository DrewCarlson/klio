// A var's value is the one it had when it was read. An argument, an
// operand, a string template part, an index or a receiver read before a
// later part of the same expression writes the var keeps what it read; a
// val bound to a var keeps its value; an inline call's parameter keeps its
// argument while the lambda it runs writes the var; and a finally that
// writes the var after a return does not change the value returned.

class Box(var n: Int)

fun pair(x: Int, y: Int): String = "$x $y"

inline fun <T> heldBefore(x: T, f: () -> Unit): T {
    f()
    return x
}

inline fun <T> heldAfter(f: () -> Unit, x: T): T {
    f()
    return x
}

fun early(): Int {
    var a = 1
    try {
        return a
    } finally {
        a = 2
    }
}

fun main() {
    var a = 1
    println(pair(a, run { a = 5; 0 }))
    a = 1
    println(a + a++)
    println(a)
    a = 1
    println(a++ + a)
    var i = 1
    println(pair(++i, i++))
    println(i)
    a = 1
    val b = a
    a = 2
    println(b)
    a = 3
    println(heldBefore(a) { a = 9 })
    a = 3
    println(heldAfter({ a = 9 }, a))
    a = 4
    println(a.let { a = 5; it })
    a = 6
    println(with(a) { a = 7; this })
    a = 8
    println("$a ${run { a = 3; a }}")
    val arr = intArrayOf(0, 0, 0)
    a = 2
    arr[a] = run { a = 1; 10 }
    println(arr.joinToString())
    var o = Box(1)
    val first = o
    o.n = run { o = Box(2); 5 }
    println("${first.n} ${o.n}")
    println(early())
    a = 1
    a = try { a + 1 } finally { println("finally $a") }
    println(a)
    a = 1
    a += run { a = 10; 1 }
    println(a)
    a = 1
    when (a) {
        run { a = 2; 1 } -> println("one $a")
        else -> println("else $a")
    }
    a = 1
    when (val v = a) {
        else -> {
            a = 5
            println("$v $a")
        }
    }
    var s: String? = null
    s = s ?: run { s = "x"; "y" }
    println(s)
    var captured = 1
    val bump = { captured += 10 }
    println(captured + run { bump(); 0 })
    println(captured)
    var n = 0
    var total = 0
    while (true) {
        n = n + 1
        if (n % 2 == 0) continue
        if (n > 7) break
        total = total + n
    }
    println("$n $total")
    var k = 0
    do {
        k++
        if (k < 3) continue
    } while (k < 5)
    println(k)
    var x = 10
    x = x - x / 2
    x = pair(x, x).length + x
    println(x)
    var c = 0
    repeat(3) { c = c + it }
    println(c)
}

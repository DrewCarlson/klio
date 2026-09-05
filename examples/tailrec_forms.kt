// `tailrec` turns a self-call in tail position into a jump, whatever form
// the call takes: bare, on an explicit receiver (`(n - 1).countDown()`,
// `this@Outer.walk(…)`, `Counter.step(…)`), infix, with omitted defaults
// or named arguments, as an `if`/`when` arm, on the right of `?:` or `||`,
// or as a Unit body's last statement (even one followed by a bare
// `return`). A self-call that is not in tail position — `1 + depth(n - 1)`
// — recurses like any other call.
tailrec fun countTo(n: Int, acc: Int = 0): Int = if (n == 0) acc else countTo(n - 1, acc + 1)

tailrec fun Int.countDown(): Int {
    if (this == 0) return 0
    return (this - 1).countDown()
}

tailrec infix fun Int.halveUntil(limit: Int): Int =
    if (this <= limit) this else (this / 2) halveUntil limit

object Counter {
    tailrec fun step(n: Int, seen: Int = 0): Int = if (n == 0) seen else Counter.step(n - 1, seen + 1)
}

class Walker(val stride: Int) {
    inner class Cursor {
        tailrec fun walk(pos: Int): Int {
            if (pos >= 1000000) return pos
            return this@Cursor.walk(pos + stride)
        }
    }
}

tailrec fun firstTrue(n: Int): Boolean = n == 0 || firstTrue(n - 1)

tailrec fun findOrNull(n: Int): Int? = (if (n == 3) n else null) ?: if (n == 0) null else findOrNull(n - 1)

var ticks = 0
tailrec fun tick(n: Int) {
    if (n > 0) {
        ticks += 1
        tick(n = n - 1)
        return
    }
}

tailrec fun byName(x: Int = 0, label: String = "done"): String =
    if (x == 0) label else byName(label = "counted", x = x - 1)

fun depth(n: Int): Int {
    tailrec fun go(k: Int, acc: Int): Int = when {
        k == 0 -> acc
        else -> go(k - 1, acc + 2)
    }
    return go(n, 0)
}

tailrec fun sumTo(n: Int): Int {
    if (n == 0) return 0
    if (n == 10) return 1 + sumTo(n - 1)
    return sumTo(n - 1)
}

fun main() {
    println(countTo(1000000))
    println(1000000.countDown())
    println(1000000 halveUntil 3)
    println(Counter.step(1000000))
    println(Walker(1).Cursor().walk(0))
    println(firstTrue(1000000))
    println(findOrNull(1000000))
    tick(1000000)
    println(ticks)
    println(byName(x = 1000000))
    println(depth(1000000))
    println(sumTo(1000000))
}

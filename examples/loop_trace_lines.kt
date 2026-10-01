// A frame in a loop's header stands at the loop, as kotlinc's line table has
// it: a `for`'s `hasNext()` and `next()` at the `for`, a `while`'s condition
// at the `while` on every test, and a `do`-`while`'s condition at the
// condition, whichever statement of the body ran last.

class Ticks(val n: Int) {
    var i = 0
    operator fun hasNext(): Boolean {
        if (i > n) throw IllegalStateException("hasNext at $i")
        return true
    }
    operator fun next(): Int {
        if (i == n) throw IllegalStateException("next at $i")
        return i++
    }
    operator fun iterator() = this
}

class Stepped(val n: Int) {
    var i = 0
    operator fun hasNext(): Boolean {
        if (i == n) throw IllegalStateException("hasNext at $i")
        i++
        return true
    }
    operator fun next(): Int = i
    operator fun iterator() = this
}

fun check(i: Int, n: Int): Boolean {
    if (i >= n) throw IllegalStateException("check at $i")
    return true
}

fun forNext(n: Int): Int {
    var s = 0
    for (x in Ticks(n)) {
        if (x % 2 == 0) {
            s += x
        } else {
            s -= 1
        }
    }
    return s
}

fun forHasNext(n: Int): Int {
    var s = 0
    for (x in Stepped(n)) {
        if (x % 2 == 0) {
            s += x
        } else {
            s -= 1
        }
    }
    return s
}

fun whileLoop(n: Int): Int {
    var s = 0
    var i = 0
    while (check(i, n)) {
        if (i % 2 == 0) {
            s += i
        } else {
            s -= 1
        }
        i++
    }
    return s
}

fun doWhileLoop(n: Int): Int {
    var s = 0
    var i = 0
    do {
        if (i % 2 == 0) {
            s += i
        } else {
            s -= 1
        }
        i++
    } while (
        check(i, n)
    )
    return s
}

fun lineOf(name: String, f: () -> Int) {
    try {
        f()
    } catch (e: IllegalStateException) {
        println("$name: ${e.message}, called at line ${e.stackTrace[1].lineNumber}")
    }
}

fun main() {
    lineOf("for next") { forNext(3) }
    lineOf("for hasNext") { forHasNext(4) }
    lineOf("while") { whileLoop(3) }
    lineOf("do-while") { doWhileLoop(3) }
}

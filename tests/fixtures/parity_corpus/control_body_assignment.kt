fun maxOf3(a: Int, b: Int, c: Int): Int {
    var m = a
    if (b > m) m = b
    if (c > m) m = c
    return m
}

fun sumUpTo(n: Int): Int {
    var s = 0
    var i = 1
    while (i <= n) s += i.also { i++ }
    return s
}

fun main() {
    println(maxOf3(1, 5, 3))
    println(maxOf3("a"[0].code, "c"[0].code, "b"[0].code))
    println(sumUpTo(10))
}

fun main() {
    val a = StringBuilder("hello world")
    a.setRange(0, 5, "HELLO")
    println(a.toString())

    val b = StringBuilder("abc")
    b.appendRange(charArrayOf('X', 'Y', 'Z', 'W'), 1, 3)
    println(b.toString())

    val c = StringBuilder("abc")
    c.appendRange("12345", 0, 3)
    println(c.toString())

    val d = StringBuilder("abc")
    d.insertRange(1, charArrayOf('-', '=', '+'), 0, 2)
    println(d.toString())

    val e = StringBuilder("hello")
    e.setRange(1, 4, "XY")
    println(e.toString())
}

fun interface Handler { fun handle(v: Int): String }

fun Handler.twice(v: Int): String = handle(v) + handle(v)

fun run1(h: Handler): String = "is=" + (h is Handler) + " r=" + h.handle(1) + " t=" + h.twice(2)

class Box { fun run2(h: Handler): String = "is=" + (h is Handler) + " t=" + h.twice(3) }

fun main() {
    println("top    = " + run1 { v -> "<$v>" })
    println("member = " + Box().run2 { v -> "[$v]" })
    println("explicit = " + run1(Handler { v -> "{$v}" }))
}

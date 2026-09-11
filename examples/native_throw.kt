// `throw` compiled to C. Any block carrying a catch handler is refused, so a
// program the backend accepts has no handler anywhere and a throw always leaves
// it — which is what makes reporting it and stopping the whole story. The
// exception classes are the runtime's own, carrying a message rather than
// fields the emitter lays out.
fun checked(n: Int): Int {
    if (n < 0) throw IllegalArgumentException("negative: " + n)
    return n * 2
}

fun main() {
    println(checked(5))
    println(checked(21))
    println(checked(-1))
    println("unreachable")
}

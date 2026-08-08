// The indexed-store fast path serves a plain mutable list: set() returns
// the PREVIOUS element, assignment discards it, a subList view writes
// through (declined to the full path), a read-only receiver throws, and
// out-of-bounds throws. String indexing serves the ASCII case and declines
// multi-byte to the UTF-16 walk.
fun main() {
    val l = mutableListOf(1, 2, 3)
    println(l.set(1, 9))
    println(l)
    l[0] = 7
    println(l[0])
    val sub = l.subList(0, 2)
    sub[1] = 42
    println(l)
    val ro: List<Int> = listOf(1)
    try {
        (ro as MutableList<Int>)[0] = 5
        println("no-throw")
    } catch (e: UnsupportedOperationException) {
        println("threw-uoe")
    }
    try {
        l[9] = 1
        println("no-throw-oob")
    } catch (e: IndexOutOfBoundsException) {
        println("threw-ioobe")
    }
    println("str"[1])
    println("héllo"[1])
}

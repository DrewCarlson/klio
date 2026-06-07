fun main() {
    val a = intArrayOf(1, 2, 3)
    try {
        println(a[5])
    } catch (e: IndexOutOfBoundsException) {
        println("caught get oob")
    }
    try {
        a[5] = 9
    } catch (e: IndexOutOfBoundsException) {
        println("caught set oob")
    }
    val b = arrayOf("x", "y")
    try {
        println(b[-1])
    } catch (e: IndexOutOfBoundsException) {
        println("caught neg")
    }
    // Valid access still works.
    println(a[0] + a[2])
    b[0] = "z"
    println(b.joinToString(","))
}

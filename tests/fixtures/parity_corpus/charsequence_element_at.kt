fun main() {
    println("abc".elementAt(0))
    println("abc".elementAt(2))
    println(StringBuilder("xyz").elementAt(1))
    val cs: CharSequence = "klio"
    println(cs.elementAt(3))
    try {
        "ab".elementAt(5)
    } catch (e: IndexOutOfBoundsException) {
        println("oob")
    }
}

fun main() {
    val x: Any = 42
    try {
        val s = x as String
        println(s)
    } catch (e: ClassCastException) {
        println("caught")
    }
}

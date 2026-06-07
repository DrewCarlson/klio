fun main() {
    val a: String? = null
    try {
        val b: String = a!!
        println(b)
    } catch (e: NullPointerException) {
        println("caught npe")
    }
}

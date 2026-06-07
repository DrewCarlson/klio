fun main() {
    try {
        throw IllegalStateException("x")
    } catch (e: Exception) {
        println(e::class.simpleName)
    }
    try {
        "z".toInt()
    } catch (e: Exception) {
        println(e::class.simpleName)
    }
    try {
        val a = intArrayOf(1)
        a[9]
    } catch (e: Exception) {
        println(e::class.simpleName)
    }
    try {
        throw IllegalArgumentException("bad")
    } catch (e: Exception) {
        println(e::class.simpleName)
    }
}

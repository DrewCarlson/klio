class Box(val n: Int) {
    private fun secret(): Int = n * 2
    fun expose(): Int = secret()
}

fun main() {
    val b = Box(3)
    println(b.secret())
}

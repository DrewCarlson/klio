fun take(vararg xs: String) {
    for (x in xs) println(x)
}

fun main() {
    val nums: IntArray = intArrayOf(1, 2, 3)
    take(*nums)
}

fun ShortArray.describe(): String {
    var total = 0
    for (i in indices) total += this[i].toInt()
    return "n=${indices.count()} last=$lastIndex total=$total"
}

fun main() {
    println(shortArrayOf(3, 4, 5).describe())
    val la = longArrayOf(10, 20)
    println(la.describe2())
}

fun LongArray.describe2(): String {
    val r = indices
    return "r=$r"
}

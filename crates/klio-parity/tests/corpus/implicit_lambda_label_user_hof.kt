inline fun <T> doIt(items: List<T>, block: (T) -> Unit) {
    for (i in items) block(i)
}

fun main() {
    doIt(listOf(1, 2, 3, 4)) {
        if (it == 2) return@doIt
        println(it)
    }
    println("done")
}

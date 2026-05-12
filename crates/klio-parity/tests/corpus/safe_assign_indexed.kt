class Holder(val items: MutableList<Int>)

fun main() {
    val h: Holder? = Holder(mutableListOf(1, 2, 3))
    h?.items[1] = 99
    println(h?.items)
    val z: Holder? = null
    z?.items[1] = 99
    println("done")
}

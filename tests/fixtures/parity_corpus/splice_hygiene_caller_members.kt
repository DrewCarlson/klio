class Ops {
    fun indices(): String = "method"
    fun lastIndex(): String = "method"
    fun sumOf(): String = "method"

    fun tail(): List<Int> {
        val a = intArrayOf(5, 6, 7)
        return a.takeLastWhile { it > 5 }
    }

    fun total(): UInt = ubyteArrayOf(200u, 200u).sum()

    fun viaLambda(): Int {
        val words = listOf("aa", "bbb")
        return words.sumOf { it.length + indices().length }
    }
}

fun main() {
    println(Ops().tail())
    println(Ops().total())
    println(Ops().viaLambda())
    println(listOf(listOf("s")).plusElement(listOf("a")))
}

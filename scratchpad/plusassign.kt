fun main() {
    val outer: MutableList<List<String>> = ArrayList()
    val inner: List<String> = emptyList()
    outer += inner
    println("size after empty inner = " + outer.size)
    val inner2: List<String> = listOf("a", "b")
    outer += inner2
    println("size after 2-elem inner = " + outer.size + " -> " + outer)

    val nums: MutableList<Int> = ArrayList()
    nums += 1
    nums += listOf(2, 3)
    println("nums = $nums")

    val flags: MutableList<Boolean> = ArrayList()
    flags += false
    println("flags = $flags")
}

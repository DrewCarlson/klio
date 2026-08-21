private fun makeIt(id: Long, tag: String): String = "B:$tag#$id"

class HolderB {
    fun use(): String {
        val f = ::makeIt
        return f(2L, "b")
    }
    fun direct(): String = makeIt(9L, "b")
    fun directBlock(): String { return makeIt(8L, "b") }
}

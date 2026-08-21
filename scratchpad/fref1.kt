private fun make(id: Long, tag: String): String = "$tag#$id"

class Holder {
    fun use(): String {
        val f = ::make
        return f(1L, "a")
    }
    fun useInLambda(): String {
        var r = ""
        run {
            val f = ::make
            r = f(2L, "b")
        }
        return r
    }
}

fun main() {
    val h = Holder()
    println(h.use())
    println(h.useInLambda())
}

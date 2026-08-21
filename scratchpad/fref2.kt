class Holder {
    fun use(): String {
        val f = ::make
        return f(1L, "a")
    }
}
private fun make(id: Long, tag: String): String = "$tag#$id"
fun main() { println(Holder().use()) }

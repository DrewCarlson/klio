class Holder {
    lateinit var late: String
    var link: Holder? = null
    fun readLate(): String = late
    fun readLink(): Holder? = link
}
fun main() {
    val h = Holder()
    println(h.readLink())
    println(h.readLink())
    try { println(h.readLate()) } catch (e: Exception) { println("threw: " + (e.message ?: "?")) }
    h.late = "set"
    println(h.readLate())
    h.link = h
    println(h.readLink() === h)
}

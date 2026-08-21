class Backing {
    @JvmField var _size: Int = 7
    fun tag(): String = "B$_size"
}
class W(val list: Backing) {
    inline fun sizeVia(): Int = list._size
    inline fun tagVia(): String = list.tag()
    fun direct(): String = "" + sizeVia() + "/" + tagVia()
    fun inBuild(): String = buildString { append(sizeVia()); append('/'); append(tagVia()) }
    fun inWith(): String { val sb = StringBuilder(); with(sb) { append(sizeVia()); append('/'); append(tagVia()) }; return sb.toString() }
}
fun main() {
    val w = W(Backing())
    println("direct   = " + w.direct())
    println("inBuild  = " + w.inBuild())
    println("inWith   = " + w.inWith())
}

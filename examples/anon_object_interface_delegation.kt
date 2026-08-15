interface Sink2 {
    fun flush(): String
    fun close(): String
}
class Buf : Sink2 {
    override fun flush() = "buf-flush"
    override fun close() = "buf-close"
}
fun main() {
    val s = object : Sink2 by Buf() {}
    println(s.flush())
    val t = object : Sink2 by Buf() {
        override fun close() = "own-close"
    }
    println(t.close())
    println(t.flush())
}
// (also: KClass.isInstance agrees with `is` across a cross-registry chain)

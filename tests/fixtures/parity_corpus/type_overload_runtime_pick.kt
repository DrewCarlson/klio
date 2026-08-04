class Meta(val tag: Int)
fun describe(flag: Boolean, width: Float): String = "bool:" + flag + " w:" + width
fun describe(meta: Meta, depth: Int): String = "meta:" + meta.tag + " d:" + depth
fun forward(meta: Meta, depth: Int): String = describe(meta, depth)
fun forwardB(flag: Boolean, width: Float): String = describe(flag, width)
fun main() {
    println(forward(Meta(7), 2))
    println(forwardB(true, 1.5f))
}

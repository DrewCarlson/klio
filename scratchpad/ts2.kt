class Box(val n: Int) { override fun toString(): String = "Box($n)" }
fun main() {
    val b = Box(1)
    val xs = listOf(b)
    val any: Any = xs
    println("concat   = " + xs)
    println("concatAny= " + any)
    println("tmpl     = $xs")
    println("explicit = " + xs.toString())
    println("stringOf = " + xs.toString() + "")
    val sb = StringBuilder(); sb.append(xs); println("sbAppend = " + sb)
}

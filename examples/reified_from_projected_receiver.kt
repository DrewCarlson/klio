// A reified type parameter inferred from a use-site projection binds the
// projected type, never the projection: `Array<out String>?.orEmpty()`
// infers `T = String`, so the spliced `emptyArray<T>()` names a class.
fun main() {
    val x: Array<String>? = null
    val y: Array<out String>? = null
    println(x.orEmpty().size)
    println(y.orEmpty().size)
    val z: Array<out CharSequence>? = arrayOf("a", "bc")
    println(z.orEmpty().joinToString(","))
}

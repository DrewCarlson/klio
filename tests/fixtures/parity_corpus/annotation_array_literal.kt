// Kotlin permits a collection literal `[a, b]` only as an annotation
// argument (upstream kotlinx-coroutines:
// `@Deprecated(replaceWith = ReplaceWith(..., imports = ["..."]))`).
// klio now parses it; it is runtime-inert, so output is unaffected.
@Target(AnnotationTarget.FUNCTION)
annotation class Tagged(val names: Array<String>)

@Tagged(names = ["alpha", "beta", "gamma"])
fun tagged(): Int = 7

@Deprecated(
    message = "use tagged",
    replaceWith = ReplaceWith(expression = "tagged()", imports = ["x.tagged"])
)
fun old(): Int = tagged()

fun main() {
    println(tagged())
    @Suppress("DEPRECATION")
    println(old())
}

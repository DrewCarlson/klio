// A user-declared top-level function shadows an implicitly imported stdlib
// function of the same name and arity. Kotlin resolves the same-file
// declaration ahead of the default-imported one, so each bare call below
// must bind the user's function, never the stdlib intrinsic.

fun emptyList(): String = "user-emptyList"
fun emptySet(): String = "user-emptySet"
fun emptyMap(): String = "user-emptyMap"
fun error(): String = "user-error"
fun listOf(): String = "user-listOf"

fun main() {
    println(emptyList())
    println(emptySet())
    println(emptyMap())
    println(error())
    println(listOf())

    // The stdlib forms remain reachable through their canonical packages,
    // and the inferred-type call sites still resolve to them.
    val xs: List<Int> = kotlin.collections.emptyList()
    println(xs.isEmpty())
}

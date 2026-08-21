// An `inline` extension's body resolves names against ITS receiver, not the
// caller's. A bare call to a same-named extension of that receiver binds the
// receiver-taking one, exactly as it does in a non-inline extension, and the
// receiver's members stay reachable through the splice.
//
// Run with: klio run examples/inline_extension_receiver_scope.kt

class Registry(val tag: String) {
    fun describe(): String = "registry($tag)"
}

fun lookup(name: String): String = "global:$name"
fun Registry.lookup(name: String): String = "registry($tag):$name"

fun Registry.viaPlain(name: String): String = lookup(name)

inline fun Registry.viaInline(name: String): String = lookup(name)

inline fun <reified T> Registry.viaReified(name: String): String =
    lookup(name) + "/" + (T::class.simpleName ?: "?")

inline fun Registry.viaMember(): String = describe()

fun Registry.viaNestedLambda(names: List<String>): List<String> =
    names.map { lookup(it) }

fun main() {
    val r = Registry("r1")
    println("plain    = " + r.viaPlain("a"))
    println("inline   = " + r.viaInline("a"))
    println("reified  = " + r.viaReified<String>("a"))
    println("member   = " + r.viaMember())
    println("lambda   = " + r.viaNestedLambda(listOf("a", "b")))
    // With no receiver in scope the global is what a bare call means.
    println("no recv  = " + lookup("a"))
}

// A member extension — an extension function declared INSIDE a class — is in
// scope for every member of that class, and applies to any receiver of the
// declared type. It stays in scope when the call site cannot name the
// receiver's static type: a value read back through an interface, a generic,
// or a chained call still reaches the enclosing class's extension.
//
// Run with: klio run examples/member_extension_untyped_receiver.kt

interface Carrier {
    val labels: List<String>
    fun describe(): Carrier
}

class Bag(override val labels: List<String>) : Carrier {
    override fun describe(): Carrier = this
}

class Report(private val bag: Carrier) {
    // Private member extensions on a builtin type.
    private fun List<String>.render(): String = "[" + joinToString("|") + "]"
    private fun List<String>.renderWith(sep: String): String = joinToString(sep)
    private val List<String>.width: Int get() = sumOf { it.length }

    // The receiver's type is written at the call site.
    fun typed(): String {
        val l: List<String> = bag.labels
        return l.render()
    }

    // Chained straight off the interface property — no type written.
    fun chained(): String = bag.labels.render()

    // Through a longer chain, still no type written.
    fun deepChain(): String = bag.describe().labels.render()

    // With arguments, and as a property.
    fun withArg(): String = bag.labels.renderWith("+")
    fun width(): Int = bag.labels.width

    // Through a generic that erases the static type.
    private fun <T> id(x: T): T = x
    fun generic(): String = id(bag.labels).render()

    // Inside a lambda, where the enclosing receiver is reached by walking out.
    fun inLambda(): String = listOf(bag, bag).joinToString(";") { it.labels.render() }
}

fun main() {
    val r = Report(Bag(listOf("aa", "b", "ccc")))
    println("typed     = " + r.typed())
    println("chained   = " + r.chained())
    println("deepChain = " + r.deepChain())
    println("withArg   = " + r.withArg())
    println("width     = " + r.width())
    println("generic   = " + r.generic())
    println("inLambda  = " + r.inLambda())
    println("empty     = " + Report(Bag(emptyList())).chained())
}

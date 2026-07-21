// An interface member is implicitly open: a default body can always be
// overridden by an implementer, so a call through the interface type stays
// virtual and must NOT be resolved to the default at lowering time.
interface Greeter {
    fun greet(): String = "default"
}

class Polite : Greeter {
    override fun greet(): String = "hello"
}

// Inherits the default body unchanged.
class Silent : Greeter

fun main() {
    val greeters: List<Greeter> = listOf(Polite(), Silent())
    for (g in greeters) println(g.greet())
}

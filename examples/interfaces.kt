// Demonstrates interface declarations with dispatch: abstract members,
// default-method bodies, multiple interfaces, interface inheritance,
// marker interfaces, mixing a parent class with interfaces, and `is`-checks.

interface Named {
    val name: String
    fun label(): String = "[$name]"
}

interface Greeter {
    fun greet(): String
    fun greetLoud(): String = greet().uppercase()
}

interface Marker

interface FormalGreeter : Greeter {
    override fun greet(): String = "Good day."
}

open class Being(val species: String) {
    open fun describe(): String = species
}

class Person(override val name: String) : Being("human"), Named, Greeter, Marker {
    override fun greet(): String = "hi, I'm $name"
    override fun describe(): String = "${super.describe()} named $name"
}

class Robot : Being("robot"), FormalGreeter

fun shout(g: Greeter) {
    println(g.greetLoud())
}

fun main() {
    val p = Person("Ada")
    println(p.label())
    println(p.greet())
    println(p.describe())
    shout(p)

    val r = Robot()
    println(r.greet())
    shout(r)

    val things: List<Any> = listOf(p, r, "x", 42)
    for (t in things) {
        val tag = when {
            t is Greeter && t is Marker -> "greeter+marker"
            t is Greeter -> "greeter"
            t is Named -> "named"
            else -> "other"
        }
        println(tag)
    }
}

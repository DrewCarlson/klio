interface I {
    val name: String
    // Members WITH default bodies must still be forwarded to the delegate.
    val tags: List<String> get() = emptyList()
    fun describe(): String = "I:" + name
    fun at(i: Int): String
}

class Base(override val name: String, override val tags: List<String>) : I {
    override fun describe(): String = "Base:" + name + tags
    override fun at(i: Int): String = tags[i]
}

class Wrap(private val original: I) : I by original {
    override val name: String get() = "wrap(" + original.name + ")"
}

fun main() {
    val b = Base("b", listOf("x", "y"))
    val w: I = Wrap(b)
    println("name     = " + w.name)
    println("tags     = " + w.tags)
    println("describe = " + w.describe())
    println("at0      = " + w.at(0))
}

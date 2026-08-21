interface D {
    val name: String
    val tags: List<String>
    fun at(i: Int): String
}

class Base(override val name: String, override val tags: List<String>) : D {
    override fun at(i: Int): String = tags[i]
}

private class Wrap(private val original: D, val k: String) : D by original {
    override val name = original.name + "<" + k + ">"
}

fun main() {
    val b = Base("base", listOf("x", "y"))
    val w: D = Wrap(b, "K")
    println("name=" + w.name)
    println("tags=" + w.tags)
    println("at0=" + w.at(0))
}

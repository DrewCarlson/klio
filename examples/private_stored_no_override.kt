interface Engine {
    val name: String

    private val closed: Boolean
        get() = name.isEmpty()

    fun status(): String {
        return if (closed) "closed" else "open"
    }
}

abstract class EngineBase : Engine {
    private val closed = "ATOM"
}

class MyEngine : EngineBase() {
    override val name = "e"
}

fun main() {
    println(MyEngine().status())
}

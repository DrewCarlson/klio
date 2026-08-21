abstract class AB<T : Any> {
    abstract val baseClass: String
}

class PS<T : Any>(override val baseClass: String) : AB<T>() {
    internal constructor(baseClass: String, extra: Array<String>) : this(baseClass) {
        _extra = extra.asList()
    }
    private var _extra: List<String> = emptyList()
    val descriptor: String by lazy { baseClass + ":" + _extra }
}

fun main() {
    val a = PS<Any>("b", arrayOf("x"))
    println("two=" + a.descriptor)
    val b = PS<Any>("c")
    println("one=" + b.descriptor)
}

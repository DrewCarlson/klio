class P(val base: String) {
    constructor(base: String, extra: List<String>) : this(base) {
        _extra = extra
    }
    private var _extra: List<String> = emptyList()
    val view: String by lazy { base + ":" + _extra }
    val direct: String get() = base + ":" + _extra
}

fun main() {
    val a = P("x", listOf("a", "b"))
    println("direct=" + a.direct)
    println("view=" + a.view)
    val b = P("y")
    println("plain=" + b.view)
}

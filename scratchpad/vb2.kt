class B(val name: String) {
    val parts = ArrayList<String>()
    var tags: List<String> = emptyList()
    fun element(s: String, d: String) { parts.add(s + "=" + d) }
}

fun build(name: String, kind: String, vararg tp: String, builder: B.() -> Unit = {}): String {
    val b = B(name)
    b.builder()
    return "[$name/$kind tags=${b.tags} parts=${b.parts}]"
}

class Holder(val base: String) {
    constructor(base: String, extra: Array<String>) : this(base) { _tags = extra.asList() }
    private var _tags: List<String> = emptyList()
    val descriptor: String by lazy {
        build("outer", "OPEN") {
            element("type", "S")
            element("value", build("inner<$base>", "CONTEXTUAL"))
            tags = _tags
        }
    }
    val simple: String by lazy {
        build("obj", "OBJECT") { tags = _tags }
    }
}

fun main() {
    val h = Holder("X", arrayOf("a"))
    println(h.simple)
    println(h.descriptor)
}

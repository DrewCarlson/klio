class C(val tag: String, val items: MutableList<Any?>) {
    constructor(tag: String) : this(tag, Shared) {
        check(Shared.isEmpty()) { "modified" }
    }
    companion object {
        val Shared: MutableList<Any?> = mutableListOf()
    }
}
fun main() {
    val c = C("x")
    println("${c.tag}|${c.items.size}")
}

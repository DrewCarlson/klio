class B(val name: String) {
    val parts = ArrayList<String>()
    fun add(s: String) { parts.add(s) }
}

fun build(
    name: String,
    tag: Int,
    vararg extra: String,
    builder: B.() -> Unit = {}
): String {
    val b = B(name)
    b.builder()
    return "name=$name tag=$tag extra=${extra.toList()} parts=${b.parts}"
}

fun main() {
    println(build("outer", 1) {
        add("a")
        add(build("inner", 2))
    })
    println(build("solo", 3))
    println(build("withExtra", 4, "e1", "e2") { add("z") })
}

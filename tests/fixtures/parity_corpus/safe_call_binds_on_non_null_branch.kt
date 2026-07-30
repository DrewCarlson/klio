// A safe call's member runs on the branch where the receiver is already proven
// non-null, so a nullable declared type must not keep it off the static path.
// The receiver is evaluated once for the null test, and the static binding
// reuses that value rather than lowering the receiver expression a second time.
class Node(val label: String) {
    fun tagWith(suffix: String): String = "node:" + label + suffix
    fun nested(): Inner? = if (label == "a") Inner(label) else null
}

class Inner(val label: String) {
    fun describeIt(): String = "inner:" + label
}

var evaluations = 0

fun makeNode(l: String?): Node? {
    evaluations++
    return if (l == null) null else Node(l)
}

fun main() {
    println(makeNode("a")?.tagWith("!"))
    println(makeNode(null)?.tagWith("!"))
    println("evaluations=" + evaluations)

    // Chained: each link null-guards independently.
    println(makeNode("a")?.nested()?.describeIt())
    println(makeNode("b")?.nested()?.describeIt())
    println("evaluations=" + evaluations)

    // A named argument still binds through the same path.
    val n: Node? = Node("z")
    println(n?.tagWith(suffix = "?"))
}

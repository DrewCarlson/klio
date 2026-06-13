fun <T> runWith(r: T, block: T.() -> Unit) { r.block() }

fun main() {
    listOf(7, 8).forEach { runWith("R") { println(it) } }
}

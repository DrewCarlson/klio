fun <T> runWith(r: T, block: T.() -> Unit) { r.block() }

fun main() {
    runWith("R") { println(it) }
}

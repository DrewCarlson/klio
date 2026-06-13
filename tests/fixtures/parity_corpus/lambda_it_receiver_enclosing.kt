fun <T> runWith(r: T, block: T.() -> Unit) { r.block() }

fun main() {
    repeat(2) { runWith("R") { println(it) } }
}

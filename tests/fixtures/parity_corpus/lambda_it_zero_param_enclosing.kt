fun call0(f: () -> Unit) { f() }

fun main() {
    repeat(2) { call0 { println(it) } }
}

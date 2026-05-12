fun <reified T> notInline(): String = "x"

fun main() {
    println(notInline<Int>())
}

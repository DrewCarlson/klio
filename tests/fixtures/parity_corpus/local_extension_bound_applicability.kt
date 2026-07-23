fun Any.tag(): String = "outer"

fun rejectedBound() {
    fun <T : CharSequence> List<T>.tag(): String = "local"

    val values: List<Int> = listOf(1)
    println(values.tag())
}

fun <T : CharSequence> acceptedEnclosingBound(values: List<T>) {
    fun List<CharSequence>.tag(): String = "local"

    println(values.tag())
}

fun main() {
    rejectedBound()
    acceptedEnclosingBound(listOf("x"))
}

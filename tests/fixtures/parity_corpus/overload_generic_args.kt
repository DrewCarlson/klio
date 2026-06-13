// Runtime overload dispatch over a same-head generic pair: the argument's
// element types select the overload. kotlinc-jvm rejects this pair under
// JVM erasure (platform declaration clash); kotlinc-native 2.3.10 accepts
// it and resolves by the full declared type, so the native compiler is the
// oracle here.
fun pick(xs: List<Int>): String = "pick(List<Int>)"
fun pick(xs: List<String>): String = "pick(List<String>)"

fun main() {
    println(pick(listOf("a", "b")))
    println(pick(listOf(1, 2)))
    println(pick(emptyList<String>()))
    println(pick(emptyList<Int>()))
}

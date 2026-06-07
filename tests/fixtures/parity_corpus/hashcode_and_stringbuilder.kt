fun main() {
    // hashCode() must be Kotlin-faithful AND terminating (previously recursed
    // into an out-of-memory fallback for builtin value types).
    println(5.hashCode())
    println((-7).hashCode())
    println(0.hashCode())
    println("hello".hashCode())
    println("".hashCode())
    println(true.hashCode())
    println(false.hashCode())
    println('A'.hashCode())
    println(100L.hashCode())
    println(3.14.hashCode())
    println(listOf(1, 2, 3).hashCode())
    println(listOf("a", "b", "c").hashCode())
    println(emptyList<Int>().hashCode())
    println((1..5).hashCode())
    println((5 downTo 1).hashCode())
    println((1..10 step 2).hashCode())
    println(setOf(1, 2, 3).hashCode())
    println(mapOf(1 to 2, 3 to 4).hashCode())

    // StringBuilder members that were missing / OOM-ing.
    val sb = StringBuilder("abcdef")
    println(sb.subSequence(1, 4))
    println(sb.lastIndex)
    sb.setCharAt(0, 'X')
    println(sb.toString())
    sb.replace(1, 3, "YY")
    println(sb.toString())
    sb.delete(0, 2)
    println(sb.toString())
}

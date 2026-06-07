fun main() {
    val inner = IllegalArgumentException("inner reason")
    val outer = RuntimeException("outer wrapper", inner)
    println(outer.message)
    println(outer.cause?.message)
    val plain = IllegalStateException("solo")
    println(plain.message)
    println(plain.cause)
}

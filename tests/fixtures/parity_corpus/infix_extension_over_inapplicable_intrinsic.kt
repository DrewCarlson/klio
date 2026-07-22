class Bits(val mask: Int)

infix fun Int.or(other: Bits): Int = this or other.mask

fun main() {
    println(1 or 2)
    println(1 or Bits(4))
}

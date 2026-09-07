// `Char` arithmetic spelled as calls: `plus(Int)` and `minus(Int)` yield
// a Char, `minus(Char)` and `compareTo(Char)` an Int; a comparison
// between a Char and a number has no builtin order, so `x < y` resolves
// to the program's `compareTo` extension.
operator fun Int.compareTo(c: Char) = this - c.code

fun main() {
    println('A'.plus(1))
    println('B'.minus('A'))
    println('D'.minus(2))
    println('a'.compareTo('c'))
    println(65 < 'B')
    println(70 < 'B')
    println(1u.plus(2u))
    val b: Byte = 1.plus(1)
    println(b)
}

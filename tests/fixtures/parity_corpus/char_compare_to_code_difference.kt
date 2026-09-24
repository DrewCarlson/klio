// kotlinc 2.4.20 compiles `Char.compareTo` to `Intrinsics.compare`, which
// returns the sign, as `Integer.compare`/`Long.compare` do for `Int`/`Long`:
// `'a'.compareTo('c')` is -1, not the code difference.
fun main() {
    println('a'.compareTo('c'))
    println('c'.compareTo('a'))
    println('a'.compareTo('a'))
    println('A'.compareTo('a'))
    println(1.compareTo(5))
    println(5.compareTo(1))
    println((1L).compareTo(5L))
    println(listOf('c', 'a', 'b').sorted())
    println('a' < 'c')
    println('c' >= 'a')
}

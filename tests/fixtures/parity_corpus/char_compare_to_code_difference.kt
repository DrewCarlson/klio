// kotlinc compiles `Char.compareTo` to `Character.compare`, which returns the
// code difference. `Int`/`Long` compile to `Integer.compare`/`Long.compare`,
// which return the sign.
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

// A property reference to a built-in type's property (`String::length`,
// `IntArray::size`) is a function value like any other: passed to `map`,
// called through `get`, or bound to a receiver.
val String.shout get() = uppercase() + "!"

fun main() {
    println(listOf("abc", "de", "f").map(String::length))
    println(listOf("hi", "yo").map(String::shout))
    val ints = intArrayOf(1, 2, 3)
    println(IntArray::size.get(ints))
    println(with(ints, IntArray::size))
    val len = "kotlin"::length
    println(len())
}

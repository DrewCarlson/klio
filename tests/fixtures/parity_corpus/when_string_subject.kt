// A `when` over a String subject with constant String branches lowers to a
// switch keyed on the string constants; each key must compare by content,
// not fall through to `else`.
fun classify(v: String): String = when (v) {
    "*" -> "star"
    "foo", "bar" -> "foobar"
    "" -> "empty"
    else -> "other:$v"
}

fun main() {
    println(classify("*"))
    println(classify("foo"))
    println(classify("bar"))
    println(classify(""))
    println(classify("baz"))
}

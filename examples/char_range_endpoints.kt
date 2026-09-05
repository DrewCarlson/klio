// A range over characters keeps its element type everywhere: the endpoints
// are `Char`s, `toString` renders the characters (`a..c`, `a..e step 2`,
// `c downTo a step 1`, kotlinc's CharProgression.toString), `contains`
// takes a `Char` whether written as `in` or as a call, and iteration,
// `reversed`, `until`, `step` and `downTo` all stay character-typed.
fun main() {
    val r = 'a'..'c'
    println(r)
    println(r.first)
    println(r.last)
    println(r.first is Char)
    println(r.contains('b'))
    println('b' in r)
    println('z' in r)
    println('a' until 'd')
    println('c' downTo 'a')
    println('a'..'e' step 2)
    println(('a'..'e' step 2).toList())
    println(r.reversed())
    println(r.map { it.uppercaseChar() })
    val sb = StringBuilder()
    for (c in 'x'..'z') sb.append(c)
    println(sb)
    println(CharRange('a', 'c') == r)
    println(CharRange.EMPTY.isEmpty())
    println(('A'..'C').joinToString("|"))
}

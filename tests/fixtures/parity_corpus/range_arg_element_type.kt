// `a..b` names a range class from its endpoints, so a local bound to one
// (and a loop variable drawn from it) keeps a receiver.
fun main() {
    val r = 1..5
    println(r.last.toLong().toString())
    val cr = 'a'..'e'
    println(cr.last.code.toString())
    val lr = 1L..4L
    println(lr.first.toString())

    var acc = 0L
    for (i in 0..3) acc += i.toLong()
    println(acc.toString())

    val letters = mutableListOf<String>()
    ('x'..'z').forEach { c -> letters.add(c.toString()) }
    println(letters.joinToString(""))
}

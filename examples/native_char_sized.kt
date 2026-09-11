// `Char` and the narrow integer kinds compiled to C. Machine-wise they are
// integers, but a Char prints as a character and a Short or Byte renders as
// itself, so the box carries the kind; arithmetic on any of them produces an
// Int, as Kotlin specifies.
fun main() {
    val c = 'A'
    println(c)
    println(c.code)

    val s: Short = 7
    val b: Byte = 3
    println(s)
    println(b)
    println(s + b)

    var i = 0
    var total = 0
    while (i < 5) {
        total = total + s + b
        i = i + 1
    }
    println(total)
    println("char=" + c + " short=" + s + " byte=" + b)
}

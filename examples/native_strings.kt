// Strings compiled to C. A string is a reference like any other — it lives in
// the frame the function publishes, so the collector can see it — and every
// value prints through the runtime's own renderer, so compiled output cannot
// drift from interpreted output.
class Tag(val name: String, val n: Int)

fun greet(who: String): String = "hello, " + who

fun main() {
    val a = "hello"
    val b = "world"
    println(a)
    println(a + " " + b)
    println(a.length)
    println(greet(b))

    val n = 42
    println("n=$n")
    println("mixed: " + n + " " + 1.5 + " " + true)

    val t = Tag("tag", 7)
    println(t.name + "/" + t.n)

    var acc = ""
    var i = 0
    while (i < 5) {
        acc = acc + i
        i = i + 1
    }
    println(acc)
    println(acc.length)
}

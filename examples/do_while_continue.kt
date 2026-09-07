// `continue` inside a `do … while` loop jumps to the condition, so the loop
// still terminates, and a `continue` chosen inside a `when` branch of a
// `for` or `while` body does the same.
fun main() {
    var i = 0
    do continue while (i++ < 3)
    println(i)
    var k = 0
    var s = ""
    while (k < 6) {
        ++k
        when {
            k % 2 == 0 -> continue
        }
        s += "$k;"
    }
    println(s)
    var n = 0
    do {
        n++
        if (n == 2) continue
        print("$n ")
    } while (n < 4)
    println()
}

// An outer loop whose body calls a function that itself runs its own inner
// loop over the outer loop's current value.
fun inner(n: Int): Int {
    var t = 0
    var a = 0
    while (a < 1000) {
        t = (t + a * n) and 0xffffff
        a = a + 1
    }
    return t
}

fun main() {
    var s = 0
    var i = 0
    while (i < 5000) {
        s = (s + inner(i)) and 0x7fffffff
        i = i + 1
    }
    println("s=$s")
}

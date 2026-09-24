// Storing into and loading from a `HashMap<Int, Int>` in a loop: `map[key] =
// value`, then `map[key] ?: default` where about half the keys are absent, so
// a missing key reads back as null and falls through to the Elvis default.
fun main() {
    val m = HashMap<Int, Int>()
    var i = 0
    while (i < 4000) {
        m[i] = i * 2
        i = i + 1
    }

    var s = 0L
    var j = 0
    while (j < 8000) { // half the keys are absent -> null -> Elvis default
        s = s + (m[j] ?: -1).toLong()
        j = j + 1
    }

    println(s)
}

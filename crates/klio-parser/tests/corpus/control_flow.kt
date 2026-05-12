fun main() {
    val x = 5
    val sign = if (x > 0) 1 else if (x < 0) -1 else 0

    var i = 0
    while (i < 10) {
        if (i == 5) break
        if (i == 3) {
            i = i + 1
            continue
        }
        i = i + 1
    }

    for (k in 1..3) {
        println(k)
    }

    fun early(): Int {
        return 7
    }
}

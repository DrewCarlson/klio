fun main() {
    var s = 0L
    var i = 0
    while (i < 100000) {
        s += i.toLong()
        i += 1
    }
    println(s)
}

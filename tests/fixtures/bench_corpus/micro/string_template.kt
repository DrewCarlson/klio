fun main() {
    var n = 0
    var i = 0
    while (i < 3000) {
        val s = "i=$i sq=${i * i}"
        n += s.length
        i += 1
    }
    println(n)
}

fun main() {
    var xs: List<Int> = emptyList()
    var i = 0
    while (i < 300) {
        xs = xs + i
        i += 1
    }
    var s = ""
    var j = 0
    while (j < 200) {
        s = s + "x"
        j += 1
    }
    println("${xs.size},${s.length}")
}

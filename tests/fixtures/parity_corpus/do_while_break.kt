fun main() {
    var i = 0
    do {
        if (i == 3) break
        println(i)
        i += 1
    } while (true)
    var j = 0
    do {
        j += 1
        if (j % 2 == 0) continue
        println("odd $j")
    } while (j < 5)
    println("done")
}

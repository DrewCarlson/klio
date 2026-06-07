fun main() {
    var i = 0
    outer@ do {
        var j = 0
        do {
            if (j == 2 && i == 1) break@outer
            println("$i,$j")
            j += 1
        } while (j < 3)
        i += 1
    } while (i < 5)
    println("done")
}

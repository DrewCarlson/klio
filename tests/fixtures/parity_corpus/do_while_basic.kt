fun main() {
    var i = 0
    do {
        println(i)
        i += 1
    } while (i < 3)
    // Body must execute at least once even when condition is false.
    var n = 10
    do {
        println("once n=$n")
        n += 1
    } while (n < 0)
    println("done")
}

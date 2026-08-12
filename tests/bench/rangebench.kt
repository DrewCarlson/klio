fun main() {
    var s = 0L
    for (rep in 1..20) {
        for (i in 1..1_000_000) s += i
        for (i in 1_000_000 downTo 1 step 3) s += i
        var j = 0
        while (j < 100) { for (c in 'a'..'z') s += c.code; j++ }
    }
    println("sum=$s")
}

class Acc(var sum: Int = 0) {
    operator fun plusAssign(x: Int) {
        sum += x
    }
    operator fun minusAssign(x: Int) {
        sum -= x
    }
}

fun main() {
    val a = Acc(10)
    a += 5
    a -= 2
    println(a.sum)
}

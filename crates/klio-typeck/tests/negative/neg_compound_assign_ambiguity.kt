class Acc(var n: Int) {
    operator fun plus(other: Acc): Acc = Acc(n + other.n)
    operator fun plusAssign(other: Acc) { n += other.n }
}

fun main() {
    var a = Acc(1)
    a += Acc(2)
}

class Box(val a: Int, val b: Int) {
    override fun equals(other: Any?): Boolean =
        other is Box && a == other.a && b == other.b

    override fun hashCode(): Int = a * 31 + b
}

fun describe(x: Any?): String {
    if (x is String && x.length > 3) return "long: ${x.uppercase()}"
    if (x !is String || x.isEmpty()) return "empty-or-not-string"
    return "short: $x"
}

fun main() {
    println(Box(1, 2) == Box(1, 2))
    println(Box(1, 2) == Box(1, 3))
    println(describe("hello"))
    println(describe("hi"))
    println(describe(42))
    println(describe(""))
}

fun lengthOrZero(s: String?): Int {
    require(s != null)
    return s.length
}

fun main() {
    println(lengthOrZero("hello"))
}

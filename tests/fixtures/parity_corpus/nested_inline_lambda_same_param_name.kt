private inline fun String.digitAt(index: Int, onError: String.(Int) -> Int): Int {
    if (index >= length) return onError(index)
    return this[index].code
}

internal inline fun String.parseAll(endIndex: Int, onError: String.(Int) -> Int): Int {
    var result = 0
    for (index in 0 until endIndex) {
        result = result + digitAt(index) { this.onError(it) }
    }
    return result
}

internal inline fun outer(s: String, onError: (String, String, Int) -> Int): Int {
    val msg = "bad"
    return s.parseAll(4) { onError(this, msg, it) }
}

internal inline fun firstBad(s: String, onError: (String, Int) -> Int): Int {
    return s.parseAll(4) { onError(this, it) }
}

fun main() {
    println(outer("ab") { p, q, i -> if (p.length + q.length > 0) -i else i })
    println(firstBad("ab") { p, i -> p.length * 100 + i })
}

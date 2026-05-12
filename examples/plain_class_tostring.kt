// Default `Any.toString` for plain (non-data, non-enum, non-object) classes
// renders as `ClassName@<hex>`. The exact hex differs between runs (kotlinc-native
// uses a real heap address; ktc uses a monotonic counter), so this example only
// prints structural assertions about the rendered string.

class Box(val x: Int)

fun isHex(c: Char): Boolean {
    val code = c.code
    if (code >= 48 && code <= 57) return true
    if (code >= 97 && code <= 102) return true
    if (code >= 65 && code <= 70) return true
    return false
}

fun main() {
    val b = Box(7)
    val s = b.toString()

    val at = s.indexOf('@')
    println("startsWithName=${s.startsWith("Box@")}")
    println("hasAt=${at >= 0}")

    val tail = if (at >= 0) s.substring(at + 1) else ""
    println("tailNonEmpty=${tail.isNotEmpty()}")

    var allHex = true
    var i = 0
    while (i < tail.length) {
        if (!isHex(tail[i])) { allHex = false }
        i = i + 1
    }
    println("tailAllHex=$allHex")

    // Different instances of the same class produce different toString values.
    val b1 = Box(1)
    val b2 = Box(1)
    println("identityDiffers=${b1.toString() != b2.toString()}")
}

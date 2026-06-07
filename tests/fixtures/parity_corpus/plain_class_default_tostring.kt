// Default `Any.toString` for plain (non-data, non-enum, non-object) classes
// renders as `ClassName@<hex>`. The exact hex digits depend on heap addresses
// in kotlinc-native and on a monotonic counter in ktc, so we only assert the
// structure of the rendered string — never the hex value itself.

class Box(val x: Int)
class Holder
open class Animal(val name: String)
class Dog(name: String) : Animal(name)

fun isHex(c: Char): Boolean {
    val code = c.code
    if (code >= 48 && code <= 57) return true        // 0-9
    if (code >= 97 && code <= 102) return true       // a-f
    if (code >= 65 && code <= 70) return true        // A-F
    return false
}

fun describe(prefix: String, s: String) {
    val at = s.indexOf('@')
    println("prefix=${s.startsWith("${prefix}@")}")
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
}

fun main() {
    val b = Box(7)
    describe("Box", b.toString())

    val h = Holder()
    describe("Holder", h.toString())

    val d = Dog("Rex")
    describe("Dog", d.toString())

    // Two different instances of the same class produce different
    // toString values (different identity).
    val b1 = Box(1)
    val b2 = Box(1)
    println("differs=${b1.toString() != b2.toString()}")
}

// A Long-typed property initialized with a bare Int literal stores a Long,
// in every property position: top-level, object, companion, constructor
// default, and class body field.
package examples.longprop

var top: Long = 0

object Holder {
    var member: Long = 0
}

class Box(var fromCtor: Long = 0) {
    var field: Long = 1
    companion object {
        var shared: Long = 2
    }
}

fun main() {
    val b = Box()
    println(top::class.simpleName)
    println(Holder.member::class.simpleName)
    println(b.fromCtor::class.simpleName)
    println(b.field + 9_000_000_000L)
    println(Box.shared + 9_000_000_000L)
}

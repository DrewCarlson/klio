// A superclass body-property initializer references the superclass's
// own primary-ctor params, which are the super-constructor call's
// evaluated arguments — not the subclass's args. When the subclass
// adds or reorders params (here `extra` between `id` and `pointers`),
// the parent initializer must still see the right values.
abstract class Seg(val id: Long, pointers: Int) {
    val packed: Int = pointers shl 4
    val raw: Int = pointers
}

class Leaf(id: Long, extra: String, pointers: Int) : Seg(id, pointers) {
    val tag: String = extra
}

fun main() {
    val l = Leaf(-1L, "x", 3)
    println(l.packed)
    println(l.raw)
    println(l.tag)
    println(l.id)
}

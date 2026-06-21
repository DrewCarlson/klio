// Hot loop writing scalar fields of a loop-invariant object each iteration (read,
// compute, store back). The loop JIT compiles the field stores as direct writes
// into the boxed receiver's stored fields (plain stored properties — no custom
// setter), so read/modify/write of `Int` and `Long` fields runs natively. Output
// must match with the JIT off (default) or on (KLIO_JIT=1).
class Point(var x: Int, var y: Long)

fun main() {
    val p = Point(0, 0)
    var i = 0
    while (i < 200000) {
        p.x = p.x + i
        p.y = p.y + i.toLong()
        i = i + 1
    }
    println("x=${p.x} y=${p.y}")
}

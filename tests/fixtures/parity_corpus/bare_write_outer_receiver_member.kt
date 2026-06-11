// A bare-name write inside a nested receiver lambda resolves against the
// implicit receivers innermost-first, exactly like the read side: `label`
// is not a member of the inner `Gadget` receiver, so the write reaches the
// outer `with(o)` receiver's member, never a synthetic global.
class Outer {
    var label: String = "init"
}

class Gadget {
    var size: Int = 0
}

fun main() {
    val o = Outer()
    with(o) {
        with(Gadget()) {
            label = "from-inner"
            size = 7
            println(size)
        }
    }
    println(o.label)
}

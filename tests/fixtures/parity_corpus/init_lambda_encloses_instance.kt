// A lambda created inside a property initializer or an `init` block sees the
// instance under construction as an enclosing receiver. A closure snapshots the
// receiver chain where it is CREATED, and the initializer thunk received the
// instance only as its `this` parameter — never pushing it onto that chain — so
// a bare name inside a nested lambda saw the inner receiver alone and fell
// through to the globals.
class Box {
    fun onDone(f: () -> Unit) { f() }
}

class Holder {
    private val tag = "T"
    var seen: String = "none"
    private val fromProp = Box().apply { onDone { seen = tag + "/prop" } }

    var viaInit: String = "none"
    init {
        Box().apply { onDone { viaInit = tag + "/init" } }
    }

    fun result(): String = seen + " " + viaInit
}

fun main() {
    println(Holder().result())
}

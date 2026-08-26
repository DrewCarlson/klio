// Bare member-extension calls take their two receivers from the implicit
// tower independently: the dispatch receiver is the innermost receiver whose
// class owns the member extension, the extension receiver the innermost one
// satisfying the declared receiver type. A bare name inside such a body reads
// the extension receiver's member before the enclosing class's.

interface Scope {
    val tag: String
}

interface Wide : Scope

class WideImpl(override val tag: String) : Wide

interface Measurer {
    fun Scope.measure(): String
}

class Sizer : Measurer {
    override fun Scope.measure(): String = "sized:" + tag
}

class Coordinator(override val tag: String) : Scope {
    private val measurer: Measurer = Sizer()

    // `with(measurer) { measure() }`: the subject owns the member extension,
    // the coordinator is the extension receiver.
    fun run(): String = with(measurer) { measure() }
}

// A member extension that calls the SAME name on another subject must reach
// that subject's declaration, not re-enter itself.
interface Semantics {
    fun Scope.apply(): String
}

class Leaf : Semantics {
    override fun Scope.apply(): String = "leaf(" + tag + ")"
}

class Branch(private val leaf: Leaf) : Semantics {
    override fun Scope.apply(): String = "branch[" + with(leaf) { apply() } + "]"
}

// The extension receiver's member shadows the enclosing class's same-named one.
class Owner {
    val tag: String = "owner"

    private fun Scope.readTag(): String = tag

    fun read(s: Scope): String = with(s) { readTag() }
}

fun main() {
    println(Coordinator("coord").run())
    println(with(Branch(Leaf())) { WideImpl("w").apply() })
    println(Owner().read(WideImpl("scope")))
}

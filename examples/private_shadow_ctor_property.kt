// A subclass's private ctor property shadowing a base class's same-named
// private stored property keeps BOTH cells: base-class code reads its own.
// The instance builder used to dedup the cells by plain name, so the
// subclass's owner-mangled shadow displaced the base's cell and any
// base-method use of it missed (`kotlinx.coroutines.flow.callbackFlow`'s
// CallbackFlowBuilder/ChannelFlowBuilder pair is exactly this shape).
class Scope {
    fun hello() = println("hello")
}

open class Base(private val block: Scope.() -> Unit) {
    open fun go(scope: Scope) = block(scope)
}

class Sub(private val block: Scope.() -> Unit) : Base(block) {
    override fun go(scope: Scope) {
        super.go(scope)
        println("sub done")
    }
}

fun main() {
    Sub { hello() }.go(Scope())
}

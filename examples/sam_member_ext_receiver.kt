// A fun interface whose single abstract method is a member extension:
// the SAM lambda's body is scoped with the extension receiver as `this`,
// so a bare interface-member call inside the lambda resolves against it.

interface Scope {
    val density: Float

    fun layout(width: Int, height: Int, block: () -> Unit): String {
        block()
        return "laid-out:" + width + "x" + height + "@" + density
    }
}

fun interface Policy {
    fun Scope.measure(w: Int, h: Int): String
}

class ScopeImpl : Scope {
    override val density = 2f
}

fun runPolicy(policy: Policy, scope: Scope, w: Int, h: Int): String =
    with(policy) { scope.measure(w, h) }

fun main() {
    val policy = Policy { w, h ->
        layout(w, h) {
            println("placing " + w + "x" + h)
        }
    }
    println(runPolicy(policy, ScopeImpl(), 30, 40))
}

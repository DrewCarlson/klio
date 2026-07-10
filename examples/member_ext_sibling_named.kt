// A member-extension invoked with named arguments seeds its owner as an
// enclosing receiver, so a bare SIBLING member-extension call inside the
// body resolves — the PlacementScope.placeWithLayer ->
// placeApparentToRealOffset shape.

class Target(val label: String)

abstract class Scope {
    val offset = 10

    fun Target.placeInner(x: Int): String = "$label@${x + offset}"

    fun Target.placeOuter(x: Int = 0, extra: Int = 0): String = placeInner(x + extra)
}

class ScopeImpl : Scope()

fun run(scope: Scope, t: Target): String = with(scope) { t.placeOuter(extra = 5) }

fun main() {
    println(run(ScopeImpl(), Target("box")))
}

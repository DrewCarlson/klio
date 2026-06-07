// At an unqualified call inside a receiver scope, a member of the
// (smart-cast) implicit receiver outranks a same-named top-level
// extension — even when the static receiver type is a supertype that
// lacks the member while the runtime value (a subtype) declares it.
// Mirrors upstream `Continuation.resumeCancellableWithInternal`
// dispatching to the `DispatchedContinuation` member rather than the
// `Continuation.resumeCancellableWith` extension (which would recurse
// unboundedly).

interface Box {
    fun label(): String
}

class Plain : Box {
    override fun label() = "plain"
}

class Special : Box {
    override fun label() = "special"
    fun pick(tag: String): String = "member:$tag:${label()}"
}

fun Box.pick(tag: String): String = pickInternal(tag)

fun Box.pickInternal(tag: String): String = when (this) {
    is Special -> pick(tag)
    else -> "ext:$tag:${label()}"
}

fun main() {
    val s: Box = Special()
    println(s.pick("a"))
    val p: Box = Plain()
    println(p.pick("b"))
    val list: List<Box> = listOf(Special(), Plain(), Special())
    for (b in list) println(b.pick("x"))
}

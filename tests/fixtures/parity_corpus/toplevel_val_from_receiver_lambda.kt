// A bare reference to a top-level (file-scope) property inside a receiver
// lambda resolves to the file-scope global, not an implicit `this.<name>`
// member of the lambda's (unrelated) receiver.
private val TAG = "module-tag"

class Ctx {
    val tag = "ctx-tag"
}

fun Ctx.render(block: Ctx.() -> String): String = block()

fun main() {
    val c = Ctx()
    // `TAG` is the top-level val; `tag` is the receiver's member.
    println(c.render { TAG })
    println(c.render { tag })
    println(c.render { "$TAG/$tag" })
}

// A lambda created inside the FIRST of two same-named local functions
// re-invokes the enclosing function itself: the later sibling declaration
// must not capture the reference (Kotlin scopes the call to declarations
// visible at that point in the body).

fun main() {
    var replay: (() -> Unit)? = null

    fun show(tag: String) {
        if (replay == null) {
            replay = { show("replayed") }
        }
        println("show/1: " + tag)
    }

    fun show() {
        println("show/0")
    }

    show("direct")
    show()
    replay?.invoke()
}

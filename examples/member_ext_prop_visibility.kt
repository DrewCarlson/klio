// A member-extension property is visible only where its owner class is a
// dispatch receiver (its own members, a `with(owner)` block) or where a
// companion member extension is imported. Outside that scope the same
// (receiver, name) resolves to the file's top-level extension instead.

import kotlin.time.Duration.Companion.seconds

class Owner {
    private val String.decorated: String
        get() = "[" + this + "]"

    fun use(s: String): String = s.decorated
}

class Helper {
    val String.tagged: String
        get() = "<" + this + ">"
}

class Bystander {
    fun tryUse(s: String): String = s.decorated
}

private val String.decorated: String
    get() = "{" + this + "}"

fun main() {
    println(Owner().use("a"))
    println(Bystander().tryUse("b"))
    with(Helper()) {
        println("c".tagged)
    }
    println(30.seconds)
}

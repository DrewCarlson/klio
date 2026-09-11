// A `data class` compiled to C renders and compares by its primary
// constructor's properties, which is the runtime's own renderer doing the work
// once the emitted class descriptor records which fields those are. Two
// renderers would be two chances to drift.
//
// A property declared without storage where the receiver stands — an
// interface's `val` — is read through a dispatcher on the receiver's class,
// exactly as a method is.
data class Point(val x: Int, val y: String)

interface Named {
    val label: String
    fun describe(): String = "<" + label + ">"
}

class Tagged(val n: Int) : Named {
    override val label get() = "t" + n
}

class Fixed : Named {
    override val label = "fixed"
}

fun show(n: Named): String = n.label + " " + n.describe()

fun main() {
    val a = Point(1, "a")
    val b = Point(1, "a")
    val c = Point(2, "b")
    println(a)
    println(a == b)
    println(a == c)

    println(show(Tagged(7)))
    println(show(Fixed()))
}

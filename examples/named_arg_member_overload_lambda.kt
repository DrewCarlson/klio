// A bare call with named arguments and a trailing receiver lambda must bind the
// implicit receiver's member overload, not a same-named global whose parameter
// list cannot take the named arguments. The global `layout(measure:)` here takes
// a MeasureScope-receiver lambda; if the named-argument mapping ever "succeeds"
// against it by dropping the unmatched names, the placement lambda records the
// wrong receiver head and `place` dispatches against the wrong scope.

class Placement {
    fun place(x: Int) {
        println("place $x")
    }
}

interface Scope {
    fun layout(width: Int, height: Int, block: Placement.() -> Unit): String {
        Placement().block()
        return "laid ${width}x$height"
    }

    fun place(x: Int) {
        println("WRONG scope place $x")
    }
}

class Modifier2

fun Modifier2.layout(measure: Scope.(Int) -> String): String {
    val s = object : Scope {}
    return s.measure(1)
}

fun runScope(body: Scope.() -> String): String {
    val s = object : Scope {}
    return s.body()
}

fun main() {
    val out = runScope {
        layout(width = 3, height = 4) { place(7) }
    }
    println(out)
    println(Modifier2().layout { n -> "measured $n" })
}

// Dotted-head resolution INSIDE receiver lambdas: a package-qualified head
// (`kotlin.math.*`) flattens to a global, while a dotted access whose head is
// a member of the lambda's implicit receiver walks `this`. The same head must
// resolve the same way regardless of lambda nesting depth.

@DslMarker
annotation class GridMarker

class Cell {
    var content: String = ""
    var weight: Int = 0
}

@GridMarker
class Row {
    val cell = Cell()
    val cells = mutableListOf<String>()
    fun fill(block: Row.() -> Unit) { block() }
    fun render(): String = cells.joinToString(",")
}

fun grid(block: Row.() -> Unit): Row {
    val r = Row()
    r.block()
    return r
}

fun main() {
    val r = grid {
        // `cell` is a member of the receiver `Row` — a member walk, not a
        // package head.
        cell.content = "hello"
        cell.weight = 3
        // `kotlin.math` is a package-qualified global head — flattens to an
        // FQN load even though we are inside a receiver lambda.
        val w = kotlin.math.max(cell.weight, 2)
        cells.add("${cell.content}:$w")
        // A nested receiver lambda: the same two kinds of head still resolve
        // identically one level deeper.
        fill {
            cell.content = "world"
            val m = kotlin.math.min(cell.weight, 1)
            cells.add("${cell.content}:$m")
        }
    }
    println(r.render())

    // `apply` exposes the receiver as `this`; a dotted head that is a member
    // of the receiver still walks `this`, and a package head still flattens.
    val cfg = Cell().apply {
        content = "cfg"
        weight = kotlin.math.abs(-7)
    }
    println("${cfg.content}=${cfg.weight}")

    // `with` over a receiver, dotted package head inside.
    val s = with(Cell()) {
        content = "w"
        weight = kotlin.math.max(10, 20)
        "${content}:${weight}"
    }
    println(s)
}

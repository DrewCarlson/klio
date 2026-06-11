// A bare-name write from a lambda inside an inner-class method reaches the
// enclosing class's property through `this@Owner` — the dispatch receiver
// brings its class-nesting tower into scope, for writes as for reads.
class Owner {
    var status: String = "init"

    inner class Pocket {
        fun update() {
            listOf(1).forEach { status = "from-lambda" }
        }

        fun updateDirect() {
            status = "direct"
        }
    }
}

fun main() {
    val o = Owner()
    o.Pocket().update()
    println(o.status)
    o.Pocket().updateDirect()
    println(o.status)
}

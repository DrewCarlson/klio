// `this@label` inside nested receiver lambdas binds the receiver of the
// scope function named by the label, not the innermost `this`. The outer
// `this@with` must survive an inner `apply` displacing the bare receiver,
// the receiver may be a primitive, and a same-named inner label shadows
// the outer one.

class Box(val tag: String) {
    fun render(n: Int): String {
        val sb = StringBuilder()
        with(n) {                    // this@with : Int = n
            sb.apply {               // this@apply : StringBuilder
                append(this@Box.tag) // enclosing class receiver
                append("/")
                append(this@with)    // outer label, primitive receiver
            }
        }
        return sb.toString()
    }
}

fun shadow(): String {
    val outer = StringBuilder("O")
    val inner = StringBuilder("I")
    outer.apply {
        inner.apply {
            this@apply.append("x")   // innermost `apply` shadows the outer
        }
    }
    return outer.toString() + "|" + inner.toString()
}

fun prim(): Int = with(7) { this@with * 6 }

fun main() {
    println(Box("T").render(42))
    println(shadow())
    println(prim())
}

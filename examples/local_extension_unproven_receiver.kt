// A local extension function — declared inside a function body — applies to
// any receiver of its declared type, including one the call site cannot type
// statically. An overload family that answers a different type per argument
// type (`abs`, `min`, `max`) must not claim a return type when the argument's
// own type is unproven: a guess there silently drops the extension.
//
// Run with: klio run examples/local_extension_unproven_receiver.kt

import kotlin.math.abs
import kotlin.math.max
import kotlin.math.min

class Report {
    private val stepped = (-3661..3661 step 1831)
    private val plain = (0..3)
    private val values = listOf(-2, 7)

    fun overRange(): String {
        fun Int.pad() = toString().padStart(3, '0')
        var out = ""
        for (t in stepped) out += abs(t / 3600).pad() + ";"
        return out
    }

    fun overPlainRange(): String {
        fun Int.pad() = toString().padStart(2, '0')
        var out = ""
        for (t in plain) out += abs(t).pad()
        return out
    }

    fun overList(): String {
        fun Int.tag() = "<" + this + ">"
        return values.joinToString("") { abs(it).tag() }
    }

    // The same call with the argument's type written out.
    fun typed(): String {
        fun Int.tag() = "<" + this + ">"
        val n: Int = abs(-9)
        return n.tag() + abs(-9).tag()
    }

    // Other members of the scalar family.
    fun family(): String {
        fun Int.tag() = "i" + this
        fun Double.tag() = "d" + this
        var out = ""
        for (t in plain) out += max(t, 1).tag() + min(t, 1).tag()
        return out
    }

    // The family still types exactly when the argument does.
    fun doubles(): String {
        fun Double.tag() = "d" + this
        return abs(-1.5).tag() + max(1.5, 2.5).tag()
    }
}

fun main() {
    val r = Report()
    println("range  = " + r.overRange())
    println("plain  = " + r.overPlainRange())
    println("list   = " + r.overList())
    println("typed  = " + r.typed())
    println("family = " + r.family())
    println("double = " + r.doubles())
}

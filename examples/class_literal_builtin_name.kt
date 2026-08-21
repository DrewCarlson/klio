// A user declaration owns its simple name at its own site, even when a
// builtin shares it. `Target`, `Retention` and `Deprecated` all name
// declarations in `kotlin`, and a class literal on the user's declaration must
// answer the USER's class — not the builtin the simple-name index happens to
// hold.
//
// Run with: klio run examples/class_literal_builtin_name.kt

object Target {
    val tag = "user object"
}

class Retention(val n: Int)

data class Deprecated(val why: String)

annotation class Mark

fun main() {
    println("object value = " + Target.tag)
    println("object class = " + Target::class.simpleName)
    println("object same  = " + (Target::class == (Target as Any)::class))

    val r = Retention(3)
    println("class value  = " + r.n)
    println("class class  = " + Retention::class.simpleName)
    println("class same   = " + (Retention::class == (r as Any)::class))

    val d = Deprecated("obsolete")
    println("data value   = " + d)
    println("data class   = " + Deprecated::class.simpleName)
    println("data same    = " + (Deprecated::class == (d as Any)::class))

    // An unshadowed name still resolves the same way.
    println("plain class  = " + Mark::class.simpleName)
}

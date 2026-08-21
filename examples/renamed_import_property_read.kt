// A renamed import (`import a.b as c`) binds the spelling `c` to the
// declaration `a.b`, whatever kind it is. A bare READ of that spelling is the
// imported declaration — not a member of whatever receiver happens to be in
// scope, and not an unresolved name.
//
// Run with: klio run examples/renamed_import_property_read.kt

import kotlin.math.PI as circleRatio
import kotlin.math.abs as magnitude

// A member with the SAME name as the alias must still win inside the class:
// the import only decides names nothing in scope claims.
class Holder(val circleRatio: String) {
    fun ownMember(): String = circleRatio
    fun imported(): String = "" + magnitude(-3)
}

object Config {
    val mode = "on"
}

fun main() {
    // A top-level property through an alias, read bare.
    println("property = " + (circleRatio > 3.14 && circleRatio < 3.15))
    // A function and a classifier through aliases, for comparison.
    println("function = " + magnitude(-7))

    // The read works inside a class body, where a member probe runs first.
    println("member   = " + Holder("mine").ownMember())
    println("aliasIn  = " + Holder("mine").imported())

    // And inside a lambda, where the enclosing receiver is a different type.
    println("inLambda = " + listOf(-1, 2).map { magnitude(it) })
    println("scoped   = " + with(Config) { mode + "/" + magnitude(-4) })

    // A qualified reference to the same declaration agrees with the alias.
    println("agrees   = " + (circleRatio == kotlin.math.PI))
}

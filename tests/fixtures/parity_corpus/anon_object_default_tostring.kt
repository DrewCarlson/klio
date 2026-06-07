// Default `toString` for anonymous-object instances renders with an
// implementation-detail synthetic name plus `@<hex>`. kotlinc-native produces
// e.g. `main$o$1@432c040`; ktc produces a `<no name provided>@<hex>` form.
// We only assert structural facts about the rendered string.
//
// When the source declares its own `toString` override, that override wins —
// the synthetic form is invisible to the user.

fun main() {
    val a = object { val x = 1 }
    val s = a.toString()
    println("hasAt=${s.indexOf('@') >= 0}")
    println("tailNonEmpty=${s.substring(s.indexOf('@') + 1).isNotEmpty()}")

    val withToString = object {
        val x = 1
        override fun toString(): String = "explicit"
    }
    println(withToString)

    // Two anonymous instances render to different strings (identity differs).
    val o1 = object { val x = 1 }
    val o2 = object { val x = 1 }
    println("differs=${o1.toString() != o2.toString()}")
}

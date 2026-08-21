// Two files in one package each declare a `private fun` of the same name and
// signature. Kotlin scopes each to its own file, so every reference — a bare
// call, a `::` reference, a call from inside a lambda — binds the caller's
// own declaration.
//
// Run with: klio run examples/file_private_collision/alpha.kt examples/file_private_collision/beta.kt examples/file_private_collision/main.kt

private fun label(id: Long, tag: String): String = "alpha:$tag#$id"

private val ORIGIN = "A"

class Alpha {
    fun direct(): String = label(1L, ORIGIN)

    fun viaRef(): String {
        val f = ::label
        return f(2L, ORIGIN)
    }

    fun fromLambda(): String {
        var out = ""
        run { out = label(3L, ORIGIN) }
        return out
    }

    fun refFromLambda(): String = listOf(4L).map(::labelOne).first()

    private fun labelOne(id: Long): String = label(id, ORIGIN)
}

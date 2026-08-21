private fun label(id: Long, tag: String): String = "beta:$tag#$id"

private val ORIGIN = "B"

class Beta {
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

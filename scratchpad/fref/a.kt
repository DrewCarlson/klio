private fun makeIt(id: Long, tag: String): String = "A:$tag#$id"
private val TAG = "A"

class HolderA {
    fun direct(): String = makeIt(1L, TAG)
    fun ref(): String {
        val f = ::makeIt
        return f(2L, TAG)
    }
    fun refInLambda(): String {
        var r = ""
        run { r = listOf(3L).map { id -> (::makeIt)(id, TAG) }.first() }
        return r
    }
    fun callInLambda(): String {
        var r = ""
        run { r = makeIt(4L, TAG) }
        return r
    }
    fun refAsArg(): String = listOf(5L).map { makeIt(it, TAG) }.first()
}

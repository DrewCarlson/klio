// A callable reference follows the rule a call does: a member the code
// cannot see hides nothing. Outside `Cache`, `c::find` is the file's
// private `Cache.find` extension, bound, unbound, typed by an expected
// function type, or adapted to a suspend one; inside `Cache`, the private
// member answers.
class Cache {
    private fun find(a: String): String = "member $a"

    private suspend fun findAndRefresh(a: String, b: String): String? = "member $a$b"

    fun inside(): (String) -> String = this::find

    suspend fun insideSuspend(): String? = run(this::findAndRefresh)
}

private fun Cache.find(a: String): String = "extension $a"

private fun Cache.findAndRefresh(a: String, b: String): String? = "extension $a$b"

fun apply1(f: (String) -> String): String = f("x")

suspend fun run(f: suspend (String, String) -> String?): String? = f("a", "b")

suspend fun main() {
    val c = Cache()
    println(apply1(c::find))
    val g: (String) -> String = c::find
    println(g("y"))
    println(Cache::find.invoke(c, "z"))
    println(c.find("call"))
    println(c.inside()("in"))
    println(c.insideSuspend())
    println(run(c::findAndRefresh))
}
